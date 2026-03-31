#!/bin/bash -e
# Phase 06a: Unpack the bundle tar into the test-install directory

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
