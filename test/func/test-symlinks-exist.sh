#!/bin/bash
# Test: Verify expected symlinks exist in subdirectories
# Ensures scripts can access shared resources
#
# NOTE: Symlinks are created by 'make init' in subdirectories (cli/, mirror/, etc.)
#       This test verifies they exist after initialization, not on fresh clone.

cd "$(dirname "$0")/../.."

echo "Test: Check symlinks exist in subdirectories"
echo "(Symlinks created by 'make init' in subdirectories)"
echo ""

failed=0

# Expected symlinks: link_path -> expected_target
check_symlink() {
	local link="$1"
	local target="$2"
	
	if [ ! -L "$link" ]; then
		echo "✗ FAIL: Symlink $link does not exist"
		return 1
	elif [ "$(readlink "$link")" != "$target" ]; then
		echo "✗ FAIL: Symlink $link points to $(readlink "$link"), expected $target"
		return 1
	else
		echo "✓ PASS: $link -> $target"
		return 0
	fi
}

# Check each expected symlink
for link in "cli/scripts" "mirror/scripts" "mirror/cli"; do
	if [ "$link" = "cli/scripts" ]; then
		target="../scripts"
	elif [ "$link" = "mirror/scripts" ]; then
		target="../scripts"
	elif [ "$link" = "mirror/cli" ]; then
		target="../cli"
	fi
	check_symlink "$link" "$target" || failed=1
done

echo ""
if [ $failed -eq 0 ]; then
	echo "✓ ALL TESTS PASSED"
	exit 0
else
	echo "✗ SOME TESTS FAILED"
	echo ""
	echo "NOTE: Symlinks are created by running:"
	echo "  make init           # In aba root (creates cli/scripts, etc.)"
	echo "  make -C mirror init # Creates mirror/cli, mirror/scripts, etc."
	echo "  make -C cli init    # Creates cli/scripts"
	exit 1
fi

