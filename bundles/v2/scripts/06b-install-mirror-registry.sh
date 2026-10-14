#!/bin/bash -e
# Phase 06b: Configure aba, install mirror registry

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

echo_step "Install mirror registry ..."

# If a previous run left any registry (Quay, Docker, or OMR), clean it up first
if podman ps -a --format '{{.Names}}' | grep -qE 'quay-app|quay-redis|quay-postgres|^registry(-[0-9]+)?$|^systemd-quay$'; then
	echo_step "Found existing registry from a previous run, uninstalling first ..."
	aba -d mirror uninstall -y || true
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
curl -sk "https://$TEST_HOST:8443/v2/" >/dev/null || { echo "ERROR: Registry at $TEST_HOST:8443 is not responding after install!"; exit 1; }

echo "Registry installed: ok" > "$WORK_BUNDLE_DIR_BUILD/tests-06b.txt"
