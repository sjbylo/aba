#!/bin/bash
# Generic wrapper to call run_once function from Makefiles/external contexts
# This allows Makefiles to use run_once without sourcing include_all.sh

# Save the original CWD so the command runs in the correct context
original_cwd="$(pwd)"

# Temporarily cd to ABA_ROOT to source include_all.sh
cd "$(dirname "$0")/.." || exit 1
source scripts/include_all.sh

# Return to original CWD before executing run_once
cd "$original_cwd" || exit 1

# Now run_once - the command it executes will run in the correct directory
run_once "$@"
