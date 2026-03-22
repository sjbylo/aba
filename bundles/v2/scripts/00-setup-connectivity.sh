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
	for m in 00-setup 01-install-aba 02-configure 03-image-save 04-bundle-tar 05-offline 06a-unpacked 06b-registry-installed 06c-registry-loaded 06d-tests-passed 07-upload; do
		touch "$WORK_BUNDLE_DIR_BUILD/.done-$m"
	done
	exit 0
fi

[ "$NOTIFY" ] && echo "Working on bundle: $BUNDLE_NAME ..." | notify.sh

# Detect stale work dirs from previous/different bundles
stale_dirs=()
for d in "$WORK_DIR"/*/; do
	[ ! -d "$d" ] && continue
	dir_name=$(basename "$d")
	case "$dir_name" in
		"$BUNDLE_NAME" | "test-install-$BUNDLE_NAME" | aba)
			;;
		*)
			stale_dirs+=("$d")
			;;
	esac
done

has_running_registry=
podman ps 2>/dev/null | grep -q registry && has_running_registry=1

if [ ${#stale_dirs[@]} -gt 0 ] || [ "$has_running_registry" ]; then
	set +x
	echo
	echo "=========================================================="
	echo "  Stale state detected from a previous/different bundle!"
	echo "=========================================================="
	if [ ${#stale_dirs[@]} -gt 0 ]; then
		echo "  Stale work dirs:"
		for d in "${stale_dirs[@]}"; do echo "    - $d"; done
	fi
	[ "$has_running_registry" ] && echo "  Running Quay registry detected (will be uninstalled first)"
	echo

	if [ "$BATCH" ]; then
		echo "  BATCH mode: auto-cleaning stale state ..."
		cleanup_answer=y
	else
		echo -n "  Clean up and continue? [y/N]: "
		read -t 60 cleanup_answer || true
	fi
	set -x

	if [[ "$cleanup_answer" =~ ^[yY] ]]; then
		# Uninstall running registry first (needs aba from the OLD test-install dir)
		if [ "$has_running_registry" ]; then
			echo_step "Uninstalling running registry from previous run ..."
			aba_dir=$(ls -d "$WORK_DIR"/test-install*/aba 2>/dev/null | head -1)
			if [ "$aba_dir" ]; then
				( cd "$aba_dir"; ./install; aba -d mirror uninstall -y )
			else
				echo "WARNING: No aba installation found to uninstall registry." >&2
				echo "         Attempting direct podman cleanup ..." >&2
				podman pod stop quay-pod 2>/dev/null || true
				podman pod rm quay-pod 2>/dev/null || true
			fi
			sudo rm -rf ~/quay-install
			sudo rm -rf ~/docker-reg
		fi

		# Now remove stale work dirs
		for d in "${stale_dirs[@]}"; do
			echo "Removing stale work dir: $d"
			rm -rf "$d"
		done
	else
		echo "Aborted. Please clean up manually before re-running:" >&2
		if [ "$has_running_registry" ]; then
			aba_dir=$(ls -d "$WORK_DIR"/test-install*/aba 2>/dev/null | head -1)
			if [ "$aba_dir" ]; then
				echo "  - cd $aba_dir && aba -d mirror uninstall -y" >&2
			else
				echo "  - podman pod stop quay-pod && podman pod rm quay-pod" >&2
				echo "  - sudo rm -rf ~/quay-install ~/docker-reg" >&2
			fi
		fi
		for d in "${stale_dirs[@]}"; do echo "  - rm -rf $d" >&2; done
		exit 1
	fi
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
