#!/bin/bash -e
# Phase 06b: Configure aba, install Quay mirror registry

set -x

source "$(cd "$(dirname "$0")/.." && pwd)/common.sh"

# Ensure internet is down for disconnected testing. On re-runs, go.sh puts
# internet UP to fetch OCP versions, and Make skips step 05 (already done),
# so the internet would stay UP without this guard.
int_down

cd "$WORK_TEST_INSTALL/aba"

# Switch to the test platform
echo_step "Switch to platform = $CLUSTER_PLATFORM ..."
sed -i "s/platform=bm/platform=$CLUSTER_PLATFORM/g" aba.conf

./install
aba
aba --noask
aba --machine-network 10.0.0.0/20 --ntp $NTP_IP --gateway-ip 10.0.1.1

echo_step "Install Quay mirror registry ..."

# If a previous install attempt left a broken Quay, clean it up first
if podman ps | grep -q quay-app; then
	echo_step "Found existing Quay from a previous failed attempt, uninstalling first ..."
	aba -d mirror uninstall -y
	cleanup_orphaned_quay_services
fi

echo_step "Show podman ps output"
podman ps

echo "pwd=$PWD"

ls -lta mirror

echo -n "Pausing: "
read -t 60 yn || true

# Pasta hairpin route is now handled by int_down() in test/lib.sh
aba -d mirror install -H $TEST_HOST

# Verify registry is actually working after install
echo_step "Verifying registry is accessible ..."
podman ps | grep -q "quay-app" || { echo "ERROR: Quay is not running after install!"; exit 1; }
curl -sk "https://$TEST_HOST:8443/v2/" >/dev/null || { echo "ERROR: Registry at $TEST_HOST:8443 is not responding!"; exit 1; }

echo "Quay installed: ok" > "$WORK_BUNDLE_DIR_BUILD/tests-06b.txt"
