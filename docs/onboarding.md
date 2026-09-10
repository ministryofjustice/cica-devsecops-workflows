# Onboarding a repository to these reusable workflows

**Current state**: all five reusable workflows (`reusable-node-ci.yml`, `reusable-security.yml`, `reusable-container.yml`, `reusable-publish.yml`, `reusable-deploy-kubernetes.yml`) and the `snyk-auth` composite action exist and are tagged at `v1.0.0`. A repository can onboard a full pipeline from this repo now, not just CI checks.

## Prerequisites

Before a repository can call a workflow from here:

1. The calling repository must have the secrets/variables each workflow needs already configured — see the `secrets:` block in each workflow's `on.workflow_call` section (e.g. `SNYK_CLIENT_ID`/`SNYK_CLIENT_SECRET` for anything Snyk-related, `ECR_ROLE_TO_ASSUME`/`ECR_REGISTRY_URL` for `reusable-publish.yml`, `KUBE_CERT`/`KUBE_CLUSTER`/`KUBE_TOKEN` for `reusable-deploy-kubernetes.yml`).
2. Repository or organisation policy must permit calling workflows from this repo — confirm with whoever administers GitHub Actions policy for the org if you get a permissions error the first time.
3. Jobs that call a reusable workflow needing elevated permissions (`security-events: write`, `id-token: write`, `attestations: write`, etc.) must declare those explicitly on the *calling* job — a called reusable workflow can't get more than its caller grants, regardless of what the reusable workflow's own inner jobs request. See `cica-apply-web`'s `pipeline.yml` for worked examples of this on its `security`, `container`, and `publish` jobs.

## Steps

1. **Decide on a caller workflow file** in the target repo, e.g. `.github/workflows/ci.yml` (or extend an existing one).
2. **Reference each reusable workflow you need, pinned to a specific tag** (never `@main`). Minimal CI-only example:

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

   For a full pipeline (CI, security scanning, container build/scan, ECR publish, Kubernetes deploy), see `cica-apply-web`'s `pipeline.yml` — it chains all five workflows together with `needs:`, branch-gated `if:` conditions for its own deploy branches, and secret/permission pass-through.
3. **Override inputs** to match the target repo's actual conventions (test/lint commands, image name, ECR repository, Kubernetes namespace, etc.) — every workflow's inputs default to `cica-apply-web`'s own pilot values where a default makes sense, so only override what's actually different for your repo.
4. **Push and check the Actions tab** for the calling repo — confirm each job you wired up runs and reports the jobs you expect (e.g. `npm-audit`/`test`/`lint` from `reusable-node-ci.yml`).
5. **Compare results against whatever the repo's existing CI/CD currently reports** (test count, coverage, lint pass/fail, deploy outcome) before removing the old pipeline config — same migration-parity principle used for the `cica-apply-web` pilot itself: don't cut over until the new path is proven to produce the same result as the old one.
6. **Roll out in stages**, per `docs/release-process.md` — don't wire up every workflow across every environment in one go. CI-only first, then security/container, then publish, then deploy, non-prod before prod.
