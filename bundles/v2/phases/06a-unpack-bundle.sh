#!/bin/bash -e
# Phase 06a: Unpack the bundle tar into the test-install directory

set -x

source "$(cd "$(dirname "$0")/.." && pwd)/common.sh"

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
