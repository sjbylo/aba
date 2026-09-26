#!/bin/bash -e
# Phase 02: Configure aba and create imageset-config

set -x

source "$(cd "$(dirname "$0")/.." && pwd)/common.sh"

cd "$WORK_DIR/aba"
./install

echo "Create the bundle in $WORK_BUNDLE_DIR ..."
mkdir -p "$WORK_BUNDLE_DIR_BUILD"

# Build the --op-sets argument only if OP_SETS is non-empty
OP=
[ "$OP_SETS" ] && OP="--op-sets $OP_SETS"

# Bundles are GA-only by design. --channel stable is intentional (no RC/EC versions in bundles).
aba --pull-secret $PS_FILE --platform bm --channel stable --version $VER $OP --base-domain $BASE_DOM

aba -d cli oc-mirror
~/bin/oc-mirror version 2>&1 | head -1 && echo "oc-mirror is valid!"

echo_step "Add additional images ..."

# Default images for all bundles
aba image add quay.io/openshifttest/hello-openshift:1.2.0

# Add curated image sets based on bundle type
source scripts/include_all.sh

# Ensure .index/ exists (detect_rhoai_version reads from it; catalogs/ has the same data)
[ ! -d .index ] && [ -d catalogs ] && ln -sf catalogs .index

# OCP utility images (support-tools, ubi) for all bundles
image_set_add ocp

# Virt companion images (container disks for VMs)
[ "$NAME" = "virt" ] && image_set_add virt

# AI companion images (RHOAI workbench/pipeline images from GitHub)
# Also add minio for DSP testing (not in the RHOAI image list but needed by DSPA)
if [ "$NAME" = "ai" ]; then
	image_set_add ai
	aba image add quay.io/opendatahub/minio:RELEASE.2019-08-14T20-37-41Z-license-compliance
fi

echo_step "Create image set config file ..."

aba isconf --dir mirror

echo_step "Show image set config file ..."

cat mirror/data/imageset-config.yaml

echo "Pausing 6s ..."
read -t 6 || true
