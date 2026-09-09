
**Current state**: only `reusable-node-ci.yml` and the `snyk-auth` composite action exist. This guide only covers adopting those two — do not attempt to onboard a repo's full pipeline (security/container/publish/deploy) yet, since those workflows don't exist here.

Also: **nothing in this repo has been tagged yet.** Don't onboard a real production repository until a `v1.0.0` (or similar) release exists — see `release-process.md`. This guide is written for when that's true; until then, treat this as a preview of the process, not something to actually run against a production caller.

## Prerequisites

Before a repository can call a workflow from here:

1. The calling repository must have the secrets/variables the workflow needs already configured (for `reusable-node-ci.yml`, none are required; for anything Snyk-related, `SNYK_CLIENT_ID`/`SNYK_CLIENT_SECRET`).
2. Repository or organization policy must permit calling workflows from this repo — confirm with whoever administers GitHub Actions policy for the org if you get a permissions error the first time.

## Steps

1. **Decide on a caller workflow file** in the target repo, e.g. `.github/workflows/ci.yml`.
2. **Reference the reusable workflow, pinned to a specific tag** (never `@main`):

   ```yaml
   name: CI

   on:
     push:

   jobs:
     ci:
       uses: ministryofjustice/cica-devsecops-workflows/.github/workflows/reusable-node-ci.yml@v1.0.0
       with:
         node-version: '24.18.1'
         test-command: 'npm test'
         lint-command: 'npm run lint'
   ```

3. **Override the `test-command`/`lint-command` inputs** to match the target repo's actual `package.json` scripts if they differ from the plain `npm test`/`npm run lint` defaults.
4. **Push and check the Actions tab** for the calling repo — you should see `npm-audit`, `test`, and `lint` jobs run, sourced from this repo's workflow.
5. **Compare results against whatever the repo's existing CI currently reports** (test count, coverage, lint pass/fail) before removing the old CI config — same migration-parity principle used for the `cica-apply-web` pilot itself: don't cut over until the new path is proven to produce the same result as the old one.

## What's still missing for a full pipeline

A repository can't yet get a complete replacement pipeline from this repo alone — security scanning, container build/scan, ECR publish, and Kubernetes deploy all still need to stay in the calling repo's own workflow file until the corresponding reusable workflows are built here. Check `README.md`'s status table for current progress.
