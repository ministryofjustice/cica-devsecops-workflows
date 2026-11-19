# Reconciling a `.snyk` policy with what Snyk reports

Over time a `.snyk` policy file drifts out of step with reality. An ignore you
added for an unfixable CVE stays in the file long after the dependency was
removed or the upstream fix shipped; meanwhile a newly disclosed vulnerability
shows up in the scan with no matching entry. Neither direction is obvious from
reading the file — you have to cross-check it against a live scan.

`actions/snyk-policy-reconcile/snyk-policy-reconcile.sh` does that cross-check. It is a **read-only
triage aid**: it tells you which entries to look at and leaves every decision —
and every line of `.snyk` — to you.

> **It never edits `.snyk`.** Removing a stale entry, or adding a new one with a
> reason and an expiry, stays hand-written and reviewed. A good ignore records
> real triage (for example, proof that a vulnerable code path is unreachable),
> and that judgement is exactly what a script cannot produce. See
> [dependency-and-container-hygiene.md §4](dependency-and-container-hygiene.md#4-how-this-ties-back-to-the-security-slas).

## The three buckets

The script sorts every issue ID into one of three buckets by comparing the IDs
declared in `.snyk` against the IDs the current scan reports:

| Bucket | Meaning | What to do |
|--------|---------|------------|
| **STALE** | In `.snyk`, but no current scan reports it. Fixed, removed, or the ID changed. | Candidate for **removal** from `.snyk`. Verify, then delete by hand. |
| **ACTIVE** | In `.snyk`, and a scan still reports it as suppressed by the policy. | **Keep.** The ignore is still doing work. |
| **NEW** | Reported at/above the severity threshold, not in `.snyk`, not otherwise suppressed. | Needs a **decision**: fix it, or add a reasoned, expiring ignore by hand. |

It also lists ignores whose `expires` falls within a window (default 14 days),
so you re-verify the reason before it lapses rather than being surprised when
the finding reappears.

## Both Snyk surfaces are covered

A single `.snyk` is read by two different scans in this estate, so reconciling
against only one would wrongly flag the other's entries as stale:

- **Open Source** (`snyk test`, in `reusable-security.yml`) — the npm
  dependency CVEs, e.g. `SNYK-JS-*`.
- **Container** (`snyk container test --policy-path=.snyk`, in
  `reusable-container.yml`) — the base-OS CVEs, e.g. `SNYK-DEBIAN13-*`.

The script unions both before comparing, which matches how the policy file is
actually used. Give it the container surface via `--image` (or
`--container-json`) whenever the repo ships an image; otherwise it reconciles
the Open Source surface alone.

`exclude:` entries (Snyk **Code**/SAST) are a separate mechanism and are
intentionally **not** reconciled here — only `ignore:` entries (Open Source,
Container, IaC) are in scope.

## Running it locally

Requires `jq` and `yq` (Mike Farah's Go `yq` — the Python `yq` wrapper has a
different expression syntax and will not work). Both are used to parse the scan
JSON and the `.snyk` YAML, so they are needed on every run, not just locally.
Unless you pass pre-generated JSON, you also need the `snyk` CLI on your PATH
with an authenticated session (`snyk auth`, or `SNYK_TOKEN` /
`SNYK_OAUTH_TOKEN` in the environment).

### Installing `yq` (read this before `apt install yq`)

There are two unrelated tools both called `yq`, and on Debian/Ubuntu/WSL the
obvious command installs the **wrong** one:

- **`sudo apt install yq`** installs the Python wrapper (v3.x). Its expression
  syntax is different and the script's filters will not work — the script
  detects this and refuses to run (`the 'yq' on PATH is not Mike Farah's Go
  yq`). **Do not use it.**
- **`sudo snap install yq`** installs Mike Farah's Go `yq` (v4). This works, but
  the version floats ahead of the pinned version CI uses.

The version CI pins is the `yq-version` input default in
`.github/workflows/reusable-snyk-policy-reconcile.yml` — that input is the
single source of truth, so install whatever it currently says rather than a
number copied here. To match CI byte-for-byte (recommended if you plan to run
the tests locally):

```bash
# Linux / WSL (x86_64). Use yq_linux_arm64 if `dpkg --print-architecture` is arm64.
# Read the pinned version straight from the workflow input default, so there is
# no copy of the number to drift. Run from the repo root.
YQ_VERSION=$(sed -n "/yq-version:/,/default:/s/.*default: *'\\([^']*\\)'.*/\\1/p" \
  .github/workflows/reusable-snyk-policy-reconcile.yml)
echo "Installing yq ${YQ_VERSION}"
sudo curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" \
  -o /usr/local/bin/yq
sudo chmod +x /usr/local/bin/yq
yq --version   # expect: ... version ${YQ_VERSION} (and the word "mikefarah")
```

On macOS, `brew install yq` installs Mike Farah's `yq` correctly. GitHub-hosted
`ubuntu-latest` runners already have both `jq` and `yq` preinstalled; the
reconcile workflow additionally installs the pinned `yq-version` over the top so
CI is reproducible regardless of the image's `yq`. Self-hosted or slim container
runners may need `jq`/`yq` added.

Reconcile both surfaces, letting the script run the scans:

```bash
actions/snyk-policy-reconcile/snyk-policy-reconcile.sh \
  --project-dir /path/to/cica-apply-web \
  --image cica-apply-web:latest
```

Just the npm/Open Source surface (no container):

```bash
actions/snyk-policy-reconcile/snyk-policy-reconcile.sh --project-dir /path/to/cica-apply-web
```

Offline — reconcile against JSON a pipeline already produced (no `snyk`
needed):

```bash
actions/snyk-policy-reconcile/snyk-policy-reconcile.sh \
  --policy /path/to/.snyk \
  --oss-json snyk-open-source.json \
  --container-json snyk-container.json
```

Machine-readable output (for piping into other tools):

```bash
actions/snyk-policy-reconcile/snyk-policy-reconcile.sh --project-dir . --json
```

Run `actions/snyk-policy-reconcile/snyk-policy-reconcile.sh --help` for the full option list.

### Reading the output

```
STALE  (in .snyk, not reported — candidate for REMOVAL): 1
    - SNYK-DEBIAN13-ZLIB-19520500
ACTIVE (in .snyk, still reported — KEEP): 4
    - SNYK-DEBIAN13-ACL-17677866
    - ...
NEW    (reported, not in .snyk — needs a hand-written decision): 1
    - SNYK-JS-FOO-1
EXPIRING within 14d (re-verify the reason before it lapses):
    - SNYK-DEBIAN13-ACL-17677866  expires 2026-12-03T00:00:00.000Z  (26 days)
```

A STALE entry means: pull up the finding, confirm it really is gone (a fix
shipped, or the dependency left the tree), then remove that block from `.snyk`
in a reviewed PR. A NEW entry means the opposite: triage it, and either fix it
within the SLA or add a reasoned, expiring ignore.

## Running it in CI (non-blocking)

`reusable-snyk-policy-reconcile.yml` runs the same script on pull requests and
posts the three buckets as a PR comment (updated in place on re-runs). It is
**non-blocking by design** — it never fails the build and never edits `.snyk`.
The comment is a prompt for human triage, surfacing drift on every PR instead of
leaving it to be discovered when an `expires` date lapses.

A caller wires it in alongside the other reusable workflows:

```yaml
jobs:
  snyk-policy-reconcile:
    uses: ministryofjustice/cica-devsecops-workflows/.github/workflows/reusable-snyk-policy-reconcile.yml@v1.x.y
    with:
      node-version: '24.22.1'
      # reconcile-image: optional — set to also cover the container surface
    secrets:
      SNYK_CLIENT_ID: ${{ secrets.SNYK_CLIENT_ID }}
      SNYK_CLIENT_SECRET: ${{ secrets.SNYK_CLIENT_SECRET }}
```

Pin the `uses:` to whatever version of this repo you want, as with the other
reusable workflows. You do **not** need to set `reconcile-ref`: by default the
workflow fetches its reconcile script from the same ref it is itself running at,
so the script version tracks the `@v1.x.y` you pin here automatically.

The job needs `pull-requests: write` to post the comment (the reusable workflow
declares this itself). To also reconcile the container surface, pass
`reconcile-image` with an image reference that is loadable in the job; wiring
the archived image artifact from `reusable-container.yml` through is left to the
caller.

The CLI can be told to fail on stale entries with `--fail-on-stale` if a team
later decides drift should block, but the CI workflow deliberately does not set
it: self-healing via `expires` plus a visible PR comment is the lighter-touch
default, and keeping the job green avoids pressuring anyone into deleting an
ignore without proper verification.

## Tests

Black-box tests for the script live in
`actions/snyk-policy-reconcile/test/`. They drive the real script with
pre-generated scan JSON and a fixture `.snyk`, then assert on its `--json`
report — covering the `.snyk` parsing, the STALE/ACTIVE/NEW set algebra, the
expiry-window warning, and both scan surfaces feeding one reconciliation.

Run them locally (needs `bash`, `jq`, and Mike Farah's Go `yq` — the same tools
the script needs):

```bash
actions/snyk-policy-reconcile/test/reconcile.test.sh
```

They also run in CI as the `reconcile-script-tests` job in `ci.yml`. If `yq` is
not installed the suite SKIPs with exit 0 rather than failing, so a box that
cannot run the script does not produce a false negative; CI installs a pinned
`yq` so it runs for real there.

The expiring-ignore fixture uses a relative date injected at run time
(`@@EXPIRING_DATE@@` in `test/fixtures/.snyk`), so the test is not time-bombed
to a fixed calendar date.
