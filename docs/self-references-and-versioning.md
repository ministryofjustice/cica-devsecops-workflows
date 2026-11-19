# Self-references, versioning, and consumer propagation

This note captures the reasoning behind how the reusable workflows reference
their own in-repo action, how consumers pin to this repo, and how new versions
propagate out. It also records one open decision that is deliberately parked for
later (see [Open question](#open-question-should-first-party-references-be-sha-pinned)).

## Background: two kinds of reference

There are two distinct `uses:` references in play, and they are governed by
different rules. Keeping them separate is the key to understanding everything
below.

1. **Same-repo (internal) references** — a file in this repo pointing at another
   file in this repo. Specifically, the reusable workflows calling the in-repo
   `actions/snyk-auth` composite action.
2. **Cross-repo (consumer) references** — a caller like `cica-apply-web`
   pointing at this repo's reusable workflows, e.g.
   `ministryofjustice/cica-devsecops-workflows/.github/workflows/reusable-container.yml@v1.0.11`.

The change described next affects only category 1. Category 2 is unchanged.

## What changed: `$/` self-repository references (internal only)

### The problem it solved

The reusable workflows (`reusable-security.yml`, `reusable-container.yml`,
`reusable-publish.yml`, `reusable-snyk-policy-reconcile.yml`) call the in-repo
`actions/snyk-auth`. They could not use a workspace-relative local path
(`./actions/snyk-auth`): when a reusable workflow runs, the checked-out
workspace belongs to the **calling** repo, where `actions/snyk-auth` does not
exist, so a local path would fail.

The previous workaround was an external pinned reference inside this repo's own
workflows, example:

```yaml
uses: ministryofjustice/cica-devsecops-workflows/actions/snyk-auth@v1.0.11
```

That is a static version string. It did not update when a new tag was cut, so
the release process required hand-editing it before every release (old
`release-process.md` step 4) and verifying with a `grep`. This step was missed
repeatedly — `v1.0.4`, `v1.0.6`, `v1.0.8`, and `v1.0.10` were each a patch
release fixing exactly this miss (see `CHANGELOG.md`).

### The fix

GitHub's self-repository reference syntax (shipped 2026-07-30, requires runner
≥ 2.336.0). A `uses:` value starting with `$/` resolves to *this* repo at the
exact commit currently running:

```yaml
uses: $/actions/snyk-auth
```

Because it resolves to the running commit, it automatically matches whatever ref
the caller pinned — a tag like `@v1.0.12` or a full commit SHA. There is no
version string to hand-edit, so the recurring release defect is eliminated by
construction, not by discipline.

### Consequences recorded elsewhere

- `release-process.md`: the old "bump the self-references before tagging" step is
  removed.
- `inputs.md`: the design note now describes the `$/` approach and the runner
  requirement.
- The action-pinning checks in both `ci.yml` and `reusable-security.yml` skip
  `$/`-prefixed references, since they are inherently pinned to the running
  commit.

### What this does NOT change

A consumer's `uses:` references are unaffected in **shape**. `cica-apply-web`
still calls the reusable workflows with the full external path and a version tag;
only the version number moves when it chooses to move forward. `$/` cannot be
used by a consumer, because `$/` means "my own repo" and the consumer is a
different repo. The `$/` change is invisible from the outside.

## How consumers pin to this repo

Consumers pin by **version tag** (e.g. `@v1.0.11`), per `release-process.md`.
The action-pinning checks deliberately exempt `ministryofjustice/cica-devsecops-workflows/*`
references from the third-party full-SHA requirement so this tag policy is
allowed.

Tags are immutable pointers to a commit, so:

- A consumer pinned to `@v1.0.11` keeps running the v1.0.11 commit's bytes,
  including that commit's (old, external) `snyk-auth` reference. Committing new
  work to `main` does not retroactively change a published tag.
- The `$/` behaviour applies only once a consumer bumps its pin to a tag that
  contains the `$/` change.

## How a new version propagates to consumers

 Automatic propagation requires each consumer to configure the `github-actions`
 ecosystem in `.github/dependabot.yml`. The current `cica-apply-web` configuration
 only covers `npm`, so its workflow references must be bumped manually until
 Actions updates are configured.

Flow:
 Once a consumer configures Actions updates and an `all-github-actions` group
 (`patterns: ['*']`), the intended flow is:

 1. Publish a new GitHub Release of this repo, creating its version tag.
 2. On its configured schedule, Dependabot notices the new version.
 3. It opens a grouped PR updating the consumer's devsecops references.
4. A human reviews and merges. The pipeline then runs the new version, with
   `$/actions/snyk-auth` resolving to that same version internally.

Notes:

- Not instant — it fires on Dependabot's schedule, not the moment the tag is
  pushed.
- Fires on a **tag/release** existing, not on a commit to `main`.
- Dependabot does not understand the staged-wave rollout policy in
  `release-process.md`; it offers PRs to every configured consumer. Ordering the
  rollout remains a human decision.

## Open question: should first-party references be SHA-pinned?

**Status: parked. No change made. Revisit later.**

Today the policy is split: third-party actions must be pinned to a full 40-char
commit SHA (enforced), but first-party references to this repo may use a version
tag (exempted). The question is whether the prod-touching consumer references
(and/or the internal references) should move to the stronger
`@<sha> # vX.Y.Z` form.

### Arguments for staying tag-only

- It is this repo's own code, in the same org, under tag/branch protections we
  control. The force-moved-tag threat that SHA-pinning defends against is far
  smaller for a repo we own than for a third party.
- Readability and auditability: `@v1.0.11` is legible at a glance; a SHA is not.
- It is the documented policy already, and the deliberate-bump workflow depends
  on it.

### Arguments for SHA + version comment

- Tags are mutable; even in our own org a tag can be force-moved by accident, a
  compromised token, or admin error. A SHA pin runs exactly the reviewed bytes.
- Removes the first-party/third-party asymmetry (and the special-case skips in
  the two pinning checks).
- The `$/` change removed the main technical blocker: a SHA-pinned consumer now
  gets `$/actions/snyk-auth` resolving to that same SHA automatically. GitHub's
  own `$/` announcement cites enabling full-SHA pinning for workflows that call
  their own actions as a motivation.
- This repo gates production (`reusable-publish.yml` → ECR,
  `reusable-deploy-kubernetes.yml` → prod cluster). `release-process.md` already
  names "security-sensitive where even a tag being force-moved is an
  unacceptable risk" as the case for a full SHA.

### Possible middle ground

A split policy: SHA-pin the prod-touching workflows (`publish`,
`deploy-kubernetes`), tag-pin the rest. Coherent, and keeps readability where the
risk is low.

### If we do tighten, remember

- Use `@<sha> # vX.Y.Z` so Dependabot still recognises and bumps the reference
  (it reads the version from the comment).
- Update `release-process.md` and both pinning-check skips (`ci.yml`,
  `reusable-security.yml`) so enforcement and docs agree.

## Related, also parked

- **Moving release detail into GitHub Releases** rather than `CHANGELOG.md`. With
  the recurring self-ref defect gone, the CHANGELOG's churn drops and
  consolidating per-tag notes into GitHub Releases becomes viable. If adopted,
  leave a pointer at the top of `CHANGELOG.md` noting the cutover version, and
  update `release-process.md`'s "update the CHANGELOG" step accordingly.
- **`reusable-snyk-policy-reconcile.yml`'s `reconcile-ref` default.** It fetches
  the reconcile script from this repo at a hardcoded `ref:` (currently
  `v1.0.0`, where the script does not yet exist). A `ref:` in a checkout cannot
  use `$/`, so this needs either deriving from `github.workflow_ref` or moving
  the script into a composite action called via `$/`. Tracked separately from
  this note.
