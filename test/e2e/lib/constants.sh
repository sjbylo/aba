# Shared constants for E2E test framework (sourced by run.sh and runner.sh)
# Single source of truth for naming conventions.

E2E_TMUX_SESSION="e2e-suite"                      # static tmux session name on each conN
E2E_RC_DIR="/tmp"
E2E_RC_PREFIX="${E2E_RC_DIR}/e2e-suite"            # RC files: /tmp/e2e-suite-<suite>.rc
E2E_DISPATCHER_PID="/tmp/e2e-dispatcher.pid"
