# Dependency and container hygiene

This guide explains how repositories in this estate keep their dependencies
current and their container images small, and — just as importantly — *why* the
conventions are set up the way they are. If you are new to the project, read it
before you touch a `dependabot.yml` or a `Dockerfile`: the setup can look
over-engineered until you understand the problem it solves, and fighting it
tends to recreate the problem.

`cica-apply-web` is the reference implementation. When in doubt, copy what it
does.

The conventions exist to:

- Keep dependencies patched within the security SLAs without drowning the team in
  pull requests. (Too many PRs is the usual reason teams give up and switch
  Dependabot off — and once it is off, dependencies rot and the list of security
  exceptions only grows.)
- Keep a clear line between updates a machine can safely merge and updates a
  human must review, so auto-merge can be switched on later without reworking
  anything.
- Keep runtime container images small, with a single source of truth for the
  base image.

---

## 1. How Dependabot is grouped

By default Dependabot opens one pull request per dependency. On a Node service
that is easily 15–20 PRs in a single cycle, each one needing a review and a CI
run. That flood is what makes teams disable Dependabot — which is the worst
outcome, because nothing then gets patched.

The answer is **grouping**: fold many updates into a few PRs. The grouping is not
arbitrary — it is split along the lines of *how each PR should be handled*.

### The principle: group by risk tier

Group updates by risk, because the risk tier decides who is allowed to merge the
PR. Two things determine the tier:

- **Is it a production or a development dependency?** A production dependency
  (express, helmet, got) runs in front of real users, so a bad update is a live
  incident. A development dependency (eslint, jest, webpack) cannot reach
  production — the worst it can do is break CI, which fails loudly and never
  ships.
- **Is it a major, or a patch/minor?** Under semver, patch and minor releases are
  backwards-compatible; a major release is an explicit signal of breaking
  changes.

Cross those two questions and you get the four npm groups you will see in the
config. Each has a different review expectation (and, later, a different
auto-merge stance):

| Group | What lands here | Risk | How to treat it |
|-------|-----------------|------|-----------------|
| `prod-patch-minor` | production, patch + minor | low | quick review; a future auto-merge candidate |
| `prod-major` | production, major | highest | always review carefully; CODEOWNERS-gated |
| `dev-patch-minor` | development, patch + minor | lowest | quick review; the safest auto-merge candidate |
| `dev-major` | development, major | medium (cannot ship to prod) | review, but lower stakes |

Docker and GitHub Actions are separate ecosystems. They **cannot** be folded in
with npm — Dependabot only groups within a single `package-ecosystem` — so each
gets its own single catch-all group:

- `all-docker` — base-image digest bumps.
- `all-github-actions` — pinned action SHA bumps.

### How many PRs to expect

At most, in a single cycle: 4 npm + 1 docker + 1 github-actions = **6 PRs** — and
only in a week where every group has something waiting. A group with nothing to
update raises no PR, so most weeks you will see fewer, sometimes none. That is a
long way from the 15–20+ that makes people turn Dependabot off, and it keeps the
review boundaries that make auto-merge safe to add later.

### Why npm is not collapsed into one group

Fewer PRs sounds better, but a single `all-npm` group would mix every risk tier
into one PR. As soon as a breaking major travels in the same PR as a handful of
trivial patches, you can no longer auto-merge it on a green build without risk —
so every npm PR goes back to needing a human, and the PR-fatigue problem returns.
One extra possible PR a week is a cheap price for keeping that boundary clean.

### The configuration

See `cica-apply-web/.github/dependabot.yml`. The npm groups look like this:

```yaml
groups:
  prod-patch-minor:
    dependency-type: 'production'
    update-types: ['patch', 'minor']
  prod-major:
    dependency-type: 'production'
    update-types: ['major']
  dev-patch-minor:
    dependency-type: 'development'
    update-types: ['patch', 'minor']
  dev-major:
    dependency-type: 'development'
    update-types: ['major']
```

When you set this up in another repo, carry these conventions across:

- A `commit-message.prefix` per ecosystem, so PRs are easy to scan.
- The same `schedule` for every ecosystem, so the PRs arrive together and can be
  handled in one sitting rather than trickling in all week.
- An `ignore` for any base-image major the repo is deliberately staying off (for
  example `node >= 25` while the image is pinned to Node 24).

### Two things to watch in the first few cycles

- Grouping by `dependency-type` relies on whether a package sits in
  `dependencies` or `devDependencies`. This is usually reliable, but a
  **transitive-only** update may not carry a clear type and can slip outside all
  four groups, arriving as its own PR. That is a Dependabot quirk, not a broken
  config — do not go rewriting the groups because of it.
- Some toolchains must move together. The eslint set (`eslint`,
  `eslint-config-prettier`, `eslint-plugin-*`) is the classic example — bump one
  major without the others and linting breaks. A major migration of a coupled set
  is deliberate, hands-on work, not a merge-on-green, and the group split can put
  parts of it in different PRs, so expect to coordinate.

---

## 2. Auto-merge (not enabled yet)

The grouping above is deliberately shaped so auto-merge can be turned on later
without restructuring anything. It is **not** switched on today. When it is, the
policy maps straight onto the groups:

| Group | Intended stance |
|-------|-----------------|
| `dev-patch-minor` | auto-merge on green — safest; cannot reach prod |
| `prod-patch-minor` | auto-merge on green — low risk, a little more caution |
| `all-github-actions` | auto-merge on green is reasonable; some teams keep a human on supply-chain grounds |
| `all-docker` | auto-merge on green **only once the smoke test actually proves the container boots** (see below) |
| `dev-major` | review; any developer can merge |
| `prod-major` | always review; CODEOWNERS-gated |

Auto-merge is only ever "on green" — it trusts the CI gate
(`reusable-node-ci.yml` + `reusable-security.yml` + `reusable-container.yml`)
completely. Before enabling it for any group, two things must hold:

1. The CI gate genuinely **blocks** on that surface.
2. The container smoke test is **real**. At the time of writing,
   `reusable-container.yml`'s smoke test just logs `docker ps` and does not check
   that the container is actually serving (there is a TODO in that workflow). Until
   that is fixed, do not auto-merge `all-docker`: a base image that fails to start
   would still show a green build.

---

## 3. Container images

Reference: `cica-apply-web/Dockerfile`.

### Build in stages

Use a `builder` stage to install dependencies and compile assets, and a separate
runtime stage for what actually ships. Drop devDependencies
(`npm prune --omit=dev`) in the builder before the runtime stage copies anything
across. This keeps build tooling out of the shipped image.

### One place to set the base image

Declare the base image once as a global `ARG`, with the full pinned
`tag@sha256:...` as its default, and point every `FROM` at it:

```dockerfile
ARG BASE_IMAGE=node:24-trixie-slim@sha256:<digest>

FROM ${BASE_IMAGE} AS builder
# ...

ARG BASE_IMAGE          # re-declared: FROM resets build args between stages
FROM ${BASE_IMAGE} AS production
```

Why it is done this way:

- **No drift.** The digest lives in one line, so the two stages can never point
  at different images.
- **Clean Dependabot bumps.** The docker ecosystem updates that one `ARG` line and
  both stages follow. Note that Dependabot only tracks an `ARG`-based `FROM` when
  the pinned value is the `ARG`'s *default* — so keep the full `tag@sha256` on the
  `ARG` line; do not pass it in at build time.
- **The repeated `ARG` is intentional.** Docker resets build args at every `FROM`,
  so the bare `ARG BASE_IMAGE` before the second stage is needed to pull the
  global default back in. Remove it and `${BASE_IMAGE}` expands to nothing and the
  build fails.

After changing any of this, check two things: the build still resolves, and the
Snyk container scan still attributes base-image CVEs to the base image (putting
the image behind an `ARG` must not break that link).

### Name the final stage `production`

`reusable-container.yml` builds with `--target production` by default, so the
final runtime stage **must** be named `production` (`FROM ... AS production`).
If it is not, the container build fails with "target stage could not be found".
If a repo genuinely needs a different stage name, override the workflow's
`build-target` input rather than quietly diverging from it.

### Keep the runtime image small

- **Remove npm and npx from the runtime image** when the app is started directly
  (see below). This also drops npm's own bundled dependency tree
  (`/usr/local/lib/node_modules/npm`) from what Snyk scans, which clears findings
  that have nothing to do with the application.
- **Start the app with `node`, not npm.** Use `CMD ["node", "./bin/www"]` rather
  than `npm start`. You get no npm in the runtime image, no npm lifecycle-script
  path, and — importantly on Kubernetes — the app receives `SIGTERM` straight from
  the orchestrator for a clean shutdown, instead of npm swallowing it as PID 1.
  Check that the `npm start` script is itself just `node ./bin/www`, so behaviour
  is unchanged.
- **Ship only what the app needs at runtime.** There are two valid ways to do
  this; either is fine, as long as source control metadata, tests, dev tooling,
  and secrets never reach the runtime image:

  1. **Whitelist `.dockerignore` (what the reference repo does).** Exclude
     everything with `*`, then re-admit only the app directories, `package*.json`,
     the entry point, and the build-time configs the in-container build needs
     (`!babel.config.js`, `!webpack.config.js`, and so on). With the build context
     already trimmed, a broad `COPY --from=builder /usr/src/app .` in the runtime
     stage carries only app code, production `node_modules` (after the prune), and
     compiled assets — there is nothing left to leak. The allow-list lives in one
     file instead of being duplicated in the Dockerfile.
  2. **Selective `COPY --from=builder`.** Copy only the runtime essentials
     (production `node_modules`, compiled assets, server code, `bin`) by name.
     Tighter on paper, but it duplicates the allow-list and is easier to break:
     add a new router directory, forget to add it to the copy list, and the
     container falls over.

  Prefer the first unless there is a specific reason to enumerate copies. A broad
  `COPY --from=builder ... .` is only a problem when the build context is *not*
  filtered — with a whitelist `.dockerignore` in place, it is not.

  > A whitelist `.dockerignore` that lets the babel/webpack configs through for
  > the in-container build will also carry those few files into the runtime image.
  > They are inert and hold no secrets, so stripping them is a marginal gain that
  > is usually not worth the extra Dockerfile complexity.
- **Run as a non-root user**, and pin the base image by digest.

---

## 4. How this ties back to the security SLAs

All of the above exists to help meet the alert-resolution timescales:

- **Secrets:** no open alerts, ever. Never use a `.snyk` ignore to silence a
  secret — fail the build, and rotate or remove the secret.
- **Dependency vulnerabilities:** resolve Critical within 72 hours, High within 7
  days. Grouped, regularly-scheduled Dependabot PRs are the main way these get
  fixed. A `.snyk` ignore is only for the case where there is genuinely no
  upgrade or patch available, and it must carry a reason and an expiry no longer
  than the matching SLA.
- **Code scanning:** resolve Critical and High within 14 days. Snyk Code findings
  are handled with `exclude:` in `.snyk` (not `ignore:`, which is for
  Open Source, Container, and IaC findings), and are otherwise treated as
  fix-required inside the window.

Every `.snyk` exception carries a reason and an expiry so the policy heals
itself: once the expiry passes, the finding comes back and is reviewed again, and
once an upstream fix exists the entry is removed. Keep these exceptions
hand-written and reviewed — not generated by a script. A good exception records
real triage (for example, an analysis showing the vulnerable code path is never
reached), and that judgement is exactly what a script cannot produce.

To spot drift between the policy file and reality — stale ignores whose finding
is gone, and new findings with no matching entry — there is a read-only triage
aid, `actions/snyk-policy-reconcile/snyk-policy-reconcile.sh`. It only *reports* the three buckets
(stale / active / new); it never edits `.snyk`, so the hand-written, reviewed
rule above still holds. See
[snyk-policy-reconcile.md](snyk-policy-reconcile.md).
