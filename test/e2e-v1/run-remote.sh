#!/bin/bash
# Thin wrapper to launch E2E tests on con1 via SSH.
# Run from the local workstation; output streams to /tmp/e2e-<suite>.log
# and to stdout (via tee).
#
# Usage:  ./run-remote.sh [run.sh args...]
# Example: ./run-remote.sh --suite cluster-ops -r rhel8 --clean
# Example: ./run-remote.sh --sync --suite cluster-ops  # rsync local tree first

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SCRIPT_DIR/config.env"
source "$_SCRIPT_DIR/lib/config-helpers.sh"

HOST="$(pool_connected_bastion "${POOL_NUM:-1}")"
ARGS="${*:---suite cluster-ops -r rhel8 --clean}"
SUITE=$(echo "$ARGS" | grep -oP '(?<=--suite\s)\S+' || echo "e2e")
LOG="/tmp/e2e-${SUITE}.log"
ABA_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

if [[ " $ARGS " == *" --sync "* ]]; then
    echo "Syncing aba tree to $HOST ..."
    rsync -az --delete \
        --exclude='mirror/save/' \
        --exclude='mirror/.oc-mirror/' \
        --exclude='mirror/*.tar' \
        --exclude='mirror/*.tar.gz' \
        --exclude='mirror/mirror-registry' \
        --exclude='cli/*.tar.gz' \
        --exclude='.git/' \
        --exclude='sno/' \
        --exclude='sno2/' \
        --exclude='compact/' \
        --exclude='standard/' \
        "$ABA_ROOT/" "$HOST:~/aba/"
fi

echo "Launching on $HOST: ./run.sh $ARGS"
echo "Log: $LOG"
echo ""

ssh "$HOST" "cd ~/aba/test/e2e && ./run.sh $ARGS" 2>&1 | tee "$LOG"
