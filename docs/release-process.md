# Release process

## Why this matters

Every repository that calls a workflow from here is trusting this repo not to break underneath it. If callers reference `@main`, a defect committed here breaks every consuming repository immediately, all at once, with no warning. That's the specific failure mode this process exists to prevent.

**Rule: no production caller ever references `@main`.** Always a specific release version (`@v1.2.0`) or, for the highest assurance, a full 40-character commit SHA.

Every version of this repo is published as a [GitHub Release](https://github.com/ministryofjustice/cica-devsecops-workflows/releases). Publishing the release creates the version's tag (`v1.2.0`), which is what a caller's `@v1.2.0` resolves to. Version tags are never created by hand.

The release notes are the changelog. `CHANGELOG.md` holds the history up to `v1.0.12` and isn't updated any more.

| Reference | When to use |
|---|---|
| `@main` | Never, for a real caller. Only acceptable while actively developing/testing a change against a throwaway branch of a non-production repo. |
| `@v1` | A floating major-version tag — reasonable once this repo has enough release discipline that a `v1` bump is guaranteed backwards-compatible, but still moves over time. Not recommended yet. |
| `@v1.2.0` | **Default recommendation.** Specific, auditable, controlled — a caller only moves forward when someone deliberately bumps the version string in their own file. |
| `@<full SHA>` | Use when policy requires immutability, or for anything security-sensitive where even a tag being force-moved is an unacceptable risk. |

## Making a change to a reusable workflow

1. Open a PR against this repo.
2. If the change affects behaviour a caller depends on (not just internal refactoring), test it end-to-end against a real caller on a throwaway branch pointed at your PR's commit SHA before merging.
3. **Once testing is done, bump the internal `snyk-auth` self-references to the version you're about to release.** Do this last: a commit whose self-references point at a version that isn't published yet can't be tested from a caller, because every Snyk step fails trying to fetch that version. `reusable-security.yml`, `reusable-container.yml`, and `reusable-publish.yml` each call `actions/snyk-auth` via a pinned external reference (`ministryofjustice/cica-devsecops-workflows/actions/snyk-auth@vX.Y.Z`) rather than a local path — see the design note in `docs/inputs.md` for why a local path doesn't work here. Publishing a release does **not** update these lines automatically; they're just text until someone edits them. Do this every release, regardless of whether `snyk-auth` itself changed. Verify nothing was missed:
   ```
   grep -rn "snyk-auth@v" .github/workflows/
   ```
   All matches should show the version you're about to release.
4. Merge to `main` once reviewed.
5. Publish the release, as described below.
6. Existing callers are **not** automatically affected — they stay on whatever version they already reference until someone deliberately bumps it in their own caller workflow file.

## Publishing a release

1. On GitHub, go to **Releases → Draft a new release**.
2. Under **Choose a tag**, type the new version (e.g. `v1.2.0`) and select **Create new tag on publish**. Set the target to `main`.
3. Set the release title to the version (e.g. `v1.2.0`).
4. Select **Generate release notes** to list the PRs merged since the last release, then edit the notes into this shape:
   ```
   ### Added
   ### Changed
   ### Fixed
   ### Upgrade notes
   ### Known issues
   ```
   Leave out any heading with nothing under it. The release notes are this repo's changelog, so write them for someone deciding whether to upgrade: what changed, why, and whether existing callers are affected.
5. Leave **Set as the latest release** ticked and select **Publish release**.

Never move or delete a published release or its tag — callers may be pinned to it. If a release turns out to be wrong, fix forward with a new version.

## Superseded releases

When a newer version replaces a faulty one (for example, `v1.0.10` fixing `v1.0.9`):

1. Publish the fix as a new version, as above.
2. Edit the faulty release on GitHub and add this line to the top of its notes:
   ```
   > **Superseded by vX.Y.Z** — <what was wrong, in one line>. Use vX.Y.Z instead.
   ```
3. Add a `### Known issues` entry to the faulty release's notes with more detail, if one line isn't enough.

Don't delete the superseded release: callers pinned to it still need it to resolve, and the note tells them why to move.

## Rolling out a new version to callers

Don't push a new version to every caller at once. Move repositories forward deliberately, in staged-wave order (pilot → similar deployable services → repos with different integration patterns → libraries).

