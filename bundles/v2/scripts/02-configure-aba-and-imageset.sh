#!/bin/bash -e
# Phase 02: Configure aba and create imageset-config

set -x

source "$(cd "$(dirname "$0")/.." && pwd)/common.sh"

cd "$WORK_DIR/aba"

echo "Create the bundle in $WORK_BUNDLE_DIR ..."
mkdir -p "$WORK_BUNDLE_DIR_BUILD"

# Build the --op-sets argument only if OP_SETS is non-empty
OP=
[ "$OP_SETS" ] && OP="--op-sets $OP_SETS"

aba --pull-secret $PS_FILE --platform bm --channel stable --version $VER $OP --base-domain $BASE_DOM

aba -d cli oc-mirror
~/bin/oc-mirror version 2>&1 | head -1 && echo "oc-mirror is valid!"

echo_step "Create image set config file ..."

aba -d mirror isconf

uncomment_line additionalImages:			mirror/data/imageset-config.yaml
uncomment_line registry.redhat.io/openshift4/ose-cli	mirror/data/imageset-config.yaml
uncomment_line registry.redhat.io/rhel9/support-tools	mirror/data/imageset-config.yaml
uncomment_line quay.io/openshifttest/hello-openshift	mirror/data/imageset-config.yaml
uncomment_line registry.redhat.io/ubi9/ubi		mirror/data/imageset-config.yaml
[ "$NAME" = "ocpv" ] && uncomment_line quay.io/containerdisks/centos-stream:9	mirror/data/imageset-config.yaml
[ "$NAME" = "ocpv" ] && uncomment_line quay.io/containerdisks/fedora:latest	mirror/data/imageset-config.yaml

echo_step "Show image set config file ..."

cat mirror/data/imageset-config.yaml

echo "Pausing 6s ..."
read -t 6 || true
