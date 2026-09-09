# Inputs, secrets and outputs reference

This document only describes workflows/actions that actually exist in this repo today. For the target design of the pieces not yet built, see the source Implementation Guide — treat anything below that isn't listed here as **not yet implemented**, not as a stable interface you can call.

### Why `snyk-auth` is referenced externally, not by local path

`reusable-security.yml`, `reusable-container.yml`, and `reusable-publish.yml` call `actions/snyk-auth` — which lives in this same repo — via a pinned external reference (`ministryofjustice/cica-devsecops-workflows/actions/snyk-auth@vX.Y.Z`), not a local path like `./actions/snyk-auth`. This looks redundant but isn't: these three files are *reusable* workflows, meant to be called via `workflow_call` from other repositories (`cica-apply-web`, and eventually its siblings). When a job in one of them runs, its `github.*` context (and whatever `actions/checkout` checks out by default) reflects the **calling** repository, not this one — so a local path would resolve against the caller's files, where `actions/snyk-auth` doesn't exist, and the step would fail. The external reference tells GitHub Actions to fetch the action from this repo specifically, regardless of what the caller checked out.

One consequence: **tagging a new release does not automatically update these three references.** See the release checklist in `docs/release-process.md`.

## `.github/workflows/reusable-node-ci.yml`

Runs `npm audit`, tests, and lint as three separate jobs (`npm-audit`, `test`, `lint`), matching the equivalent jobs in `cica-apply-web`'s `pipeline.yml`.

### Inputs

| Input | Type | Default | Required | Purpose |
|---|---|---|---|---|
| `node-version` | string | `24.18.1` | No | Node.js version used by every job in this workflow |
| `npm-audit-level` | string | `moderate` | No | Passed to `npm audit --audit-level=<value>` |
| `test-command` | string | `npm test` | No | Command used to run the caller's test suite |
| `lint-command` | string | `npm run lint` | No | Command used to run the caller's linter |
| `working-directory` | string | `.` | No | Directory all steps run from — for callers whose `package.json` isn't at repo root |

### Secrets

None. This workflow doesn't need any secrets.

### Outputs

None currently exposed.

### Example call

```yaml
jobs:
  ci:
    uses: ministryofjustice/cica-devsecops-workflows/.github/workflows/reusable-node-ci.yml@v1.0.0
    with:
      node-version: '24.18.1'
      test-command: 'npx jest --ci --runInBand --bail --silent --coverage --projects jest.config.js jest.config.jsdom.js'
      lint-command: 'npx eslint .'
```

---

## `actions/snyk-auth`

Composite action. Exchanges a Snyk service account's OAuth client ID/secret for a short-lived access token via the client-credentials grant.

### Inputs

| Input | Required | Default | Purpose |
|---|---|---|---|
| `client-id` | Yes | — | Snyk service account OAuth client ID |
| `client-secret` | Yes | — | Snyk service account OAuth client secret |
| `api-url` | No | `https://api.snyk.io` | Snyk API base URL |

### Outputs

| Output | Description |
|---|---|
| `token` | Short-lived Snyk OAuth access token. Already masked (`::add-mask::`) before being written to `$GITHUB_OUTPUT` — safe to pass to subsequent steps, will never appear in plaintext in logs. |

### Example call

```yaml
- name: Get Snyk OAuth token
  id: snyk-auth
  uses: ministryofjustice/cica-devsecops-workflows/actions/snyk-auth@v1.0.0
  with:
    client-id: ${{ secrets.SNYK_CLIENT_ID }}
    client-secret: ${{ secrets.SNYK_CLIENT_SECRET }}
- run: snyk test --severity-threshold=high
  env:
    SNYK_OAUTH_TOKEN: ${{ steps.snyk-auth.outputs.token }}
```

---

## `.github/workflows/reusable-security.yml`

⚠️ **Not shippable yet** — this workflow's own calls to `actions/snyk-auth` are pinned to `@v1.0.0`, but that tag doesn't exist yet since this repo hasn't been pushed or released. See the `TODO` comments in the file itself. Fix by cutting the `v1.0.0` release (see `docs/release-process.md`), not by editing these lines again.

Runs `validate-action-pinning` (now scanning both `.github/workflows` **and** `.github/actions` in the caller repo), `secret-scan` (TruffleHog, verified secrets only), `snyk-open-source` (SCA, blocking), `snyk-code` (SAST, informational by default), and `snyk-iac` (informational by default).

### Inputs

| Input | Type | Default | Purpose |
|---|---|---|---|
| `node-version` | string | `24.18.1` | Node.js version for the Snyk jobs |
| `snyk-version` | string | `1.1306.3` | Pinned Snyk CLI version |
| `snyk-api-url` | string | `https://api.snyk.io` | Snyk API base URL |
| `working-directory` | string | `.` | Directory to run npm-related steps from |
| `validate-action-pinning` | boolean | `true` | Set `false` to skip the pinning check |
| `secret-scan` | boolean | `true` | Set `false` to skip TruffleHog |
| `oss-severity` | string | `high` | Severity threshold for the Snyk Open Source scan |
| `snyk-code-enabled` | boolean | `true` | Whether Snyk Code runs at all |
| `snyk-code-blocking` | boolean | `false` | Whether a Snyk Code finding fails the job, or is informational |
| `snyk-iac-enabled` | boolean | `true` | Whether Snyk IaC runs at all |
| `snyk-iac-blocking` | boolean | `false` | Whether a Snyk IaC finding fails the job, or is informational |
| `iac-path` | string | `kube_deploy/` | Path passed to `snyk iac test` |

### Secrets

| Secret | Required | Purpose |
|---|---|---|
| `SNYK_CLIENT_ID` | Yes | Passed through to `snyk-auth` |
| `SNYK_CLIENT_SECRET` | Yes | Passed through to `snyk-auth` |

### Example call

```yaml
jobs:
  security:
    uses: ministryofjustice/cica-devsecops-workflows/.github/workflows/reusable-security.yml@v1.0.0
    with:
      iac-path: 'kube_deploy/'
      snyk-code-blocking: false
      snyk-iac-blocking: false
    secrets:
      SNYK_CLIENT_ID: ${{ secrets.SNYK_CLIENT_ID }}
      SNYK_CLIENT_SECRET: ${{ secrets.SNYK_CLIENT_SECRET }}
```

Note: `snyk-monitor` (uploading a dependency snapshot to Snyk's dashboard) is **not** part of this workflow. The source Implementation Guide's own section 2 table describes it as belonging to a separate "post-merge/monitor workflow," but doesn't allocate that a file in the section 5 repository layout — that's a gap in the source document, not a decision made here. Flag it with whoever owns that document before assuming where it should live.

---

## `.github/workflows/reusable-container.yml`

⚠️ **Not shippable yet** — same unreleased `@v1.0.0` pinning issue on its `snyk-auth` calls as `reusable-security.yml`. See the `TODO` comments in the file.

Runs `docker-build` (build + Snyk container scan + archive as an artifact), `container-smoke-test` (start the container, optionally health-check it, confirm it's actually running), and `sbom-generate` (CycloneDX SBOM of the built image).

Two things worth knowing that go beyond a straight port of the `cica-apply-web` pilot:

- **The smoke test's "is it running" check is now a real assertion**, not just a log line. The pilot's version ran a bare `docker ps` with no assertion on its output — it would "pass" even if the container had already crashed, since nothing checked what `docker ps` actually returned. This version filters by container name and running status and fails if that comes back empty.
- **`health-check-path` is optional, off by default.** If set, the smoke test will `curl` that path after a short wait and fail if it doesn't respond. Left empty, it falls back to just the running-status check. This is deliberately not forced on — a caller's app may need a live database or other external dependency to even boot, which this standalone smoke-test container won't have, and a forced health check would then fail a perfectly good image. Only set this for an app confirmed to boot and respond without needing anything the smoke test doesn't provide.

### Inputs

| Input | Type | Default | Required | Purpose |
|---|---|---|---|---|
| `dockerfile` | string | `Dockerfile` | No | Path to the Dockerfile |
| `docker-context` | string | `.` | No | Docker build context |
| `build-target` | string | `production` | No | Dockerfile stage to build |
| `image-name` | string | — | **Yes** | Local tag to build the image as |
| `artifact-name` | string | `docker-image` | No | Name of the archived-image artifact |
| `artifact-retention-days` | number | `1` | No | Retention for the image artifact |
| `policy-path` | string | `.snyk` | No | Snyk policy file used by the container scan |
| `container-severity` | string | `high` | No | Severity threshold for the container scan |
| `snyk-version` | string | `1.1306.3` | No | Pinned Snyk CLI version |
| `snyk-api-url` | string | `https://api.snyk.io` | No | Snyk API base URL |
| `smoke-test-host-port` | number | `3001` | No | Host-side port for the smoke test |
| `smoke-test-container-port` | number | — | **Yes** | Port the app listens on *inside* the container — must match the app, not an arbitrary default |
| `health-check-path` | string | `''` (off) | No | HTTP path to curl after starting the container. See caveat above before setting this. |
| `sbom-format` | string | `cyclonedx1.6+json` | No | SBOM output format |
| `sbom-artifact-retention-days` | number | `90` | No | Retention for the SBOM artifact |

### Secrets

Same as `reusable-security.yml`: `SNYK_CLIENT_ID`, `SNYK_CLIENT_SECRET` (both required).

### Outputs

| Output | Description |
|---|---|
| `image-artifact` | Name of the uploaded archived-image artifact (equal to whatever `artifact-name` was set to), for a downstream `reusable-publish.yml` call to download |

### Example call

```yaml
jobs:
  container:
    needs: [ci, security]
    uses: ministryofjustice/cica-devsecops-workflows/.github/workflows/reusable-container.yml@v1.0.0
    with:
      image-name: cica/cica-repo-dev
      smoke-test-container-port: 3000
    secrets:
      SNYK_CLIENT_ID: ${{ secrets.SNYK_CLIENT_ID }}
      SNYK_CLIENT_SECRET: ${{ secrets.SNYK_CLIENT_SECRET }}
```

---

## Not yet implemented

All five core reusable workflows described in the source Implementation Guide's section 6 now exist. Nothing left in this "not yet implemented" category.

---

## `.github/workflows/reusable-publish.yml`

⚠️ **Not shippable yet** — same unreleased `@v1.0.0` pinning issue as the two files above.

Runs `publish-image` (AWS OIDC → ECR push → digest capture), `artifact-attestation` (GitHub build provenance), and an optional `snyk-container-monitor`.

**Design note**: the pilot's container-monitor job only ran on one specific branch (`cw-deploy`) — hardcoded knowledge this generic reusable workflow shouldn't have, since other callers will have different branch conventions. That's exposed here as a `run-container-monitor` input instead; set it from the caller's own `if:` logic (e.g. `run-container-monitor: ${{ github.ref == 'refs/heads/main' }}`).

### Inputs

| Input | Type | Default | Required | Purpose |
|---|---|---|---|---|
| `artifact-name` | string | `docker-image` | No | Must match the container workflow's `artifact-name`/`image-artifact` output |
| `image-name` | string | — | **Yes** | Local tag the image was built and archived as |
| `ecr-region` | string | — | **Yes** | AWS region for the ECR repository |
| `ecr-repository` | string | — | **Yes** | ECR repository name |
| `run-container-monitor` | boolean | `true` | No | See design note above |
| `snyk-version` | string | `1.1306.3` | No | Only used if `run-container-monitor` is true |
| `snyk-api-url` | string | `https://api.snyk.io` | No | Only used if `run-container-monitor` is true |

### Secrets

| Secret | Required | Purpose |
|---|---|---|
| `ECR_ROLE_TO_ASSUME` | Yes | AWS OIDC role for ECR push |
| `ECR_REGISTRY_URL` | Yes | ECR registry hostname |
| `SNYK_CLIENT_ID` | No | Only needed if `run-container-monitor` is true |
| `SNYK_CLIENT_SECRET` | No | Only needed if `run-container-monitor` is true |

### Outputs

| Output | Description |
|---|---|
| `image-digest` | Digest of the pushed image |
| `image-uri` | Full `registry/repository:tag` reference — feed this into `reusable-deploy-kubernetes.yml`'s `image-uri` input |

### Example call

```yaml
jobs:
  publish:
    needs: container
    permissions:
      contents: read
      id-token: write
      attestations: write
    uses: ministryofjustice/cica-devsecops-workflows/.github/workflows/reusable-publish.yml@v1.0.0
    with:
      image-name: cica/cica-repo-dev
      ecr-region: ${{ vars.ECR_REGION }}
      ecr-repository: ${{ vars.ECR_REPOSITORY }}
      run-container-monitor: ${{ github.ref == 'refs/heads/cw-deploy' }}
    secrets:
      ECR_ROLE_TO_ASSUME: ${{ secrets.ECR_ROLE_TO_ASSUME }}
      ECR_REGISTRY_URL: ${{ secrets.ECR_REGISTRY_URL }}
      SNYK_CLIENT_ID: ${{ secrets.SNYK_CLIENT_ID }}
      SNYK_CLIENT_SECRET: ${{ secrets.SNYK_CLIENT_SECRET }}
```

---

## `.github/workflows/reusable-deploy-kubernetes.yml`

✅ No `@main` issue — this workflow doesn't call `snyk-auth`, so it isn't affected by the pinning problem the other three have.

Single `deploy` job: authenticates to the cluster (same format-tolerant cert handling as the pilot — accepts either raw PEM or base64), patches and applies the Deployment manifest, optionally applies Service/Ingress manifests and a kustomize base, and optionally restarts+waits on an additional shared Deployment.

**Design note**: the pilot's rollout-restart step was specific to its own `custom-errors` shared component (a ConfigMap-backed Deployment that needs restarting to pick up changes, since Kubernetes doesn't do that automatically). That's generalized here as `additional-rollout-restart-deployment` — leave it empty for callers that don't have an equivalent pattern.

### Inputs

| Input | Type | Default | Required | Purpose |
|---|---|---|---|---|
| `environment` | string | — | **Yes** | GitHub Environment to gate this job behind |
| `namespace` | string | — | **Yes** | Kubernetes namespace to deploy into |
| `manifest-dir` | string | — | **Yes** | Directory containing this environment's manifests |
| `container-name` | string | — | **Yes** | Container name inside the Deployment manifest to patch |
| `image-uri` | string | — | **Yes** | Full image reference to deploy — typically `reusable-publish.yml`'s `image-uri` output |
| `deploy-manifest` | string | `deploy.yml` | No | Deployment manifest filename within `manifest-dir` |
| `service-manifest` | string | `service.yml` | No | Service manifest filename. Empty string skips it. |
| `ingress-manifest` | string | `ingress.yml` | No | Ingress manifest filename. Empty string skips it. |
| `apply-kustomize` | boolean | `true` | No | Whether to also run `kubectl apply -k` against `manifest-dir` |
| `additional-rollout-restart-deployment` | string | `''` (off) | No | See design note above |

### Secrets

| Secret | Required | Purpose |
|---|---|---|
| `KUBE_CERT` | Yes | Cluster CA certificate (raw PEM or base64, auto-detected) |
| `KUBE_CLUSTER` | Yes | Cluster hostname |
| `KUBE_TOKEN` | Yes | ServiceAccount bearer token, scoped to this environment/namespace |

### Example call

```yaml
jobs:
  deploy-dev:
    needs: publish
    if: github.ref == 'refs/heads/cw-deploy'
    uses: ministryofjustice/cica-devsecops-workflows/.github/workflows/reusable-deploy-kubernetes.yml@v1.0.0
    with:
      environment: dev
      namespace: claim-criminal-injuries-compensation-dev
      manifest-dir: kube_deploy/Dev
      container-name: webapp
      image-uri: ${{ needs.publish.outputs.image-uri }}
      additional-rollout-restart-deployment: custom-errors
    secrets:
      KUBE_CERT: ${{ secrets.KUBE_CERT }}
      KUBE_CLUSTER: ${{ secrets.KUBE_CLUSTER }}
      KUBE_TOKEN: ${{ secrets.KUBE_TOKEN }}
```
