#!/bin/bash -e
# Phase 01: Install aba from git

set -x

source "$(cd "$(dirname "$0")/.." && pwd)/common.sh"

cd "$WORK_DIR"

echo_step "Install Aba to $PWD/aba ..."

rm -rf aba

echo_step "Install Aba from branch $GIT_BRANCH"
set +x
install_script=$(curl -fsSL "https://raw.githubusercontent.com/sjbylo/aba/refs/heads/$GIT_BRANCH/install")
bash -c "$install_script" -- $GIT_BRANCH
set -x
