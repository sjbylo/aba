#!/bin/bash
# Thin wrapper to launch E2E tests on con1 via SSH.
# Run from the local workstation; output streams to /tmp/e2e-<suite>.log
# and to stdout (via tee).
#
# Usage:  ./run-remote.sh [run.sh args...]
# Example: ./run-remote.sh --suite connected-sync -r rhel8 --clean

set -uo pipefail

HOST="steve@con1.example.com"
ARGS="${*:---suite connected-sync -r rhel8 --clean}"
SUITE=$(echo "$ARGS" | grep -oP '(?<=--suite\s)\S+' || echo "e2e")
LOG="/tmp/e2e-${SUITE}.log"
ABA_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

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

echo "Launching on $HOST: ./run.sh $ARGS"
echo "Log: $LOG"
echo ""

ssh "$HOST" "cd ~/aba/test/e2e && ./run.sh $ARGS" 2>&1 | tee "$LOG"
