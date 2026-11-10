#!/usr/bin/env bash
#
# snyk-policy-reconcile.sh — triage the drift between a .snyk policy file and
# what Snyk actually reports right now.
#
# This is a READ-ONLY triage aid. It never edits .snyk. By design it only tells
# you which entries to look at; the judgement behind an ignore (and its reason
# text) is hand-written and reviewed — see
# cica-devsecops-workflows/docs/dependency-and-container-hygiene.md §4.
#
# It sorts every issue ID into three buckets:
#
#   STALE   — an ignore in .snyk that no current scan reports. The vuln was
#             fixed, the dependency was removed, or the ID changed. Candidate
#             for REMOVAL from .snyk (verify first).
#   ACTIVE  — an ignore in .snyk that a current scan still reports and that
#             Snyk is still suppressing because of the policy. KEEP.
#   NEW     — an issue at/above the severity threshold that is NOT in .snyk and
#             is NOT otherwise suppressed. Needs a hand-written triage decision:
#             fix it, or add a reasoned, expiring ignore.
#
# It also warns about ignores whose `expires` falls within --expiry-window days.
#
# Both Snyk surfaces that read this .snyk are covered:
#   - npm / Open Source  (`snyk test`)            -> e.g. SNYK-JS-* entries
#   - container           (`snyk container test`) -> e.g. SNYK-DEBIAN13-* entries
# The union of both is reconciled against the single .snyk, matching how the
# reusable-security.yml and reusable-container.yml workflows use it.
#
# ---------------------------------------------------------------------------
# USAGE
#
#   Local, run the scans for you (needs snyk on PATH and an authenticated
#   session — SNYK_TOKEN / SNYK_OAUTH_TOKEN, or `snyk auth`):
#
#     actions/snyk-policy-reconcile/snyk-policy-reconcile.sh \
#       --project-dir /path/to/cica-apply-web \
#       --image my-local-image:latest
#
#   Reconcile only the npm/OSS surface (no container):
#
#     actions/snyk-policy-reconcile/snyk-policy-reconcile.sh --project-dir /path/to/repo
#
#   CI / offline, feed it JSON the pipeline already produced (no snyk needed):
#
#     actions/snyk-policy-reconcile/snyk-policy-reconcile.sh \
#       --policy /path/to/.snyk \
#       --oss-json snyk-open-source.json \
#       --container-json snyk-container.json
#
# OPTIONS
#   --policy PATH           Path to the .snyk file. Default: <project-dir>/.snyk
#   --project-dir PATH      Repo dir to run `snyk test` in. Default: cwd.
#   --image NAME            Image ref for `snyk container test`. Omit to skip
#                           the container surface.
#   --dockerfile PATH       Passed to `snyk container test --file=`. Optional.
#   --oss-json PATH         Use this pre-generated `snyk test --json` output
#                           instead of running the scan.
#   --container-json PATH   Use this pre-generated `snyk container test --json`
#                           output instead of running the scan.
#   --severity LEVEL        Severity threshold for scans this script runs.
#                           Default: high. (Ignored for pre-generated JSON.)
#   --expiry-window DAYS    Warn on ignores expiring within this many days.
#                           Default: 14.
#   --json                  Emit a machine-readable JSON report on stdout
#                           instead of the human-readable buckets.
#   --fail-on-stale         Exit non-zero if any STALE entry is found. Intended
#                           for CI that should surface drift. Default: never
#                           fail on findings (report only).
#   -h | --help             Show this help.
#
# EXIT CODES
#   0  success (report produced; no --fail-on-stale trigger)
#   1  stale entries found AND --fail-on-stale set
#   2  usage / environment error (bad args, missing jq, scan failed)
#
# Note: a non-reporting scan exit is expected. `snyk test` exits non-zero when
# it finds issues; this script captures that without treating it as failure.
# ---------------------------------------------------------------------------

set -euo pipefail

die() { echo "error: $*" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || die "jq is required but not found on PATH"

POLICY=""
PROJECT_DIR="."
IMAGE=""
DOCKERFILE=""
OSS_JSON=""
CONTAINER_JSON=""
SEVERITY="high"
EXPIRY_WINDOW=14
OUTPUT="human"
FAIL_ON_STALE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --policy)         POLICY="${2:?}"; shift 2 ;;
    --project-dir)    PROJECT_DIR="${2:?}"; shift 2 ;;
    --image)          IMAGE="${2:?}"; shift 2 ;;
    --dockerfile)     DOCKERFILE="${2:?}"; shift 2 ;;
    --oss-json)       OSS_JSON="${2:?}"; shift 2 ;;
    --container-json) CONTAINER_JSON="${2:?}"; shift 2 ;;
    --severity)       SEVERITY="${2:?}"; shift 2 ;;
    --expiry-window)  EXPIRY_WINDOW="${2:?}"; shift 2 ;;
    --json)           OUTPUT="json"; shift ;;
    --fail-on-stale)  FAIL_ON_STALE=1; shift ;;
    -h|--help)        sed -n '2,70p' "$0"; exit 0 ;;
    *)                die "unknown argument: $1" ;;
  esac
done

[ -n "$POLICY" ] || POLICY="${PROJECT_DIR%/}/.snyk"
[ -f "$POLICY" ] || die "policy file not found: $POLICY"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# --- 1. Gather scan JSON (either run scans, or use what was handed in) -------

# Emit the captured Snyk stderr (if any) before dying, so the real reason for an
# empty-JSON failure — bad image ref, auth, network — is visible instead of
# hidden behind a generic message. stdout is Snyk's human report and is dropped;
# the machine-readable results come from --json-file-output.
fail_scan() {
  # $1 = message, $2 = stderr log file
  local msg="$1" log="$2"
  if [ -s "$log" ]; then
    echo "--- snyk output ---" >&2
    tail -n 20 "$log" >&2
    echo "-------------------" >&2
  fi
  die "$msg"
}

run_oss_scan() {
  local out="$WORKDIR/oss.json" log="$WORKDIR/oss.err"
  echo "==> snyk test (Open Source) in $PROJECT_DIR" >&2
  # `snyk test` exits non-zero when vulns are found; that is not a failure here.
  ( cd "$PROJECT_DIR" && snyk test \
      --severity-threshold="$SEVERITY" \
      --json-file-output="$out" >/dev/null 2>"$log" ) || true
  [ -s "$out" ] || fail_scan "snyk test produced no JSON (auth? network? wrong dir?)" "$log"
  echo "$out"
}

run_container_scan() {
  local out="$WORKDIR/container.json" log="$WORKDIR/container.err"
  local file_arg=()
  [ -n "$DOCKERFILE" ] && file_arg=(--file="$DOCKERFILE")
  echo "==> snyk container test $IMAGE" >&2
  ( snyk container test "$IMAGE" "${file_arg[@]}" \
      --severity-threshold="$SEVERITY" \
      --policy-path="$POLICY" \
      --json-file-output="$out" >/dev/null 2>"$log" ) || true
  [ -s "$out" ] || fail_scan "snyk container test produced no JSON (image built? name/tag correct? auth?)" "$log"
  echo "$out"
}

if [ -z "$OSS_JSON" ]; then
  if command -v snyk >/dev/null 2>&1; then
    OSS_JSON="$(run_oss_scan)"
  else
    echo "note: snyk not on PATH and no --oss-json given; skipping OSS surface" >&2
  fi
fi

if [ -z "$CONTAINER_JSON" ] && [ -n "$IMAGE" ]; then
  command -v snyk >/dev/null 2>&1 || die "--image given but snyk not on PATH"
  CONTAINER_JSON="$(run_container_scan)"
fi

[ -n "$OSS_JSON$CONTAINER_JSON" ] || \
  die "no scan data: provide --oss-json/--container-json or have snyk on PATH"

# --- 2. Extract ID sets from the scan JSON -----------------------------------
#
# Snyk's `snyk test` and `snyk container test` can emit either a single object
# or an array of project objects (multi-project). We normalise to an array and
# pull two ID sets from each:
#   reported  = every issue at/above threshold the scan surfaced, whether or
#               not it is ignored (vulnerabilities[] + filtered.ignore[]).
#   suppressed = issues Snyk actively suppressed because of the policy
#               (filtered.ignore[]), i.e. the ones your .snyk is doing work for.

# jq filter: given one-or-many Snyk result objects on stdin, print issue IDs.
#   arg mode=reported   -> vulnerabilities[].id  +  filtered.ignore[].id
#   arg mode=suppressed -> filtered.ignore[].id  (and .meta/.ignoreReasons shapes)
EXTRACT='
  def arr: if type=="array" then . else [.] end;
  arr
  | map(
      if $mode=="reported" then
        ((.vulnerabilities // []) | map(.id))
        + ((.filtered.ignore // []) | map(.id))
      else
        ((.filtered.ignore // []) | map(.id))
      end
    )
  | add // []
  | .[]
'

collect_ids() {
  # $1 = json file, $2 = mode (reported|suppressed)
  local file="$1" mode="$2"
  [ -n "$file" ] || return 0
  [ -s "$file" ] || die "scan JSON not found or empty: $file"
  jq -r --arg mode "$mode" "$EXTRACT" "$file" 2>/dev/null || die "invalid scan JSON: $file"
}

{
  collect_ids "$OSS_JSON" reported
  collect_ids "$CONTAINER_JSON" reported
} | sort -u > "$WORKDIR/reported.txt"

{
  collect_ids "$OSS_JSON" suppressed
  collect_ids "$CONTAINER_JSON" suppressed
} | sort -u > "$WORKDIR/suppressed.txt"

# --- 3. Extract the ID set declared in .snyk ---------------------------------
#
# .snyk is YAML. We avoid a YAML dependency by reading the top-level keys under
# `ignore:` — they are the vuln IDs. Snyk IDs match [A-Z0-9-]+ and are indented
# two spaces under `ignore:`. `exclude:` (Snyk Code) is a different mechanism
# and intentionally NOT reconciled here.

awk '
  /^ignore:[[:space:]]*$/ { in_ignore=1; next }
  /^[A-Za-z_]+:[[:space:]]*$/ { in_ignore=0 }          # next top-level key
  in_ignore && /^  [A-Z0-9][A-Z0-9-]*:[[:space:]]*$/ {
    line=$0
    sub(/^  /, "", line)
    sub(/:.*$/, "", line)
    print line
  }
' "$POLICY" | sort -u > "$WORKDIR/policy.txt"

# Expiry dates per ID, for the expiry-window warning.
awk '
  /^ignore:[[:space:]]*$/ { in_ignore=1; next }
  /^[A-Za-z_]+:[[:space:]]*$/ { in_ignore=0 }
  in_ignore && /^  [A-Z0-9][A-Z0-9-]*:[[:space:]]*$/ {
    id=$0; sub(/^  /, "", id); sub(/:.*$/, "", id); current=id
  }
  in_ignore && /expires:/ {
    e=$0; sub(/^.*expires:[[:space:]]*/, "", e); gsub(/['"'"'"]/, "", e)
    if (current != "") print current "\t" e
  }
' "$POLICY" > "$WORKDIR/expiry.tsv" || true

# --- 4. Compute the three buckets --------------------------------------------

#   STALE   = policy - reported
#   ACTIVE  = policy ∩ reported
#   NEW     = reported - policy - suppressed
comm -23 "$WORKDIR/policy.txt" "$WORKDIR/reported.txt" > "$WORKDIR/stale.txt"
comm -12 "$WORKDIR/policy.txt" "$WORKDIR/reported.txt" > "$WORKDIR/active.txt"
comm -23 \
  <(comm -23 "$WORKDIR/reported.txt" "$WORKDIR/policy.txt") \
  "$WORKDIR/suppressed.txt" > "$WORKDIR/new.txt"

count() { wc -l < "$1" | tr -d ' '; }

# Expiring-soon IDs (within the window, in the future or already past).
EXPIRING="$WORKDIR/expiring.txt"
: > "$EXPIRING"
if [ -s "$WORKDIR/expiry.tsv" ]; then
  now_s=$(date -u +%s)
  window_s=$(( EXPIRY_WINDOW * 86400 ))
  while IFS=$'\t' read -r id exp; do
    [ -n "$exp" ] || continue
    # Accept ISO-8601 like 2026-12-03T00:00:00.000Z
    exp_s=$(date -u -d "$exp" +%s 2>/dev/null || true)
    [ -n "$exp_s" ] || continue
    if [ $(( exp_s - now_s )) -le "$window_s" ]; then
      days=$(( (exp_s - now_s) / 86400 ))
      printf '%s\t%s\t%s\n' "$id" "$exp" "$days" >> "$EXPIRING"
    fi
  done < "$WORKDIR/expiry.tsv"
fi

# --- 5. Report ----------------------------------------------------------------

if [ "$OUTPUT" = "json" ]; then
  jq -n \
    --rawfile stale "$WORKDIR/stale.txt" \
    --rawfile active "$WORKDIR/active.txt" \
    --rawfile new "$WORKDIR/new.txt" \
    --rawfile expiring "$EXPIRING" \
    '
    def lines: split("\n") | map(select(length>0));
    def exlines: split("\n") | map(select(length>0)) | map(split("\t") | {id:.[0], expires:.[1], days_left:(.[2]|tonumber)});
    {
      stale:    ($stale   | lines),
      active:   ($active  | lines),
      new:      ($new     | lines),
      expiring: ($expiring | exlines)
    }
    '
else
  echo
  echo "Snyk policy reconciliation — $POLICY"
  echo "-------------------------------------------------------------"
  echo "STALE  (in .snyk, not reported — candidate for REMOVAL): $(count "$WORKDIR/stale.txt")"
  sed 's/^/    - /' "$WORKDIR/stale.txt"
  echo
  echo "ACTIVE (in .snyk, still reported — KEEP): $(count "$WORKDIR/active.txt")"
  sed 's/^/    - /' "$WORKDIR/active.txt"
  echo
  echo "NEW    (reported, not in .snyk — needs a hand-written decision): $(count "$WORKDIR/new.txt")"
  sed 's/^/    - /' "$WORKDIR/new.txt"
  echo
  if [ -s "$EXPIRING" ]; then
    echo "EXPIRING within ${EXPIRY_WINDOW}d (re-verify the reason before it lapses):"
    while IFS=$'\t' read -r id exp days; do
      printf '    - %s  expires %s  (%s days)\n' "$id" "$exp" "$days"
    done < "$EXPIRING"
    echo
  fi
  echo "Reminder: this tool only triages. Edits to .snyk — removing a stale"
  echo "entry, or adding a NEW one with a reason + expiry — stay hand-written"
  echo "and reviewed. See docs/dependency-and-container-hygiene.md §4."
  echo
fi

# --- 6. Exit code -------------------------------------------------------------

if [ "$FAIL_ON_STALE" -eq 1 ] && [ -s "$WORKDIR/stale.txt" ]; then
  exit 1
fi
exit 0
