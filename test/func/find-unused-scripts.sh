#!/bin/bash
# Find unused scripts in aba/scripts/

cd "$(dirname "$0")/../.."

echo "Analyzing script usage in aba codebase..."
echo ""

unused=()
used=()

for script in scripts/*.sh; do
	script_name=$(basename "$script")
	
	# Skip aba.sh and include_all.sh (obviously used)
	if [ "$script_name" = "aba.sh" ] || [ "$script_name" = "include_all.sh" ]; then
		continue
	fi
	
	# Search for references in:
	# - Makefiles
	# - Other scripts
	# - aba.sh command handling
	
	references=$(grep -r "$script_name" \
		--include="Makefile" \
		--include="*.sh" \
		--exclude="$script_name" \
		. 2>/dev/null | wc -l)
	
	if [ "$references" -eq 0 ]; then
		unused+=("$script_name")
	else
		used+=("$script_name")
	fi
done

echo "════════════════════════════════════════════════════════"
echo "POTENTIALLY UNUSED SCRIPTS (${#unused[@]} scripts)"
echo "════════════════════════════════════════════════════════"
for script in "${unused[@]}"; do
	echo "  $script"
done

echo ""
echo "════════════════════════════════════════════════════════"
echo "USED SCRIPTS (${#used[@]} scripts)"
echo "════════════════════════════════════════════════════════"
for script in "${used[@]}"; do
	refs=$(grep -r "$script" \
		--include="Makefile" \
		--include="*.sh" \
		--exclude="$script" \
		. 2>/dev/null | wc -l)
	echo "  $script (referenced $refs times)"
done

echo ""
echo "Note: Review 'unused' scripts before deleting!"
echo "Some may be called directly by users or documentation."

