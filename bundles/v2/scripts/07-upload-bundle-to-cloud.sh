#!/bin/bash -e
# Phase 07: Upload bundle to cloud directory

set -x

source "$(cd "$(dirname "$0")/.." && pwd)/common.sh"

# Ensure internet is down for disconnected testing. On re-runs, go.sh puts
# internet UP to fetch OCP versions, and Make skips step 05 (already done),
# so the internet would stay UP without this guard.
int_down

cd "$WORK_TEST_INSTALL/aba"

# --- Assemble test log ---
{
	echo "## Test results for install bundle: $BUNDLE_NAME"
	echo
	cat "$WORK_BUNDLE_DIR_BUILD"/tests-06*.txt
} > "$WORK_TEST_LOG"

# --- Generate README and helper scripts into WORK_BUNDLE_DIR ---
# This runs for both dev and production builds (single code path).

s=$(cd cli && echo $(ls -r *.gz) | sed "s/ /\\\n    - /g")
d=$(date -u)
bundle_size=$(du -shc "$WORK_BUNDLE_DIR"/ocp_* 2>/dev/null | tail -1 | awk '{print $1}')
[ -z "$bundle_size" ] && bundle_size="unknown"
aba_ver=$(cat "$REPO_ROOT/VERSION" 2>/dev/null)
[ -z "$aba_ver" ] && aba_ver="unknown"

op_list=$(for i in $OP_SETS; do cat "$WORK_TEST_INSTALL/aba/templates/operator-set-$i"; done | cut -d'#' -f1 | sed 's/[[:space:]]*$//; /^[[:space:]]*$/d' | sort | uniq | sed "s/^/  - /g")
[ ! "$op_list" ] && op_list="  - No Operators!"

sed -e "s/<VERSION>/$VER/g" -e "s/<CLIS>/$s/g" -e "s/<DATETIME>/$d/g" -e "s/<SIZE>/$bundle_size/g" -e "s/<ABA_VERSION>/$aba_ver/g" < "$TEMPLATES_DIR/README.txt" > "$WORK_BUNDLE_DIR/README.txt"

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

echo_step "Create the install bundle dir and copy the files ..."

# Clean slate for idempotent retry (stale partial uploads from interrupted runs)
rm -rf "$CLOUD_DIR_BUNDLE"
mkdir -p "$CLOUD_DIR_BUNDLE"

# Mark it as incomplete
{
	echo "========================================================================================"
	echo
	echo "THIS ARCHIVE IS INCOMPLETE OR IT'S STILL UPLOADING.  PLEASE WAIT FOR UPLOAD TO COMPLETE!"
	echo
	echo "========================================================================================"
} > "$CLOUD_DIR_BUNDLE/$BUNDLE_UPLOADING"
mypause 60

ls -l "$WORK_BUNDLE_DIR"/ocp_*

# Copy all bundle files (split archives, README, helpers, checksum) to cloud dir
cp -v "$WORK_BUNDLE_DIR"/ocp_*		"$CLOUD_DIR_BUNDLE"
cp -v "$WORK_BUNDLE_DIR/CHECKSUM.txt"	"$CLOUD_DIR_BUNDLE"
cp -v "$WORK_BUNDLE_DIR/README.txt"	"$CLOUD_DIR_BUNDLE"
cp -v "$WORK_BUNDLE_DIR/VERIFY.sh"	"$CLOUD_DIR_BUNDLE"
cp -v "$WORK_BUNDLE_DIR/UNPACK.sh"	"$CLOUD_DIR_BUNDLE"

echo
echo "BUNDLE COMPLETE!"
echo

echo "Copy build artifact dir from $WORK_BUNDLE_DIR_BUILD to $CLOUD_DIR_BUNDLE"
ls -la "$WORK_BUNDLE_DIR_BUILD"
cp -rpv "$WORK_BUNDLE_DIR_BUILD"	"$CLOUD_DIR_BUNDLE"

# Tidy the cloud build dir: combine logs, remove build artifacts
_cloud_build="$CLOUD_DIR_BUNDLE/build"
cat "$_cloud_build"/log-*.log > "$_cloud_build/build.log" 2>/dev/null && rm -f "$_cloud_build"/log-*.log
rm -f "$_cloud_build"/.done-*
rm -f "$_cloud_build"/tests-06*.txt "$_cloud_build"/*-test.sh

# Remove the warning file (marks upload as complete)
rm -f "$CLOUD_DIR_BUNDLE/$BUNDLE_UPLOADING"

# Only remove source tarballs after upload is fully committed
rm -fv "$WORK_BUNDLE_DIR"/ocp_*

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
