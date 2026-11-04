#!/usr/bin/env bash
set -euo pipefail

: "${GH_TOKEN:?GitHub App token is required}"
: "${JEV_API_KEY:?Configure the JEV_API_KEY Actions secret before enabling automated releases}"
: "${REPOSITORY:?REPOSITORY is required}"
: "${ENGINE_ROOT:?ENGINE_ROOT is required}"

OWNER="${REPOSITORY%%/*}"
REPO="${REPOSITORY#*/}"
STABILIZATION_SECONDS="${STABILIZATION_SECONDS:-900}"
DRY_RUN="${DRY_RUN:-false}"
DIRECT_IMPACT="${DIRECT_IMPACT:-}"
if [[ "$DIRECT_IMPACT" == auto ]]; then DIRECT_IMPACT=""; fi
if [[ -n "$DIRECT_IMPACT" && ! "$DIRECT_IMPACT" =~ ^(major|minor|patch|none)$ ]]; then
  echo "::error::DIRECT_IMPACT must be empty, major, minor, patch or none."
  exit 1
fi
if [[ "$DRY_RUN" != "true" && "$DRY_RUN" != "false" ]]; then
  echo "::error::DRY_RUN must be true or false."
  exit 1
fi
if ! [[ "$STABILIZATION_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "::error::STABILIZATION_SECONDS must be a non-negative integer."
  exit 1
fi
MIN_CONFIDENCE=0.70
MAX_PRS=50
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

queue_size() {
  gh api graphql \
    -f query='query($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        mergeQueue(branch: "main") {
          entries(first: 100) {
            totalCount
            nodes { id position }
          }
        }
      }
    }' \
    -F owner="$OWNER" -F name="$REPO" \
    --jq '.data.repository.mergeQueue.entries.totalCount // 0'
}

echo "Checking merge queue for $OWNER/$REPO..."
before="$(queue_size)"
if [[ "$before" != "0" ]]; then
  echo "Queue has $before entr(y/ies); no release."
  exit 0
fi

echo "Queue is empty. Waiting ${STABILIZATION_SECONDS}s for late enqueues..."
sleep "$STABILIZATION_SECONDS"

after="$(queue_size)"
if [[ "$after" != "0" ]]; then
  echo "Queue now has $after entr(y/ies); no release."
  exit 0
fi

git fetch --force origin main --tags
MAIN_SHA="$(git rev-parse origin/main)"
MARKER_TAG="release-state/processed/$MAIN_SHA"
if [[ "$DRY_RUN" != "true" && "${FORCE_REANALYZE:-false}" != "true" ]] && git show-ref --verify --quiet "refs/tags/$MARKER_TAG"; then
  echo "Main commit $MAIN_SHA was already analyzed; no repeated classification."
  exit 0
fi

mark_processed() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "Dry run: not creating processed marker $MARKER_TAG."
    return 0
  fi
  if ! git show-ref --verify --quiet "refs/tags/$MARKER_TAG"; then
    gh api --method POST "repos/$REPOSITORY/git/refs" \
      -f "ref=refs/tags/$MARKER_TAG" -f "sha=$MAIN_SHA" >/dev/null
  fi
}

needs_review() {
  message="$1"
  echo "::warning::$message"
  {
    echo "### Intelligent release paused for manual review"
    echo
    echo "$message"
    echo
    echo "No release was published. Review the PR metadata and rerun this workflow with force=true when ready."
  } >> "$GITHUB_STEP_SUMMARY"
  mark_processed
  exit 0
}
if [[ "$DRY_RUN" != "true" && "$MAIN_SHA" != "$(git rev-parse HEAD)" ]]; then
  echo "Checkout is not at the latest main commit; a newer push will handle it."
  exit 0
fi
if [[ "$DRY_RUN" == "true" ]]; then
  echo "Dry run enabled: executing this branch's script against current main; no release mutations will be made."
fi

LAST_TAG="$(git tag -l 'v[0-9]*' --sort=-version:refname | head -n 1)"
if [[ -z "$LAST_TAG" ]]; then
  LAST_TAG="${BASELINE_REF:-$(git rev-list --max-parents=0 "$MAIN_SHA" | tail -n 1)}"
  if ! [[ "$LAST_TAG" =~ ^[a-f0-9]{40}$ ]] || ! git merge-base --is-ancestor "$LAST_TAG" "$MAIN_SHA"; then
    echo "::error::Baseline ref must be a full commit SHA in main's history."
    exit 1
  fi
  BASELINE_VERSION="${BASELINE_VERSION:-0.0.0}"
  if ! [[ "$BASELINE_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "::error::Baseline version must be strict SemVer X.Y.Z."
    exit 1
  fi
  MAJOR="${BASH_REMATCH[1]}" MINOR="${BASH_REMATCH[2]}" PATCH="${BASH_REMATCH[3]}"
  echo "No version tag exists; using baseline $LAST_TAG and v$BASELINE_VERSION as version."
else
  if ! [[ "$LAST_TAG" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    echo "::error::Latest version tag '$LAST_TAG' is not strict SemVer vX.Y.Z."
    exit 1
  fi
  MAJOR="${BASH_REMATCH[1]}"
  MINOR="${BASH_REMATCH[2]}"
  PATCH="${BASH_REMATCH[3]}"
fi
TAG_DATE="$(git show -s --format=%cs "$LAST_TAG")"

echo "Last release tag: $LAST_TAG ($TAG_DATE); main: $MAIN_SHA"

# Search by date, then use commit ancestry to exclude PRs already covered by
# the tag. The date search is intentionally inclusive because GitHub search
# filters are day-granular.
gh pr list --state merged --base main \
  --search "merged:>=$TAG_DATE" --limit 1000 \
  --json number,title,body,mergedAt,url,labels,files,mergeCommit > "$TMP/pulls.json"

pull_count="$(jq 'length' "$TMP/pulls.json")"
if (( pull_count >= 1000 )); then
  echo "::error::PR search reached its 1000-result limit; refusing a potentially incomplete release."
  exit 1
fi

jq -c '[.[] | select(.mergeCommit.oid != null)]' "$TMP/pulls.json" > "$TMP/candidates.json"
: > "$TMP/eligible.jsonl"
while IFS= read -r pr; do
  sha="$(jq -r '.mergeCommit.oid' <<< "$pr")"
  if git merge-base --is-ancestor "$LAST_TAG" "$sha" &&
     git merge-base --is-ancestor "$sha" "$MAIN_SHA"; then
    printf '%s\n' "$pr" >> "$TMP/eligible.jsonl"
  fi
done < <(jq -c '.[]' "$TMP/candidates.json")

# Include direct commits as one conservative batch. A full-range diff can
# include PR changes as well, but never hides a direct change from review.
direct_commits=0
while IFS= read -r commit; do
  if ! jq -e --arg commit "$commit" 'any(.[]; .mergeCommit.oid == $commit)' "$TMP/candidates.json" >/dev/null; then
    ((direct_commits+=1))
  fi
done < <(git rev-list --first-parent --reverse "$LAST_TAG..$MAIN_SHA")
if (( direct_commits > 0 )); then
  files_json="$(git diff --name-only "$LAST_TAG" "$MAIN_SHA" | jq -Rsc 'split("\n") | map(select(length > 0) | {path: .})')"
  jq -cn --arg url "https://github.com/$REPOSITORY/compare/$LAST_TAG...$MAIN_SHA" --arg impact "$DIRECT_IMPACT" \
    --argjson files "$files_json" --argjson count "$direct_commits" \
    '{number:0,title:"Direct commits on main",body:("Complete comparison includes " + ($count|tostring) + " direct commit(s), potentially alongside merged PRs."),url:$url,labels:(if $impact == "" then [] else [{name:("release-impact/" + $impact)}] end),files:$files,direct:true}' >> "$TMP/eligible.jsonl"
fi

eligible_count="$(wc -l < "$TMP/eligible.jsonl" | tr -d ' ')"
if (( eligible_count == 0 )); then
  echo "No merged PRs after $LAST_TAG; no release."
  mark_processed
  exit 0
fi
if (( eligible_count > MAX_PRS )); then
  echo "::error::Found $eligible_count unreleased PRs (limit $MAX_PRS); refusing to classify an unexpectedly large batch."
  exit 1
fi

echo "Classifying $eligible_count merged PR(s) with Jev..."
major_count=0
minor_count=0
patch_count=0
none_count=0
review_count=0
: > "$TMP/major.md"
: > "$TMP/minor.md"
: > "$TMP/patch.md"
: > "$TMP/decisions.jsonl"

while IFS= read -r pr; do
  number="$(jq -r '.number' <<< "$pr")"
  title="$(jq -r '.title' <<< "$pr")"
  body="$(jq -r '.body // ""' <<< "$pr")"
  url="$(jq -r '.url' <<< "$pr")"
  labels="$(jq -c '[.labels[].name]' <<< "$pr")"
  files="$(jq -c '[.files[].path]' <<< "$pr")"

  # Maintainers may resolve an ambiguous classification explicitly on the PR.
  overrides="$(jq -c '[.[] | select(test("^release-impact/(major|minor|patch|none)$"))] | unique' <<< "$labels")"
  override_count="$(jq 'length' <<< "$overrides")"
  if (( override_count > 1 )); then
    jq -cn --argjson number "$number" --arg title "$title" --arg url "$url" \
      '{number:$number,title:$title,url:$url,impact:"review",probability:null,method:"manual-label",needs_review:true,review_reason:"Conflicting release-impact labels"}' >> "$TMP/decisions.jsonl"
    ((review_count+=1))
    continue
  fi
  if (( override_count == 1 )); then
    choice="$(jq -r '.[0] | split("/")[1]' <<< "$overrides")"
    jq -cn --argjson number "$number" --arg title "$title" --arg url "$url" --arg choice "$choice" \
      '{number:$number,title:$title,url:$url,impact:$choice,probability:1,method:"manual-label",needs_review:false}' >> "$TMP/decisions.jsonl"
    item="- **#$number** $title ([PR](<$url>))"
    case "$choice" in
      major) printf '%s\n' "$item" >> "$TMP/major.md"; ((major_count+=1)) ;;
      minor) printf '%s\n' "$item" >> "$TMP/minor.md"; ((minor_count+=1)) ;;
      patch) printf '%s\n' "$item" >> "$TMP/patch.md"; ((patch_count+=1)) ;;
      none) ((none_count+=1)) ;;
    esac
    echo "PR #$number => $choice (maintainer label)"
    continue
  fi

  # Release/CI automation changes cannot alter the shipped product behavior.
  # Keep this policy narrow and deterministic; mixed product+automation PRs go to Jev.
  if jq -e 'length > 0 and all(.[]; startswith(".github/workflows/") or startswith("scripts/ci/") or startswith(".jev/"))' <<< "$files" >/dev/null; then
    printf '{"number":%s,"title":%s,"url":%s,"impact":"none","probability":1.0,"method":"path-policy","needs_review":false}\n' \
      "$number" "$(jq -Rn --arg v "$title" '$v')" "$(jq -Rn --arg v "$url" '$v')" >> "$TMP/decisions.jsonl"
    ((none_count+=1))
    echo "PR #$number => none (deterministic: release/CI-only paths)"
    continue
  fi

  # Test-only changes do not ship behavior. Treat a PR as no-impact only when
  # every changed path is explicitly a test file or inside a test directory.
  if jq -e 'length > 0 and all(.[]; test("(^|/)(__tests__|tests?|testdata|testes)/|(^|/)[^/]+([._-](test|spec))[.][^/]+$|(^|/)[^/]+_test[.][^/]+$"))' <<< "$files" >/dev/null; then
    printf '{"number":%s,"title":%s,"url":%s,"impact":"none","probability":1.0,"method":"test-only-path-policy","needs_review":false}\n' \
      "$number" "$(jq -Rn --arg v "$title" '$v')" "$(jq -Rn --arg v "$url" '$v')" >> "$TMP/decisions.jsonl"
    ((none_count+=1))
    echo "PR #$number => none (deterministic: test-only paths)"
    continue
  fi

  # Send the complete unified diff to Jev; never classify a partial patch.
  diff_file="$TMP/pr-$number.diff"
  if [[ "$(jq -r '.direct // false' <<< "$pr")" == true ]]; then
    git diff "$LAST_TAG" "$MAIN_SHA" -- > "$diff_file"
  elif ! gh pr diff "$number" --repo "$REPOSITORY" > "$diff_file"; then
    echo "::warning::Could not retrieve diff for PR #$number; requiring manual review."
    printf '{"number":%s,"title":%s,"url":%s,"impact":"review","probability":null,"method":"jev","needs_review":true,"review_reason":"Could not retrieve PR diff"}\n' \
      "$number" "$(jq -Rn --arg v "$title" '$v')" "$(jq -Rn --arg v "$url" '$v')" >> "$TMP/decisions.jsonl"
    ((review_count+=1))
    continue
  fi
  diff_bytes="$(wc -c < "$diff_file" | tr -d ' ')"
  if (( diff_bytes == 0 )); then
    echo "::warning::PR #$number has an empty diff; requiring manual review."
    printf '{"number":%s,"title":%s,"url":%s,"impact":"review","probability":null,"method":"jev","needs_review":true,"review_reason":"Empty or binary-only diff"}\n' \
      "$number" "$(jq -Rn --arg v "$title" '$v')" "$(jq -Rn --arg v "$url" '$v')" >> "$TMP/decisions.jsonl"
    ((review_count+=1))
    continue
  fi
  # Deterministically separate implementation from tests, docs, lockfiles,
  # and release automation before paying for semantic model analysis.
  prep_file="$TMP/pr-$number-prepared.json"
  if ! python3 "$ENGINE_ROOT/scripts/prepare-release-diff.py" "$diff_file" "$title" "$body" > "$prep_file"; then
    echo "::warning::PR #$number diff pre-analysis failed; requiring manual review."
    printf '{"number":%s,"title":%s,"url":%s,"impact":"review","probability":null,"method":"pre-analysis","needs_review":true,"review_reason":"Diff pre-analysis failed"}\n' \
      "$number" "$(jq -Rn --arg v "$title" '$v')" "$(jq -Rn --arg v "$url" '$v')" >> "$TMP/decisions.jsonl"
    ((review_count+=1))
    continue
  fi

  pre_action="$(jq -r '.action' "$prep_file")"
  pre_reason="$(jq -r '.policy_reason' "$prep_file")"
  pre_summary="$(jq -r '.summary' "$prep_file")"
  pre_impact="$(jq -r '.policy_impact // ""' "$prep_file")"
  if [[ "$pre_action" != "jev" ]]; then
    if [[ "$pre_action" == "review" ]]; then
      printf '{"number":%s,"title":%s,"url":%s,"impact":"review","probability":null,"method":"deterministic-pre-analysis","needs_review":true,"review_reason":%s}\n' \
        "$number" "$(jq -Rn --arg v "$title" '$v')" "$(jq -Rn --arg v "$url" '$v')" "$(jq -Rn --arg v "$pre_reason" '$v')" >> "$TMP/decisions.jsonl"
      ((review_count+=1))
      echo "PR #$number => review (deterministic pre-analysis: $pre_reason)"
    else
      printf '{"number":%s,"title":%s,"url":%s,"impact":%s,"probability":1.0,"method":"deterministic-pre-analysis","needs_review":false,"reason":%s}\n' \
        "$number" "$(jq -Rn --arg v "$title" '$v')" "$(jq -Rn --arg v "$url" '$v')" "$(jq -Rn --arg v "$pre_action" '$v')" "$(jq -Rn --arg v "$pre_reason" '$v')" >> "$TMP/decisions.jsonl"
      case "$pre_action" in
        major) printf '%s\n' "- **#$number** $title ([PR](<$url>))" >> "$TMP/major.md"; ((major_count+=1)) ;;
        minor) printf '%s\n' "- **#$number** $title ([PR](<$url>))" >> "$TMP/minor.md"; ((minor_count+=1)) ;;
        patch) printf '%s\n' "- **#$number** $title ([PR](<$url>))" >> "$TMP/patch.md"; ((patch_count+=1)) ;;
        none) ((none_count+=1)) ;;
      esac
      echo "PR #$number => $pre_action (deterministic pre-analysis: $pre_reason)"
    fi
    continue
  fi

  files="$(jq -c '.analysis_files' "$prep_file")"
  body="$body

$pre_summary"
  diff_truncated=false
  classification_method_override=""
  review_input_file="$TMP/pr-$number.json"
  : > "$TMP/pr-$number-chunk-results.jsonl"
  jq -r '.analysis_diff' "$prep_file" > "$diff_file"
  diff_bytes="$(wc -c < "$diff_file" | tr -d ' ')"
  if (( diff_bytes == 0 )); then
    echo "::warning::PR #$number has no implementation diff after pre-analysis; requiring manual review."
    printf '{"number":%s,"title":%s,"url":%s,"impact":"review","probability":null,"method":"pre-analysis","needs_review":true,"review_reason":"No implementation diff remains after pre-analysis"}\n' \
      "$number" "$(jq -Rn --arg v "$title" '$v')" "$(jq -Rn --arg v "$url" '$v')" >> "$TMP/decisions.jsonl"
    ((review_count+=1))
    continue
  fi

  # Keep a canonical filtered request available for both single-call and
  # chunked paths, including the targeted second pass after chunk aggregation.
  jq -n \
    --argjson number "$number" \
    --arg title "$title" \
    --arg body "$body" \
    --arg url "$url" \
    --argjson labels "$labels" \
    --argjson files "$files" \
    --rawfile diff "$diff_file" \
    --argjson diff_truncated false \
    '{number:$number,title:$title,body:$body,url:$url,labels:$labels,changed_files:$files,diff:$diff,diff_truncated:$diff_truncated}' \
    > "$TMP/pr-$number.json"

  # Only the filtered implementation diff reaches Jev; diffs above 12 KB are
  # split after filtering, so medium-sized ambiguous PRs get file-level analysis too.
  if (( diff_bytes <= 12000 )); then
    echo "PR #$number diff: $diff_bytes bytes; sending complete diff to Jev."
    jq -n \
      --argjson number "$number" \
      --arg title "$title" \
      --arg body "$body" \
      --arg url "$url" \
      --argjson labels "$labels" \
      --argjson files "$files" \
      --rawfile diff "$diff_file" \
      --argjson diff_truncated "$diff_truncated" \
      '{number:$number,title:$title,body:$body,url:$url,labels:$labels,changed_files:$files,diff:$diff,diff_truncated:$diff_truncated}' \
      > "$TMP/pr-$number.json"

    if ! result="$(jev ask --preset release-impact --param "pr=@$TMP/pr-$number.json")"; then
      echo "::warning::Jev could not process the complete diff for PR #$number; requiring manual review."
      printf '{"number":%s,"title":%s,"url":%s,"impact":"review","probability":null,"method":"jev","needs_review":true,"review_reason":"Jev failed to process complete PR diff"}\n' \
        "$number" "$(jq -Rn --arg v "$title" '$v')" "$(jq -Rn --arg v "$url" '$v')" >> "$TMP/decisions.jsonl"
      ((review_count+=1))
      continue
    fi
  else
    echo "PR #$number diff: $diff_bytes bytes; splitting into complete-file batches (12,000-byte maximum each)."
    if ! python3 "$ENGINE_ROOT/scripts/split-release-diff.py" "$diff_file" 12000 > "$TMP/pr-$number-chunks.json"; then
      echo "::warning::PR #$number could not be safely chunked (likely an oversized individual file); requiring manual review."
      printf '{"number":%s,"title":%s,"url":%s,"impact":"review","probability":null,"method":"jev-chunked","needs_review":true,"review_reason":"Diff could not be split safely at file boundaries"}\n' \
        "$number" "$(jq -Rn --arg v "$title" '$v')" "$(jq -Rn --arg v "$url" '$v')" >> "$TMP/decisions.jsonl"
      ((review_count+=1))
      continue
    fi

    chunk_count="$(jq 'length' "$TMP/pr-$number-chunks.json")"
    chunk_failed=false
    while IFS= read -r chunk; do
      chunk_index="$(jq -r '.index' <<< "$chunk")"
      chunk_diff="$(jq -r '.diff' <<< "$chunk")"
      chunk_files="$(jq -c '.files' <<< "$chunk")"
      if jq -e 'length > 0 and all(.[]; test("(^|/)(__tests__|tests?|testdata|testes)/|(^|/)[^/]+([._-](test|spec))[.][^/]+$|(^|/)[^/]+_test[.][^/]+$"))' <<< "$chunk_files" >/dev/null; then
        echo "PR #$number chunk $chunk_index/$chunk_count => none (deterministic: test-only paths)"
        jq -cn '{choice:"none",confidence:1.0,probabilities:{none:1.0}}' >> "$TMP/pr-$number-chunk-results.jsonl"
        continue
      fi
      jq -n \
        --argjson number "$number" \
        --arg title "$title" \
        --arg body "$body" \
        --arg url "$url" \
        --argjson labels "$labels" \
        --argjson files "$chunk_files" \
        --arg diff "$chunk_diff" \
        --argjson diff_truncated false \
        --argjson chunk_index "$chunk_index" \
        --argjson chunk_count "$chunk_count" \
        '{number:$number,title:$title,body:$body,url:$url,labels:$labels,changed_files:$files,diff:$diff,diff_truncated:$diff_truncated,chunk_index:$chunk_index,chunk_count:$chunk_count,analysis_mode:"complete-file-chunk"}' \
        > "$TMP/pr-$number-chunk-$chunk_index.json"

      echo "PR #$number chunk $chunk_index/$chunk_count ($(jq -r '.bytes' <<< "$chunk") bytes; files: $(jq -r '.files | join(", ")' <<< "$chunk"))"
      if ! chunk_result="$(jev ask --preset release-impact --param "pr=@$TMP/pr-$number-chunk-$chunk_index.json")"; then
        echo "::warning::Jev failed on PR #$number chunk $chunk_index/$chunk_count; requiring manual review."
        chunk_failed=true
        continue
      fi
      if ! chunk_choice="$(jq -er '.answers.impact.choice' <<< "$chunk_result")" ||
         ! chunk_confidence="$(jq -er --arg choice "$chunk_choice" '.answers.impact.probabilities[$choice]' <<< "$chunk_result")" ||
         ! [[ "$chunk_confidence" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
         ! [[ "$chunk_choice" =~ ^(major|minor|patch|none|review)$ ]]; then
        echo "::warning::Jev returned an invalid result for PR #$number chunk $chunk_index/$chunk_count; requiring manual review."
        chunk_failed=true
        continue
      fi

      # Give an ambiguous chunk the same targeted second pass as a full diff.
      # Keep the original chunk and response together so Jev can resolve its uncertainty.
      if [[ "$chunk_choice" == "review" ]] || ! awk -v p="$chunk_confidence" -v min="$MIN_CONFIDENCE" 'BEGIN { exit !(p >= min) }'; then
        echo "PR #$number chunk $chunk_index/$chunk_count is ambiguous (impact=$chunk_choice, p=$chunk_confidence); running targeted second pass."
        jq --argjson initial_analysis "$chunk_result" \
          '. + {review_pass:true,initial_analysis:$initial_analysis}' \
          "$TMP/pr-$number-chunk-$chunk_index.json" > "$TMP/pr-$number-chunk-$chunk_index-review.json"
        if ! chunk_result="$(jev ask --preset release-impact --param "pr=@$TMP/pr-$number-chunk-$chunk_index-review.json")"; then
          echo "::warning::Jev second pass failed for PR #$number chunk $chunk_index/$chunk_count; requiring manual review."
          chunk_failed=true
          continue
        fi
        if ! chunk_choice="$(jq -er '.answers.impact.choice' <<< "$chunk_result")" ||
           ! chunk_confidence="$(jq -er --arg choice "$chunk_choice" '.answers.impact.probabilities[$choice]' <<< "$chunk_result")" ||
           ! [[ "$chunk_confidence" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
           ! [[ "$chunk_choice" =~ ^(major|minor|patch|none|review)$ ]]; then
          echo "::warning::Jev second pass returned an invalid result for PR #$number chunk $chunk_index/$chunk_count; requiring manual review."
          chunk_failed=true
          continue
        fi
        echo "PR #$number chunk $chunk_index/$chunk_count second pass => $chunk_choice (p=$chunk_confidence)"
        if [[ "$chunk_choice" == "review" ]] || ! awk -v p="$chunk_confidence" -v min="$MIN_CONFIDENCE" 'BEGIN { exit !(p >= min) }'; then
          echo "::warning::PR #$number chunk $chunk_index/$chunk_count remains ambiguous after second pass (impact=$chunk_choice, p=$chunk_confidence); deferring to whole-PR synthesis."
          jq -c --arg choice "$chunk_choice" --argjson confidence "$chunk_confidence" --argjson chunk_index "$chunk_index" --argjson files "$chunk_files" \
            '{chunk_index:$chunk_index,files:$files,choice:$choice,confidence:$confidence,probabilities:.answers.impact.probabilities,needs_synthesis:true,analysis:.answers.impact}' \
            <<< "$chunk_result" >> "$TMP/pr-$number-chunk-results.jsonl"
          continue
        fi
      fi
      echo "PR #$number chunk $chunk_index/$chunk_count => $chunk_choice (p=$chunk_confidence)"
      jq -c --arg choice "$chunk_choice" --argjson confidence "$chunk_confidence" --argjson chunk_index "$chunk_index" --argjson files "$chunk_files" \
        '{chunk_index:$chunk_index,files:$files,choice:$choice,confidence:$confidence,probabilities:.answers.impact.probabilities,needs_synthesis:false,analysis:.answers.impact}' \
        <<< "$chunk_result" >> "$TMP/pr-$number-chunk-results.jsonl"
    done < <(jq -c '.[]' "$TMP/pr-$number-chunks.json")

    if [[ "$chunk_failed" == true ]] || (( $(wc -l < "$TMP/pr-$number-chunk-results.jsonl" | tr -d ' ') != chunk_count )); then
      printf '{"number":%s,"title":%s,"url":%s,"impact":"review","probability":null,"method":"jev-chunked","needs_review":true,"review_reason":"At least one diff chunk failed or was unavailable"}\n' \
        "$number" "$(jq -Rn --arg v "$title" '$v')" "$(jq -Rn --arg v "$url" '$v')" >> "$TMP/decisions.jsonl"
      ((review_count+=1))
      continue
    fi

    # Synthesize the whole PR when any chunk remains ambiguous, or when every
    # chunk says "none". Multiple individually harmless chunks can still be
    # related, but that is a reason to assess the combined PR—not to force review.
    # The aggregate result still must meet the normal confidence threshold.
    needs_synthesis="$(jq -s 'any(.[]; .needs_synthesis == true) or (length > 1 and all(.[]; .choice == "none"))' "$TMP/pr-$number-chunk-results.jsonl")"
    if [[ "$needs_synthesis" == true ]]; then
      echo "PR #$number needs whole-PR synthesis; reconciling all chunk analyses."
      jq --slurpfile chunk_results "$TMP/pr-$number-chunk-results.jsonl" \
        '. + {analysis_mode:"chunk-aggregate",diff:"",chunk_results:$chunk_results}' \
        "$TMP/pr-$number.json" > "$TMP/pr-$number-aggregate.json"
      if ! result="$(jev ask --preset release-impact --param "pr=@$TMP/pr-$number-aggregate.json")"; then
        echo "::warning::Jev could not synthesize chunk results for PR #$number; requiring manual review."
        printf '{"number":%s,"title":%s,"url":%s,"impact":"review","probability":null,"method":"jev-chunk-aggregate","needs_review":true,"review_reason":"Whole-PR synthesis failed"}\n' \
          "$number" "$(jq -Rn --arg v "$title" '$v')" "$(jq -Rn --arg v "$url" '$v')" >> "$TMP/decisions.jsonl"
        ((review_count+=1))
        continue
      fi
      classification_method_override="jev-chunk-aggregate"
      review_input_file="$TMP/pr-$number-aggregate.json"

      echo "PR #$number whole-PR synthesis completed; validating its impact and confidence."
    else
      # A higher-impact chunk sets the release level for the complete PR.
    choice="$(jq -s 'if any(.[]; .choice == "major") then "major" elif any(.[]; .choice == "minor") then "minor" elif any(.[]; .choice == "patch") then "patch" else "none" end' "$TMP/pr-$number-chunk-results.jsonl" | tr -d '"')"
    # One chunk evidencing the highest impact is enough for the whole PR, so its
    # confidence comes from the chunks that chose it; chunks confidently
    # assessed as lower impact must not dilute it.
    confidence="$(jq -s --arg choice "$choice" '[.[] | select(.choice == $choice) | .confidence] | max' "$TMP/pr-$number-chunk-results.jsonl")"
    probabilities="$(jq -s 'reduce .[].probabilities as $p ({"major":0,"minor":0,"patch":0,"none":0,"review":0}; reduce ["major","minor","patch","none","review"][] as $k (. ; .[$k] = ([.[$k], ($p[$k] // 0)] | max)))' "$TMP/pr-$number-chunk-results.jsonl")"
    result="$(jq -n --arg choice "$choice" --argjson confidence "$confidence" --argjson probabilities "$probabilities" \
      '{answers:{impact:{choice:$choice,probabilities:($probabilities | .[$choice]=$confidence)}}}')"
      classification_method_override="jev-chunked"
      echo "PR #$number combined chunk result => $choice (strongest chunk confidence=$confidence)"
    fi
  fi
  if ! initial_choice="$(jq -er '.answers.impact.choice' <<< "$result")" ||
     ! initial_confidence="$(jq -er --arg choice "$initial_choice" '.answers.impact.probabilities[$choice]' <<< "$result")" ||
     ! [[ "$initial_confidence" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "::warning::Jev returned an invalid classification for PR #$number; requiring manual review."
    printf '{"number":%s,"title":%s,"url":%s,"impact":"review","probability":null,"method":"jev","needs_review":true,"review_reason":"Invalid initial Jev response"}\n' \
      "$number" "$(jq -Rn --arg v "$title" '$v')" "$(jq -Rn --arg v "$url" '$v')" >> "$TMP/decisions.jsonl"
    ((review_count+=1))
    continue
  fi

  choice="$initial_choice"
  confidence="$initial_confidence"
  classification_method="${classification_method_override:-jev}"
  # Missing upstream notes set no floor: Jev already sees the manifest diff,
  # and its confidence plus the batch gate decide, as for any other PR.
  if [[ "$pre_impact" == "review" ]]; then
    echo "PR #$number has no dependency release-note evidence; using Jev's classification without a floor."
  fi
  # A dependency's documented compatible user-facing fix establishes a patch
  # floor for the whole PR, while Jev still determines implementation impact.
  if [[ "$pre_impact" == "patch" && "$choice" == "none" ]]; then
    choice="patch"
  elif [[ "$pre_impact" == "minor" && "$choice" =~ ^(none|patch)$ ]]; then
    choice="minor"
  elif [[ "$pre_impact" == "major" && "$choice" != "major" ]]; then
    choice="major"
  fi
  # Ambiguous results get a second, targeted pass with the original response
  # included so Jev can revisit its uncertainty instead of repeating blindly.
  if [[ "$choice" == "review" ]] || ! awk -v p="$confidence" -v min="$MIN_CONFIDENCE" 'BEGIN { exit !(p >= min) }'; then
    jq --argjson initial_analysis "$result" \
      '. + {review_pass:true,initial_analysis:$initial_analysis}' \
      "$review_input_file" > "$TMP/pr-$number-review.json"
    if ! result="$(jev ask --preset release-impact --param "pr=@$TMP/pr-$number-review.json")"; then
      echo "::warning::Jev's second pass could not process the complete diff for PR #$number; requiring manual review."
      printf '{"number":%s,"title":%s,"url":%s,"impact":"review","probability":null,"initial_impact":%s,"initial_probability":%s,"method":"jev-second-pass","needs_review":true,"review_reason":"Jev second pass failed to process complete PR diff"}\n' \
        "$number" "$(jq -Rn --arg v "$title" '$v')" "$(jq -Rn --arg v "$url" '$v')" \
        "$(jq -Rn --arg v "$initial_choice" '$v')" "$initial_confidence" >> "$TMP/decisions.jsonl"
      ((review_count+=1))
      continue
    fi
    classification_method=jev-second-pass
    if ! choice="$(jq -er '.answers.impact.choice' <<< "$result")" ||
       ! confidence="$(jq -er --arg choice "$choice" '.answers.impact.probabilities[$choice]' <<< "$result")" ||
       ! [[ "$confidence" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      echo "::warning::Jev's second pass returned an invalid classification for PR #$number; requiring manual review."
      printf '{"number":%s,"title":%s,"url":%s,"impact":"review","probability":null,"initial_impact":%s,"initial_probability":%s,"method":"jev-second-pass","needs_review":true,"review_reason":"Invalid second-pass Jev response"}\n' \
        "$number" "$(jq -Rn --arg v "$title" '$v')" "$(jq -Rn --arg v "$url" '$v')" \
        "$(jq -Rn --arg v "$initial_choice" '$v')" "$initial_confidence" >> "$TMP/decisions.jsonl"
      ((review_count+=1))
      continue
    fi
  fi

  if ! [[ "$choice" =~ ^(major|minor|patch|none|review)$ ]]; then
    choice=review
    confidence=0
  fi

  semver_fallback=false
  if [[ "$diff_truncated" == false ]] && { [[ "$choice" == "review" ]] || ! awk -v p="$confidence" -v min="$MIN_CONFIDENCE" 'BEGIN { exit !(p >= min) }'; }; then
    previous_choice="$choice"
    fallback_choice="$(jq -r '
      .answers.impact.probabilities // {} |
      [{impact:"patch",probability:(.patch // 0)},
       {impact:"minor",probability:(.minor // 0)},
       {impact:"major",probability:(.major // 0)}] |
      max_by(.probability) | .impact
    ' <<< "$result")"
    choice="$fallback_choice"
    confidence="$(jq -r --arg choice "$choice" '.answers.impact.probabilities[$choice] // 0' <<< "$result")"
    classification_method="${classification_method}+semver-fallback"
    semver_fallback=true
    echo "PR #$number unresolved classification ($previous_choice, p=$confidence); using $choice as the best-supported SemVer impact."
  fi

  echo "PR #$number probabilities: $(jq -c '.answers.impact.probabilities' <<< "$result")"
  review_reason=""
  if [[ "$diff_truncated" == true ]]; then
    review_reason="Diff was truncated at $max_diff_bytes bytes; manual review is required"
  elif [[ "$choice" == "review" ]]; then
    review_reason="Jev still marked this PR for manual review after the second pass"
  elif [[ "$semver_fallback" == true ]]; then
    echo "PR #$number using a SemVer fallback after targeted re-analysis."
  elif ! awk -v p="$confidence" -v min="$MIN_CONFIDENCE" 'BEGIN { exit !(p >= min) }'; then
    # Patch vs. no-release ambiguity is low risk only when Jev assigns very
    # little probability to a feature, breaking change, or unresolved review.
    high_impact_probability="$(jq -r '[.answers.impact.probabilities.major // 0, .answers.impact.probabilities.minor // 0, .answers.impact.probabilities.review // 0] | add' <<< "$result")"
    if [[ "$diff_truncated" == false && "$choice" =~ ^(patch|none)$ ]] &&
       awk -v p="$confidence" -v low=0.55 -v high="$high_impact_probability" \
         'BEGIN { exit !(p >= low && high < 0.20) }'; then
      echo "PR #$number accepted under low-risk policy (p=$confidence; combined major/minor/review probability=$high_impact_probability)"
    else
      # Low confidence only matters if it could change the version bump; that
      # depends on the whole batch, so the decision is deferred past the loop.
      jq -cn --argjson number "$number" --arg title "$title" --arg url "$url" \
        --arg choice "$choice" --argjson confidence "$confidence" \
        --arg initial_choice "$initial_choice" --argjson initial_confidence "$initial_confidence" \
        --arg method "$classification_method" --argjson probabilities "$(jq -c '.answers.impact.probabilities' <<< "$result")" \
        '{number:$number,title:$title,url:$url,choice:$choice,confidence:$confidence,initial_choice:$initial_choice,initial_confidence:$initial_confidence,method:$method,probabilities:$probabilities}' \
        >> "$TMP/uncertain.jsonl"
      echo "PR #$number => uncertain $choice (p=$confidence); deciding against the batch's version bump"
      continue
    fi
  fi

  if [[ -n "$review_reason" ]]; then
    printf '{"number":%s,"title":%s,"url":%s,"impact":"review","probability":%s,"initial_impact":%s,"initial_probability":%s,"method":%s,"needs_review":true,"review_reason":%s}\n' \
      "$number" "$(jq -Rn --arg v "$title" '$v')" "$(jq -Rn --arg v "$url" '$v')" \
      "$confidence" "$(jq -Rn --arg v "$initial_choice" '$v')" "$initial_confidence" \
      "$(jq -Rn --arg v "$classification_method" '$v')" "$(jq -Rn --arg v "$review_reason" '$v')" >> "$TMP/decisions.jsonl"
    ((review_count+=1))
    echo "PR #$number => review (p=$confidence; $review_reason)"
    continue
  fi

  printf '{"number":%s,"title":%s,"url":%s,"impact":%s,"probability":%s,"initial_impact":%s,"initial_probability":%s,"method":%s,"needs_review":false}\n' \
    "$number" "$(jq -Rn --arg v "$title" '$v')" "$(jq -Rn --arg v "$url" '$v')" \
    "$(jq -Rn --arg v "$choice" '$v')" "$confidence" \
    "$(jq -Rn --arg v "$initial_choice" '$v')" "$initial_confidence" \
    "$(jq -Rn --arg v "$classification_method" '$v')" >> "$TMP/decisions.jsonl"

  item="- **#$number** $title ([PR](<$url>))"
  case "$choice" in
    major) printf '%s\n' "$item" >> "$TMP/major.md"; ((major_count+=1)) ;;
    minor) printf '%s\n' "$item" >> "$TMP/minor.md"; ((minor_count+=1)) ;;
    patch) printf '%s\n' "$item" >> "$TMP/patch.md"; ((patch_count+=1)) ;;
    none) ((none_count+=1)) ;;
  esac
  echo "PR #$number => $choice (p=$confidence; $classification_method)"
done < "$TMP/eligible.jsonl"

# Batch gate: an uncertain PR blocks only when it could raise the version
# bump already set by confident PRs. Its argmax may not exceed that bump, and
# the probability above it must stay under 1 - MIN_CONFIDENCE. Review mass is
# "unsure", not a direction, so it is spread across impacts proportionally.
touch "$TMP/uncertain.jsonl"
if (( major_count > 0 )); then bump_rank=3
elif (( minor_count > 0 )); then bump_rank=2
elif (( patch_count > 0 )); then bump_rank=1
else bump_rank=0
fi
while IFS= read -r pending; do
  read -r number choice confidence above_mass < <(jq -r --argjson bump "$bump_rank" '
    {none:0,patch:1,minor:2,major:3} as $rank
    | [.number, .choice, .confidence,
       ((([.probabilities | to_entries[] | select(.key != "review" and ($rank[.key] // 0) > $bump) | .value] | add // 0)
         / ([1 - (.probabilities.review // 0), 0.01] | max) * 100 | round / 100))]
    | @tsv' <<< "$pending")
  title="$(jq -r '.title' <<< "$pending")"
  url="$(jq -r '.url' <<< "$pending")"
  choice_rank="$(jq -rn --arg c "$choice" '{none:0,patch:1,minor:2,major:3}[$c] // 4')"
  echo "PR #$number batch gate: choice=$choice (p=$confidence), bump rank=$bump_rank, mass above bump=$above_mass, limit=$(awk -v m="$MIN_CONFIDENCE" 'BEGIN { print 1 - m }')"
  if (( choice_rank > bump_rank )) ||
     ! awk -v mass="$above_mass" -v min="$MIN_CONFIDENCE" 'BEGIN { exit !(mass < 1 - min) }'; then
    review_reason="Confidence $confidence remains below $MIN_CONFIDENCE and the PR could raise the version bump (mass above bump=$above_mass)"
    jq -c --arg reason "$review_reason" \
      '{number,title,url,impact:"review",probability:.confidence,initial_impact:.initial_choice,initial_probability:.initial_confidence,method,needs_review:true,review_reason:$reason}' \
      <<< "$pending" >> "$TMP/decisions.jsonl"
    ((review_count+=1))
    echo "PR #$number => review (p=$confidence; $review_reason)"
    continue
  fi
  jq -c '{number,title,url,impact:.choice,probability:.confidence,initial_impact:.initial_choice,initial_probability:.initial_confidence,method:(.method + "+batch-gate"),needs_review:false}' \
    <<< "$pending" >> "$TMP/decisions.jsonl"
  item="- **#$number** $title ([PR](<$url>))"
  case "$choice" in
    major) printf '%s\n' "$item" >> "$TMP/major.md"; ((major_count+=1)) ;;
    minor) printf '%s\n' "$item" >> "$TMP/minor.md"; ((minor_count+=1)) ;;
    patch) printf '%s\n' "$item" >> "$TMP/patch.md"; ((patch_count+=1)) ;;
    none) ((none_count+=1)) ;;
  esac
  echo "PR #$number => $choice (p=$confidence; accepted: cannot change the version bump)"
done < "$TMP/uncertain.jsonl"


if (( review_count > 0 )); then
  {
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "### Intelligent release dry run — blocked by manual review"
      echo
      echo "- **No release or processed-marker tag was created.**"
      echo "- Main commit: $MAIN_SHA"
      echo "- Previous tag: $LAST_TAG"
      echo "- PRs classified: $eligible_count"
      echo "- Resolved: major $major_count; minor $minor_count; patch $patch_count; no impact $none_count"
      echo "- Still requiring review: $review_count"
      echo
      echo "The next version cannot be finalized until all review decisions are resolved."
    else
      echo "### Intelligent release paused for manual review"
      echo
      echo "No release was published. $review_count of $eligible_count PR(s) still require review after classification and targeted re-analysis."
      echo
      echo "Rerun this workflow with \`force=true\` after reviewing the decisions."
    fi
    echo
    echo "#### PRs requiring review"
    jq -r 'select(.needs_review == true) | "- #\(.number) \(.title): \(.review_reason // "insufficient confidence") (initial=\(.initial_impact // "unavailable"), final probability=\(.probability // "unavailable"))"' "$TMP/decisions.jsonl"
    echo
    echo "#### All classifier decisions"
    jq -r '"- #\(.number) \(.title): \(.impact) (p=\(.probability // "n/a"), method=\(.method // "n/a"))"' "$TMP/decisions.jsonl"
  } >> "$GITHUB_STEP_SUMMARY"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "Dry run blocked by $review_count PR(s) requiring manual review; no repository mutations were made."
    exit 0
  fi
  mark_processed
  exit 0
fi
if (( major_count + minor_count + patch_count == 0 )); then
  {
    echo "### Intelligent release"
    echo
    echo "No release created: all $none_count merged PR(s) were classified as having no meaningful user-facing impact."
    echo "Baseline: $LAST_TAG"
    echo "Commit: $MAIN_SHA"
  } >> "$GITHUB_STEP_SUMMARY"
  mark_processed
  exit 0
fi

if (( major_count > 0 )); then
  NEXT_TAG="v$((MAJOR + 1)).0.0"
elif (( minor_count > 0 )); then
  NEXT_TAG="v$MAJOR.$((MINOR + 1)).0"
else
  NEXT_TAG="v$MAJOR.$MINOR.$((PATCH + 1))"
fi

if gh release view "$NEXT_TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
  echo "::error::Release $NEXT_TAG already exists; refusing to create a duplicate."
  exit 1
fi

{
  echo "<!-- $REPO-intelligent-release -->"
  echo
  echo "## $REPO $NEXT_TAG"
  echo
  echo "Changes since \`$LAST_TAG\`."
  if (( major_count > 0 )); then
    echo
    echo "### Breaking changes"
    echo
    cat "$TMP/major.md"
  fi
  if (( minor_count > 0 )); then
    echo
    echo "### Features"
    echo
    cat "$TMP/minor.md"
  fi
  if (( patch_count > 0 )); then
    echo
    echo "### Fixes and improvements"
    echo
    cat "$TMP/patch.md"
  fi
  if (( none_count > 0 )); then
    echo
    echo "<details><summary>Internal changes ($none_count)</summary>"
    echo
    jq -r 'select(.impact == "none") | "- **#\(.number)** \(.title) ([PR](<\(.url)>))"' "$TMP/decisions.jsonl"
    echo
    echo "</details>"
  fi
} > "$TMP/notes.md"

# Final race check: the queue and main must still match the state classified.
final_queue="$(queue_size)"
final_main="$(git ls-remote origin refs/heads/main | awk '{print $1}')"
if [[ "$final_queue" != "0" || "$final_main" != "$MAIN_SHA" ]]; then
  echo "Queue or main changed during classification; aborting. A later push/schedule will retry."
  exit 0
fi

if [[ "$DRY_RUN" == "true" ]]; then
  {
    echo "### Intelligent release dry run"
    echo
    echo "- No release or processed-marker tag was created."
    echo "- Would publish: $NEXT_TAG"
    echo "- Target main commit: $MAIN_SHA"
    echo "- Previous tag: $LAST_TAG"
    echo "- PRs classified: $eligible_count"
    echo "- Major: $major_count; minor: $minor_count; patch: $patch_count; no release impact: $none_count"
    echo
    echo "#### Classifier decisions"
    jq -r '"- #\(.number) \(.title): \(.impact) (p=\(.probability))"' "$TMP/decisions.jsonl"
  } >> "$GITHUB_STEP_SUMMARY"
  echo "Dry run complete. No release was published and no processed marker was created."
  exit 0
fi

echo "Publishing $NEXT_TAG for $MAIN_SHA..."
gh release create "$NEXT_TAG" \
  --repo "$REPOSITORY" \
  --target "$MAIN_SHA" \
  --title "$NEXT_TAG" \
  --notes-file "$TMP/notes.md"

{
  echo "### Intelligent release published"
  echo
  echo "- Release: https://github.com/$REPOSITORY/releases/tag/$NEXT_TAG"
  echo "- Previous tag: $LAST_TAG"
  echo "- Commit: $MAIN_SHA"
  echo "- PRs classified: $eligible_count"
  echo "- Major: $major_count; minor: $minor_count; patch: $patch_count; no release impact: $none_count"
  echo
  echo "#### Classifier decisions"
  jq -r '"- #\(.number) \(.title): \(.impact) (p=\(.probability))"' "$TMP/decisions.jsonl"
} >> "$GITHUB_STEP_SUMMARY"
