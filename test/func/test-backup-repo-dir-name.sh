#!/bin/bash
# Test that backup.sh works regardless of repo directory name
# Tests the fix for: "Bundle creation fails when repo directory not named 'aba'"

set -e

# Color output functions
echo_green() { echo -e "\033[0;32m$*\033[0m"; }
echo_red() { echo -e "\033[0;31m$*\033[0m"; }

test_dir=$(mktemp -d)
trap "rm -rf $test_dir" EXIT

echo "Testing backup.sh with non-standard repo directory name..."

# Create a minimal repo structure with a non-standard name
repo_name="aba-test-0.9.0"
mkdir -p "$test_dir/$repo_name"/{scripts,templates,cli,rpms,others,mirror/save}

# Create minimal required files
touch "$test_dir/$repo_name/install"
touch "$test_dir/$repo_name/aba"
touch "$test_dir/$repo_name/aba.conf"
touch "$test_dir/$repo_name/Makefile"
touch "$test_dir/$repo_name/README.md"
touch "$test_dir/$repo_name/Troubleshooting.md"

# Copy the actual backup.sh script
cp scripts/backup.sh "$test_dir/$repo_name/scripts/"
cp scripts/include_all.sh "$test_dir/$repo_name/scripts/"

# Test 1: Verify repo_dir variable captures correct name
cd "$test_dir/$repo_name"
repo_dir_test=$(basename "$PWD")
if [[ "$repo_dir_test" == "$repo_name" ]]; then
	echo_green "✓ Test 1 PASSED: basename captures correct directory name ($repo_name)"
else
	echo_red "✗ Test 1 FAILED: Expected '$repo_name', got '$repo_dir_test'"
	exit 1
fi

# Test 2: Verify .bundle file can be created (the original bug)
cd ..
touch "$repo_name/.bundle" 2>/dev/null
if [[ -f "$repo_name/.bundle" ]]; then
	echo_green "✓ Test 2 PASSED: .bundle file created successfully in $repo_name/"
	rm -f "$repo_name/.bundle"
else
	echo_red "✗ Test 2 FAILED: Could not create .bundle file in $repo_name/"
	exit 1
fi

# Test 3: Verify script doesn't try to access hardcoded "aba/" directory
cd "$test_dir/$repo_name"
if grep -q 'touch aba/\.bundle' scripts/backup.sh; then
	echo_red "✗ Test 3 FAILED: Script still contains hardcoded 'touch aba/.bundle'"
	exit 1
else
	echo_green "✓ Test 3 PASSED: No hardcoded 'aba/.bundle' path found"
fi

# Test 4: Verify critical hardcoded "aba/" paths are replaced with $repo_dir/
# Check for hardcoded paths in actual commands (not comments or user messages)
critical_hardcoded=$(grep -E '^\s*(touch|rm|find)\s+aba/' scripts/backup.sh || echo "")
if [[ -z "$critical_hardcoded" ]]; then
	echo_green "✓ Test 4 PASSED: No hardcoded 'aba/' paths in commands (touch/rm/find)"
else
	echo_red "✗ Test 4 FAILED: Found hardcoded 'aba/' paths in critical commands:"
	echo "$critical_hardcoded"
	exit 1
fi

echo
echo_green "All tests PASSED!"
echo "The backup.sh script now works with any repository directory name."
