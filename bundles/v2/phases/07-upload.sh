#!/bin/bash -e
# Phase 07: Upload bundle to cloud directory

set -x

source "$(cd "$(dirname "$0")/.." && pwd)/common.sh"

cd "$WORK_TEST_INSTALL/aba"

# Assemble the final test log from per-phase results
{
	echo "## Test results for install bundle: $BUNDLE_NAME"
	echo
	cat "$WORK_BUNDLE_DIR_BUILD"/tests-06*.txt
} > "$WORK_TEST_LOG"

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

# Generate README with bundle version and list of install files
s=$(cd cli && echo $(ls -r *.gz) | sed "s/ /\\\n  - /g")
d=$(date -u)

# Fetch list of available operators
op_list=$(for i in $OP_SETS; do cat "$WORK_TEST_INSTALL/aba/templates/operator-set-$i"; done | cut -d'#' -f1 | sed "/^[ \t]*$/d" | sort | uniq | sed "s/^/  - /g")
[ ! "$op_list" ] && op_list="  - No Operators!"

# Create readme file from template
sed -e "s/<VERSION>/$VER/g" -e "s/<CLIS>/$s/g" -e "s/<DATETIME>/$d/g" < "$TEMPLATES_DIR/README.txt" > "$CLOUD_DIR_BUNDLE/README.txt"

# Append test results and operator list to README
(
	echo
	cat "$WORK_TEST_LOG"
	echo
	echo "## List of Operators included in this install bundle:"
	echo
	echo "$op_list"
	echo
	echo "## The oc-mirror Image Set Config file used for this install bundle:"
	echo
	cat "$WORK_TEST_INSTALL/aba/mirror/data/imageset-config.yaml"
) >> "$CLOUD_DIR_BUNDLE/README.txt"

# Copy in the image set config file used
cp "$WORK_TEST_INSTALL/aba/mirror/data/imageset-config.yaml" "$WORK_BUNDLE_DIR_BUILD"

ls -l "$WORK_BUNDLE_DIR"/ocp_*

# Copy the files into the cloud sync dir
cp -v "$WORK_BUNDLE_DIR"/ocp_*		"$CLOUD_DIR_BUNDLE"

cp -v "$WORK_BUNDLE_DIR/CHECKSUM.txt"	"$CLOUD_DIR_BUNDLE"
cp -v "$TEMPLATES_DIR/VERIFY.sh"	"$CLOUD_DIR_BUNDLE"
cp -v "$TEMPLATES_DIR/UNPACK.sh"	"$CLOUD_DIR_BUNDLE"

echo
echo "BUNDLE COMPLETE!"
echo

echo "Copy build artifact dir from $WORK_BUNDLE_DIR_BUILD to $CLOUD_DIR_BUNDLE"
ls -la "$WORK_BUNDLE_DIR_BUILD"
cp -rpv "$WORK_BUNDLE_DIR_BUILD"	"$CLOUD_DIR_BUNDLE"

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
