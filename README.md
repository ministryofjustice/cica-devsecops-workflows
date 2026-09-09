# cica-devsecops-workflows

Centrally managed, reusable GitHub Actions workflows and composite actions for the CICA Apply repository estate.

This repo exists to move common CI/CD and DevSecOps logic (build, test, security scanning, container build/scan, publish, deploy) out of each individual repository's own workflow file and into one governed, versioned place. Application repositories keep a thin "caller" workflow that references these reusable workflows and supplies repository-specific inputs; this repo owns how the standard jobs are actually implemented.

## Status

**Early scaffold — not yet ready for production callers.** Only a subset of the target design is implemented so far. Do not point a production repository's pipeline at this repo yet.

| Piece | Status |
|---|---|
| `actions/snyk-auth` | ✅ Implemented — Snyk OAuth client-credentials token exchange, carried over from `cica-apply-web`'s pilot implementation |
| `.github/workflows/reusable-node-ci.yml` | ✅ Implemented — npm audit, test, lint |
| `.github/workflows/reusable-security.yml` | ⚠️ Implemented but not shippable yet — its `snyk-auth` references are pinned to `@v1.0.0`, a tag that doesn't exist yet (this repo hasn't been pushed or released). Fix by cutting the `v1.0.0` release (see the TODO comments in the file). Otherwise covers action pinning (now including `.github/actions/`), verified-secret scanning, Snyk Open Source, Snyk Code, Snyk IaC |
| `.github/workflows/reusable-container.yml` | ⚠️ Implemented but not shippable yet — same unreleased `@v1.0.0` pinning issue as `reusable-security.yml`. Covers Docker build, Snyk container scan, smoke test, and SBOM generation |
| `.github/workflows/reusable-publish.yml` | ⚠️ Implemented but not shippable yet — same unreleased `@v1.0.0` pinning issue. Covers AWS OIDC, ECR push, digest capture, build provenance, and (caller-controlled) Snyk container monitoring |
| `.github/workflows/reusable-deploy-kubernetes.yml` | ✅ Implemented — environment-agnostic Kubernetes deploy, no pinning issue (doesn't call `snyk-auth`) |

**All five core reusable workflows now exist.** Still blocking before any real caller can use this repo: cutting the actual `v1.0.0` release the three files above already reference (three files affected), a real `CODEOWNERS` owner, and pushing this repo to GitHub at all.

## Pilot

The reference implementation this repo is extracted from is `ministryofjustice/cica-apply-web`'s `.github/workflows/pipeline.yml` — a repository-specific GitHub Actions pipeline that itself replaced that repo's CircleCI configuration. That pipeline is the functional baseline every reusable workflow here is expected to reproduce before it's considered ready to adopt.

## Repository layout

```
cica-devsecops-workflows/
├── .github/workflows/     # the reusable workflows themselves (workflow_call)
├── actions/                # composite actions shared across the reusable workflows
├── docs/                   # inputs/outputs reference, onboarding guide, release process
├── CHANGELOG.md
├── CODEOWNERS
└── README.md
```

## Using a reusable workflow from this repo

Once a given workflow is marked implemented above, a caller repository references it like:

```yaml
jobs:
  ci:
    uses: ministryofjustice/cica-devsecops-workflows/.github/workflows/reusable-node-ci.yml@v1.0.0
    with:
      node-version: '24.18.1'
      test-command: 'npm test'
      lint-command: 'npm run lint'
```

Always pin to a specific released tag (`@v1.2.0`) or commit SHA, never `@main`, for any real caller — see `docs/release-process.md`.

See `docs/onboarding.md` for a full walkthrough and `docs/inputs.md` for the input/output/secret reference of each workflow.
