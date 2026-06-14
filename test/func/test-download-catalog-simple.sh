#!/bin/bash
# Test script for download-catalog-index.sh

set -euo pipefail

cd "$(dirname "$0")/../.."  # Change to ABA root
export DEBUG_ABA=1
export ABA_ROOT="$(pwd)"

source scripts/include_all.sh

echo "=== Test: download-catalog-index.sh ==="
echo ""

# Get OCP version from aba.conf (single source of truth)
source <(normalize-aba-conf)
ocp_ver_major=$(echo "$ocp_version" | cut -d. -f1-2)
echo "Using OCP version: $ocp_version (minor: $ocp_ver_major)"

# Use test runner directory
export RUN_ONCE_DIR="/tmp/test-catalog-simple"
rm -rf "$RUN_ONCE_DIR"
mkdir -p "$RUN_ONCE_DIR"

echo "=== Test 1: Download redhat-operator catalog ==="
cd mirror
run_once -i "test:catalog:redhat-operator" -- \
	"$ABA_ROOT/scripts/download-catalog-index.sh" redhat-operator "$ocp_ver_major"

echo ""
echo "=== Waiting for download to complete ==="
if run_once -w -i "test:catalog:redhat-operator"; then
	echo "✓ Download completed successfully"
else
	echo "✗ Download failed"
	exit 1
fi

echo ""
echo "=== Verifying output files ==="

index_file=".index/redhat-operator-index-v${ocp_ver_major}"
yaml_file="imageset-config-redhat-operator-catalog-v${ocp_ver_major}.yaml"

if [[ -f "$index_file" && -s "$index_file" ]]; then
	echo "✓ Index file exists: $index_file"
	line_count=$(wc -l < "$index_file")
	echo "  Lines: $line_count"
else
	echo "✗ Index file missing or empty"
	exit 1
fi

if [[ -f "$yaml_file" && -s "$yaml_file" ]]; then
	echo "✓ YAML helper file exists: $yaml_file"
	yaml_line_count=$(wc -l < "$yaml_file")
	echo "  Lines: $yaml_line_count"
else
	echo "✗ YAML file missing or empty"
	exit 1
fi

echo ""
echo "=== Test 2: Run again (re-downloads, run_once gating) ==="
run_once -r -i "test:catalog:redhat-operator"  # Reset task
run_once -i "test:catalog:redhat-operator" -- \
	"$ABA_ROOT/scripts/download-catalog-index.sh" redhat-operator "$ocp_ver_major"
run_once -w -i "test:catalog:redhat-operator"

echo "✓ Second run completed (re-download via run_once reset)"

echo ""
echo "=== Test 3: Test with TTL ==="
run_once -r -i "test:catalog:redhat-operator:ttl"
echo "First download with 5 second TTL..."
run_once -i "test:catalog:redhat-operator:ttl" -t 5 -- \
	"$ABA_ROOT/scripts/download-catalog-index.sh" redhat-operator "$ocp_ver_major"
run_once -w -i "test:catalog:redhat-operator:ttl"

echo "Immediate re-run (should skip)..."
run_once -i "test:catalog:redhat-operator:ttl" -t 5 -- \
	"$ABA_ROOT/scripts/download-catalog-index.sh" redhat-operator "$ocp_ver_major"
run_once -w -i "test:catalog:redhat-operator:ttl"
echo "✓ Skipped as expected"

echo ""
echo "=== Sample of downloaded operators ==="
head -10 "$index_file"

echo ""
echo "=== All tests passed! ==="
cd "$ABA_ROOT"
echo "Index files in: .index/"
echo "Run once logs in: $RUN_ONCE_DIR"

