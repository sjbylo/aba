#!/bin/bash -e
# Phase 01: Install aba from git

set -x

source "$(cd "$(dirname "$0")/.." && pwd)/common.sh"

cd "$WORK_DIR"

echo_step "Install Aba to $PWD/aba ..."

rm -rf aba

echo_step "Install Aba from branch $GIT_BRANCH"
set +x
bash -c "$(gitrepo=sjbylo/aba; gitbranch=$GIT_BRANCH; curl -fsSL https://raw.githubusercontent.com/$gitrepo/refs/heads/$gitbranch/install)" -- $GIT_BRANCH
set -x
