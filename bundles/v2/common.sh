#!/bin/bash
# Common variables and functions for v2 bundle pipeline
# Sourced by all phase scripts

V2_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$V2_DIR/../.." && pwd)"

source "$V2_DIR/bundle.conf"
source "$REPO_ROOT/test/lib.sh"

# VER and NAME must be set in the environment (passed by Makefile)
[ -z "$VER" ] && echo "ERROR: VER not set" >&2 && exit 1
[ -z "$NAME" ] && echo "ERROR: NAME not set" >&2 && exit 1

# Derived variables
BUNDLE_NAME=${VER}-${NAME}
WORK_BUNDLE_DIR=$WORK_DIR/$BUNDLE_NAME
WORK_BUNDLE_DIR_BUILD=$WORK_DIR/$BUNDLE_NAME/build
WORK_TEST_INSTALL=$WORK_DIR/test-install-$BUNDLE_NAME
CLOUD_DIR_BUNDLE=$CLOUD_DIR/$BUNDLE_NAME
BUNDLE_UPLOADING=INSTALL-BUNDLE-UPLOADING-OR-INCOMPLETE.txt
WORK_TEST_LOG=$WORK_BUNDLE_DIR_BUILD/tests-completed.txt
LOGFILE="$WORK_BUNDLE_DIR_BUILD/bundle-build.log"

export ABA_TESTING=1
export PLAIN_OUTPUT=1

# Logging: append all output to the build log
mkdir -p "$WORK_BUNDLE_DIR_BUILD"
exec > >(tee -a "$LOGFILE") 2>&1

cat <<BANNER
================================================================================
  BUNDLE BUILD: $BUNDLE_NAME
  OCP Version:  $VER
  Bundle Type:  $NAME
  Operators:    ${OP_SETS:-none (release)}
  Host:         $(hostname -f)
  Started:      $(date)
  Work Dir:     $WORK_BUNDLE_DIR
  Cloud Dir:    $CLOUD_DIR_BUNDLE
  Log File:     $LOGFILE
================================================================================
BANNER

# Notification helper
which notify.sh &>/dev/null && NOTIFY=1 || NOTIFY=

uncomment_line() {
	local search="$1"
	local file="$2"
	sed -i "s|^[[:space:]]*#\(.*${search}.*\)|\1|" "$file"
}

echo_step() {
	set +x
	echo
	echo "##################################################################################################"
	echo "$@"
	echo "##################################################################################################"
	set -x
}

mypause() {
	[ "$BATCH" ] && return 0
	set +x
	echo "Pausing ${1} seconds ... Hit Enter to skip"
	read -t "$1" yn || true
	set -x
}

# Safety net ONLY -- call AFTER 'aba -d mirror uninstall'.
# Removes quay-* systemd user services left by older mirror-registry versions
# that the current uninstaller does not know about (e.g. quay-postgres).
# Will NOT run if quay-pod still exists -- forces proper aba uninstall first.
cleanup_orphaned_quay_services() {
	if podman pod exists quay-pod; then
		echo "WARNING: quay-pod still exists. Use 'aba -d mirror uninstall -y' first."
		return 0
	fi
	local svc changed=
	for svc in $(systemctl --user list-unit-files --no-legend 'quay-*' | awk '{print $1}'); do
		echo "Removing orphaned service: $svc"
		systemctl --user stop "$svc"
		systemctl --user disable "$svc"
		rm -f "$HOME/.config/systemd/user/$svc"
		changed=1
	done
	if [ "$changed" ]; then systemctl --user daemon-reload; fi
}
