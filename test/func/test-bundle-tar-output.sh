#!/bin/bash -e
# Integration test: aba bundle -o - produces clean tar output
# Verifies that stdout contains ONLY tar data, no text messages
#
# NOTE: This test is SKIPPED in automated runs because:
# - It takes 5-20 minutes (downloads images from network)
# - It's tested in end-to-end tests separately
# - Run manually with: test/func/test-bundle-tar-output.sh

echo "SKIPPED: Bundle test takes too long for automated runs (5-20 minutes)"
echo "Run manually if needed: test/func/test-bundle-tar-output.sh"
exit 0

cd "$(dirname "$0")/../.."

# Acquire test lock to prevent concurrent test runs
TEST_LOCK_FILE="$HOME/.aba/test-bundle.lock"
mkdir -p "$HOME/.aba"
exec 200>"$TEST_LOCK_FILE"
if ! flock -n 200; then
	echo "Error: Another bundle test is running. Please wait." >&2
	exit 1
fi
# Lock released on exit

echo "=== Test: aba bundle -o - (tar output validation) ==="
echo "Working directory: $PWD"
echo ""

# Set ABA_ROOT for scripts that still need it (temporary during transition)
export ABA_ROOT="$PWD"

source scripts/include_all.sh

# Clean up previous state to force fresh download
echo "Cleaning up previous state..."
rm -rf ~/.aba/runner/cli:install:oc-mirror
rm -rf mirror/.index/*-operator-index-*

# Test 1: Verify tar output is valid
echo ""
echo "Test 1: Bundle output is valid tar format"
echo "-----------------------------------------"

temp_tar=$(mktemp /tmp/aba-bundle-test.XXXXXX.tar)
trap "rm -f $temp_tar" EXIT

# Note: This test requires images to be already downloaded/saved (takes 5-20 minutes)
# The test verifies tar output format, not the complete mirror process
aba_info "Note: This test requires a complete mirror setup. If it times out, run 'aba -d mirror save' first." >&2

# Use timeout to prevent hanging (5 minutes should be enough if images are cached)
if ! timeout 300 ./aba bundle -o - > "$temp_tar" 2>/dev/null; then
	exit_code=$?
	if [ $exit_code -eq 124 ]; then
		aba_abort "Test 1 FAILED: aba bundle command timed out after 5 minutes (images may not be cached)"
	else
		aba_abort "Test 1 FAILED: aba bundle command failed with exit code $exit_code"
	fi
fi

# Verify it's a tar file
if ! file "$temp_tar" | grep -q "tar archive"; then
	file "$temp_tar"
	aba_abort "Test 1 FAILED: Output is not a tar archive"
fi

aba_info_ok "Test 1 PASSED: Output is valid tar format" >&2

# Test 2: Verify no text leakage in tar output
echo ""
echo "Test 2: No text messages in tar output"
echo "---------------------------------------"

# Check for common text patterns that shouldn't be in a tar file
if strings "$temp_tar" | grep -q "^\[ABA\]"; then
	aba_abort "Test 2 FAILED: Found [ABA] messages in tar output"
fi

if strings "$temp_tar" | head -20 | grep -qE "^(Error|Warning|INFO|DEBUG):"; then
	aba_abort "Test 2 FAILED: Found error/warning messages in tar output"
fi

aba_info_ok "Test 2 PASSED: No text leakage detected" >&2

# Test 3: Verify tar contents are reasonable
echo ""
echo "Test 3: Tar contents validation"
echo "--------------------------------"

# List tar contents
if ! tar -tf "$temp_tar" >/dev/null 2>&1; then
	aba_abort "Test 3 FAILED: Cannot list tar contents"
fi

# Check for expected directories/files
expected_paths=(
	"aba/"
	"bin/"
)

for path in "${expected_paths[@]}"; do
	if ! tar -tf "$temp_tar" | grep -q "^$path"; then
		aba_warning "Expected path '$path' not found in tar (may be normal)" >&2
	else
		aba_info_ok "✓ Found: $path" >&2
	fi
done

aba_info_ok "Test 3 PASSED: Tar contents are valid" >&2

# Test 4: Verify tar can be extracted
echo ""
echo "Test 4: Tar extraction test"
echo "----------------------------"

temp_dir=$(mktemp -d /tmp/aba-extract-test.XXXXXX)
trap "rm -rf $temp_dir $temp_tar" EXIT

if ! tar -xf "$temp_tar" -C "$temp_dir" 2>/dev/null; then
	aba_abort "Test 4 FAILED: Cannot extract tar file"
fi

# Verify some content was extracted
if [ -z "$(ls -A "$temp_dir")" ]; then
	aba_abort "Test 4 FAILED: Extracted directory is empty"
fi

aba_info_ok "Test 4 PASSED: Tar extracts successfully" >&2

# Cleanup
rm -rf "$temp_dir" "$temp_tar"

# All tests passed
echo ""
echo "========================================="
aba_info_ok "✓ ALL BUNDLE TESTS PASSED" >&2
echo "========================================="
echo ""
echo "Summary:"
echo "  - Bundle creates valid tar output"
echo "  - No text leakage in tar stream"
echo "  - Tar contents are valid"
echo "  - Tar can be extracted"
echo ""

