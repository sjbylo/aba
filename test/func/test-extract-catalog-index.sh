#!/bin/bash
# Validate extract-catalog-index.sh against oc-mirror reference data.
#
# For each OCP version x catalog combination (18 total):
#   1. Run podman-based extraction to a test directory
#   2. Compare name+channel ($1 $NF) against oc-mirror reference
#   3. Report display name coverage (best effort, not pass/fail)
#
# Usage:
#   test-extract-catalog-index.sh              # run all 18 combos
#   test-extract-catalog-index.sh 4.20         # single version, all 3 catalogs
#   test-extract-catalog-index.sh 4.20 redhat-operator  # single combo

set -e

cd "$(dirname "$0")/../.."

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

VERSIONS="${1:-4.16 4.17 4.18 4.19 4.20 4.21}"
CATALOGS="${2:-redhat-operator certified-operator community-operator}"

REF_DIR=".index"
TEST_DIR=".index-test"
BACKUP_DIR=".index-backup"
mkdir -p "$TEST_DIR" "$BACKUP_DIR"

_pass=0
_fail=0
_skip=0
_total=0

summary_lines=()

echo ""
echo -e "${CYAN}=== Catalog Extraction Validation ===${NC}"
echo "  Versions: $VERSIONS"
echo "  Catalogs: $CATALOGS"
echo ""

# Phase A: Back up all existing oc-mirror references
echo -e "${CYAN}--- Backing up existing oc-mirror references ---${NC}"
for f in "$REF_DIR"/*-index-v*; do
	[ -f "$f" ] || continue
	base=$(basename "$f")
	cp "$f" "$BACKUP_DIR/$base"
	echo "  Saved $base"
done
echo ""

# Phase B: Generate missing oc-mirror references (4.16, 4.18)
for ver in $VERSIONS; do
	for cat in $CATALOGS; do
		ref_backup="$BACKUP_DIR/${cat}-index-v${ver}"
		if [ -s "$ref_backup" ]; then
			continue
		fi
		echo -e "${CYAN}--- Generating oc-mirror reference: ${cat} v${ver} ---${NC}"
		rm -f "${REF_DIR}/.${cat}-index-v${ver}.done"
		if scripts/download-catalog-index.sh "$cat" "$ver" 2>&1 | tail -3; then
			if [ -s "${REF_DIR}/${cat}-index-v${ver}" ]; then
				cp "${REF_DIR}/${cat}-index-v${ver}" "$ref_backup"
				echo -e "  ${GREEN}OK${NC}: generated reference"
			else
				echo -e "  ${YELLOW}WARN${NC}: oc-mirror produced empty output"
			fi
		else
			echo -e "  ${YELLOW}WARN${NC}: oc-mirror failed (catalog may not exist for v${ver})"
		fi
		echo ""
	done
done

# Phase C: Run podman extraction and compare
for ver in $VERSIONS; do
	for cat in $CATALOGS; do
		label="${cat} v${ver}"
		ref_backup="$BACKUP_DIR/${cat}-index-v${ver}"
		podman_file="$TEST_DIR/${cat}-podman-v${ver}"
		_total=$((_total + 1))

		echo -e "${CYAN}--- ${label} ---${NC}"

		# Check if we have an oc-mirror reference
		has_ref=1
		if [ ! -s "$ref_backup" ]; then
			echo -e "  ${YELLOW}No oc-mirror reference available${NC}"
			has_ref=0
		fi

		# Clear state and run podman extraction
		rm -f "${REF_DIR}/${cat}-index-v${ver}" "${REF_DIR}/.${cat}-index-v${ver}.done"

		echo "  Running podman extraction ..."
		if ! scripts/extract-catalog-index.sh "$cat" "$ver" 2>&1 | tail -2; then
			echo -e "  ${RED}FAIL${NC}: podman extraction failed"
			_fail=$((_fail + 1))
			summary_lines+=("FAIL  ${label}  extraction failed")
			echo ""
			continue
		fi

		# The extraction writes to REF_DIR; copy to test dir
		extracted="${REF_DIR}/${cat}-index-v${ver}"
		if [ ! -s "$extracted" ]; then
			echo -e "  ${RED}FAIL${NC}: extraction produced empty output"
			_fail=$((_fail + 1))
			summary_lines+=("FAIL  ${label}  empty output")
			echo ""
			continue
		fi
		cp "$extracted" "$podman_file"

		# Count operators and check format
		total_ops=$(wc -l < "$podman_file")
		bad_cols=$(awk 'NF < 3' "$podman_file" | wc -l)
		if [ "$bad_cols" -gt 0 ]; then
			echo -e "  ${YELLOW}WARN${NC}: $bad_cols lines with fewer than 3 columns"
		fi

		# Display name coverage (best effort)
		has_display=$(awk '$2 != "-" {count++} END {print count+0}' "$podman_file")
		no_display=$((total_ops - has_display))
		pct=0
		[ "$total_ops" -gt 0 ] && pct=$((has_display * 100 / total_ops))

		# Compare name+channel against oc-mirror reference
		if [ "$has_ref" -eq 1 ]; then
			# Extract 2-column (name channel) from both
			awk '{print $1, $NF}' "$ref_backup" | sort > "$TEST_DIR/.ref-2col"
			awk '{print $1, $NF}' "$podman_file" | sort > "$TEST_DIR/.podman-2col"

			ref_count=$(wc -l < "$TEST_DIR/.ref-2col")
			podman_count=$(wc -l < "$TEST_DIR/.podman-2col")

			diff_output=$(diff "$TEST_DIR/.ref-2col" "$TEST_DIR/.podman-2col" 2>&1) || true

			if [ -z "$diff_output" ]; then
				echo -e "  ${GREEN}MATCH${NC}: name+channel identical (${total_ops} ops, ref=${ref_count})"
				echo -e "  Display names: ${has_display}/${total_ops} (${pct}%)"
				_pass=$((_pass + 1))
				summary_lines+=("PASS  ${label}  ops=${total_ops}  match=exact  display=${has_display}/${total_ops} (${pct}%)")
			else
				# Count differences
				only_ref=$(echo "$diff_output" | grep '^< ' | wc -l)
				only_podman=$(echo "$diff_output" | grep '^> ' | wc -l)
				echo -e "  ${RED}MISMATCH${NC}: ref=${ref_count} podman=${podman_count} (only-in-ref=${only_ref}, only-in-podman=${only_podman})"
				echo -e "  Display names: ${has_display}/${total_ops} (${pct}%)"

				# Show first few diffs
				echo "  First differences:"
				echo "$diff_output" | head -10 | sed 's/^/    /'

				# Save full diff for review
				echo "$diff_output" > "$TEST_DIR/${cat}-diff-v${ver}.txt"
				echo "  Full diff: $TEST_DIR/${cat}-diff-v${ver}.txt"

				_fail=$((_fail + 1))
				summary_lines+=("FAIL  ${label}  ref=${ref_count} podman=${podman_count}  only-ref=${only_ref} only-podman=${only_podman}")
			fi
		else
			# No reference -- just validate format
			echo -e "  ${YELLOW}NO-REF${NC}: ${total_ops} operators extracted (no oc-mirror ref to compare)"
			echo -e "  Display names: ${has_display}/${total_ops} (${pct}%)"
			_skip=$((_skip + 1))
			summary_lines+=("SKIP  ${label}  ops=${total_ops}  display=${has_display}/${total_ops} (${pct}%)  (no ref)")
		fi

		echo ""
	done
done

# Restore original index files from backup
echo -e "${CYAN}--- Restoring original index files ---${NC}"
for f in "$BACKUP_DIR"/*-index-v*; do
	[ -f "$f" ] || continue
	base=$(basename "$f")
	cp "$f" "$REF_DIR/$base"
done
echo "  Done."
echo ""

echo -e "${CYAN}=== Summary ===${NC}"
echo ""
for line in "${summary_lines[@]}"; do
	if [[ "$line" == PASS* ]]; then
		echo -e "  ${GREEN}${line}${NC}"
	elif [[ "$line" == FAIL* ]]; then
		echo -e "  ${RED}${line}${NC}"
	else
		echo -e "  ${YELLOW}${line}${NC}"
	fi
done

echo ""
echo -e "  Total: ${_total} tested -- ${GREEN}${_pass} passed${NC}, ${RED}${_fail} failed${NC}, ${YELLOW}${_skip} skipped${NC}"
echo ""

[ "$_fail" -gt 0 ] && exit 1
exit 0
