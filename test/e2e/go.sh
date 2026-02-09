#!/bin/bash
# =============================================================================
# E2E Test Framework -- Quick Launcher
# =============================================================================
# Thin wrapper around run.sh. Defaults to --all --interactive when no
# arguments are given.
# =============================================================================

_GO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ $# -eq 0 ]; then
    exec "$_GO_DIR/run.sh" --all --interactive
else
    exec "$_GO_DIR/run.sh" "$@"
fi
