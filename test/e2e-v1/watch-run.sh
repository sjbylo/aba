#!/bin/bash
# Watch the e2e run and write a summary to ~/e2e-status.txt
# Run: nohup ./watch-run.sh &

LOG_DIR="$HOME/aba/test/e2e/logs"
STATUS="$HOME/e2e-status.txt"

while true; do
    {
        echo "=== E2E Status @ $(date) ==="
        echo ""

        # Check if run.sh is still running
        if pgrep -f 'run.sh.*--all' > /dev/null 2>&1; then
            echo "STATUS: RUNNING"
        else
            echo "STATUS: FINISHED (or not running)"
        fi
        echo ""

        # Golden VM log tail
        if [ -f "$LOG_DIR/golden-rhel8.log" ]; then
            echo "--- Golden VM (last 5 lines) ---"
            tail -5 "$LOG_DIR/golden-rhel8.log"
            echo ""
        fi

        # Pool logs
        for f in "$LOG_DIR"/create-pool*.log; do
            [ -f "$f" ] || continue
            echo "--- $(basename "$f") (last 5 lines) ---"
            tail -5 "$f"
            echo ""
        done

        # Suite results
        for f in "$LOG_DIR"/suite-*.log; do
            [ -f "$f" ] || continue
            echo "--- $(basename "$f") (last 5 lines) ---"
            tail -5 "$f"
            echo ""
        done

        # Check for PASS/FAIL in any results file
        echo "--- Results summary ---"
        grep -rh 'PASS\|FAIL\|ERROR\|complete\|FAILED' "$LOG_DIR"/*.log 2>/dev/null | tail -20
        echo ""
    } > "$STATUS"

    sleep 60
done
