#!/bin/bash
# Test: Bug #1227 — Parallel catalog downloads race on pull-secret-full.json
#
# Reproduces the race condition where 3 parallel download-catalog-index.sh
# processes all call create-containers-auth.sh simultaneously. The non-atomic
# write at line 65:
#   jq ... > "$regcreds_dir/pull-secret-full.json"
# truncates the file (O_TRUNC) before jq writes output. A concurrent reader
# sees an empty file (null), causing:
#   "jq: error ... object and null cannot be multiplied"
#
# The test forces a cold-cache state (no run_once results, no content-layer
# digests) so all 3 catalogs must do a full download, hitting
# create-containers-auth.sh in parallel.

cd "$(dirname "$0")/../.." || exit 1
source scripts/include_all.sh
source <(normalize-aba-conf)

# Disable errexit — tests intentionally trigger failures
set +e
trap - ERR

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  ${GREEN}PASS${NC}  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  ${RED}FAIL${NC}  %s\n" "$*"; }
_info() { printf "  ${YELLOW}INFO${NC}  %s\n" "$*"; }

OCP_MAJOR=$(echo "$ocp_version" | cut -d. -f1-2)
[ -z "$OCP_MAJOR" ] && { echo "FATAL: could not determine ocp_version from aba.conf"; exit 1; }

CATALOGS=(redhat-operator certified-operator community-operator)

# --- Backup ---
_bak=$(mktemp -d /tmp/test-1227-bak.XXXXXX)
trap '_restore_all; rm -rf "$_bak"' EXIT

_backup_all() {
	for cat in "${CATALOGS[@]}"; do
		[ -f ".index/${cat}-index-v${OCP_MAJOR}" ] && \
			cp ".index/${cat}-index-v${OCP_MAJOR}" "$_bak/" 2>/dev/null || true
		[ -f ".index/.${cat}-index-v${OCP_MAJOR}.content-layer-digest" ] && \
			cp ".index/.${cat}-index-v${OCP_MAJOR}.content-layer-digest" "$_bak/" 2>/dev/null || true
	done
	[ -f "catalogs/redhat-operator-index-v${OCP_MAJOR}" ] && \
		cp "catalogs/redhat-operator-index-v${OCP_MAJOR}" "$_bak/" 2>/dev/null || true
}

_restore_all() {
	for cat in "${CATALOGS[@]}"; do
		[ -f "$_bak/${cat}-index-v${OCP_MAJOR}" ] && \
			cp "$_bak/${cat}-index-v${OCP_MAJOR}" ".index/" 2>/dev/null || true
		[ -f "$_bak/.${cat}-index-v${OCP_MAJOR}.content-layer-digest" ] && \
			cp "$_bak/.${cat}-index-v${OCP_MAJOR}.content-layer-digest" ".index/" 2>/dev/null || true
	done
	[ -f "$_bak/redhat-operator-index-v${OCP_MAJOR}" ] && \
		cp "$_bak/redhat-operator-index-v${OCP_MAJOR}" "catalogs/" 2>/dev/null || true
}

_nuke_cache() {
	for cat in "${CATALOGS[@]}"; do
		rm -f ".index/${cat}-index-v${OCP_MAJOR}"
		rm -f ".index/.${cat}-index-v${OCP_MAJOR}.content-layer-digest"
		rm -f ".index/.${cat}-index-v${OCP_MAJOR}.expected-count"
		rm -f ".index/.${cat}-index-v${OCP_MAJOR}.digest"
	done
	rm -f "catalogs/redhat-operator-index-v${OCP_MAJOR}"
	for d in "$HOME/.aba/runner/catalog:${OCP_MAJOR}:"*; do
		[ -d "$d" ] && rm -rf "$d"
	done
}

echo "=== Bug #1227: Parallel catalog auth race (OCP $OCP_MAJOR) ==="
echo

# ─────────────────────────────────────────────────────────────────
# Test 1: Parallel downloads via download_all_catalogs + wait
# ─────────────────────────────────────────────────────────────────
echo "--- Test 1: download_all_catalogs + wait_for_all_catalogs (cold cache) ---"
_info "This forces 3 parallel download-catalog-index.sh processes"
_info "Each calls create-containers-auth.sh → races on pull-secret-full.json"

_backup_all
_nuke_cache

out=$(download_all_catalogs "$OCP_MAJOR" && wait_for_all_catalogs "$OCP_MAJOR" 2>&1) && rc=0 || rc=$?

if [ $rc -eq 0 ]; then
	_pass "download_all_catalogs + wait completed successfully (rc=0)"
else
	_fail "download_all_catalogs + wait failed (rc=$rc) — Bug #1227 reproduced"
	if echo "$out" | grep -q "cannot be multiplied"; then
		_fail "Confirmed: jq merge race (object * null)"
	fi
	if echo "$out" | grep -q "Failed to merge container auth"; then
		_fail "Confirmed: create-containers-auth.sh failed"
	fi
	echo "$out" | grep -iE "error|fail|cannot" | head -5 | sed 's/^/       /'
fi

_restore_all
echo

# ─────────────────────────────────────────────────────────────────
# Test 2: show-ops with cold cache (same code path)
# ─────────────────────────────────────────────────────────────────
echo "--- Test 2: show-ops.sh with cold cache (triggers auto-download) ---"

_backup_all
_nuke_cache

out=$(scripts/show-ops.sh 2>&1) && rc=0 || rc=$?

if [ $rc -eq 0 ]; then
	count=$(echo "$out" | grep -c '^ ' || true)
	_pass "show-ops completed successfully ($count lines, rc=0)"
else
	_fail "show-ops failed (rc=$rc) — Bug #1227 reproduced via show-ops"
	echo "$out" | grep -iE "error|fail|cannot" | head -5 | sed 's/^/       /'
fi

_restore_all
echo

# ─────────────────────────────────────────────────────────────────
# Test 3: Direct race on create-containers-auth.sh (targeted)
# ─────────────────────────────────────────────────────────────────
echo "--- Test 3: 10 parallel create-containers-auth.sh (targeted race) ---"
_info "Runs create-containers-auth.sh 10x in parallel to widen the race window"

# Ensure regcreds_dir is set (same as download-catalog-index.sh does)
export regcreds_dir=$HOME/.aba/mirror/mirror

# Back up auth files
_auth_bak=$(mktemp -d /tmp/test-1227-auth.XXXXXX)
[ -f ~/.docker/config.json ] && cp ~/.docker/config.json "$_auth_bak/" || true
[ -f ~/.containers/auth.json ] && cp ~/.containers/auth.json "$_auth_bak/" || true
[ -f "$regcreds_dir/pull-secret-full.json" ] && cp "$regcreds_dir/pull-secret-full.json" "$_auth_bak/" || true

auth_race_fails=0
auth_race_runs=5
for attempt in $(seq 1 $auth_race_runs); do
	# Delete the intermediate file to force recreation
	rm -f "$regcreds_dir/pull-secret-full.json"

	# Run 10 instances in parallel
	pids=()
	tmpdir=$(mktemp -d /tmp/test-1227-out.XXXXXX)
	for i in $(seq 1 10); do
		scripts/create-containers-auth.sh >"$tmpdir/$i.out" 2>"$tmpdir/$i.err" &
		pids+=($!)
	done

	any_fail=0
	for pid in "${pids[@]}"; do
		wait "$pid" 2>/dev/null || any_fail=1
	done

	if [ $any_fail -eq 1 ]; then
		auth_race_fails=$(( auth_race_fails + 1 ))
		# Show the first error
		err=$(cat "$tmpdir"/*.err 2>/dev/null | grep -m1 "cannot be multiplied\|Failed to merge" || true)
		[ -z "$err" ] && err=$(cat "$tmpdir"/*.err 2>/dev/null | head -1)
		_fail "Attempt $attempt/$auth_race_runs: parallel auth merge failed: $err"
	fi
	rm -rf "$tmpdir"
done

if [ $auth_race_fails -gt 0 ]; then
	_fail "Race triggered in $auth_race_fails/$auth_race_runs attempts — Bug #1227 confirmed"
else
	_pass "No race in $auth_race_runs attempts (10 parallel each)"
fi

# Restore auth files
[ -f "$_auth_bak/config.json" ] && cp "$_auth_bak/config.json" ~/.docker/ || true
[ -f "$_auth_bak/auth.json" ] && cp "$_auth_bak/auth.json" ~/.containers/ || true
[ -f "$_auth_bak/pull-secret-full.json" ] && cp "$_auth_bak/pull-secret-full.json" "$regcreds_dir/" || true
rm -rf "$_auth_bak"
echo

# ─────────────────────────────────────────────────────────────────
# Test 4: Sequential downloads (control — should always pass)
# ─────────────────────────────────────────────────────────────────
echo "--- Test 4: Sequential downloads (control — no race possible) ---"

_backup_all
_nuke_cache

seq_rc=0
for cat in "${CATALOGS[@]}"; do
	if ! scripts/download-catalog-index.sh "$cat" "$OCP_MAJOR" >/dev/null 2>&1; then
		seq_rc=1
		_fail "Sequential download of $cat failed"
		break
	fi
done
if [ $seq_rc -eq 0 ]; then
	_pass "All 3 catalogs downloaded sequentially without error"
fi

_restore_all
echo

# ─────────────────────────────────────────────────────────────────
echo "========================================="
echo "  Results: $pass passed, $fail failed"
echo "========================================="
echo
if [ $fail -gt 0 ]; then
	echo -e "${RED}Bug #1227 reproduced${NC}: parallel create-containers-auth.sh races on pull-secret-full.json"
	exit 1
else
	echo -e "${GREEN}Race did not trigger this run${NC} (may be timing-dependent, or already fixed)"
	exit 0
fi
