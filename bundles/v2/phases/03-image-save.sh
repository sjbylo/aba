#!/bin/bash -e
# Phase 03: Save images to disk (THE EXPENSIVE STEP)

set -x

source "$(cd "$(dirname "$0")/.." && pwd)/common.sh"

cd "$WORK_DIR/aba"

echo_step "Save images to disk ..."

# Keep the oc-mirror cache for reuse across bundles of the same version
sed -i "s/--since 2025-01-01//g" scripts/reg-save.sh
aba -d cli download-all
aba -d mirror save -r 2

# Explicitly fetch govc since we are in 'bm' mode
aba -d cli govc
