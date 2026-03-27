#!/bin/bash -e
# Phase 06c: Load images into the mirror registry

set -x

source "$(cd "$(dirname "$0")/.." && pwd)/common.sh"

cd "$WORK_TEST_INSTALL/aba"

echo_step "Load images into Quay ..."

# On re-run after a failed load, Quay may have crashed. Verify it's up first.
if ! curl -sk "https://$TEST_HOST:8443/v2/" >/dev/null; then
	echo_step "Quay is not responding -- restarting the pod ..."
	systemctl --user restart quay-pod.service
	sleep 10
	systemctl --user restart quay-redis.service
	sleep 3
	systemctl --user restart quay-app.service
	sleep 30
	curl -sk "https://$TEST_HOST:8443/v2/" >/dev/null || { echo "ERROR: Quay still not responding after restart!"; exit 1; }
	echo_step "Quay recovered after pod restart."
fi

aba -d mirror load --retry 5 -H $TEST_HOST

# Verify registry is still healthy after load
echo_step "Verifying registry is accessible after load ..."
podman ps | grep -q "quay-app" || { echo "ERROR: Quay is not running after load!"; exit 1; }
curl -sk "https://$TEST_HOST:8443/v2/" >/dev/null || { echo "ERROR: Registry at $TEST_HOST:8443 is not responding!"; exit 1; }

# Verify all CLI files can install and are executable
scripts/cli-install-all.sh --wait
for cmd in butane govc kubectl oc oc-mirror openshift-install
do
	~/bin/$cmd version >/dev/null 2>&1 || ~/bin/$cmd --help >/dev/null 2>&1 || { echo "~/bin/$cmd cannot execute!"; exit 1; }
done

echo "All images loaded (disk2mirror) into Quay: ok" > "$WORK_BUNDLE_DIR_BUILD/tests-06c.txt"
