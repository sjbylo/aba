#!/bin/bash
# Test: Verify run_once task IDs for oc-mirror use correct paths
# All scripts should use "make -sC cli" (symlinks handle the rest)

cd "$(dirname "$0")/../.."

echo "Test: Check run_once paths for cli:install:oc-mirror"

failed=0

# Check all scripts - they should all use "cli" (not ../cli, not $ABA_ROOT)
for script in scripts/*.sh; do
	if ! [ -f "$script" ]; then continue; fi
	
	# Extract run_once lines with oc-mirror
	lines=$(grep 'run_once.*cli:install:oc-mirror.*make' "$script" 2>/dev/null || true)
	if [ -z "$lines" ]; then
		continue  # No oc-mirror usage in this script
	fi
	
	# Check each line
	while IFS= read -r line; do
		# Skip commented lines
		if echo "$line" | grep -qE '^\s*#'; then
			continue
		fi
		
		# Must use "cli" (not ../cli, not $ABA_ROOT)
		if echo "$line" | grep -q '\$ABA_ROOT'; then
			echo "✗ FAIL [$script]: Uses \$ABA_ROOT (should use 'cli')"
			echo "  $line"
			failed=1
		elif echo "$line" | grep -qE 'make -sC \.\./cli'; then
			echo "✗ FAIL [$script]: Uses '../cli' (should use 'cli' - symlinks handle it)"
			echo "  $line"
			failed=1
		elif echo "$line" | grep -qE 'make -sC cli'; then
			echo "✓ PASS [$script]: Correctly uses 'cli'"
		else
			echo "✗ FAIL [$script]: Unexpected path"
			echo "  $line"
			failed=1
		fi
	done <<< "$lines"
done

echo ""
if [ $failed -eq 0 ]; then
	echo "✓ ALL TESTS PASSED"
	exit 0
else
	echo "✗ SOME TESTS FAILED"
	exit 1
fi

