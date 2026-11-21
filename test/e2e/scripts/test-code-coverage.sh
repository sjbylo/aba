#!/usr/bin/env bash
# Unit tests for e2e "all suites passed since last code update" coverage.
# No pools or SSH.
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_E2E_DIR="$(cd "$_SCRIPT_DIR/.." && pwd)"

pass=0
fail=0
_assert() {
	local desc="$1"; shift
	# eval so callers can use ! / [[ / &&
	if eval "$@"; then
		echo "  PASS: $desc"
		pass=$(( pass + 1 ))
	else
		echo "  FAIL: $desc"
		fail=$(( fail + 1 ))
	fi
}

# Isolated state
COV_DIR=$(mktemp -d /tmp/e2e-cov-test.XXXXXX)
NOTIFY_LOG="$COV_DIR/notify.log"
: > "$NOTIFY_LOG"
NOTIFY_STUB="$COV_DIR/notify-stub.sh"
cat > "$NOTIFY_STUB" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$NOTIFY_LOG"
EOF
chmod +x "$NOTIFY_STUB"

export E2E_CODE_COV_DIR="$COV_DIR"
export _RUN_DIR="$_E2E_DIR"
export _ABA_ROOT="$(cd "$_E2E_DIR/../.." && pwd)"
export NOTIFY_CMD="$NOTIFY_STUB"

# Tiny expected set — override all_suite_names before sourcing coverage
all_suite_names() {
	echo "alpha beta gamma"
}

source "$_E2E_DIR/lib/code-coverage.sh"

_notify_count() {
	local _n
	_n=$(grep -c 'All suites passed since last code update' "$NOTIFY_LOG" 2>/dev/null || true)
	_n=${_n//[^0-9]/}
	echo "${_n:-0}"
}

_wait_notify() {
	# Background NOTIFY_CMD — give it a moment
	local _i
	for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
		[ "$(_notify_count)" -ge "${1:-1}" ] 2>/dev/null && return 0
		sleep 0.05
	done
	return 1
}

echo "=== test-code-coverage ==="

# -------------------------------------------------------------------------
echo "--- 1) first deploy creates stamp and empty ledger ---"
rm -f "$NOTIFY_LOG"; : > "$NOTIFY_LOG"
_e2e_cov_on_deploy "cksumAAA" "git:aaaa1111"
_assert "stamp file exists" [ -f "$COV_DIR/stamp" ]
_assert "stamp checksum is AAA" [ "$(_e2e_cov_current_stamp)" = "cksumAAA" ]
_assert "passed ledger empty" [ ! -s "$COV_DIR/passed" ]
_assert "not complete yet" ! _e2e_cov_is_complete

# -------------------------------------------------------------------------
echo "--- 2) same stamp re-deploy does not reset progress ---"
_e2e_cov_record_pass "alpha"
_assert "alpha recorded" grep -qxF alpha "$COV_DIR/passed"
_e2e_cov_on_deploy "cksumAAA" "git:aaaa1111"
_assert "alpha still recorded after same-stamp deploy" grep -qxF alpha "$COV_DIR/passed"

# -------------------------------------------------------------------------
echo "--- 3) incomplete set does not notify ---"
rm -f "$NOTIFY_LOG"; : > "$NOTIFY_LOG"
_e2e_cov_record_pass "beta"
_assert "still incomplete (missing gamma)" ! _e2e_cov_is_complete
sleep 0.1
_assert "no notify yet" [ "$(_notify_count)" -eq 0 ]

# -------------------------------------------------------------------------
echo "--- 4) completing the set notifies once and clears ledger ---"
rm -f "$NOTIFY_LOG"; : > "$NOTIFY_LOG"
_e2e_cov_record_pass "gamma"
_wait_notify 1 || true
_assert "notified on complete" [ "$(_notify_count)" -eq 1 ]
_assert "notify text mentions last code update" "grep -qF 'All suites passed since last code update' \"$NOTIFY_LOG\""
_assert "notify includes stamp label" "grep -qF 'git:aaaa1111' \"$NOTIFY_LOG\""
_assert "ledger cleared after notify (for repeat)" [ ! -s "$COV_DIR/passed" ]

# -------------------------------------------------------------------------
echo "--- 5) second full cycle notifies again (repeat claim) ---"
rm -f "$NOTIFY_LOG"; : > "$NOTIFY_LOG"
_e2e_cov_record_pass "alpha"
_e2e_cov_record_pass "beta"
_e2e_cov_record_pass "gamma"
_wait_notify 1 || true
_assert "second cycle also notified" [ "$(_notify_count)" -eq 1 ]
_assert "ledger cleared again" [ ! -s "$COV_DIR/passed" ]

# -------------------------------------------------------------------------
echo "--- 6) new deploy resets; old passes do not count ---"
rm -f "$NOTIFY_LOG"; : > "$NOTIFY_LOG"
_e2e_cov_record_pass "alpha"
_e2e_cov_on_deploy "cksumBBB" "dev:bbbb2222"
_assert "stamp is now BBB" [ "$(_e2e_cov_current_stamp)" = "cksumBBB" ]
_assert "ledger empty after new deploy" [ ! -s "$COV_DIR/passed" ]
_e2e_cov_record_pass "alpha"
_e2e_cov_record_pass "beta"
_assert "incomplete under new stamp" ! _e2e_cov_is_complete
sleep 0.1
_assert "no notify while incomplete" [ "$(_notify_count)" -eq 0 ]
_e2e_cov_record_pass "gamma"
_wait_notify 1 || true
_assert "notified under new stamp" [ "$(_notify_count)" -eq 1 ]
_assert "notify mentions new label" "grep -qF 'dev:bbbb2222' \"$NOTIFY_LOG\""

# -------------------------------------------------------------------------
echo "--- 7) duplicate PASS of same suite does not double-count ---"
rm -f "$NOTIFY_LOG"; : > "$NOTIFY_LOG"
: > "$COV_DIR/passed"
_e2e_cov_record_pass "alpha"
_e2e_cov_record_pass "alpha"
_e2e_cov_record_pass "alpha"
_n=$(grep -c . "$COV_DIR/passed" || echo 0)
_assert "alpha appears once" [ "$_n" -eq 1 ]

# -------------------------------------------------------------------------
echo "--- 8) no stamp → PASS is a no-op ---"
rm -rf "$COV_DIR"
mkdir -p "$COV_DIR"
rm -f "$NOTIFY_LOG"; : > "$NOTIFY_LOG"
_e2e_cov_record_pass "alpha"
_assert "no stamp file created by orphan PASS" [ ! -f "$COV_DIR/stamp" ]
_assert "no notify without stamp" [ "$(_notify_count)" -eq 0 ]

# -------------------------------------------------------------------------
echo "--- 9) label falls back to checksum when note absent ---"
_e2e_cov_reset "cksumCCC"
_lab=$(_e2e_cov_stamp_label)
_assert "label is checksum prefix" [[ "$_lab" == cksumCCC* ]] || [[ "$_lab" == "cksumCCC" ]]

# -------------------------------------------------------------------------
echo "--- 10) expected suite list has three names ---"
_exp=$(_e2e_cov_expected_suites | tr '\n' ' ')
_assert "expected includes alpha" "[[ \"$_exp\" == *alpha* ]]"
_assert "expected includes beta" "[[ \"$_exp\" == *beta* ]]"
_assert "expected includes gamma" "[[ \"$_exp\" == *gamma* ]]"

# Cleanup
rm -rf "$COV_DIR" "$NOTIFY_LOG"

echo ""
echo "Results: $pass PASS, $fail FAIL"
[ "$fail" -eq 0 ]
