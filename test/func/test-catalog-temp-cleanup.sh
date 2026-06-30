#!/bin/bash
# Test: catalog extraction temp dir cleanup and image caching
#
# Verifies:
#   1. Temp dirs use hidden .aba-* prefix (identifiable for sweep)
#   2. Temp dirs are cleaned up after normal run
#   3. Stale .aba-* dirs (>24h) are swept at startup
#   4. Catalog image remains cached in podman after extraction (no rmi)
#   5. No aba-catalog-* containers leak after extraction

set -euo pipefail

cd "$(dirname "$0")/../.."

source scripts/include_all.sh
source <(normalize-aba-conf)

ocp_ver_major=$(echo "$ocp_version" | cut -d. -f1-2)
catalog="redhat-operator"

echo "=== Test: catalog temp dir cleanup and image caching ==="
echo "OCP version: $ocp_ver_major"
echo ""

# ── Test 1: temp dir is cleaned up after normal run ──────────────────
echo "=== Test 1: No .aba-catalog-* temp dirs left after extraction ==="

# Count before
before=$(find /tmp -maxdepth 1 -name '.aba-catalog-*' -user "$(id -un)" 2>/dev/null | wc -l)

scripts/download-catalog-index.sh "$catalog" "$ocp_ver_major"

after=$(find /tmp -maxdepth 1 -name '.aba-catalog-*' -user "$(id -un)" 2>/dev/null | wc -l)

if [ "$after" -le "$before" ]; then
	echo "✓ No temp dirs leaked (before=$before, after=$after)"
else
	echo "✗ Temp dirs leaked! (before=$before, after=$after)"
	find /tmp -maxdepth 1 -name '.aba-catalog-*' -user "$(id -un)" -ls
	exit 1
fi
echo ""

# ── Test 2: catalog image remains cached (no podman rmi) ─────────────
echo "=== Test 2: Catalog image cached in podman graph storage ==="

catalog_url="registry.redhat.io/redhat/${catalog}-index:v${ocp_ver_major}"
if podman image exists "$catalog_url" 2>/dev/null; then
	echo "✓ Image cached: $catalog_url"
else
	echo "✗ Image was removed! Expected it to remain cached: $catalog_url"
	exit 1
fi
echo ""

# ── Test 3: no aba-catalog-* containers left ─────────────────────────
echo "=== Test 3: No leaked aba-catalog-* containers ==="

leaked=$(podman ps -a --format '{{.Names}}' | grep -c '^aba-catalog-' || true)
if [ "$leaked" -eq 0 ]; then
	echo "✓ No leaked containers"
else
	echo "✗ Found $leaked leaked container(s):"
	podman ps -a --format '{{.Names}}' | grep '^aba-catalog-'
	exit 1
fi
echo ""

# ── Test 4: stale dirs are swept at startup ──────────────────────────
echo "=== Test 4: Stale temp dirs swept at startup ==="

# Plant a fake stale dir with old timestamp (>24h)
stale_dir="$ABA_TMP/catalog-STALETEST"
mkdir -p "$stale_dir"
touch -d "2 days ago" "$stale_dir"

if [ ! -d "$stale_dir" ]; then
	echo "✗ Failed to create test stale dir"
	exit 1
fi
echo "  Planted stale dir: $stale_dir (mtime=$(stat -c %y "$stale_dir"))"

# Run extraction -- sweep happens at startup
scripts/download-catalog-index.sh "$catalog" "$ocp_ver_major"

if [ -d "$stale_dir" ]; then
	echo "✗ Stale dir was NOT swept: $stale_dir"
	rm -rf "$stale_dir"
	exit 1
else
	echo "✓ Stale dir swept successfully"
fi
echo ""

# ── Test 5: fresh dirs are NOT swept ─────────────────────────────────
echo "=== Test 5: Fresh temp dirs are NOT swept ==="

fresh_dir="$ABA_TMP/catalog-FRESHTEST"
mkdir -p "$fresh_dir"

scripts/download-catalog-index.sh "$catalog" "$ocp_ver_major"

if [ -d "$fresh_dir" ]; then
	echo "✓ Fresh dir preserved (not swept)"
	rm -rf "$fresh_dir"
else
	echo "✗ Fresh dir was incorrectly swept!"
	exit 1
fi
echo ""

echo "=== All catalog temp cleanup tests passed! ==="
