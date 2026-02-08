#!/bin/bash
# Wrapper to call ensure_* functions from Makefiles
# Usage: ensure-cli.sh {oc-mirror|oc|openshift-install|govc|butane|quay-registry}

# Use pwd -P to resolve symlinks (important when called via cluster-dir/scripts/ symlink)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
cd "$SCRIPT_DIR/.." || exit 1
source scripts/include_all.sh

tool="$1"

case "$tool" in
    oc-mirror)
        if ! ensure_oc_mirror; then
            echo "Error: Failed to install oc-mirror" >&2
            exit 1
        fi
        ;;
    oc)
        if ! ensure_oc; then
            echo "Error: Failed to install oc" >&2
            exit 1
        fi
        ;;
    openshift-install)
        if ! ensure_openshift_install; then
            echo "Error: Failed to install openshift-install" >&2
            exit 1
        fi
        ;;
    govc)
        if ! ensure_govc; then
            echo "Error: Failed to install govc" >&2
            exit 1
        fi
        ;;
    butane)
        if ! ensure_butane; then
            echo "Error: Failed to install butane" >&2
            exit 1
        fi
        ;;
    quay-registry)
        if ! ensure_quay_registry; then
            echo "Error: Failed to install quay-registry" >&2
            exit 1
        fi
        ;;
    *)
        echo "Error: Unknown tool: $tool" >&2
        echo "Usage: $0 {oc-mirror|oc|openshift-install|govc|butane|quay-registry}" >&2
        exit 1
        ;;
esac
