#!/bin/bash -e
# Phase 00: Setup - go online, verify connectivity, check prerequisites

set -x

source "$(cd "$(dirname "$0")/.." && pwd)/common.sh"

mkdir -p ~/tmp
rpm -q podman || sudo dnf install podman -y
hash -r

# Go online and verify connectivity
int_up
~/bin/intcheck.sh | grep UP
echo_step "Test internet connection with curl google.com ..."
curl -sfkIL google.com >/dev/null

# Check if bundle already exists and is complete in CLOUD_DIR
if [ -d "$CLOUD_DIR_BUNDLE" ] && [ ! -f "$CLOUD_DIR_BUNDLE/$BUNDLE_UPLOADING" ]; then
	echo "Install bundle dir already exists: $CLOUD_DIR_BUNDLE" >&2
	# Touch all markers so Make sees everything as complete
	for m in setup install-aba configure image-save bundle-tar offline unpacked registry-installed registry-loaded tests-passed upload; do
		touch "$WORK_BUNDLE_DIR_BUILD/.done-$m"
	done
	exit 0
fi

[ "$NOTIFY" ] && echo "Working on bundle: $BUNDLE_NAME ..." | notify.sh

# Remove stale work dirs from previous/different bundles
for d in "$WORK_DIR"/*/; do
	[ ! -d "$d" ] && continue
	dir_name=$(basename "$d")
	case "$dir_name" in
		"$BUNDLE_NAME" | "test-install-$BUNDLE_NAME" | aba)
			;;
		*)
			echo "Removing stale work dir: $d"
			rm -rf "$d"
			;;
	esac
done

# Clean any leftover registry from a previous failed run
if podman ps | grep -q registry; then
	echo_step "Found running registry from previous run, cleaning up ..."
	if [ -d "$WORK_TEST_INSTALL/aba" ]; then
		(
			cd "$WORK_TEST_INSTALL/aba"
			./install
			aba -d mirror uninstall -y
		)
	else
		echo "ERROR: Running registry found but no aba installation to uninstall it." >&2
		echo "       Please run 'aba -d mirror uninstall -y' from an aba directory first." >&2
		exit 1
	fi
	sudo rm -rf ~/quay-install
	sudo rm -rf ~/docker-reg
fi

# Safety net: remove orphaned quay-* services that 'aba uninstall' missed
cleanup_orphaned_quay_services

# Verify cloud dir is available
[ ! -d "$CLOUD_DIR" ] && echo "Dir $CLOUD_DIR not available!  Set up a directory that syncs with a cloud drive, e.g. gdrive" && exit 1

echo_step "Processing: $CLOUD_DIR_BUNDLE"
mypause 2

# If the cloud dir exists but is incomplete, remove it
if [ -d "$CLOUD_DIR_BUNDLE" ]; then
	rm -rf "$CLOUD_DIR_BUNDLE"
fi

# Create work directories
mkdir -p "$WORK_DIR" "$WORK_BUNDLE_DIR" "$WORK_BUNDLE_DIR_BUILD"

# Convenience symlink so user can: tail -f bundles/v2/build.log
ln -sf "$LOGFILE" "$V2_DIR/build.log"
