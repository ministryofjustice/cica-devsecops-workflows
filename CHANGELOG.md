# Changelog

All notable changes to this repository are documented here. Format loosely follows [Keep a Changelog](https://keepachangelog.com/) — dated entries, grouped by Added/Changed/Fixed.

## [Unreleased]

### Fixed
- `reusable-security.yml`'s `run-snyk-monitor` input description no longer contains a literal `${{ }}` expression — see the `v1.0.0` entry below for what this broke. Rephrased the example as prose instead; the actual worked example lives in `docs/inputs.md`, which GitHub Actions never parses, so it carries no risk of the same bug. Not yet confirmed working end-to-end — see `docs/release-process.md`'s test-before-tag step. Rename this section once that's actually passed.

## [1.0.1] - 2026-09-10

**⚠️ Broken — do not use, fixed in a later version once this fix is confirmed.** Inherits the `reusable-security.yml` parse error from `v1.0.0` below (this version only added `ci.yml` on top, didn't touch `reusable-security.yml`).

### Added
- `.github/workflows/ci.yml` — this repo's own PR/push CI: YAML syntax validation, action-pinning enforcement, and verified-secret scanning against this repo's own files (previously done manually, ad hoc). 

## [1.0.0] - 2026-09-10

**⚠️ Broken — do not use, fixed in a later version once this fix is confirmed.** `reusable-security.yml`'s `run-snyk-monitor` input `description` contained a literal `${{ github.ref == 'refs/heads/cw-deploy' }}` expression, meant only as prose showing an example value. GitHub Actions evaluates `${{ }}` wherever it appears in a workflow file, including inside `description:` text — and the `github` context isn't available in that evaluation scope, so every caller of `reusable-security.yml` failed at parse time with `Unrecognized named-value: 'github'`. Discovered when `cica-apply-web` made its first real call against this workflow. No caller successfully ran against either this version or `v1.0.1` before the bug was found.

### Added
- Initial repository scaffold: directory layout for `.github/workflows`, `actions/`, `docs/`.
- `actions/snyk-auth` — Snyk OAuth client-credentials token exchange composite action, carried over from `cica-apply-web`'s pilot implementation, including the shell-injection hardening applied there (inputs passed via `env:`, not interpolated directly into the script).
- `.github/workflows/reusable-node-ci.yml` — parameterised npm audit / test / lint workflow, reproducing the equivalent jobs from `cica-apply-web`'s `pipeline.yml`.
- `.github/workflows/reusable-security.yml` — action pinning, verified-secret scanning (TruffleHog), Snyk Open Source/Monitor/Code/IaC, reproducing the equivalent jobs from `cica-apply-web`'s `pipeline.yml`. Two improvements over the pilot baked in while rebuilding this fresh: the action-pinning check now also scans `.github/actions/` in the caller repo (not just `.github/workflows/`, a gap identified in review of the pilot), and the Snyk Code/IaC jobs now correctly pin their Node version via `actions/setup-node`, `snyk-monitor` was added as well.
- `.github/workflows/reusable-container.yml` — Docker build, Snyk container scan, smoke test, and SBOM generation, reproducing the equivalent jobs from `cica-apply-web`'s `pipeline.yml`. The smoke test matches the pilot's (cica-web) original behaviour (starts the container, logs `docker ps`, doesn't assert on it) — see Known issues below for more.
- `.github/workflows/reusable-publish.yml` — AWS OIDC authentication, ECR push, image digest capture, build provenance attestation, and an optional Snyk container-monitor job, reproducing the equivalent jobs from `cica-apply-web`'s `pipeline.yml`. The pilot's container-monitor job was hardcoded to only run on one specific branch (`cw-deploy`) — generalised here as a `run-container-monitor` input the caller sets from its own branch logic, since a generic reusable workflow shouldn't know any particular caller's branch conventions.
- `.github/workflows/reusable-deploy-kubernetes.yml` — environment-agnostic Kubernetes deploy, reproducing the equivalent jobs from `cica-apply-web`'s `pipeline.yml`. The pilot's rollout-restart step (for its `custom-errors` shared component, needed because Kubernetes doesn't auto-restart pods when a mounted ConfigMap changes) is generalised as an optional `additional-rollout-restart-deployment` input.

### Known issues
- `reusable-container.yml`'s `container-smoke-test` job doesn't assert the container actually stayed running — it logs `docker ps` but doesn't check the result, (matching the cica-webs original (non-blocking) behaviour). A stricter version (asserting via `docker ps --filter status=running`) was tried and reverted: the smoke-test container gets no environment variables, and every deployable-service caller in this estate needs some minimal boot-time config (confirmed for `cica-apply-web`, which crashes on a missing `CW_COOKIE_SECRET`; suspected for data-capture-service/notify-gateway/application-service too). Fix: add a `smoke-test-env` input (caller-supplied `KEY=value` pairs passed to the container) so each caller can provide dummy config, then restore the assertion. See the `TODO` comment in the file. The optional `health-check-path` input (an HTTP-level check) was removed for the same reason rather than left in as dead, guaranteed-broken-if-enabled config — no caller had set it, and it has the identical missing-env-var problem. Reintroduce alongside the running-check once `smoke-test-env` exists.

