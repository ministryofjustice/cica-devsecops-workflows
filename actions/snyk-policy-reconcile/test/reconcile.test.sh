#!/usr/bin/env bash
#
# reconcile.test.sh — black-box tests for snyk-policy-reconcile.sh.
#
# Drives the real script with pre-generated scan JSON and a fixture .snyk, then
# asserts on its --json report. This covers the parts most likely to regress:
#   - .snyk YAML parsing via yq (ignore IDs, quoted keys, exclude: ignored)
#   - the STALE / ACTIVE / NEW set algebra
#   - the expiry-window warning
#   - both scan surfaces (OSS + container) feeding one reconciliation
#
# No test framework required — just bash, jq and yq (the same tools the script
# itself needs). If yq is not available the suite SKIPS rather than fails, so a
# box that can't run the script doesn't produce a false negative; CI installs a
# pinned yq (see reusable-snyk-policy-reconcile.yml) so it runs for real there.
#
# Usage:  actions/snyk-policy-reconcile/test/reconcile.test.sh
# Exit:   0 all passed (or skipped), 1 a test failed, 2 harness/env error.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../snyk-policy-reconcile.sh"
FIXTURES="$HERE/fixtures"

[ -f "$SCRIPT" ] || { echo "harness error: script not found at $SCRIPT" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "harness error: jq required" >&2; exit 2; }

# yq is a hard dependency of the script under test. Without it we cannot run the
# real parsing path, so skip loudly rather than fake it.
if ! command -v yq >/dev/null 2>&1 || ! yq --version 2>&1 | grep -qi 'mikefarah'; then
  echo "SKIP: Mike Farah's yq not available; cannot exercise snyk-policy-reconcile.sh"
  exit 0
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0

check() {
  # $1 = description, $2 = expected, $3 = actual
  if [ "$2" = "$3" ]; then
    printf '  ok   %s\n' "$1"
    PASS=$((PASS + 1))
  else
    printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"
    FAIL=$((FAIL + 1))
  fi
}

# Build a .snyk with a concrete expiry inside the 14-day window, so the expiry
# assertion is stable rather than depending on a hardcoded calendar date.
EXPIRING_DATE="$(date -u -d '+5 days' +%Y-%m-%dT%H:%M:%S.000Z)"
POLICY="$WORKDIR/.snyk"
sed "s|@@EXPIRING_DATE@@|$EXPIRING_DATE|" "$FIXTURES/.snyk" > "$POLICY"

echo "== snyk-policy-reconcile.sh: both surfaces, JSON report =="

REPORT="$WORKDIR/report.json"
"$SCRIPT" \
  --policy "$POLICY" \
  --oss-json "$FIXTURES/oss.json" \
  --container-json "$FIXTURES/container.json" \
  --json > "$REPORT" 2> "$WORKDIR/stderr.log" || {
    echo "harness error: script exited non-zero" >&2
    cat "$WORKDIR/stderr.log" >&2
    exit 2
  }

# Each bucket is compared as a sorted, comma-joined string for a readable diff.
joined() { jq -r --arg k "$1" '.[$k] | sort | join(",")' "$REPORT"; }

check "STALE  = the one policy entry no scan reports" \
  "SNYK-JS-STALE-000" "$(joined stale)"

check "ACTIVE = suppressed entries across OSS + container" \
  "SNYK-DEBIAN13-OPENSSL-123456,SNYK-JS-LODASH-1018905" "$(joined active)"

check "NEW    = reported, not in .snyk, not suppressed" \
  "SNYK-JS-NEWVULN-999" "$(joined new)"

check "EXPIRING lists exactly the in-window id" \
  "SNYK-JS-EXPIRING-555" \
  "$(jq -r '.expiring | map(.id) | sort | join(",")' "$REPORT")"

check "a NO-expiry quoted-key policy entry is parsed but not in expiring" \
  "false" \
  "$(jq -r '[.expiring[].id] | index("SNYK-JS-QUOTEDKEY-777") != null' "$REPORT")"

echo
echo "== OSS-only surface (no container json) =="

REPORT2="$WORKDIR/report-oss.json"
"$SCRIPT" \
  --policy "$POLICY" \
  --oss-json "$FIXTURES/oss.json" \
  --json > "$REPORT2" 2>/dev/null

# Without the container scan, the DEBIAN id is no longer reported, so it drops
# out of ACTIVE and becomes STALE (in policy, not reported).
check "OSS-only: DEBIAN id moves to STALE (container surface absent)" \
  "true" \
  "$(jq -r '[.stale[]] | index("SNYK-DEBIAN13-OPENSSL-123456") != null' "$REPORT2")"

check "OSS-only: ACTIVE no longer contains the DEBIAN id" \
  "false" \
  "$(jq -r '[.active[]] | index("SNYK-DEBIAN13-OPENSSL-123456") != null' "$REPORT2")"

echo
echo "== missing policy file is a usage error (exit 2) =="
set +e
"$SCRIPT" --policy "$WORKDIR/does-not-exist.snyk" --oss-json "$FIXTURES/oss.json" --json >/dev/null 2>&1
rc=$?
set -e
check "nonexistent --policy exits 2" "2" "$rc"

echo
echo "-------------------------------------------"
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
