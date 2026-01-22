#!/bin/bash
# Wrapper to call ensure_* functions from Makefiles
# Usage: ensure-cli.sh {oc-mirror|oc|openshift-install|govc|butane|mirror-registry}

cd "$(dirname "$0")/.." || exit 1
source scripts/include_all.sh

tool="$1"

case "$tool" in
    oc-mirror)
        ensure_oc_mirror
        ;;
    oc)
        ensure_oc
        ;;
    openshift-install)
        ensure_openshift_install
        ;;
    govc)
        ensure_govc
        ;;
    butane)
        ensure_butane
        ;;
    mirror-registry)
        ensure_mirror_registry
        ;;
    *)
        echo "Error: Unknown tool: $tool" >&2
        echo "Usage: $0 {oc-mirror|oc|openshift-install|govc|butane|mirror-registry}" >&2
        exit 1
        ;;
esac
