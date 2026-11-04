#!/bin/bash
# test-load-skip-marker.sh — Makefile data/.images-loaded skip semantics
#
# Validates Make dependency behaviour for the load-skip marker without a
# real registry. Uses a minimal Makefile matching Makefile.mirror's rule.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ABA_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

_green() { echo -e "\033[0;32m$*\033[0m"; }
_red() { echo -e "\033[0;31m$*\033[0m"; }

PASS=0
FAIL=0

assert_pass() { PASS=$(( PASS + 1 )); _green "  ✓ $1"; }
assert_fail() { FAIL=$(( FAIL + 1 )); _red "  ✗ $1"; }

assert_contains() {
	local desc="$1" haystack="$2" needle="$3"
	if echo "$haystack" | grep -qF "$needle"; then
		assert_pass "$desc"
	else
		assert_fail "$desc (needle '$needle' not found)"
	fi
}

assert_not_contains() {
	local desc="$1" haystack="$2" needle="$3"
	if ! echo "$haystack" | grep -qF "$needle"; then
		assert_pass "$desc"
	else
		assert_fail "$desc (unexpected needle '$needle' found)"
	fi
}

echo "=== test-load-skip-marker.sh ==="
echo

# --- Sanity: real Makefile.mirror has the marker rule ---
echo "Test 0: Makefile.mirror contains images-loaded rule"
mf="$ABA_ROOT/templates/Makefile.mirror"
assert_contains "has data/.images-loaded target" "$(grep -E '^data/\.images-loaded:' "$mf")" "data/.images-loaded:"
assert_contains "depends on mirror_*.tar" "$(cat "$mf")" '$(wildcard data/mirror_*.tar)'
assert_contains "depends on configs tar" "$(cat "$mf")" '$(wildcard data/aba-transfer-configs.tar)'
assert_contains "unavailable removes marker" "$(grep -A5 '^\.unavailable:' "$mf")" "data/.images-loaded"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Minimal Makefile mirroring the production dependency rule (recipe is a stub)
cat > "$TMPDIR/Makefile" << 'EOF'
SCRIPTS := ./scripts
data/.images-loaded: $(wildcard data/mirror_*.tar) $(wildcard data/aba-transfer-configs.tar)
	@echo "WOULD_RUN_LOAD"
	@touch $@

.PHONY: load
load: data/.images-loaded
EOF
mkdir -p "$TMPDIR/data" "$TMPDIR/scripts"
# Stub so recipe path exists if make ever runs for real
echo '#!/bin/true' > "$TMPDIR/scripts/reg-load.sh"
chmod +x "$TMPDIR/scripts/reg-load.sh"

# --- No marker, dummy tars present → would run ---
echo "Test 1: no marker + tars → load runs"
touch "$TMPDIR/data/mirror_000000.tar"
out=$(cd "$TMPDIR" && make -n data/.images-loaded 2>&1)
assert_contains "no marker: would run load" "$out" "WOULD_RUN_LOAD"

# Create marker newer than tars
echo "Test 2: marker newer than tars → skip"
touch "$TMPDIR/data/mirror_000000.tar"
sleep 1
touch "$TMPDIR/data/.images-loaded"
out=$(cd "$TMPDIR" && make -n data/.images-loaded 2>&1)
assert_not_contains "marker up to date: no WOULD_RUN_LOAD" "$out" "WOULD_RUN_LOAD"
assert_contains "make says up to date" "$out" "up to date"

# --- Tar newer than marker → would run ---
echo "Test 3: tar newer than marker → load runs"
sleep 1
touch "$TMPDIR/data/mirror_000000.tar"
out=$(cd "$TMPDIR" && make -n data/.images-loaded 2>&1)
assert_contains "newer tar: would run load" "$out" "WOULD_RUN_LOAD"

# Reset: marker current, then new configs tar
echo "Test 4: new aba-transfer-configs.tar → load runs (Day N)"
touch "$TMPDIR/data/mirror_000000.tar"
touch "$TMPDIR/data/.images-loaded"
sleep 1
touch "$TMPDIR/data/aba-transfer-configs.tar"
out=$(cd "$TMPDIR" && make -n data/.images-loaded 2>&1)
assert_contains "newer configs tar: would run load" "$out" "WOULD_RUN_LOAD"

# --- After rename to .tar.done, configs no longer trigger ---
echo "Test 5: configs renamed to .tar.done → skip (if marker still newer than image tars)"
mv -f "$TMPDIR/data/aba-transfer-configs.tar" "$TMPDIR/data/aba-transfer-configs.tar.done"
# Ensure marker is newer than remaining image tar
touch "$TMPDIR/data/.images-loaded"
out=$(cd "$TMPDIR" && make -n data/.images-loaded 2>&1)
assert_not_contains ".tar.done ignored: no WOULD_RUN_LOAD" "$out" "WOULD_RUN_LOAD"

# --- Rename-after-extract helper behaviour (unit-level) ---
echo "Test 6: rename configs tar after successful extract"
EXTRACT_DIR=$(mktemp -d)
mkdir -p "$EXTRACT_DIR/mirror/data" "$EXTRACT_DIR/clusterx"
echo "cluster_name=x" > "$EXTRACT_DIR/clusterx/cluster.conf"
( cd "$EXTRACT_DIR" && tar cf mirror/data/aba-transfer-configs.tar clusterx )
# Simulate _extract_configs_tar success path
(
	cd "$EXTRACT_DIR/mirror"
	tar xf "data/aba-transfer-configs.tar" -C ..
	mv -f data/aba-transfer-configs.tar data/aba-transfer-configs.tar.done
)
[ -f "$EXTRACT_DIR/mirror/data/aba-transfer-configs.tar.done" ] && \
	assert_pass "configs tar renamed to .tar.done" || \
	assert_fail "configs tar not renamed"
[ ! -f "$EXTRACT_DIR/mirror/data/aba-transfer-configs.tar" ] && \
	assert_pass "live configs tar removed" || \
	assert_fail "live configs tar still present"
[ -f "$EXTRACT_DIR/clusterx/cluster.conf" ] && \
	assert_pass "cluster dir extracted" || \
	assert_fail "cluster dir missing after extract"
rm -rf "$EXTRACT_DIR"

echo
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -gt 0 ] && exit 1
exit 0
