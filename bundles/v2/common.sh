#!/bin/bash
# Common variables and functions for v2 bundle pipeline
# Sourced by all phase scripts

V2_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$V2_DIR/../.." && pwd)"

source "$V2_DIR/bundle.conf"
source "$REPO_ROOT/test/lib.sh"

# Ensure ~/bin is in PATH (cron doesn't expand $HOME in its PATH= line)
PATH="$HOME/bin:$PATH"

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
LOGFILE="$WORK_DIR/bundle-build.log"

export ABA_TESTING=1
export PLAIN_OUTPUT=1

# Per-step log: fresh on each run (overwrite). Global log: append for tail -f monitoring.
STEP_NAME=$(basename "$0" .sh)
STEP_LOG="$WORK_BUNDLE_DIR_BUILD/log-${STEP_NAME}.log"
mkdir -p "$WORK_BUNDLE_DIR_BUILD"
exec > >(tee "$STEP_LOG" | tee -a "$LOGFILE") 2>&1

if [[ "$STEP_NAME" == 00-* ]]; then
	cat <<BANNER
================================================================================
  BUNDLE BUILD: $BUNDLE_NAME
  OCP Version:  $VER
  Bundle Type:  $NAME
  Operators:    ${OP_SETS:-none (release)}
  Arch:         $(uname -m)
  Host:         $(hostname -f)
  Started:      $(date)
  Work Dir:     $WORK_BUNDLE_DIR
  Cloud Dir:    $CLOUD_DIR_BUNDLE
  Step Log:     $STEP_LOG
  Build Log:    $LOGFILE
================================================================================
BANNER
else
	echo "================ Step: $STEP_NAME | $BUNDLE_NAME | $(date) ================"
fi

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

# Fetch RHOAI additional images and add to images.conf.
# Tries GitHub first; falls back to shipped static file.
# Usage: fetch_rhoai_images <rhoai-version>  (e.g. "3.5")
fetch_rhoai_images() {
	local rhoai_ver="$1"
	local github_url="https://raw.githubusercontent.com/red-hat-data-services/rhoai-disconnected-install-helper/main/rhoai-${rhoai_ver}-imagesetconfig.yaml"
	local static_file="$V2_DIR/data/rhoai-images-${rhoai_ver}.txt"
	local tmp_images
	tmp_images=$(mktemp)

	echo "Fetching RHOAI ${rhoai_ver} additional images ..."

	# Try GitHub first
	if curl -fsSL --retry 3 --max-time 30 "$github_url" 2>/dev/null | \
	   grep '^\s*- name:' | awk '{print $3}' | \
	   grep -E '^(quay\.io|registry\.redhat\.io)/' | sort -u > "$tmp_images" && \
	   [ -s "$tmp_images" ]; then
		echo "Fetched $(wc -l < "$tmp_images") RHOAI images from GitHub"
	elif [ -f "$static_file" ]; then
		# Fall back to shipped static list
		echo "GitHub fetch failed — using shipped static list: $static_file"
		grep -v '^#' "$static_file" | grep -v '^$' > "$tmp_images"
	else
		echo "WARNING: No RHOAI image list available for version $rhoai_ver" >&2
		rm -f "$tmp_images"
		return 1
	fi

	# Add images via aba image add
	local _imgs=()
	while IFS= read -r _img; do
		[ -n "$_img" ] && _imgs+=("$_img")
	done < "$tmp_images"
	rm -f "$tmp_images"

	if [ ${#_imgs[@]} -gt 0 ]; then
		echo "Adding ${#_imgs[@]} RHOAI companion images ..."
		aba image add "${_imgs[@]}"
	fi
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
