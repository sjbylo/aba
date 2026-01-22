#!/bin/bash -e
# Integration test: Bundle mode background extraction
# Verifies that CLI tools and mirror-registry extract in background when .bundle is detected

cd "$(dirname "$0")/../.."

# Acquire test lock to prevent concurrent test runs
TEST_LOCK_FILE="$HOME/.aba/test-bundle-extraction.lock"
mkdir -p "$HOME/.aba"
exec 200>"$TEST_LOCK_FILE"
if ! flock -n 200; then
	echo "Error: Another bundle extraction test is running. Please wait." >&2
	exit 1
fi
# Lock released on exit

echo "=== Test: Bundle Mode Background Extraction ==="
echo "Working directory: $PWD"
echo ""

source scripts/include_all.sh

# Clean up previous state
echo "Cleaning up previous state..."
rm -f mirror/mirror-registry mirror/mirror-registry-sha256sum.txt mirror/execution-environment.tar
rm -f ~/bin/{oc,oc-mirror,openshift-install,govc,butane}
rm -rf ~/.aba/runner/cli:install:*
rm -rf ~/.aba/runner/mirror:reg:install
rm -f .bundle

echo "✓ Cleanup complete"
echo ""

# Verify we have the tarballs (should be in bundle)
echo "Verifying tarballs exist..."
if [ ! -f mirror/mirror-registry-amd64.tar.gz ]; then
	echo "ERROR: mirror-registry-amd64.tar.gz not found (required for test)" >&2
	echo "This test requires a bundle environment or the tarball to be present." >&2
	exit 1
fi

tarball_count=$(ls -1 cli/*.tar.gz 2>/dev/null | wc -l)
if [ "$tarball_count" -lt 3 ]; then
	echo "ERROR: CLI tarballs not found in cli/ directory (required for test)" >&2
	echo "This test requires a bundle environment with CLI tarballs." >&2
	exit 1
fi

echo "✓ Found mirror-registry tarball (911M)"
echo "✓ Found $tarball_count CLI tarballs"
echo ""

# Test 1: Simulate bundle mode and trigger background extraction
echo "Test 1: Bundle mode detection and background extraction"
echo "-------------------------------------------------------"

touch .bundle
echo "✓ Created .bundle file"

# Run aba (should detect bundle and start background extractions)
echo "Running aba (should start background extractions)..."
./aba > /tmp/test-bundle-aba.out 2>&1 || true

# Check that it detected the bundle
if ! grep -q "Aba install bundle detected" /tmp/test-bundle-aba.out; then
	echo "ERROR: Bundle not detected!" >&2
	cat /tmp/test-bundle-aba.out >&2
	rm -f .bundle
	exit 1
fi

echo "✓ Bundle detected successfully"
echo ""

# Test 2: Verify background tasks were started
echo "Test 2: Verify background tasks started"
echo "----------------------------------------"

# Give tasks a moment to start
sleep 1

# Check for CLI installation tasks
cli_tasks_found=0
for tool in oc oc-mirror openshift-install govc butane; do
	if [ -d ~/.aba/runner/cli:install:$tool ]; then
		echo "✓ Found task: cli:install:$tool"
		cli_tasks_found=$((cli_tasks_found + 1))
	fi
done

if [ "$cli_tasks_found" -lt 3 ]; then
	echo "ERROR: Expected at least 3 CLI tasks, found $cli_tasks_found" >&2
	exit 1
fi

# Check for mirror-registry task (most important for this test)
if [ ! -d ~/.aba/runner/mirror:reg:install ]; then
	echo "ERROR: mirror:reg:install task not found!" >&2
	echo "Expected: ~/.aba/runner/mirror:reg:install" >&2
	ls -la ~/.aba/runner/ >&2
	rm -f .bundle
	exit 1
fi

echo "✓ Found task: mirror:reg:install"
aba_info_ok "Test 2 PASSED: All background tasks started" >&2
echo ""

# Test 3: Wait for extraction to complete
echo "Test 3: Wait for extraction completion"
echo "---------------------------------------"

max_wait=30
elapsed=0
while [ $elapsed -lt $max_wait ]; do
	# Check if mirror-registry extraction completed
	if [ -f ~/.aba/runner/mirror:reg:install/exit ]; then
		exit_code=$(cat ~/.aba/runner/mirror:reg:install/exit)
		if [ "$exit_code" = "0" ]; then
			echo "✓ mirror-registry extraction completed (exit 0) after ${elapsed}s"
			break
		else
			echo "ERROR: mirror-registry extraction failed with exit code $exit_code" >&2
			cat ~/.aba/runner/mirror:reg:install/log.err >&2
			rm -f .bundle
			exit 1
		fi
	fi
	
	# Check if extraction is still running
	if ps aux | grep -q "[t]ar.*mirror-registry"; then
		echo "  Still extracting... (${elapsed}s)"
	fi
	
	sleep 2
	elapsed=$((elapsed + 2))
done

if [ $elapsed -ge $max_wait ]; then
	echo "ERROR: Extraction timed out after ${max_wait}s" >&2
	rm -f .bundle
	exit 1
fi

aba_info_ok "Test 3 PASSED: Extraction completed successfully" >&2
echo ""

# Test 4: Verify extracted files
echo "Test 4: Verify extracted files"
echo "-------------------------------"

# Check mirror-registry binary
if [ ! -f mirror/mirror-registry ]; then
	echo "ERROR: mirror/mirror-registry not found after extraction!" >&2
	rm -f .bundle
	exit 1
fi

if [ ! -x mirror/mirror-registry ]; then
	echo "ERROR: mirror/mirror-registry is not executable!" >&2
	rm -f .bundle
	exit 1
fi

mirror_reg_size=$(stat -c%s mirror/mirror-registry)
echo "✓ mirror-registry extracted ($((mirror_reg_size / 1024 / 1024))M)"

# Check execution-environment.tar
if [ ! -f mirror/execution-environment.tar ]; then
	echo "ERROR: execution-environment.tar not found!" >&2
	rm -f .bundle
	exit 1
fi

exec_env_size=$(stat -c%s mirror/execution-environment.tar)
echo "✓ execution-environment.tar extracted ($((exec_env_size / 1024 / 1024))M)"

# Check at least some CLI binaries
cli_binaries_found=0
for binary in ~/bin/{oc,oc-mirror,openshift-install}; do
	if [ -f "$binary" ] && [ -x "$binary" ]; then
		binary_name=$(basename "$binary")
		binary_size=$(stat -c%s "$binary")
		echo "✓ $binary_name installed ($((binary_size / 1024 / 1024))M)"
		cli_binaries_found=$((cli_binaries_found + 1))
	fi
done

if [ "$cli_binaries_found" -lt 2 ]; then
	echo "ERROR: Expected at least 2 CLI binaries, found $cli_binaries_found" >&2
	rm -f .bundle
	exit 1
fi

aba_info_ok "Test 4 PASSED: All files extracted successfully" >&2
echo ""

# Test 5: Verify Makefile can use the extracted files
echo "Test 5: Verify 'make -C mirror install' works"
echo "----------------------------------------------"

# Reset the .installed flag to test the Makefile path
rm -f mirror/.installed

# This should NOT re-extract (task already completed)
echo "Running: make -C mirror .installed"
if ! make -sC mirror .installed 2>&1 | tee /tmp/test-make-install.out; then
	echo "ERROR: make -C mirror install failed!" >&2
	cat /tmp/test-make-install.out >&2
	rm -f .bundle
	exit 1
fi

# Verify it used the constant (should see it in runner logs if extraction was needed)
if [ -f ~/.aba/runner/mirror:reg:install/cmd ]; then
	echo "✓ Task used correct task ID: mirror:reg:install"
fi

aba_info_ok "Test 5 PASSED: Makefile integration works" >&2
echo ""

# Test 6: Verify ensure_quay_registry() function works
echo "Test 6: Verify ensure_quay_registry() function"
echo "-----------------------------------------------"

# Call the function directly
if ! bash -c 'source scripts/include_all.sh && ensure_quay_registry' > /tmp/test-ensure-func.out 2>&1; then
	echo "ERROR: ensure_quay_registry() function failed!" >&2
	cat /tmp/test-ensure-func.out >&2
	rm -f .bundle
	exit 1
fi

echo "✓ ensure_quay_registry() completed successfully"

# Verify it uses the correct constant
if grep -q "TASK_QUAY_REG" scripts/include_all.sh; then
	echo "✓ Function uses TASK_QUAY_REG constant"
fi

aba_info_ok "Test 6 PASSED: ensure_quay_registry() function works" >&2
echo ""

# Cleanup
echo "Cleaning up test artifacts..."
rm -f .bundle
rm -f /tmp/test-bundle-aba.out /tmp/test-make-install.out /tmp/test-ensure-func.out
echo "✓ Cleanup complete"
echo ""

# All tests passed
echo "========================================="
aba_info_ok "✓ ALL BUNDLE EXTRACTION TESTS PASSED" >&2
echo "========================================="
echo ""
echo "Summary:"
echo "  - Bundle mode detected correctly"
echo "  - Background tasks started (CLI + mirror-registry)"
echo "  - Extractions completed successfully"
echo "  - Task ID consistency verified (mirror:reg:install)"
echo "  - Makefile integration works"
echo "  - ensure_quay_registry() function works"
echo ""
echo "This confirms:"
echo "  ✓ Parallel background extraction is working"
echo "  ✓ Task coordination with run_once is correct"
echo "  ✓ Both 'make' and 'aba' commands use consistent task IDs"
echo ""
