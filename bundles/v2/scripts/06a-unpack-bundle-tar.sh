#!/bin/bash -e
# Phase 06a: Unpack the bundle tar, then trickle-copy chunks to NAS in background

set -x

source "$(cd "$(dirname "$0")/.." && pwd)/common.sh"

# Ensure internet is down for disconnected testing. On re-runs, go.sh puts
# internet UP to fetch OCP versions, and Make skips step 05 (already done),
# so the internet would stay UP without this guard.
int_down

mkdir -p "$WORK_TEST_INSTALL"
cd "$WORK_TEST_INSTALL"

rm -rf aba

ls -l "$WORK_BUNDLE_DIR"/ocp_*

echo_step "Unpack the install bundle ..."

cat "$WORK_BUNDLE_DIR"/ocp_* | tar xvf -

# Uninstall old version of aba if present
if which aba; then sudo rm -fv "$(which aba)"; fi

cd aba
./install

# --- Background trickle-copy: move tar chunks to NAS while pipeline continues ---
# Each chunk is read once via tee (cksum + NAS copy in parallel), then deleted
# to free local disk space incrementally.  Step 07 is the safety net: if this
# background process dies, step 07 finishes the job for any remaining chunks.
echo_step "Starting background trickle-copy of tar chunks to NAS ..."
(
	set -o pipefail
	mkdir -p "$NAS_TEMP_DIR/$BUNDLE_NAME"
	cd "$WORK_BUNDLE_DIR"
	for f in ocp_*; do
		until < "$f" tee "$NAS_TEMP_DIR/$BUNDLE_NAME/$f" \
			| cksum | sed "s| -$| $f|" >> "$NAS_TEMP_DIR/$BUNDLE_NAME/CHECKSUM.txt"
		do
			echo "ERROR: cksum+copy failed for $f -- retrying in 10s ..." >&2
			rm -f "$NAS_TEMP_DIR/$BUNDLE_NAME/$f"
			sleep 10
		done
		rm -f "$f"
		echo "Trickle-copied $f to NAS"
	done
	touch "$NAS_TEMP_DIR/$BUNDLE_NAME/.copy-complete"
) >> "$LOGFILE" 2>&1 &
echo $! > "$WORK_BUNDLE_DIR_BUILD/.bg-copy-pid"
echo "Background trickle-copy started (PID $(cat "$WORK_BUNDLE_DIR_BUILD/.bg-copy-pid"))"
