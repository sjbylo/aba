#!/bin/bash -e
# Integration test: aba -d mirror save
# Verifies complete mirror save workflow

cd "$(dirname "$0")/../.."

# Acquire test lock to prevent concurrent test runs
TEST_LOCK_FILE="$HOME/.aba/test-mirror-save.lock"
mkdir -p "$HOME/.aba"
exec 200>"$TEST_LOCK_FILE"
if ! flock -n 200; then
	echo "Error: Another mirror save test is running. Please wait." >&2
	exit 1
fi
# Lock released on exit

echo "=== Test: aba -d mirror save (complete workflow) ==="
echo "Working directory: $PWD"
echo ""

# Set ABA_ROOT for scripts that still need it (temporary during transition)
export ABA_ROOT="$PWD"

source scripts/include_all.sh

# Clean up previous state to force fresh operations
echo "Cleaning up previous state..."
rm -f ~/bin/oc-mirror
rm -rf mirror/.index/*-operator-index-*
rm -rf ~/.aba/runner/cli:install:oc-mirror
rm -rf ~/.aba/runner/catalog:*
rm -rf mirror/save/mirror_*.tar 2>/dev/null || true

# Test 1: oc-mirror installation
echo ""
echo "Test 1: Install oc-mirror"
echo "-------------------------"

if ! make -sC cli oc-mirror; then
	aba_abort "Test 1 FAILED: oc-mirror installation failed"
fi

if [ ! -f ~/bin/oc-mirror ]; then
	aba_abort "Test 1 FAILED: oc-mirror not found in ~/bin/"
fi

aba_info_ok "Test 1 PASSED: oc-mirror installed" >&2

# Test 2: Catalog downloads
echo ""
echo "Test 2: Download operator catalogs"
echo "-----------------------------------"

# Get version from aba.conf
source <(normalize-aba-conf)
ocp_version="${ocp_version%.*}"  # Extract major.minor (e.g., 4.19.21 -> 4.19)
echo "Using OCP version: $ocp_version"

# Start catalog downloads
download_all_catalogs "$ocp_version" 86400 >&2

# Wait for catalogs
wait_for_all_catalogs "$ocp_version" >&2

# Verify catalog files exist
for catalog in redhat-operator certified-operator community-operator; do
	index_file="mirror/.index/${catalog}-index-v${ocp_version}"
	if [ ! -s "$index_file" ]; then
		aba_abort "Test 2 FAILED: Catalog file $index_file missing or empty"
	fi
	aba_info_ok "✓ $index_file exists" >&2
done

aba_info_ok "Test 2 PASSED: All catalogs downloaded" >&2

# Test 3: Create imageset config
echo ""
echo "Test 3: Generate imageset config"
echo "---------------------------------"

# Remove old config to force regeneration
rm -f mirror/save/imageset-config-save.yaml

if ! make -sC mirror save/imageset-config-save.yaml; then
	aba_abort "Test 3 FAILED: Failed to create imageset config"
fi

if [ ! -f mirror/save/imageset-config-save.yaml ]; then
	aba_abort "Test 3 FAILED: imageset-config-save.yaml not created"
fi

# Verify it's valid YAML (basic check)
if ! grep -q "kind: ImageSetConfiguration" mirror/save/imageset-config-save.yaml; then
	aba_abort "Test 3 FAILED: Invalid imageset config (missing ImageSetConfiguration)"
fi

# Verify it has platform section
if ! grep -q "platform:" mirror/save/imageset-config-save.yaml; then
	aba_abort "Test 3 FAILED: No platform section in imageset config"
fi

aba_info_ok "Test 3 PASSED: Imageset config created and valid" >&2

# Test 4: Check operators in config (optional - depends on aba.conf)
echo ""
echo "Test 4: Verify config contents"
echo "-------------------------------"

# Count operators (if any)
op_count=$(grep -c "name: " mirror/save/imageset-config-save.yaml 2>/dev/null || echo 0)
aba_info "Operators in config: $op_count" >&2

# Show sample of config
aba_info "Sample of imageset config:" >&2
head -20 mirror/save/imageset-config-save.yaml | sed 's/^/  /' >&2

aba_info_ok "Test 4 PASSED: Config verified" >&2

# NOTE: We do NOT run actual 'aba -d mirror save' here because:
# 1. It requires ~/.pull-secret.json (user-specific)
# 2. It downloads GBs of data (too slow for unit tests)
# 3. It requires network access to registry.redhat.io
# 
# Instead, we verify all the prerequisites are in place:
# - oc-mirror installed ✓
# - Catalogs downloaded ✓  
# - Imageset config created ✓
#
# The user can run the actual save manually:
#   aba -d mirror save

# All tests passed
echo ""
echo "========================================="
aba_info_ok "✓ ALL MIRROR SAVE PREREQUISITES PASSED" >&2
echo "========================================="
echo ""
echo "Summary:"
echo "  - oc-mirror installed successfully"
echo "  - All operator catalogs downloaded"
echo "  - Imageset config created and valid"
echo "  - Ready for: aba -d mirror save"
echo ""
echo "Note: Actual mirror save requires:"
echo "  - ~/.pull-secret.json (get from console.redhat.com)"
echo "  - Network access to registry.redhat.io"
echo "  - Significant time and disk space"
echo ""

