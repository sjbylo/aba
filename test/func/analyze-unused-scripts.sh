#!/bin/bash
# Deep analysis of potentially unused scripts
# Check git history and README mentions

cd "$(dirname "$0")/../.."

echo "Deep Analysis of Potentially Unused Scripts"
echo "============================================"
echo ""

scripts=(
	"aba-get-version.sh"
	"ask.sh"
	"configure-pxe.sh"
	"download-and-wait-catalogs.sh"
	"init.sh"
	"install-govc.sh"
	"latest_stable_version.sh"
	"listopdeps.sh"
	"output_ver_lower_4.14.9.sh"
	"show-govc-conf.sh"
	"vmw-on.sh"
)

for script in "${scripts[@]}"; do
	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	echo "Script: $script"
	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	
	# Check comment
	comment=$(head -3 "scripts/$script" | grep "^#" | tail -1)
	echo "Comment: $comment"
	
	# Check last modification
	if [ -d .git ]; then
		last_mod=$(git log -1 --format="%ar" -- "scripts/$script" 2>/dev/null || echo "unknown")
		echo "Last modified: $last_mod"
	fi
	
	# Check if mentioned in README
	readme_mentions=$(grep -i "$script" README.md 2>/dev/null | wc -l)
	echo "README mentions: $readme_mentions"
	
	# Check if executable
	if [ -x "scripts/$script" ]; then
		echo "Executable: yes"
	else
		echo "Executable: NO (possibly abandoned)"
	fi
	
	echo ""
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "RECOMMENDATION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Safe to delete (marked 'not in use' or incomplete):"
echo "  - configure-pxe.sh"
echo "  - output_ver_lower_4.14.9.sh"
echo "  - init.sh (old architecture)"
echo ""
echo "Probably safe (check README first):"
echo "  - download-and-wait-catalogs.sh"
echo "  - aba-get-version.sh"
echo "  - ask.sh"
echo "  - vmw-on.sh"
echo ""
echo "Keep (may be used manually):"
echo "  - install-govc.sh"
echo "  - latest_stable_version.sh"
echo "  - listopdeps.sh"
echo "  - show-govc-conf.sh"
echo ""

