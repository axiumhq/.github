#!/usr/bin/env python3
"""Prepare a PR diff for release classification: keep implementation, summarize noise."""
from __future__ import annotations

import json
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

TEST_PATH = re.compile(
    r"(^|/)(__tests__|tests?|testdata|testes|__mocks__|__screenshots__|__snapshots__)/|"
    r"(^|/)[^/]+([._-](test|spec))[.][^/]+$|"
    r"(^|/)[^/]+_test[.][^/]+$",
    re.IGNORECASE,
)
DOC_PATH = re.compile(
    r"(^|/)(docs?|documentation|examples?|guides?)/|"
    r"(^|/)(readme|contributing|changelog|changes|authors|license)([.]|$)|"
    r"[.](md|mdx|rst|adoc|txt)$",
    re.IGNORECASE,
)
LOCKFILE = re.compile(
    r"(^|/)(package-lock[.]json|npm-shrinkwrap[.]json|pnpm-lock[.]yaml|"
    r"yarn[.]lock|bun[.]lockb?|Cargo[.]lock|go[.]sum|Gemfile[.]lock|"
    r"poetry[.]lock|Pipfile[.]lock|composer[.]lock|uv[.]lock|"
    r"Podfile[.]lock|pubspec[.]lock)$",
    re.IGNORECASE,
)
# Manifesto não é lockfile: package.json e Cargo.toml também guardam script,
# bin e a versão do próprio pacote. Só um diff que não mexe em nada disso
# pode sair do Jev.
MANIFEST = re.compile(r"(^|/)(package[.]json|Cargo[.]toml)$")
VERSION_SPEC = re.compile(
    r"^(?:[\^~]|>=|<=|>|<)?"
    r"\d+\.\d+\.\d+"
    r"(?:[-+][0-9A-Za-z.-]+)?"
    r"$"
)
PACKAGE_JSON_DEP = re.compile(
    r'^\s*"(?P<key>[^"]+)"\s*:\s*"(?P<spec>[^"]+)"\s*,?\s*$'
)
PACKAGE_JSON_RESERVED = {
    "author", "bin", "browser", "bugs", "config", "cpu", "description",
    "directories", "engines", "exports", "files", "funding", "homepage",
    "keywords", "license", "main", "man", "module", "name", "os",
    "packageManager", "private", "publishConfig", "repository", "scripts",
    "sideEffects", "type", "types", "typings", "version", "workspaces",
}
CARGO_DEP = re.compile(
    r'^\s*(?P<key>[A-Za-z0-9_-]+)\s*=\s*"(?P<spec>[^"]+)"\s*$'
)
CARGO_RESERVED = {
    "authors", "autobenches", "autobins", "autoexamples", "autotests",
    "description", "documentation", "edition", "homepage", "license",
    "name", "publish", "readme", "repository", "resolver", "rust-version",
    "version",
}
RELEASE_AUTOMATION = (".github/workflows/", "scripts/ci/", ".jev/")
UPSTREAM_CHANGELOG_LINK = re.compile(
    r"https?://(?:redirect\.)?github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/"
    r"(?:compare|releases/tag)/"
)
VERSION_HEADING = re.compile(r"^#{1,4}\s+v?(\d+\.\d+\.\d+)\b", re.MULTILINE)
VERSION_NUMBER = re.compile(r"\bv?(\d+\.\d+\.\d+)\b")


def changed_payloads(section: str) -> list[str]:
    payloads = []
    for line in section.splitlines():
        if line.startswith(("+++", "---")):
            continue
        if line.startswith(("+", "-")):
            payloads.append(line[1:])
    return payloads


def is_manifest_version_bump(path: str, section: str) -> bool:
    """True quando o manifesto só troca especificador de dependência.

    `version` do próprio pacote, script, bin e tabela inline ficam de fora:
    isso volta para o Jev em vez de virar `none` calado.
    """
    if MANIFEST.search(path) is None:
        return False
    payloads = changed_payloads(section)
    if not payloads:
        return False
    if path.endswith("package.json"):
        pattern, reserved = PACKAGE_JSON_DEP, PACKAGE_JSON_RESERVED
    elif path.endswith("Cargo.toml"):
        pattern, reserved = CARGO_DEP, CARGO_RESERVED
    else:
        return False
    for payload in payloads:
        match = pattern.match(payload)
        if match is None or match.group("key") in reserved:
            return False
        if VERSION_SPEC.match(match.group("spec")) is None:
            return False
    return True


def category(path: str) -> str:
    if path.startswith(RELEASE_AUTOMATION):
        return "release-automation"
    if TEST_PATH.search(path):
        return "tests"
    if LOCKFILE.search(path):
        return "dependency-lockfile"
    if DOC_PATH.search(path):
        return "documentation"
    return "implementation"


# Binary and pure-rename sections have no `---`/`+++` lines.
SECTION_PATH = (
    re.compile(r"^\+\+\+ b/(.+)$", re.MULTILINE),
    re.compile(r"^--- a/(.+)$", re.MULTILINE),
    re.compile(r"^rename to (.+)$", re.MULTILINE),
    re.compile(r"^Binary files .* and b/(.+) differ$", re.MULTILINE),
)


def section_path(section: str) -> str:
    for pattern in SECTION_PATH:
        match = pattern.search(section)
        if match:
            return match.group(1)
    raise ValueError("diff section has no recognizable file path")


def split_sections(diff: str) -> list[tuple[str, str]]:
    sections: list[tuple[str, str]] = []
    current: list[str] = []
    for line in diff.splitlines(keepends=True):
        if line.startswith("diff --git "):
            if current:
                section = "".join(current)
                sections.append((section_path(section), section))
            current = [line]
        elif current:
            current.append(line)
        elif line.strip():
            raise ValueError("unexpected content before first diff section")
    if current:
        section = "".join(current)
        sections.append((section_path(section), section))
    if not sections:
        raise ValueError("diff is empty or contains no file sections")
    return sections


def linked_upstream_release_notes(title: str, body: str) -> str:
    """Fetch versioned changelog sections only from GitHub repos linked by release notes."""
    repos = list(dict.fromkeys(UPSTREAM_CHANGELOG_LINK.findall(body)))
    if not repos:
        return ""
    versions = set(VERSION_NUMBER.findall(title + "\n" + body))
    notes: list[str] = []
    for owner, repo in repos[:3]:
        if repo.endswith(".git"):
            repo = repo[:-4]
        changelog = ""
        repo_slug = repo.split("/")[-1]
        changelog_paths = ("CHANGELOG.md", f"packages/{repo_slug}/CHANGELOG.md", "packages/solid/CHANGELOG.md")
        for branch in ("main", "master"):
            for path in dict.fromkeys(changelog_paths):
                url = f"https://raw.githubusercontent.com/{owner}/{repo}/{branch}/{path}"
                try:
                    request = urllib.request.Request(url, headers={"User-Agent": "vortex-release-classifier"})
                    with urllib.request.urlopen(request, timeout=3) as response:
                        changelog = response.read(1_500_000).decode("utf-8", errors="replace")
                    break
                except (urllib.error.URLError, TimeoutError, OSError):
                    continue
            if changelog:
                break
        if not changelog:
            continue
        headings = list(VERSION_HEADING.finditer(changelog))
        for index, heading in enumerate(headings):
            if heading.group(1) not in versions:
                continue
            end = headings[index + 1].start() if index + 1 < len(headings) else len(changelog)
            notes.append(f"Upstream changelog {owner}/{repo} {heading.group(1)}:\n{changelog[heading.start():end]}")
    return "\n".join(notes)


def dependency_impact(text: str) -> tuple[str, str]:
    text = re.sub(r"[^a-z0-9]+", " ", text.lower())
    if re.search(r"\b(breaking change|breaking changes|not backward compatible|incompatible api)\b", text):
        return "major", "Upstream release notes explicitly indicate a breaking change."
    if re.search(r"\b(new feature|new capability|adds support for|introduces support for)\b", text):
        return "minor", "Upstream release notes explicitly indicate an additive capability."
    if re.search(
        r"\b(fix(es|ed|ing)?|bug fix|correctness|security fixes?|vulnerability|"
        r"improv(e|es|ed|ement)|performance|rendering|styling|theme overrides?|"
        r"preserv\w* existing styles|reliability|regression)\b",
        text,
    ):
        return "patch", "Upstream release notes describe a user-facing fix or improvement."
    if re.search(r"\b(lint|formatting|format only|build tooling|build tool|"
                 r"developer tooling|internal tooling)\b", text) and not re.search(
        r"\b(bug fix|security|vulnerability|rendering|styling|performance|correctness)\b", text
    ):
        return "none", "Upstream notes describe tooling-only maintenance without a user-facing effect."
    return "review", "Dependency-only change lacks sufficient release-note evidence for a safe impact decision."


def prepare(diff: str, title: str, body: str) -> dict:
    sections = split_sections(diff)
    classified = [(path, section, category(path)) for path, section in sections]
    counts: dict[str, int] = {}
    for _, _, kind in classified:
        counts[kind] = counts.get(kind, 0) + 1

    kinds = set(counts)
    paths_by_kind = {
        kind: [path for path, _, item_kind in classified if item_kind == kind]
        for kind in sorted(kinds)
    }

    non_implementation = {"release-automation", "tests", "documentation", "dependency-lockfile"}
    # package.json e Cargo.toml contam como código, então um Renovate que só
    # sobe a versão caía no Jev. `review` ali trava a release inteira. O bump
    # puro é o mesmo caso do lockfile: grafo de dependência, sem código nosso.
    implementation = [(path, section) for path, section, kind in classified if kind == "implementation"]
    other_kinds = {kind for _, _, kind in classified if kind != "implementation"}
    if implementation and other_kinds <= non_implementation and all(
        is_manifest_version_bump(path, section) for path, section in implementation
    ):
        bumped = {path for path, _ in implementation}
        for kind, paths in list(paths_by_kind.items()):
            paths_by_kind[kind] = [path for path in paths if path not in bumped]
        paths_by_kind.setdefault("dependency-lockfile", [])
        paths_by_kind["dependency-lockfile"] = sorted(
            set(paths_by_kind["dependency-lockfile"]) | bumped
        )
        paths_by_kind = {kind: paths for kind, paths in paths_by_kind.items() if paths}
        counts["dependency-lockfile"] = counts.get("dependency-lockfile", 0) + counts.pop("implementation", 0)
        return result(
            "none",
            "Changes are limited to dependency version bumps in manifests and lockfiles; no first-party implementation changed.",
            counts,
            paths_by_kind,
        )
    if kinds <= non_implementation:
        # Dependency-only PRs maintain the dependency graph but do not change
        # first-party behavior directly. Keep them out of user-facing release
        # notes and never block release classification on upstream changelogs.
        if "dependency-lockfile" in kinds:
            return result(
                "none",
                "Changes are limited to dependency lockfiles, tests, documentation, or release automation; no first-party implementation changed.",
                counts,
                paths_by_kind,
            )
        if kinds <= {"release-automation"}:
            reason = "Changes are confined to release/CI automation."
        elif kinds <= {"tests"}:
            reason = "Changes are confined to tests, fixtures, or test helpers."
        elif kinds <= {"documentation"}:
            reason = "Changes are confined to documentation; no implementation behavior changed."
        else:
            reason = "Changes are confined to tests, documentation, and release automation."
        return result("none", reason, counts, paths_by_kind)

    # Only implementation-bearing sections reach Jev. The metadata summary keeps
    # the excluded categories visible so mixed PRs are not misrepresented.
    included = [(path, section) for path, section, kind in classified
                if kind not in {"tests", "documentation", "dependency-lockfile", "release-automation"}]
    if not included:
        return result("review", "No implementation diff remains after filtering mixed categories.", counts, paths_by_kind)

    dependency_floor = "none"
    dependency_reason = ""
    if "dependency-lockfile" in kinds:
        dependency_notes = title + "\n" + body
        dependency_floor, dependency_reason = dependency_impact(dependency_notes)
        if dependency_floor == "review":
            upstream_notes = linked_upstream_release_notes(title, body)
            if upstream_notes:
                dependency_floor, dependency_reason = dependency_impact(dependency_notes + "\n" + upstream_notes)
        if dependency_floor == "review":
            dependency_reason = "Dependency update also needs review: " + dependency_reason

    summary_lines = ["Pre-analysis summary (deterministic path classification):"]
    for kind, paths in paths_by_kind.items():
        summary_lines.append(f"- {kind}: {len(paths)} file(s): " + ", ".join(paths[:12]))
    if len(paths_by_kind.get("documentation", [])) or len(paths_by_kind.get("tests", [])):
        summary_lines.append("Documentation/test diffs were excluded from semantic classification; they do not override implementation impact.")
    if "dependency-lockfile" in kinds:
        summary_lines.append(f"Dependency release-note assessment: {dependency_floor}. {dependency_reason}")
        summary_lines.append("Consider this evidence when deciding the overall PR impact, but analyze implementation behavior only from the supplied diff.")
    return {
        "action": "jev",
        "policy_impact": dependency_floor if "dependency-lockfile" in kinds else "",
        "policy_reason": dependency_reason,
        "summary": "\n".join(summary_lines),
        "analysis_files": [path for path, _ in included],
        "analysis_diff": "".join(section for _, section in included),
        "counts": counts,
        "paths_by_category": paths_by_kind,
    }


def result(impact: str, reason: str, counts: dict, paths: dict) -> dict:
    return {
        "action": impact,
        "policy_impact": impact,
        "policy_reason": reason,
        "summary": reason,
        "analysis_files": [],
        "analysis_diff": "",
        "counts": counts,
        "paths_by_category": paths,
    }


def main() -> int:
    try:
        diff_path = Path(sys.argv[1])
        title = sys.argv[2] if len(sys.argv) > 2 else ""
        body = sys.argv[3] if len(sys.argv) > 3 else ""
        print(json.dumps(prepare(diff_path.read_text(encoding="utf-8"), title, body)))
        return 0
    except (OSError, ValueError) as exc:
        print(f"prepare-release-diff: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
