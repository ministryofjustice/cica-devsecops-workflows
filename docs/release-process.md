# Release process

## Why this matters

Every repository that calls a workflow from here is trusting this repo not to break underneath it. If callers reference `@main`, a defect committed here breaks every consuming repository immediately, all at once, with no warning. That's the specific failure mode this process exists to prevent.

**Rule: no production caller ever references `@main`.** Always a specific tag (`@v1.2.0`) or, for the highest assurance, a full 40-character commit SHA.

| Reference | When to use |
|---|---|
| `@main` | Never, for a real caller. Only acceptable while actively developing/testing a change against a throwaway branch of a non-production repo. |
| `@v1` | A floating major-version tag — reasonable once this repo has enough release discipline that a `v1` bump is guaranteed backwards-compatible, but still moves over time. Not recommended yet. |
| `@v1.2.0` | **Default recommendation.** Specific, auditable, controlled — a caller only moves forward when someone deliberately bumps the version string in their own file. |
| `@<full SHA>` | Use when policy requires immutability, or for anything security-sensitive where even a tag being force-moved is an unacceptable risk. |

## Making a change to a reusable workflow

1. Open a PR against this repo.
2. If the change affects behaviour a caller depends on (not just internal refactoring), test it end-to-end against a real caller on a throwaway branch pointed at your PR's branch/SHA before merging.
3. Merge to `main` once reviewed.
4. **Before tagging, bump the internal `snyk-auth` self-references to the version you're about to release.** `reusable-security.yml`, `reusable-container.yml`, and `reusable-publish.yml` each call `actions/snyk-auth` via a pinned external reference (`ministryofjustice/cica-devsecops-workflows/actions/snyk-auth@vX.Y.Z`) rather than a local path — see the design note in `docs/inputs.md` for why a local path doesn't work here. Tagging the repo does **not** update these lines automatically; they're just text until someone edits them. Do this every release, regardless of whether `snyk-auth` itself changed. Verify nothing was missed:
   ```
   grep -rn "snyk-auth@v" .github/workflows/
   ```
   All matches should show the version you're about to tag.
5. Once `main` is in a state you're confident releasing, tag it: `git tag v1.x.y && git push origin v1.x.y`.
6. Update `CHANGELOG.md` with what changed in that version.
7. Existing callers are **not** automatically affected — they stay on whatever tag they already reference until someone deliberately bumps it in their own caller workflow file.

## Rolling out a new version to callers

Don't push a new version to every caller at once. Move repositories forward deliberately, in staged-wave order (pilot → similar deployable services → repos with different integration patterns → libraries).

