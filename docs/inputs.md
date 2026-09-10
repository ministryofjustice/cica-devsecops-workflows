# Usage reference

For the exact inputs, secrets, and outputs of a workflow, read its `on.workflow_call` block in the file itself — every input already carries a `description`, `type`, `required`, and `default` there. This document covers: worked example calls, and the design rationale behind choices that aren't obvious from reading the YAML.

### Why `snyk-auth` is referenced externally, not by local path

`reusable-security.yml`, `reusable-container.yml`, and `reusable-publish.yml` call `actions/snyk-auth` (which lives in this same repo) via a pinned external reference (`ministryofjustice/cica-devsecops-workflows/actions/snyk-auth@vX.Y.Z`), not a local path like `./actions/snyk-auth`. This looks redundant but isn't: these three files are *reusable* workflows, meant to be called via `workflow_call` from other repositories (`cica-apply-web`, and eventually its siblings). When a job in one of them runs, its `github.*` context (and whatever `actions/checkout` checks out by default) reflects the **calling** repository, not this one — so a local path would resolve against the caller's files, where `actions/snyk-auth` doesn't exist, and the step would fail. The external reference tells GitHub Actions to fetch the action from this repo specifically, regardless of what the caller checked out.

One consequence: **tagging a new release does not automatically update these three references.** See the release checklist in `docs/release-process.md`.

---

## `.github/workflows/reusable-node-ci.yml`

Runs `npm audit`, tests, and lint as three separate jobs (`npm-audit`, `test`, `lint`), matching the equivalent jobs in `cica-apply-web`'s `pipeline.yml`.

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

Composite action. Exchanges a Snyk service account's OAuth client ID/secret for a short-lived access token via the client-credentials grant. Its `token` output is already masked (`::add-mask::`) before being written to `$GITHUB_OUTPUT` — safe to pass to subsequent steps, will never appear in plaintext in logs.

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

Runs `validate-action-pinning` (now scanning both `.github/workflows` **and** `.github/actions` in the caller repo), `secret-scan` (TruffleHog, verified secrets only), `snyk-open-source` (SCA, blocking), `snyk-monitor` (uploads a dependency snapshot to Snyk's dashboard, non-blocking), `snyk-code` (SAST, informational by default), and `snyk-iac` (informational by default).

`snyk-monitor` is different from `snyk-open-source`'s `snyk test`: it doesn't check anything or fail the job, it just gives Snyk's dashboard a snapshot to watch for vulnerabilities disclosed *after* this run. Its `run-snyk-monitor` input defaults to `true`, but — same reasoning as `reusable-publish.yml`'s `run-container-monitor` — the pilot only ran this on one specific deploy branch, so a caller should set it from its own branch logic rather than relying on a default.

### Example call

```yaml
jobs:
  security:
    uses: ministryofjustice/cica-devsecops-workflows/.github/workflows/reusable-security.yml@v1.0.0
    with:
      iac-path: 'kube_deploy/'
      snyk-code-blocking: false
      snyk-iac-blocking: false
      run-snyk-monitor: ${{ github.ref == 'refs/heads/cw-deploy' }}
    secrets:
      SNYK_CLIENT_ID: ${{ secrets.SNYK_CLIENT_ID }}
      SNYK_CLIENT_SECRET: ${{ secrets.SNYK_CLIENT_SECRET }}
```

---

## `.github/workflows/reusable-container.yml`

Runs `docker-build` (build + Snyk container scan + archive as an artifact), `container-smoke-test` (start the container, log its status), and `sbom-generate` (CycloneDX SBOM of the built image).

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

## `.github/workflows/reusable-publish.yml`

Runs `publish-image` (AWS OIDC → ECR push → digest capture), `artifact-attestation` (GitHub build provenance), and an optional `snyk-container-monitor`.

**Design note**: the pilot's container-monitor job only ran on one specific branch (`cw-deploy`) — hardcoded knowledge this generic reusable workflow shouldn't have, since other callers will have different branch conventions. That's exposed here as a `run-container-monitor` input instead; set it from the caller's own `if:` logic (e.g. `run-container-monitor: ${{ github.ref == 'refs/heads/main' }}`).

Its `image-uri` output feeds directly into `reusable-deploy-kubernetes.yml`'s `image-uri` input — see that workflow's example call below.

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

Single `deploy` job: authenticates to the cluster (same format-tolerant cert handling as the pilot — accepts either raw PEM or base64), patches and applies the Deployment manifest, optionally applies Service/Ingress manifests and a kustomize base, and optionally restarts+waits on an additional shared Deployment.

**Design note**: the pilot's rollout-restart step was specific to its own `custom-errors` shared component (a ConfigMap-backed Deployment that needs restarting to pick up changes, since Kubernetes doesn't do that automatically). That's generalised here as `additional-rollout-restart-deployment` — leave it empty for callers that don't have an equivalent pattern. (only cica-web has)

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
