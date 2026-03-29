#!/bin/bash -e
# Phase 08: Cleanup - uninstall Quay, go online, clean work dirs

set -x

source "$(cd "$(dirname "$0")/.." && pwd)/common.sh"

echo_step "Remove Quay ..."

# Uninstall Quay first (most likely step to fail)
if [ -d "$WORK_TEST_INSTALL/aba" ]; then
	cd "$WORK_TEST_INSTALL/aba"
	./install
	aba --noask
	aba -d mirror uninstall -y
fi

# Verify mirror data dirs were properly removed by 'aba uninstall'.
# If they persist, that's a bug -- do NOT brute-force rm -rf them.
for _mdir in ~/quay-install ~/docker-reg; do
	if [ -d "$_mdir" ]; then
		echo "WARNING: $_mdir still exists after 'aba -d mirror uninstall'." >&2
		echo "         This is a bug in aba uninstall. Investigate before re-running." >&2
	fi
done

# Safety net: remove orphaned quay-* services that 'aba uninstall' missed
cleanup_orphaned_quay_services

# Go online
int_up
~/bin/intcheck.sh | grep UP

echo_step "Test internet connection with curl google.com ..."
curl -sfkIL google.com >/dev/null

[ "$NOTIFY" ] && notify.sh "New bundle created for $BUNDLE_NAME"

echo_step "Reset ..."

rm -f "$V2_DIR/build.log"
rm -rf "$WORK_DIR/aba"
rm -rf "$WORK_BUNDLE_DIR"
rm -rf "$WORK_TEST_INSTALL"

echo_step "Done $0"
