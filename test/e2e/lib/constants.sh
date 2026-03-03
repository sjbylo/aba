# Shared constants for E2E test framework (sourced by run.sh and runner.sh)
# Single source of truth for naming conventions.

E2E_TMUX_SESSION="e2e-suite"                      # static tmux session name on each conN
E2E_RC_DIR="/tmp"
E2E_RC_PREFIX="${E2E_RC_DIR}/e2e-suite"            # RC files: /tmp/e2e-suite-<suite>.rc
E2E_DISPATCHER_PID="/tmp/e2e-dispatcher.pid"
E2E_DISPATCH_STATE="/tmp/e2e-dispatch-state.txt"
E2E_INJECT_QUEUE="/tmp/e2e-inject-queue.txt"

POOL_REG_DIR="/opt/pool-reg"                      # Docker pool registry data dir (certs, auth, data)
