#!/bin/bash
# =============================================================================
# DEMO: Summary dashboard (bastion tmux, read-only) + interactive attach
# =============================================================================
# Tests both viewing modes from the redesign plan:
#
#   1. Summary dashboard: bastion tmux session with split panes, each tailing
#      a pool's summary log via SSH. Read-only, NO nested tmux (panes just
#      run "ssh conN tail -f summary.log", not "ssh conN tmux attach").
#
#   2. Interactive attach: from a separate Mac terminal tab, the user runs
#      "ssh -t conN tmux attach -t e2e-run" for full interactive control.
#      One level of tmux only (on conN).
#
# Since only con1 is available, this simulates 2 pools using two separate
# tmux sessions on con1, each with its own summary log.
#
# Usage:
#   ./demo-dashboards.sh [HOST]    (default: steve@con1.example.com)
#
# After running:
#   1. Attach to dashboard:   tmux attach -t e2e-dashboard
#   2. Interactive (pool 1):  ssh -t HOST tmux attach -t e2e-pool1
# =============================================================================

set -u

HOST="${1:-steve@con1.example.com}"
DASH_SESSION="e2e-dashboard"
POOL1_SESSION="e2e-pool1"
POOL2_SESSION="e2e-pool2"
SUMMARY_LOG1="/tmp/e2e-pool1-summary.log"
SUMMARY_LOG2="/tmp/e2e-pool2-summary.log"

_ssh() { ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR "$HOST" "$@"; }

echo "=== Demo: Summary dashboard + Interactive attach ==="
echo ""
echo "Host: $HOST"
echo ""

# -------------------------------------------------------------------------
# Step 1: Create two pool tmux sessions on remote host (simulate 2 pools)
# -------------------------------------------------------------------------
echo "--- Step 1: Create simulated pool sessions on $HOST ---"

for sess in $POOL1_SESSION $POOL2_SESSION; do
    _ssh "tmux kill-session -t $sess 2>/dev/null; tmux new-session -d -s $sess"
    echo "  Created tmux session: $sess"
done

_ssh "rm -f $SUMMARY_LOG1 $SUMMARY_LOG2; touch $SUMMARY_LOG1 $SUMMARY_LOG2"

# -------------------------------------------------------------------------
# Step 2: Upload runner scripts (output to both screen AND log via tee)
# -------------------------------------------------------------------------
echo ""
echo "--- Step 2: Upload simulated runners ---"

cat > /tmp/_demo-pool1-runner.sh << 'POOL1SCRIPT'
#!/bin/bash
LOG=/tmp/e2e-pool1-summary.log
R='\033[1;31m'; G='\033[1;32m'; C='\033[1;36m'; Y='\033[1;33m'; N='\033[0m'

_log() { echo -e "$@" | tee -a $LOG; }

_log "${C}========== SUITE: airgapped-local-reg ==========${N}"
sleep 1
_log "  L ${G}Install aba${N} ${Y}[steve@con1:~/testing/aba]${N}"
_log "    ${C}./install${N}"
sleep 2
_log "    ${G}PASS${N}: Install aba  (2s)"
sleep 1
_log "  L ${G}Configure aba.conf${N} ${Y}[steve@con1:~/testing/aba]${N}"
_log "    ${C}aba --noask --platform vmw --channel stable --version p${N}"
sleep 2
_log "    ${G}PASS${N}: Configure aba.conf  (2s)"
sleep 1
_log "  R ${G}Install Quay registry${N}"
_log "    ${C}aba -d mirror install${N}"
sleep 3
_log "    ${G}PASS${N}: Install Quay registry  (3s)"
_log "${G}========== PASSED: airgapped-local-reg  (10s) ==========${N}"
sleep 2

_log ""
_log "${C}========== SUITE: cluster-ops ==========${N}"
sleep 1
_log "  L ${G}Install aba${N} ${Y}[steve@con1:~/testing/aba]${N}"
_log "    ${C}./install${N}"
sleep 2
_log "    ${G}PASS${N}: Install aba  (2s)"
sleep 1
_log "  L ${G}Create SNO cluster${N} ${Y}[steve@con1:~/testing/aba]${N}"
_log "    ${C}aba cluster -n sno1 -t sno --step install${N}"
sleep 3
_log "    ${R}FAIL${N}: Create SNO cluster  (3s)"
_log "${R}FAILED: 'Create SNO cluster'  [r]etry [s]kip [S]kip-suite [a]bort [cmd]: ${N}"

read -r -p ""

_log "    ${G}PASS (retried)${N}: Create SNO cluster  (1s)"
_log "${G}========== PASSED: cluster-ops  (8s) ==========${N}"
_log ""
_log "=== Pool 1 Summary ==="
_log "  ${G}PASS${N}  airgapped-local-reg    (10s)"
_log "  ${G}PASS${N}  cluster-ops             (8s)"
_log "Result: 2/2 passed"
POOL1SCRIPT

cat > /tmp/_demo-pool2-runner.sh << 'POOL2SCRIPT'
#!/bin/bash
LOG=/tmp/e2e-pool2-summary.log
R='\033[1;31m'; G='\033[1;32m'; C='\033[1;36m'; Y='\033[1;33m'; N='\033[0m'

_log() { echo -e "$@" | tee -a $LOG; }

_log "${C}========== SUITE: mirror-sync ==========${N}"
sleep 2
_log "  L ${G}Install aba${N} ${Y}[steve@con2:~/testing/aba]${N}"
_log "    ${C}./install${N}"
sleep 3
_log "    ${G}PASS${N}: Install aba  (3s)"
sleep 1
_log "  L ${G}Run aba mirror${N} ${Y}[steve@con2:~/testing/aba]${N}"
_log "    ${C}aba mirror${N}"
sleep 4
_log "    ${G}PASS${N}: Run aba mirror  (4s)"
sleep 1
_log "  L ${G}Save and reload${N} ${Y}[steve@con2:~/testing/aba]${N}"
_log "    ${C}aba --dir mirror save load${N}"
sleep 3
_log "    ${G}PASS${N}: Save and reload  (3s)"
_log "${G}========== PASSED: mirror-sync  (14s) ==========${N}"
sleep 2

_log ""
_log "${C}========== SUITE: connected-public ==========${N}"
sleep 1
_log "  L ${G}Install aba${N} ${Y}[steve@con2:~/testing/aba]${N}"
_log "    ${C}./install${N}"
sleep 2
_log "    ${G}PASS${N}: Install aba  (2s)"
sleep 1
_log "  L ${G}Install SNO from public registry${N} ${Y}[steve@con2:~/testing/aba]${N}"
_log "    ${C}aba -d sno1 install${N}"
sleep 4
_log "    ${G}PASS${N}: Install SNO from public registry  (4s)"
_log "${G}========== PASSED: connected-public  (10s) ==========${N}"
_log ""
_log "=== Pool 2 Summary ==="
_log "  ${G}PASS${N}  mirror-sync            (14s)"
_log "  ${G}PASS${N}  connected-public        (10s)"
_log "Result: 2/2 passed"
POOL2SCRIPT

scp -o StrictHostKeyChecking=no -o LogLevel=ERROR \
    /tmp/_demo-pool1-runner.sh "$HOST:/tmp/demo-pool1-runner.sh"
scp -o StrictHostKeyChecking=no -o LogLevel=ERROR \
    /tmp/_demo-pool2-runner.sh "$HOST:/tmp/demo-pool2-runner.sh"
_ssh "chmod +x /tmp/demo-pool1-runner.sh /tmp/demo-pool2-runner.sh"

echo "  Uploaded pool1 and pool2 runner scripts."

# -------------------------------------------------------------------------
# Step 3: Dispatch runners into pool tmux sessions
# -------------------------------------------------------------------------
echo ""
echo "--- Step 3: Dispatch runners to pool sessions ---"

_ssh "tmux send-keys -t $POOL1_SESSION 'bash /tmp/demo-pool1-runner.sh' Enter"
echo "  Dispatched to $POOL1_SESSION (suites: airgapped-local-reg, cluster-ops)"

_ssh "tmux send-keys -t $POOL2_SESSION 'bash /tmp/demo-pool2-runner.sh' Enter"
echo "  Dispatched to $POOL2_SESSION (suites: mirror-sync, connected-public)"

sleep 1

# -------------------------------------------------------------------------
# Step 4: Create summary dashboard on bastion (tmux with read-only panes)
# -------------------------------------------------------------------------
echo ""
echo "--- Step 4: Create summary dashboard on bastion ---"

tmux kill-session -t $DASH_SESSION 2>/dev/null

# Pane 1: tail pool 1 summary log (read-only, just SSH + tail, no tmux on remote)
# Pane 2: tail pool 2 summary log
tmux new-session -d -s $DASH_SESSION \
    "echo '=== Pool 1 (con1) ===' && ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR $HOST 'tail -f $SUMMARY_LOG1'"

tmux split-window -t $DASH_SESSION -v \
    "echo '=== Pool 2 (con2) ===' && ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR $HOST 'tail -f $SUMMARY_LOG2'"

tmux select-layout -t $DASH_SESSION even-vertical

echo "  Dashboard created: 2 panes tailing summary logs (read-only, no nested tmux)."

# -------------------------------------------------------------------------
# Done
# -------------------------------------------------------------------------
echo ""
echo "=== Demo ready ==="
echo ""
echo "  SUMMARY DASHBOARD (read-only, on bastion):"
echo "    tmux attach -t $DASH_SESSION"
echo "    - Top pane: pool 1 summary log"
echo "    - Bottom pane: pool 2 summary log"
echo "    - Ctrl-b + arrows to switch panes (read-only, just watching)"
echo "    - Ctrl-b + d to detach"
echo ""
echo "  INTERACTIVE ATTACH (from a separate Mac terminal tab):"
echo "    ssh -t $HOST tmux attach -t $POOL1_SESSION"
echo "    ssh -t $HOST tmux attach -t $POOL2_SESSION"
echo "    - Full interactive control (respond to failure prompts)"
echo "    - Ctrl-b + d to detach"
echo ""
echo "  Pool 1 will pause with a FAIL prompt."
echo "  Attach interactively to respond, then check the dashboard."
echo ""
echo "  Cleanup:"
echo "    tmux kill-session -t $DASH_SESSION"
echo "    ssh $HOST 'tmux kill-session -t $POOL1_SESSION; tmux kill-session -t $POOL2_SESSION'"
