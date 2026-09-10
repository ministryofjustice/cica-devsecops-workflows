# cica-devsecops-workflows

Centrally managed, reusable GitHub Actions workflows and composite actions for the CICA Apply repository estate.

This repo exists to move common CI/CD and DevSecOps logic (build, test, security scanning, container build/scan, publish, deploy) out of each individual repository's own workflow file and into one governed, versioned place. Application repositories keep a thin "caller" workflow that references these reusable workflows and supplies repository-specific inputs; this repo owns how the standard jobs are actually implemented.

## Status

**First tagged release: `v1.0.0`.** All five core reusable workflows and the shared `snyk-auth` composite action are implemented and safe to reference from a real caller, pinned to `@v1.0.0`.

| Piece | Status |
|---|---|
| `actions/snyk-auth` | ✅ Implemented — Snyk OAuth client-credentials token exchange, carried over from `cica-apply-web`'s pilot implementation |
| `.github/workflows/reusable-node-ci.yml` | ✅ Implemented — npm audit, test, lint |
| `.github/workflows/reusable-security.yml` | ✅ Implemented — action pinning (including `.github/actions/`), verified-secret scanning, Snyk Open Source, Snyk Code, Snyk IaC |
| `.github/workflows/reusable-container.yml` | ✅ Implemented — Docker build, Snyk container scan, smoke test, and SBOM generation |
| `.github/workflows/reusable-publish.yml` | ✅ Implemented — AWS OIDC, ECR push, digest capture, build provenance, and (caller-controlled) Snyk container monitoring |
| `.github/workflows/reusable-deploy-kubernetes.yml` | ✅ Implemented — environment-agnostic Kubernetes deploy |

See `CHANGELOG.md`'s "Known issues".

## Repository layout

```
cica-devsecops-workflows/
├── .github/workflows/     # the reusable workflows (workflow_call) plus this repo's own PR CI
├── actions/                # composite actions shared across the reusable workflows
├── docs/                   # inputs/outputs reference, onboarding guide, release process
├── CHANGELOG.md
└── README.md
```

This repo's own PRs are checked by `.github/workflows/ci.yml` — YAML validation, action-pinning enforcement, and secret scanning against this repo's own files. It's a normal `pull_request`/`push`-triggered workflow, not a reusable one, so it's not part of what a caller invokes.

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

See `docs/onboarding.md` for a full walkthrough and `docs/inputs.md` for a worked example call per workflow. For the exact inputs/secrets/outputs of a given workflow, read its `on.workflow_call` block in the file itself.
