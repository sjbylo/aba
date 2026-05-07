# Shared constants for E2E test framework (sourced by run.sh and runner.sh)
# Single source of truth for naming conventions.

E2E_TMUX_SESSION="e2e-suite"                      # static tmux session name on each conN
E2E_RC_DIR="/tmp"
E2E_RC_PREFIX="${E2E_RC_DIR}/e2e-suite"            # RC files: /tmp/e2e-suite-<suite>.rc
E2E_DISPATCHER_PID="/tmp/e2e-dispatcher.pid"
E2E_DAEMON_PID="/tmp/e2e-daemon.pid"                # PID of the daemon (crash-recovery) wrapper
E2E_DISPATCH_STATE="/tmp/e2e-dispatch-state.txt"
E2E_INJECT_QUEUE="/tmp/e2e-inject-queue.txt"
E2E_FORCED_DISPATCH="/tmp/e2e-forced-dispatch.txt"  # one-shot dispatch signals for running dispatcher
E2E_DAEMON_LOG=""                                    # set at runtime to $_RUN_DIR/logs/daemon.log
E2E_GLOBAL_LOCK="/tmp/e2e-run.lock"                # flock guard -- only for golden VM rebuild (shared resource)
E2E_POOL_LOCK_PREFIX="/tmp/e2e-pool"               # Per-pool lock: /tmp/e2e-pool-N.lock
E2E_HUNG_TIMEOUT="${E2E_HUNG_TIMEOUT:-3600}"        # No-output watchdog threshold (seconds, default 60 min)

POOL_REG_DIR="/opt/pool-reg"                      # Docker pool registry data dir (certs, auth, data)
