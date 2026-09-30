#!/bin/bash -e
# Phase 06c: Load images into the mirror registry

set -x

source "$(cd "$(dirname "$0")/.." && pwd)/common.sh"

# Ensure internet is down for disconnected testing. On re-runs, go.sh puts
# internet UP to fetch OCP versions, and Make skips step 05 (already done),
# so the internet would stay UP without this guard.
int_down

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

# ABA writes the real oc-mirror exit code to mirror/.oc-mirror-exit-code,
# bypassing make's exit-code masking (make always returns 2 for recipe failures).
#   oc-mirror bitmask: bit 2 = release, bit 4 = operator, bit 8 = additional, bit 16 = helm
# NOTE: The bundled ABA may be an older version (main) that doesn't produce
# this file.  Always handle "file missing" gracefully — see bundle.conf for
# the full branch architecture explanation.
load_rc=0
aba -d mirror load --retry 2 -H $TEST_HOST || load_rc=$?

if [ $load_rc -ne 0 ]; then
	# Read the real oc-mirror exit code from the file ABA writes.
	# Older ABA versions (e.g. in a pre-built bundle) may not produce this file.
	_real_rc=""
	_exit_file="$WORK_TEST_INSTALL/aba/mirror/.oc-mirror-exit-code"
	if [ -f "$_exit_file" ]; then
		_real_rc=$(cat "$_exit_file")
	fi

	# Release image failures (bit 2) or generic/unknown errors (1) are fatal.
	if [ -n "$_real_rc" ] && { [ $(( _real_rc & 2 )) -ne 0 ] || [ "$_real_rc" -eq 1 ]; }; then
		echo
		echo "ERROR: Image load failed (oc-mirror exit code $_real_rc, make exit code $load_rc). Aborting."

		for _errfile in "$WORK_TEST_INSTALL/aba/mirror/data/working-dir/logs"/mirroring_errors_*.txt; do
			if [ -f "$_errfile" ] && [ -s "$_errfile" ]; then
				echo
				echo "--- oc-mirror errors ($_errfile) ---"
				cat "$_errfile"
			fi
		done

		exit 1
	fi

	# Non-fatal: operator/additional image failures, or exit code unavailable.
	_rc_display="${_real_rc:-unavailable}"
	echo
	echo "##########################################################################"
	echo "WARNING: Image load completed with errors (oc-mirror exit code $_rc_display)."
	echo "         Some images may have failed to load into the registry."
	echo "         Possible causes: upstream image format issues, registry"
	echo "         compatibility, network timeouts, or transient errors."
	echo "         All images were saved successfully -- the bundle is complete."
	echo "         Running tests anyway to verify cluster functionality ..."
	echo "##########################################################################"

	for _errfile in "$WORK_TEST_INSTALL/aba/mirror/data/working-dir/logs"/mirroring_errors_*.txt; do
		if [ -f "$_errfile" ] && [ -s "$_errfile" ]; then
			echo
			echo "--- oc-mirror errors ($_errfile) ---"
			cat "$_errfile"
		fi
	done
	echo
fi

# Verify registry is still healthy after load
echo_step "Verifying registry is accessible after load ..."
podman ps | grep -q "quay-app" || { echo "ERROR: Quay is not running after load!"; exit 1; }
curl -sk "https://$TEST_HOST:8443/v2/" >/dev/null || { echo "ERROR: Registry at $TEST_HOST:8443 is not responding!"; exit 1; }

# Verify all CLI files can install and are executable
scripts/cli-install-all.sh --wait
for cmd in butane govc kubectl oc openshift-install
do
	~/bin/$cmd version >/dev/null || ~/bin/$cmd --help >/dev/null || { echo "~/bin/$cmd cannot execute!"; exit 1; }
done
oc-mirror --v2 --help > /dev/null

if [ $load_rc -ne 0 ]; then
	echo "Images loaded with warnings (oc-mirror exit ${_real_rc:-unavailable}) -- some images may have failed to load" > "$WORK_BUNDLE_DIR_BUILD/tests-06c.txt"
	echo "${_real_rc:-unknown}" > "$WORK_BUNDLE_DIR_BUILD/load-exit-code"
else
	echo "All images loaded (disk2mirror) into Quay: ok" > "$WORK_BUNDLE_DIR_BUILD/tests-06c.txt"
fi
