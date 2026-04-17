#!/bin/bash -e
# Phase 03: Save images to disk (THE EXPENSIVE STEP)

set -x

source "$(cd "$(dirname "$0")/.." && pwd)/common.sh"

cd "$WORK_DIR/aba"

echo_step "Save images to disk ..."

# Bundle builds want differential archives (cache reused across bundle types
# of the same OCP version). Disable OC_MIRROR_SINCE from ~/.aba/config.
sed -i 's/^OC_MIRROR_SINCE=.*/OC_MIRROR_SINCE=/' ~/.aba/config
aba -d cli download-all
aba -d mirror save -r 2

# Explicitly fetch govc since we are in 'bm' mode
aba -d cli govc
