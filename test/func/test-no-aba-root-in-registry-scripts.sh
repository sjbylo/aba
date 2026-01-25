#!/bin/bash
# Test: Verify $ABA_ROOT is not used in make commands within registry scripts
# This ensures cleanup was done correctly and scripts use relative paths

cd "$(dirname "$0")/../.."

echo "Test: Check registry scripts for \$ABA_ROOT in make commands"

failed=0

for script in scripts/reg-install.sh scripts/reg-save.sh scripts/reg-load.sh scripts/reg-sync.sh; do
	if [ ! -f "$script" ]; then
		echo "✗ FAIL: Script $script not found"
		failed=1
		continue
	fi
	
	# Check for $ABA_ROOT in make commands
	if grep -n 'make.*\$ABA_ROOT' "$script"; then
		echo "✗ FAIL: Found \$ABA_ROOT in make command in $script"
		failed=1
	else
		echo "✓ PASS: No \$ABA_ROOT in $script"
	fi
	
	# Also check for absolute "mirror" path in make -C (should be "." when running from mirror/)
	if grep -n 'make.*-C mirror ' "$script"; then
		echo "✗ FAIL: Found 'make -C mirror' in $script (should be 'make -C .')"
		failed=1
	fi
done

if [ $failed -eq 0 ]; then
	echo ""
	echo "✓ ALL TESTS PASSED"
	exit 0
else
	echo ""
	echo "✗ SOME TESTS FAILED"
	exit 1
fi

