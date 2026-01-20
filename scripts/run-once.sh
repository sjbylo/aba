#!/bin/bash
# Generic wrapper to call run_once function from Makefiles/external contexts
# This allows Makefiles to use run_once without sourcing include_all.sh

cd "$(dirname "$0")/.." || exit 1
source scripts/include_all.sh
run_once "$@"
