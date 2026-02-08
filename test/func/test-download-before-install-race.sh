#!/bin/bash
# Test: Download-before-install race condition
#
# Verifies that cli-install-all.sh waits for all downloads to complete
# before starting extractions. Without this, tar reads a partially
# downloaded tarball, producing a truncated/corrupt binary (segfault).
#
# This test simulates the exact race condition using run_once tasks:
# - A "download" task that slowly writes a file
# - An "install" task that reads and processes that file
# The install must not start until the download is truly done.

# Note: NOT using set -e because some tests deliberately trigger failures
cd "$(dirname "$0")/../.." || exit 1
source scripts/include_all.sh

# Disable ERR trap for test
trap - ERR

# Use isolated test runner directory
export RUN_ONCE_DIR="$HOME/.aba/runner-test-download-race-$$"
TEST_DIR="/tmp/aba-test-download-race-$$"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass_count=0
fail_count=0

test_pass() {
	echo -e "${GREEN}  PASS${NC}: $1"
	pass_count=$((pass_count + 1))
}

test_fail() {
	echo -e "${RED}  FAIL${NC}: $1"
	fail_count=$((fail_count + 1))
}

cleanup() {
	run_once -G 2>/dev/null || true
	rm -rf "$RUN_ONCE_DIR" "$TEST_DIR"
}
trap cleanup EXIT
cleanup

mkdir -p "$TEST_DIR"

echo "=================================================================="
echo "Test 1: Slow download + immediate install = race condition"
echo "  Simulates curl writing a file slowly while tar tries to read it"
echo "=================================================================="

DOWNLOAD_FILE="$TEST_DIR/large-file.tar.gz"
INSTALL_OUTPUT="$TEST_DIR/installed-binary"

# Simulate a slow download: writes 5 chunks with delays
# Uses > (truncate) on first write and >> after, to be idempotent for self-healing
download_cmd=(bash -c "
	echo 'chunk-1' > '$DOWNLOAD_FILE'
	for i in 2 3 4 5; do
		sleep 0.5
		echo \"chunk-\$i\" >> '$DOWNLOAD_FILE'
	done
")

# Simulate install: reads the download file and copies it
# A correct install reads ALL 5 chunks; a racy one reads fewer
install_cmd=(bash -c "
	if [ ! -f '$DOWNLOAD_FILE' ]; then
		echo 'ERROR: download file missing' >&2
		exit 1
	fi
	cp '$DOWNLOAD_FILE' '$INSTALL_OUTPUT'
")

# Start download in background (non-blocking)
echo "  Starting slow download (2.5s)..."
run_once -i "test:race:download" -- "${download_cmd[@]}"

# Immediately start install with wait (simulates cli-install-all.sh WITHOUT fix)
# The install task itself does NOT wait for the download task.
# It just runs immediately and reads whatever is on disk.
echo "  Starting install immediately (no download wait)..."
run_once -w -i "test:race:install-nofix" -- "${install_cmd[@]}"

# Check if install got a complete file
if [ -f "$INSTALL_OUTPUT" ]; then
	lines=$(wc -l < "$INSTALL_OUTPUT")
	if [ "$lines" -eq 5 ]; then
		test_fail "Install got complete file WITHOUT waiting (lucky timing, not reliable)"
		echo "         This means the race wasn't triggered this time, but it's not safe."
	else
		test_pass "Race confirmed: install got incomplete file ($lines/5 chunks)"
	fi
else
	test_pass "Race confirmed: install ran before download created the file"
fi

# Wait for download to actually finish
run_once -w -i "test:race:download" -- "${download_cmd[@]}"

# Verify download itself completed correctly
if [ -f "$DOWNLOAD_FILE" ]; then
	lines=$(wc -l < "$DOWNLOAD_FILE")
	if [ "$lines" -eq 5 ]; then
		test_pass "Download completed correctly (5/5 chunks)"
	else
		test_fail "Download incomplete: $lines/5 chunks"
	fi
else
	test_fail "Download file missing after wait"
fi

echo ""
echo "=================================================================="
echo "Test 2: Wait for download THEN install = correct behavior"
echo "  Simulates the fix in cli-install-all.sh"
echo "=================================================================="

# Clean up for fresh test
run_once -G 2>/dev/null || true
rm -f "$DOWNLOAD_FILE" "$INSTALL_OUTPUT"

DOWNLOAD_FILE2="$TEST_DIR/large-file-2.tar.gz"
INSTALL_OUTPUT2="$TEST_DIR/installed-binary-2"

download_cmd2=(bash -c "
	echo 'chunk-1' > '$DOWNLOAD_FILE2'
	for i in 2 3 4 5; do
		sleep 0.5
		echo \"chunk-\$i\" >> '$DOWNLOAD_FILE2'
	done
")

install_cmd2=(bash -c "
	if [ ! -f '$DOWNLOAD_FILE2' ]; then
		echo 'ERROR: download file missing' >&2
		exit 1
	fi
	cp '$DOWNLOAD_FILE2' '$INSTALL_OUTPUT2'
")

# Start download in background
echo "  Starting slow download (2.5s)..."
run_once -i "test:fix:download" -- "${download_cmd2[@]}"

# NOW: wait for download to complete FIRST (this is the fix)
echo "  Waiting for download to complete FIRST (the fix)..."
run_once -w -i "test:fix:download" -- "${download_cmd2[@]}"
echo "  Download complete, now running install..."

# Then run install
run_once -w -i "test:fix:install" -- "${install_cmd2[@]}"

# Verify install got the complete file
if [ -f "$INSTALL_OUTPUT2" ]; then
	lines=$(wc -l < "$INSTALL_OUTPUT2")
	if [ "$lines" -eq 5 ]; then
		test_pass "Install got complete file (5/5 chunks) after waiting for download"
	else
		test_fail "Install got incomplete file ($lines/5 chunks) despite waiting"
	fi
else
	test_fail "Install output missing"
fi

echo ""
echo "=================================================================="
echo "Test 3: Multiple downloads + single install gate"
echo "  Simulates cli-download-all.sh (multiple) + cli-install-all.sh"
echo "=================================================================="

run_once -G 2>/dev/null || true

# Simulate 3 parallel downloads with different durations
for i in 1 2 3; do
	duration=$((i))  # 1s, 2s, 3s
	outfile="$TEST_DIR/download-$i.dat"
	run_once -i "test:multi:download:$i" -- bash -c "
		sleep $duration
		echo 'complete-$i' > '$outfile'
	"
done

echo "  Started 3 downloads (1s, 2s, 3s)..."

# Wait for ALL downloads (simulates cli-download-all.sh --wait)
echo "  Waiting for ALL downloads..."
for i in 1 2 3; do
	run_once -w -i "test:multi:download:$i"
done
echo "  All downloads complete."

# Now run install that needs all 3 files
run_once -w -i "test:multi:install" -- bash -c "
	for i in 1 2 3; do
		f='$TEST_DIR/download-'\$i'.dat'
		if [ ! -f \"\$f\" ]; then
			echo \"ERROR: missing \$f\" >&2
			exit 1
		fi
		content=\$(cat \"\$f\")
		if [ \"\$content\" != \"complete-\$i\" ]; then
			echo \"ERROR: \$f has wrong content: \$content\" >&2
			exit 1
		fi
	done
	echo 'all files verified'
"

if [ $? -eq 0 ]; then
	test_pass "Install verified all 3 downloads are complete and correct"
else
	test_fail "Install found missing or incomplete downloads"
fi

echo ""
echo "=================================================================="
echo "Test 4: cli-install-all.sh script has the download wait guard"
echo "  Static check that the fix is present in the actual script"
echo "=================================================================="

if grep -q 'cli-download-all.sh --wait' scripts/cli-install-all.sh; then
	test_pass "cli-install-all.sh calls cli-download-all.sh --wait"
else
	test_fail "cli-install-all.sh MISSING cli-download-all.sh --wait call"
fi

# Verify the guard skips for --reset mode
if grep -q '"$1" != "--reset"' scripts/cli-install-all.sh; then
	test_pass "Download wait guard is skipped during --reset"
else
	test_fail "Download wait guard missing --reset skip"
fi

echo ""
echo "=================================================================="
echo "Test 5: Idempotent re-run after successful download+install"
echo "  Verifies that repeated runs don't break when files already exist"
echo "=================================================================="

run_once -G 2>/dev/null || true

IDEM_FILE="$TEST_DIR/idempotent.dat"

# First run: download + install
run_once -w -i "test:idem:download" -- bash -c "echo 'data' > '$IDEM_FILE'"
run_once -w -i "test:idem:install" -- bash -c "[ -f '$IDEM_FILE' ] && echo ok || exit 1"

if [ $? -eq 0 ]; then
	test_pass "First run: download + install succeeded"
else
	test_fail "First run failed"
fi

# Second run: should use cached results and skip quickly
run_once -w -i "test:idem:download" -- bash -c "echo 'data' > '$IDEM_FILE'"
run_once -w -i "test:idem:install" -- bash -c "[ -f '$IDEM_FILE' ] && echo ok || exit 1"

if [ $? -eq 0 ]; then
	test_pass "Second run: idempotent re-run succeeded (cached)"
else
	test_fail "Second run failed (should have used cached result)"
fi

echo ""
echo "=================================================================="
echo "Test 6: Self-healing after binary deletion"
echo "  Verifies that run_once -w re-creates missing output"
echo "=================================================================="

run_once -G 2>/dev/null || true

HEAL_FILE="$TEST_DIR/heal-binary"

# Create the "binary"
run_once -w -i "test:heal:install" -- bash -c "
	if [ -f '$HEAL_FILE' ]; then
		exit 0  # Already exists, idempotent
	fi
	echo 'valid-binary' > '$HEAL_FILE'
"

if [ -f "$HEAL_FILE" ]; then
	test_pass "Binary created successfully"
else
	test_fail "Binary not created"
fi

# Delete the "binary" (simulate user deletion)
rm -f "$HEAL_FILE"

# Wait again - self-healing validation should recreate it
run_once -w -i "test:heal:install"

if [ -f "$HEAL_FILE" ]; then
	content=$(cat "$HEAL_FILE")
	if [ "$content" = "valid-binary" ]; then
		test_pass "Self-healing recreated the binary correctly"
	else
		test_fail "Self-healing produced wrong content: $content"
	fi
else
	test_fail "Self-healing did NOT recreate the binary"
fi

echo ""
echo "=================================================================="
echo "Test 7: Concurrent waiters on same download task"
echo "  Multiple install processes waiting for same download"
echo "=================================================================="

run_once -G 2>/dev/null || true

CONCURRENT_FILE="$TEST_DIR/concurrent.dat"

# Start slow download
run_once -i "test:concurrent:dl" -- bash -c "sleep 2 && echo 'done' > '$CONCURRENT_FILE'"

echo "  Starting 5 concurrent waiters..."
pids=()
results=()
for i in {1..5}; do
	(
		run_once -q -w -i "test:concurrent:dl"
		exit $?
	) &
	pids+=($!)
done

all_ok=true
for pid in "${pids[@]}"; do
	if ! wait "$pid"; then
		all_ok=false
	fi
done

if $all_ok && [ -f "$CONCURRENT_FILE" ]; then
	test_pass "All 5 concurrent waiters succeeded"
else
	test_fail "Some concurrent waiters failed or file missing"
fi

echo ""
echo "=================================================================="
echo "                       RESULTS"
echo "=================================================================="
echo ""
echo -e "  ${GREEN}Passed${NC}: $pass_count"
echo -e "  ${RED}Failed${NC}: $fail_count"
echo ""

if [ $fail_count -eq 0 ]; then
	echo -e "${GREEN}ALL TESTS PASSED${NC}"
	exit 0
else
	echo -e "${RED}SOME TESTS FAILED${NC}"
	exit 1
fi
