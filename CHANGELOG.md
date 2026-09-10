# Changelog

All notable changes to this repository are documented here. Format loosely follows [Keep a Changelog](https://keepachangelog.com/) — dated entries, grouped by Added/Changed/Fixed.

## [1.0.1] - 2026-09-10

### Added
- `.github/workflows/ci.yml` — this repo's own PR/push CI: YAML syntax validation, action-pinning enforcement, and verified-secret scanning against this repo's own files (previously done manually, ad hoc). 

## [1.0.0] - 2026-09-10

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

