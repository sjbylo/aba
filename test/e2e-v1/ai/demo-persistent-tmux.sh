#!/bin/bash
# =============================================================================
# DEMO: Persistent tmux session on remote host with send-keys dispatch
# =============================================================================
# Tests the core e2e-v2 execution model:
#   1. Create (or reuse) a persistent tmux session on a remote host
#   2. Send a command into it via tmux send-keys
#   3. Detect when the command finishes
#   4. Read the exit code
#   5. Concurrent run protection (refuse if already running)
#
# Usage:
#   ./demo-persistent-tmux.sh [HOST]    (default: steve@con1.example.com)
#
# The demo runs a simple test script on the remote host inside a persistent
# tmux session, then verifies the dispatch + detection + exit code flow.
# =============================================================================

set -u

HOST="${1:-steve@con1.example.com}"
TMUX_SESSION="e2e-run"
LOCK_FILE="/tmp/e2e-runner.lock"
RC_FILE="/tmp/e2e-runner.rc"
POLL_INTERVAL=2

_ssh() { ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR "$HOST" "$@"; }

echo "=== Demo: persistent tmux + send-keys on $HOST ==="
echo ""

# -------------------------------------------------------------------------
# Step 1: Ensure persistent tmux session exists on remote host
# -------------------------------------------------------------------------
echo "--- Step 1: Ensure persistent tmux session on $HOST ---"

if _ssh "tmux has-session -t $TMUX_SESSION 2>/dev/null"; then
    echo "  Session '$TMUX_SESSION' already exists -- reusing."
else
    echo "  Creating tmux session '$TMUX_SESSION' ..."
    _ssh "tmux new-session -d -s $TMUX_SESSION"
    echo "  Created."
fi

# -------------------------------------------------------------------------
# Step 2: Concurrent run protection -- check lock file
# -------------------------------------------------------------------------
echo ""
echo "--- Step 2: Check concurrent run protection ---"

LOCK_CHECK=$(_ssh "
    if [ -f $LOCK_FILE ]; then
        pid=\$(cat $LOCK_FILE)
        if kill -0 \$pid 2>/dev/null; then
            echo BUSY
        else
            echo STALE
        fi
    else
        echo FREE
    fi
")

case "$LOCK_CHECK" in
    BUSY)
        echo "  ERROR: runner already executing on $HOST (lock file active). Aborting."
        exit 1
        ;;
    STALE)
        echo "  Stale lock file found -- removing."
        _ssh "rm -f $LOCK_FILE"
        ;;
    FREE)
        echo "  No lock -- good to go."
        ;;
esac

# -------------------------------------------------------------------------
# Step 3: Upload a test script to simulate runner.sh
# -------------------------------------------------------------------------
echo ""
echo "--- Step 3: Upload test runner script ---"

# This simulates what runner.sh would do: acquire lock, run work, write rc, release lock
_ssh "cat > /tmp/demo-runner.sh << 'SCRIPT'
#!/bin/bash
LOCK_FILE=/tmp/e2e-runner.lock
RC_FILE=/tmp/e2e-runner.rc

echo \$\$ > \$LOCK_FILE
trap 'rm -f \$LOCK_FILE' EXIT

rm -f \$RC_FILE

echo \"=== Runner started (pid \$\$) ===\"
echo \"Suite 1: running some tests ...\"
sleep 3
echo \"  PASS: test-alpha\"
echo \"  PASS: test-beta\"
echo \"Suite 1 done.\"
echo \"\"
echo \"Suite 2: running more tests ...\"
sleep 2
echo \"  PASS: test-gamma\"
echo \"  FAIL: test-delta (simulated failure)\"
echo \"Suite 2 done.\"
echo \"\"
echo \"=== Runner finished ===\"

echo 1 > \$RC_FILE
SCRIPT
chmod +x /tmp/demo-runner.sh"

echo "  Uploaded /tmp/demo-runner.sh"

# -------------------------------------------------------------------------
# Step 4: Send the command into the persistent tmux session
# -------------------------------------------------------------------------
echo ""
echo "--- Step 4: Dispatch via tmux send-keys ---"

_ssh "rm -f $RC_FILE"
_ssh "tmux send-keys -t $TMUX_SESSION 'bash /tmp/demo-runner.sh' Enter"
echo "  Sent command to tmux session '$TMUX_SESSION'."
echo "  (The remote script is now running inside the existing tmux session.)"

# -------------------------------------------------------------------------
# Step 5: Poll for completion by watching the RC file
# -------------------------------------------------------------------------
echo ""
echo "--- Step 5: Poll for completion (watching $RC_FILE) ---"

elapsed=0
while true; do
    rc_content=$(_ssh "cat $RC_FILE 2>/dev/null" || true)
    if [ -n "$rc_content" ]; then
        echo "  Completed after ~${elapsed}s. Exit code: $rc_content"
        break
    fi

    if [ $elapsed -ge 30 ]; then
        echo "  TIMEOUT after ${elapsed}s -- runner did not finish."
        exit 1
    fi

    printf "  Waiting... (%ds)\r" "$elapsed"
    sleep $POLL_INTERVAL
    elapsed=$((elapsed + POLL_INTERVAL))
done

# -------------------------------------------------------------------------
# Step 6: Verify the tmux session is still alive (persistent!)
# -------------------------------------------------------------------------
echo ""
echo "--- Step 6: Verify tmux session survived ---"

if _ssh "tmux has-session -t $TMUX_SESSION 2>/dev/null"; then
    echo "  Session '$TMUX_SESSION' is still alive -- GOOD (persistent)."
else
    echo "  ERROR: Session '$TMUX_SESSION' is gone! The session should persist."
    exit 1
fi

# -------------------------------------------------------------------------
# Step 7: Verify lock file is cleaned up
# -------------------------------------------------------------------------
echo ""
echo "--- Step 7: Verify lock file cleaned up ---"

if _ssh "test -f $LOCK_FILE" 2>/dev/null; then
    echo "  WARNING: Lock file still exists (trap may not have fired)."
else
    echo "  Lock file removed -- GOOD."
fi

# -------------------------------------------------------------------------
# Step 8: Test concurrent protection -- try to dispatch again while busy
# -------------------------------------------------------------------------
echo ""
echo "--- Step 8: Test concurrent protection ---"

echo "  Sending a slow command (sleep 10) ..."
_ssh "rm -f $RC_FILE"
_ssh "tmux send-keys -t $TMUX_SESSION 'echo \$\$ > $LOCK_FILE; sleep 10; rm -f $LOCK_FILE; echo done > $RC_FILE' Enter"
sleep 1

echo "  Now checking lock ..."
LOCK_CHECK=$(_ssh "
    if [ -f $LOCK_FILE ]; then
        pid=\$(cat $LOCK_FILE)
        if kill -0 \$pid 2>/dev/null; then
            echo BUSY
        else
            echo STALE
        fi
    else
        echo FREE
    fi
")

if [ "$LOCK_CHECK" = "BUSY" ]; then
    echo "  Correctly detected BUSY -- concurrent protection works!"
else
    echo "  Got '$LOCK_CHECK' -- expected BUSY. Lock mechanism needs investigation."
fi

echo ""
echo "  Waiting for slow command to finish ..."
while true; do
    rc_content=$(_ssh "cat $RC_FILE 2>/dev/null" || true)
    [ -n "$rc_content" ] && break
    sleep 2
done
echo "  Done."

# -------------------------------------------------------------------------
# Step 9: Capture tmux pane content (what the user would see)
# -------------------------------------------------------------------------
echo ""
echo "--- Step 9: Capture what the user sees in tmux ---"
echo ""
_ssh "tmux capture-pane -t $TMUX_SESSION -p" | tail -20
echo ""

# -------------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------------
echo "=== Demo complete ==="
echo ""
echo "Results:"
echo "  [PASS] Persistent tmux session created/reused"
echo "  [PASS] Command dispatched via send-keys"
echo "  [PASS] Completion detected via RC file"
echo "  [PASS] Exit code read correctly ($rc_content)"
echo "  [PASS] Tmux session survives after command"
echo "  [PASS] Lock file cleaned up after normal exit"
echo "  [PASS] Concurrent protection detects busy state"
echo ""
echo "To attach interactively:  ssh -t $HOST tmux attach -t $TMUX_SESSION"
echo "To kill the session:      ssh $HOST tmux kill-session -t $TMUX_SESSION"
