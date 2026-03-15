#!/bin/bash
# Test: run_once validation uses saved command+CWD pair, not caller's command
#
# Reproduces the bug where:
#   1. aba.sh starts a task from /aba root: make -sC subdir target
#   2. ensure_*() waits from /aba/subdir:  make -sC .     target
#   3. Validation restores saved CWD (/aba root) but ran the CALLER's
#      command (make -sC . target), hitting the wrong Makefile.
#
# The fix: validation loads the saved command from cmd.sh to match saved CWD.

set -e

cd "$(dirname "$0")/../.." || exit 1
source scripts/include_all.sh

trap - ERR

export RUN_ONCE_DIR="$HOME/.aba/runner-test-cwd-mismatch"
TEST_DIR="/tmp/aba-test-cwd-mismatch-$$"
PARENT_DIR="$TEST_DIR/parent"
SUB_DIR="$TEST_DIR/parent/subdir"

cleanup() {
	rm -rf "$RUN_ONCE_DIR" "$TEST_DIR"
}
trap cleanup EXIT
cleanup

mkdir -p "$SUB_DIR"

# Create a Makefile in the subdirectory with a file target
cat > "$SUB_DIR/Makefile" <<'MKEOF'
.SILENT:
output.txt:
	echo "built from subdir Makefile" > output.txt
MKEOF

# Create a DIFFERENT Makefile in the parent (no output.txt target)
cat > "$PARENT_DIR/Makefile" <<'MKEOF'
.SILENT:
other:
	echo "parent target"
MKEOF

passed=0
failed=0

pass() { echo "✓ PASS: $1"; passed=$((passed + 1)); }
fail() { echo "✗ FAIL: $1"; failed=$((failed + 1)); }

echo "======================================================================"
echo "Test 1: Baseline — task started from parent with make -sC subdir"
echo "======================================================================"

cd "$PARENT_DIR"
run_once -i "test:cwd:mismatch1" -- make -sC subdir output.txt
run_once -w -i "test:cwd:mismatch1"

if [[ -f "$SUB_DIR/output.txt" ]]; then
	pass "Task created output.txt in subdir"
else
	fail "Task did not create output.txt"
fi

echo ""
echo "======================================================================"
echo "Test 2: Wait from subdir with different relative path (the bug)"
echo "======================================================================"
echo "  Caller CWD:     $SUB_DIR (make -sC . output.txt)"
echo "  Saved CWD:      $PARENT_DIR (make -sC subdir output.txt)"
echo "  Without fix:    validation would run 'make -sC . output.txt' from"
echo "                  parent dir → No rule to make target 'output.txt'"

# Remove the output so validation must re-create it
rm -f "$SUB_DIR/output.txt"

# Call from subdirectory with a DIFFERENT relative path — same task ID
cd "$SUB_DIR"
if run_once -w -i "test:cwd:mismatch1" -- make -sC . output.txt; then
	pass "Validation succeeded (used saved command, not caller's)"
else
	fail "Validation failed (likely used caller's command with saved CWD)"
fi

if [[ -f "$SUB_DIR/output.txt" ]]; then
	pass "Validation re-created output.txt via saved command"
else
	fail "output.txt not re-created — validation ran wrong command"
fi

echo ""
echo "======================================================================"
echo "Test 3: Verify saved command was actually used (check history)"
echo "======================================================================"

history_file="$RUN_ONCE_DIR/test:cwd:mismatch1/history"
if [[ -f "$history_file" ]] && grep -q "VALIDATE rc=0" "$history_file"; then
	pass "History shows successful validation"
else
	fail "History missing or validation not recorded"
fi

# Verify the saved command file has the ORIGINAL command
cmd_file="$RUN_ONCE_DIR/test:cwd:mismatch1/cmd"
if [[ -f "$cmd_file" ]] && grep -q "subdir" "$cmd_file"; then
	pass "Saved command uses 'subdir' path (original command preserved)"
else
	fail "Saved command was overwritten or missing"
fi

echo ""
echo "======================================================================"
echo "Test 4: First-time start from subdir still works"
echo "======================================================================"

cd "$SUB_DIR"
rm -f "$SUB_DIR/output.txt"
run_once -i "test:cwd:mismatch2" -- make -sC . output.txt
run_once -w -i "test:cwd:mismatch2"

if [[ -f "$SUB_DIR/output.txt" ]]; then
	pass "Fresh task from subdir with 'make -sC .' succeeded"
else
	fail "Fresh task from subdir failed"
fi

# Now validate from parent with different path — same pattern, reversed
rm -f "$SUB_DIR/output.txt"
cd "$PARENT_DIR"
if run_once -w -i "test:cwd:mismatch2" -- make -sC subdir output.txt; then
	pass "Reverse mismatch: validation used saved command (make -sC .)"
else
	fail "Reverse mismatch: validation failed"
fi

if [[ -f "$SUB_DIR/output.txt" ]]; then
	pass "Reverse mismatch: output.txt re-created correctly"
else
	fail "Reverse mismatch: output.txt not re-created"
fi

echo ""
echo "======================================================================"
echo "Results: $passed passed, $failed failed"
echo "======================================================================"

if [[ $failed -gt 0 ]]; then
	echo ""
	echo "FAILED — see output above"
	exit 1
fi

echo ""
echo "All tests passed — CWD/command mismatch is handled correctly."
