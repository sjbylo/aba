#!/bin/bash -e
# Phase 05: Go offline to test the install bundle in disconnected mode

set -x

source "$(cd "$(dirname "$0")/.." && pwd)/common.sh"

echo_step "Going offline to test the install bundle ..."
int_down
~/bin/intcheck.sh | grep DOWN

echo_step "Test internet connection with curl google.com ..."
! curl -sfkIL google.com >/dev/null
