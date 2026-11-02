#!/bin/bash
# Test the real day2.sh through the TUI progress engine.
# Uses sno2-ext cluster (which is down) — exercises the error/FAIL path.
# Run interactively on conno: bash test/func/test-tui-progress-real.sh
set -e

cd "$(cd "$(dirname "$0")/../.." && pwd -P)"

source scripts/include_all.sh
source tui/v2/tui-progress.sh

echo "=== Real day2 through TUI progress engine ==="
echo
echo "This runs 'aba --dir sno2-ext day2 --yes' through _exec_with_progress."
echo "The cluster is down, so it will fail at the API check."
echo "You should see:"
echo "  - 8 progress steps appear in the dialog"
echo "  - 'Accessing cluster' goes to In Progress, then Failed"
echo "  - Error dialog with 'Cluster API is not reachable'"
echo "  - Press [O] to view output, or OK to exit"
echo
echo "Press Enter to start..."
read -r

_exec_with_progress "aba --dir sno2-ext day2 --yes" "Day-2: sno2-ext"
rc=$?

echo
echo "Exit code: $rc"
[ "$rc" -eq 0 ] && echo "Result: SUCCESS" || echo "Result: FAILURE (expected — cluster is down)"
