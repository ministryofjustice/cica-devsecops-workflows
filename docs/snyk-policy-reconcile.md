# Reconciling a `.snyk` policy with what Snyk reports

Over time a `.snyk` policy file drifts out of step with reality. An ignore you
added for an unfixable CVE stays in the file long after the dependency was
removed or the upstream fix shipped; meanwhile a newly disclosed vulnerability
shows up in the scan with no matching entry. Neither direction is obvious from
reading the file — you have to cross-check it against a live scan.

`scripts/snyk-policy-reconcile.sh` does that cross-check. It is a **read-only
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

Requires `jq`, and — unless you pass pre-generated JSON — the `snyk` CLI on your
PATH with an authenticated session (`snyk auth`, or `SNYK_TOKEN` /
`SNYK_OAUTH_TOKEN` in the environment).

Reconcile both surfaces, letting the script run the scans:

```bash
scripts/snyk-policy-reconcile.sh \
  --project-dir /path/to/cica-apply-web \
  --image cica-apply-web:latest
```

Just the npm/Open Source surface (no container):

```bash
scripts/snyk-policy-reconcile.sh --project-dir /path/to/cica-apply-web
```

Offline — reconcile against JSON a pipeline already produced (no `snyk`
needed):

```bash
scripts/snyk-policy-reconcile.sh \
  --policy /path/to/.snyk \
  --oss-json snyk-open-source.json \
  --container-json snyk-container.json
```

Machine-readable output (for piping into other tools):

```bash
scripts/snyk-policy-reconcile.sh --project-dir . --json
```

Run `scripts/snyk-policy-reconcile.sh --help` for the full option list.

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
