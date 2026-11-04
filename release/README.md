# Shared intelligent release

The reusable workflow classifies merged changes after the queue stabilizes, and publishes a semver release when warranted. Callers retain their own triggers and per-repository secrets. The shared engine is checked out separately from the caller so it also works with private repositories.

Inputs: `stabilization_seconds`, `dry_run`, `force`, `baseline_version`. Required secrets: `CI_APP_ID`, `CI_APP_PRIVATE_KEY`, `JEV_API_KEY`. The GitHub App needs contents write and pull request read on the calling repository. First releases use the first commit as a baseline and the specified `baseline_version` (default `0.0.0`) for version arithmetic. Direct commits are included in a conservative whole-range comparison. No tag is created in a dry run. A stale checkout exits successfully, deferring to the newer queued run. API errors, incomplete diffs and uncertain classifications fail closed or request review.

The workflow fetches the shared engine from the organization repository's `main` branch. A central change therefore reaches callers on their next run. A caller must serialize its runs per repository and should provide a manual dry run.
