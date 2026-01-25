#!/bin/bash
# Cleanup script for run_once background tasks and runner cache
# Usage: scripts/cleanup-runner.sh

# Use pwd -P to resolve symlinks (important when called via cluster-dir/scripts/ symlink)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
cd "$SCRIPT_DIR/.." || exit 1

source scripts/include_all.sh

# Kill all background run_once tasks and clean runner directory
echo "[ABA] Cleaning up background tasks and runner cache..."
run_once -G || true

echo "[ABA] Cleanup complete"
