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
aba image add registry.redhat.io/openshift4/ose-cli:latest \
              registry.redhat.io/rhel9/support-tools:latest \
              quay.io/openshifttest/hello-openshift:1.2.0 \
              registry.redhat.io/ubi9/ubi:latest

# Virt companion images
[ "$NAME" = "virt" ] && aba image add quay.io/containerdisks/centos-stream:9 \
                                      quay.io/containerdisks/fedora:latest

# AI companion images (fetch from GitHub, fall back to static list)
[ "$NAME" = "ai" ] && fetch_rhoai_images "3.5"

echo_step "Create image set config file ..."

aba isconf --dir mirror

echo_step "Show image set config file ..."

cat mirror/data/imageset-config.yaml

echo "Pausing 6s ..."
read -t 6 || true
