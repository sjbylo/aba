#!/bin/bash
# Test script for catalog helper functions

set -euo pipefail

cd "$(dirname "$0")/../.."  # Change to ABA root
export DEBUG_ABA=1
export ABA_ROOT="$(pwd)"

source scripts/include_all.sh

echo "=== Test: Catalog Helper Functions ==="
echo ""

# Clean up
export RUN_ONCE_DIR="/tmp/test-catalog-helpers"
rm -rf "$RUN_ONCE_DIR"
mkdir -p "$RUN_ONCE_DIR"

# Get OCP version from aba.conf
source <(normalize-aba-conf)
ocp_ver_major=$(echo "$ocp_version" | cut -d. -f1-2)

echo "=== Test 1: download_all_catalogs function ==="
echo "OCP Version: $ocp_ver_major"
echo ""

# Start downloads with 5-second TTL for testing
cd mirror
download_all_catalogs "$ocp_ver_major" 5

echo ""
echo "=== Test 2: wait_for_all_catalogs function ==="
if wait_for_all_catalogs "$ocp_ver_major"; then
	echo "✓ All 3 catalogs downloaded successfully"
else
	echo "✗ Catalog download failed"
	exit 1
fi

echo ""
echo "=== Test 3: Verify all 3 catalogs started ==="
for catalog in redhat-operator certified-operator community-operator; do
	if [[ -f "$RUN_ONCE_DIR/catalog:${ocp_ver_major}:${catalog}.exit" ]]; then
		echo "✓ $catalog task completed"
	else
		echo "⚠ $catalog task not found"
	fi
done

echo ""
echo "=== Test 4: Re-run (should skip within TTL) ==="
download_all_catalogs "$ocp_ver_major" 5
wait_for_all_catalogs "$ocp_ver_major"
echo "✓ Re-run completed (tasks should have been skipped)"

echo ""
echo "=== Test 5: Verify index files exist ==="
for catalog in redhat-operator certified-operator community-operator; do
	index_file=".index/${catalog}-index-v${ocp_ver_major}"
	if [[ -f "$index_file" && -s "$index_file" ]]; then
		lines=$(wc -l < "$index_file")
		echo "✓ $catalog: $lines lines"
	else
		echo "✗ $catalog index missing"
		exit 1
	fi
done

echo ""
echo "=== All tests passed! ==="
cd "$ABA_ROOT"
echo "Logs in: $RUN_ONCE_DIR"

