#!/bin/bash -e
# Phase 07: Upload bundle to cloud directory
#
# The 06a background trickle-copy should have moved tar chunks to NAS already.
# This step is the idempotency safety net: it finishes the copy for any chunks
# still on local disk (handles interrupted/dead BG process), assembles the
# README and helper files on NAS, then renames the temp dir to the final
# cloud location (instant -- same CIFS mount).

set -x

source "$(cd "$(dirname "$0")/.." && pwd)/common.sh"

# Ensure internet is down for disconnected testing. On re-runs, go.sh puts
# internet UP to fetch OCP versions, and Make skips step 05 (already done),
# so the internet would stay UP without this guard.
int_down

cd "$WORK_TEST_INSTALL/aba"

# --- Wait for background trickle-copy, then safety-net any remaining chunks ---

_bg_pid=$(cat "$WORK_BUNDLE_DIR_BUILD/.bg-copy-pid" 2>/dev/null) || true
if [ -n "$_bg_pid" ] && kill -0 "$_bg_pid" 2>/dev/null; then
	echo_step "Waiting for background NAS copy (PID $_bg_pid) ..."
	wait "$_bg_pid" || true
fi

# Safety net: copy any chunks still on local disk (handles interrupted BG)
mkdir -p "$NAS_TEMP_DIR/$BUNDLE_NAME"
if ls "$WORK_BUNDLE_DIR"/ocp_* &>/dev/null; then
	echo_step "Copying remaining local chunks to NAS (BG was incomplete) ..."
	(
		set -o pipefail
		cd "$WORK_BUNDLE_DIR"
		for f in ocp_*; do
			until < "$f" tee "$NAS_TEMP_DIR/$BUNDLE_NAME/$f" \
				| cksum | sed "s| -$| $f|" >> "$NAS_TEMP_DIR/$BUNDLE_NAME/CHECKSUM.txt"
			do
				echo "ERROR: copy failed for $f -- retrying in 10s ..." >&2
				rm -f "$NAS_TEMP_DIR/$BUNDLE_NAME/$f"
				sleep 10
			done
			rm -f "$f"
			echo "Copied remaining chunk $f to NAS"
		done
	)
fi

# Verify NAS has chunks
_nas_count=$(ls "$NAS_TEMP_DIR/$BUNDLE_NAME"/ocp_* 2>/dev/null | wc -l)
echo "Chunks on NAS: $_nas_count"
[ "$_nas_count" -gt 0 ] || { echo "ERROR: No ocp_* files on NAS!"; exit 1; }

# --- Assemble test log ---
{
	echo "## Test results for install bundle: $BUNDLE_NAME"
	echo
	cat "$WORK_BUNDLE_DIR_BUILD"/tests-06*.txt
} > "$WORK_TEST_LOG"

# --- Generate README and helper scripts into WORK_BUNDLE_DIR ---
# This runs for both dev and production builds (single code path).

s_primary=$(cd cli && echo $({ ls -1d openshift-install-*.gz 2>/dev/null; ls -1d openshift-client-*.gz 2>/dev/null; ls -1d oc-mirror*.gz 2>/dev/null; }) | sed "s/ /\\\n    - /g")
s_secondary=$(cd cli && echo $(ls -1d *.gz | grep -v '^openshift-' | grep -v '^oc-mirror') | sed "s/ /\\\n    - /g")
d=$(date -u)

# Bundle size was saved by step 04 (chunks are gone from local disk by now)
bundle_size=$(cat "$WORK_BUNDLE_DIR_BUILD/bundle-size.txt" 2>/dev/null)
[ -z "$bundle_size" ] && bundle_size="unknown"

# Compute ~3x disk needed (e.g. "106G" → "318G")
if _num=$(echo "$bundle_size" | grep -oE '^[0-9]+'); then
	_unit=$(echo "$bundle_size" | grep -oE '[A-Za-z]+$')
	disk_needed="$(( _num * 3 ))${_unit}"
else
	disk_needed="unknown"
fi
aba_ver=$(cat "$REPO_ROOT/VERSION" 2>/dev/null)
[ -z "$aba_ver" ] && aba_ver="unknown"

# Human-readable vendor name for README
case "${BUNDLE_VENDOR:-omr}" in
	omr)    vendor_display="OMR v3 (OpenShift Mirror Registry)" ;;
	quay)   vendor_display="Quay" ;;
	docker) vendor_display="Docker Distribution" ;;
	*)      vendor_display="$BUNDLE_VENDOR" ;;
esac

op_list=$(for i in $OP_SETS; do cat "$WORK_TEST_INSTALL/aba/templates/operator-set-$i"; done | cut -d'#' -f1 | sed 's/[[:space:]]*$//; /^[[:space:]]*$/d' | sort | uniq | sed "s/^/  - /g")
[ ! "$op_list" ] && op_list="  - No Operators!"

sed -e "s/<VERSION>/$VER/g" -e "s/<PRIMARY_CLIS>/$s_primary/g" -e "s/<SECONDARY_CLIS>/$s_secondary/g" -e "s/<DATETIME>/$d/g" -e "s/<SIZE>/$bundle_size/g" -e "s/<DISK_NEEDED>/$disk_needed/g" -e "s/<ABA_VERSION>/$aba_ver/g" -e "s/<VENDOR>/$vendor_display/g" < "$TEMPLATES_DIR/README.txt" > "$WORK_BUNDLE_DIR/README.txt"

# Insert test results into the <TEST_RESULTS> placeholder (strip the markdown header)
test_body=$(grep -v '^## ' "$WORK_TEST_LOG")
awk -v results="$test_body" '{
	if ($0 == "<TEST_RESULTS>") print results
	else print
}' "$WORK_BUNDLE_DIR/README.txt" > "$WORK_BUNDLE_DIR/README.txt.tmp" \
	&& mv "$WORK_BUNDLE_DIR/README.txt.tmp" "$WORK_BUNDLE_DIR/README.txt"

# Append operator list and imageset-config to README
(
	echo
	echo "## List of Operators included in this install bundle:"
	echo
	echo "$op_list"
	echo
	echo "## The oc-mirror Image Set Config file used for this install bundle:"
	echo
	cat "$WORK_TEST_INSTALL/aba/mirror/data/imageset-config.yaml"
) >> "$WORK_BUNDLE_DIR/README.txt"

cp -v "$TEMPLATES_DIR/VERIFY.sh"  "$WORK_BUNDLE_DIR/"
cp -v "$TEMPLATES_DIR/UNPACK.sh"  "$WORK_BUNDLE_DIR/"

# Copy in the image set config file used
cp "$WORK_TEST_INSTALL/aba/mirror/data/imageset-config.yaml" "$WORK_BUNDLE_DIR_BUILD"

echo
echo "Bundle contents in $WORK_BUNDLE_DIR:"
ls -la "$WORK_BUNDLE_DIR"

# --- Dev mode: stop here (no NAS upload) ---
if [ "${BUNDLE_DEV_MODE:-}" = "1" ]; then
	echo
	echo "##########################################################################"
	echo "DEV MODE: Bundle built from branch 'dev' — skipping NAS upload."
	echo "          This bundle is for local testing only."
	echo "##########################################################################"
	cat "$WORK_TEST_LOG"
	exit 0
fi

# --- Production: upload to cloud/NAS directory ---

echo_step "Cluster installed ok, all tests passed. Building install bundle."

echo_step "Determine older bundles ... to delete later"

# Before we create the bundle dir, fetch list of old dirs to delete
MAJOR_VER=$(echo "$VER" | cut -d\. -f1,2)
todel=
for d in "$CLOUD_DIR/$MAJOR_VER".[0-9]*-"$NAME" "$CLOUD_DIR/$MAJOR_VER".[0-9]*-"$NAME"-*; do
	[ -d "$d" ] && todel="$todel $d"
done
ls -l "$CLOUD_DIR"

[ ! "$todel" ] && echo "No older install bundles to delete" || echo "Install bundles to delete: $todel"

echo_step "Assemble bundle on NAS and publish ..."

# Copy small files (README, helpers, build artifacts) to NAS temp dir
cp -v "$WORK_BUNDLE_DIR/README.txt"  "$NAS_TEMP_DIR/$BUNDLE_NAME/"
cp -v "$WORK_BUNDLE_DIR/VERIFY.sh"   "$NAS_TEMP_DIR/$BUNDLE_NAME/"
cp -v "$WORK_BUNDLE_DIR/UNPACK.sh"   "$NAS_TEMP_DIR/$BUNDLE_NAME/"
cp -rpv "$WORK_BUNDLE_DIR_BUILD"     "$NAS_TEMP_DIR/$BUNDLE_NAME/"

# Tidy the build dir on NAS: combine logs, remove build artifacts
_cloud_build="$NAS_TEMP_DIR/$BUNDLE_NAME/build"
cat "$_cloud_build"/log-*.log > "$_cloud_build/build.log" 2>/dev/null && rm -f "$_cloud_build"/log-*.log
rm -f "$_cloud_build"/.done-* "$_cloud_build"/.bg-copy-pid
rm -f "$_cloud_build"/tests-06*.txt "$_cloud_build"/*-test.sh
rm -f "$NAS_TEMP_DIR/$BUNDLE_NAME/.copy-complete"

echo
echo "BUNDLE COMPLETE!"
echo

# Rename NAS temp dir to final cloud location (instant — same CIFS mount)
rm -rf "$CLOUD_DIR_BUNDLE"
mv "$NAS_TEMP_DIR/$BUNDLE_NAME" "$CLOUD_DIR_BUNDLE"

echo_step "Show content of new bundle in cloud dir $CLOUD_DIR_BUNDLE:"

ls -al "$CLOUD_DIR_BUNDLE"
echo
ls -al "$CLOUD_DIR_BUNDLE/build"
echo

echo_step "Delete older bundles? ..."

if [ "$todel" ]; then
	echo "Deleting the following old bundles: $todel:"
	ls -d $todel
	echo "rm -vrf $todel"
	rm -vrf $todel
else
	echo "No older install bundles to delete!"
fi
