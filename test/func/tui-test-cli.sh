#!/bin/bash
# CLI wrapper for AI-driven TUI testing.
# Allows calling tui-test-lib.sh functions as one-liners.
#
# Usage:
#   bash test/func/tui-test-cli.sh <function> [args...]
#
# Examples:
#   bash test/func/tui-test-cli.sh tui_start
#   bash test/func/tui-test-cli.sh tui_capture
#   bash test/func/tui-test-cli.sh tui_keys Enter
#   bash test/func/tui-test-cli.sh tui_select_item "Day-2"
#   bash test/func/tui-test-cli.sh tui_assert_contains "OperatorHub" "Has OperatorHub"
#   bash test/func/tui-test-cli.sh tui_press_button "Help"
#   bash test/func/tui-test-cli.sh tui_menu_items
#   bash test/func/tui-test-cli.sh tui_buttons
#   bash test/func/tui-test-cli.sh tui_stop

cd "$(dirname "$0")/../.." || exit 1
source test/func/tui-test-lib.sh

fn="$1"
shift

if [[ -z "$fn" ]]; then
	echo "Usage: $0 <function> [args...]" >&2
	echo "" >&2
	echo "Available functions:" >&2
	echo "  tui_start [cmd]        Start TUI in tmux session" >&2
	echo "  tui_stop               Kill TUI session" >&2
	echo "  tui_capture            Print current screen content" >&2
	echo "  tui_keys <keys...>     Send keystrokes" >&2
	echo "  tui_select_item <pat>  Select menu item by label" >&2
	echo "  tui_press_button <pat> Press button by label" >&2
	echo "  tui_menu_items         List KEY<tab>LABEL for each menu item" >&2
	echo "  tui_buttons            List button labels" >&2
	echo "  tui_dialog_title       Print dialog title" >&2
	echo "  tui_back_to <pat> [n]  Escape back to a known screen" >&2
	echo "  tui_wait_for <pat> [t] Wait for pattern (timeout seconds)" >&2
	echo "  tui_wait_gone <pat>[t] Wait for pattern to disappear" >&2
	echo "  tui_wait_isc_done [t]  Wait for ISC generation to finish" >&2
	echo "  tui_screenshot <label> Save screenshot to /tmp/" >&2
	echo "  tui_assert_contains <pat> <desc>    Assert pattern present" >&2
	echo "  tui_assert_not_contains <pat> <desc> Assert pattern absent" >&2
	echo "  tui_assert_appears <pat> <desc> [t]  Assert pattern appears" >&2
	echo "  tui_clear_failed_tasks Clear failed run_once tasks" >&2
	exit 1
fi

if ! declare -f "$fn" >/dev/null 2>&1; then
	echo "Error: unknown function '$fn'" >&2
	exit 1
fi

"$fn" "$@"
