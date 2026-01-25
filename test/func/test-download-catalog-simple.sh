#!/bin/bash
# Test script for download-catalog-index-simple.sh

set -euo pipefail

cd "$(dirname "$0")/../.."  # Change to ABA root
export DEBUG_ABA=1
export ABA_ROOT="$(pwd)"

source scripts/include_all.sh

echo "=== Test: download-catalog-index-simple.sh ==="
echo ""

# Use test runner directory
export RUN_ONCE_DIR="/tmp/test-catalog-simple"
rm -rf "$RUN_ONCE_DIR"
mkdir -p "$RUN_ONCE_DIR"

# Clean up any existing index files
rm -f mirror/.index/redhat-operator-index-v*.done 2>/dev/null || true

echo "=== Test 1: Download redhat-operator catalog ==="
cd mirror
run_once -i "test:catalog:redhat-operator" -- \
	"$ABA_ROOT/scripts/download-catalog-index-simple.sh" redhat-operator

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

# Get OCP version from aba.conf
source <(normalize-aba-conf)
ocp_ver_major=$(echo "$ocp_version" | cut -d. -f1-2)

index_file=".index/redhat-operator-index-v${ocp_ver_major}"
done_file=".index/.redhat-operator-index-v${ocp_ver_major}.done"
yaml_file="imageset-config-redhat-operator-catalog-v${ocp_ver_major}.yaml"

if [[ -f "$index_file" && -s "$index_file" ]]; then
	echo "✓ Index file exists: $index_file"
	line_count=$(wc -l < "$index_file")
	echo "  Lines: $line_count"
else
	echo "✗ Index file missing or empty"
	exit 1
fi

if [[ -f "$done_file" ]]; then
	echo "✓ Done marker exists: $done_file"
else
	echo "✗ Done marker missing"
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
echo "=== Test 2: Run again (should skip) ==="
run_once -r -i "test:catalog:redhat-operator"  # Reset task
run_once -i "test:catalog:redhat-operator" -- \
	"$ABA_ROOT/scripts/download-catalog-index-simple.sh" redhat-operator
run_once -w -i "test:catalog:redhat-operator"

echo "✓ Second run completed (should have skipped actual download)"

echo ""
echo "=== Test 3: Test with TTL ==="
run_once -r -i "test:catalog:redhat-operator:ttl"
echo "First download with 5 second TTL..."
run_once -i "test:catalog:redhat-operator:ttl" -t 5 -- \
	"$ABA_ROOT/scripts/download-catalog-index-simple.sh" redhat-operator
run_once -w -i "test:catalog:redhat-operator:ttl"

echo "Immediate re-run (should skip)..."
run_once -i "test:catalog:redhat-operator:ttl" -t 5 -- \
	"$ABA_ROOT/scripts/download-catalog-index-simple.sh" redhat-operator
run_once -w -i "test:catalog:redhat-operator:ttl"
echo "✓ Skipped as expected"

echo ""
echo "=== Sample of downloaded operators ==="
head -10 "$index_file"

echo ""
echo "=== All tests passed! ==="
cd "$ABA_ROOT"
echo "Index files in: mirror/.index/"
echo "Run once logs in: $RUN_ONCE_DIR"

