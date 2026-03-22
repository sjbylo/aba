#!/bin/bash -e
# Phase 06b: Configure aba, install Quay mirror registry

set -x

source "$(cd "$(dirname "$0")/.." && pwd)/common.sh"

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

# Pasta needs a default route to handle hairpin connections (host to own IP).
# Without it, the ansible health check (which curls the hostname from the host
# itself) gets "Connection reset by peer" even though external clients work fine.
# Add a temp route via the internal gateway -- it can't reach the internet, but
# pasta only needs it present when the pod is created.
echo_step "Adding temporary default route for pasta hairpin ..."
local_iface=$(ip route get $GATEWAY_IP | grep -oP 'dev \K\S+')
sudo ip route add default via $GATEWAY_IP dev $local_iface

aba -d mirror install -H $TEST_HOST

echo_step "Removing temporary default route ..."
sudo ip route del default via $GATEWAY_IP dev $local_iface

# Verify registry is actually working after install
echo_step "Verifying registry is accessible ..."
podman ps | grep -q "quay-app" || { echo "ERROR: Quay is not running after install!"; exit 1; }
curl -sk "https://$TEST_HOST:8443/v2/" >/dev/null || { echo "ERROR: Registry at $TEST_HOST:8443 is not responding!"; exit 1; }

echo "Quay installed: ok" > "$WORK_BUNDLE_DIR_BUILD/tests-06b.txt"
