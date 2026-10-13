#!/bin/bash
# Proto TUI: ALL output stays inside dialog widgets. No raw terminal.
# Every step redraws as a dialog. Progress shown via dialog --gauge.
#
# Requires: dialog (install with: dnf install dialog)
#
# Key insight for TUI:
# - Confirmation prompts are dialog --yesno BEFORE Make runs
# - Progress shown via dialog --gauge (percentage) with step labels
# - Final result shown in dialog --msgbox
# - User-abort = user says "No" to yesno = Make never called = no error possible

cd "$(dirname "$0")"

rm -f .user-abort 2>/dev/null || true

TMP=$(mktemp)
FIFO="/tmp/proto-tui-$$"
trap 'rm -f "$TMP" "$FIFO" /tmp/proto-tui-rc-$$' EXIT

BACKTITLE="ABA Proto TUI  |  Cluster: demo1.example.com"
STEPS_CONF="./steps.conf"

# Load step definitions for a command
_load_steps() {
	local target="$1"
	local line
	line=$(grep "^${target}=" "$STEPS_CONF" 2>/dev/null | head -1)
	[[ -z "$line" ]] && echo "" && return
	echo "${line#*=}"
}

# Run a multi-step command showing progress in a dialog --gauge.
# The gauge updates as @@STEP markers arrive.
_tui_run_with_gauge() {
	local cmd="$1"
	local title="$2"

	local steps_str
	steps_str=$(_load_steps "$cmd")

	# Parse steps
	local -a ids=()
	local -A labels=()
	if [[ -n "$steps_str" ]]; then
		IFS=',' read -ra pairs <<< "$steps_str"
		for pair in "${pairs[@]}"; do
			ids+=("${pair%%|*}")
			labels["${pair%%|*}"]="${pair#*|}"
		done
	fi
	local total=${#ids[@]}
	[[ $total -eq 0 ]] && total=1

	# Create fifo for event communication
	mkfifo "$FIFO"

	# Run make in background, parse markers, write events to fifo
	local _rc_file="/tmp/proto-tui-rc-$$"
	(
		set +e
		make -s "$cmd" 2>&1 | while IFS= read -r line; do
			if [[ "$line" =~ ^@@STEP:([^:]+):(.+)$ ]]; then
				echo "${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"
			fi
		done
		echo "${PIPESTATUS[0]:-0}" > "$_rc_file"
		echo "FINISHED"
	) > "$FIFO" &
	local bg_pid=$!

	# Feed the gauge dialog from fifo events
	(
		local completed=0
		local pct=0
		while IFS= read -r event; do
			[[ "$event" == "FINISHED" ]] && break
			local eid="${event%%:*}"
			local eaction="${event#*:}"
			case "$eaction" in
				start)
					echo "XXX"
					echo "$pct"
					echo "\n  ► ${labels[$eid]:-$eid} ..."
					echo "XXX"
					;;
				done)
					completed=$(( completed + 1 ))
					pct=$(( completed * 100 / total ))
					echo "XXX"
					echo "$pct"
					echo "\n  ✓ ${labels[$eid]:-$eid}"
					echo "XXX"
					;;
			esac
		done < "$FIFO"
		echo "100"
	) | dialog --no-shadow --backtitle "$BACKTITLE" --title " $title " \
		--gauge "\n  Preparing..." 8 55 0

	wait "$bg_pid" 2>/dev/null
	local _make_rc=0
	[[ -f "$_rc_file" ]] && _make_rc=$(<"$_rc_file")
	rm -f "$FIFO" "$_rc_file"

	# Show completion, error with Retry, or abort
	if [[ -f .user-abort ]]; then
		rm -f .user-abort
		dialog --no-shadow --backtitle "$BACKTITLE" --title " $title " \
			--msgbox "\n  Aborted by user." 7 35
	elif [[ "$_make_rc" -ne 0 ]]; then
		# Error — offer Retry
		local _btn_rc=0
		dialog --no-shadow --backtitle "$BACKTITLE" --title " $title — Error " \
			--yes-label "Retry" \
			--no-label "OK" \
			--yesno "\n  A step failed (exit $_make_rc).\n\n  Retry the operation?" 9 45 || _btn_rc=$?
		if [[ "$_btn_rc" -eq 0 ]]; then
			_tui_run_with_gauge "$cmd" "$title"
			return $?
		fi
	else
		# Build summary
		local summary="\n"
		for id in "${ids[@]}"; do
			summary+="  ✓  ${labels[$id]}\n"
		done
		summary+="\n  All steps completed successfully."
		dialog --no-shadow --backtitle "$BACKTITLE" --title " $title — Done " \
			--msgbox "$summary" $(( total + 7 )) 50
	fi
}

# Run a command with a confirmation prompt (dialog --yesno).
# If user says No → never calls Make → no error.
_tui_run_with_confirm() {
	local cmd="$1"
	local title="$2"
	local question="$3"

	# Confirmation via dialog
	dialog --no-shadow --backtitle "$BACKTITLE" --title " $title " \
		--yesno "\n$question" 8 50
	if [[ $? -ne 0 ]]; then
		dialog --no-shadow --backtitle "$BACKTITLE" --title " $title " \
			--msgbox "\n  Aborted by user." 7 35
		return 0
	fi

	# User said Yes -- run non-interactively (scripts auto-accept their own ask)
	export ABA_NOASK=1
	_tui_run_with_gauge "$cmd" "$title"
	unset ABA_NOASK
}

# Main menu loop
while true; do
	dialog --no-shadow --backtitle "$BACKTITLE" --title " Main Menu " \
		--cancel-label "Exit" \
		--menu "\nSelect an action:" 16 50 6 \
		"install"  "Install cluster (full pipeline)" \
		"day2"     "Apply day-2 configuration" \
		"shutdown" "Graceful cluster shutdown" \
		"delete"   "Delete cluster VMs" \
		"status"   "Show cluster status" \
		"clean"    "Reset state (re-run install)" \
		2>"$TMP"

	rc=$?
	[[ $rc -ne 0 ]] && break

	choice=$(<"$TMP")

	case "$choice" in
		install)
			_tui_run_with_gauge "install" "Install Cluster"
			;;
		day2)
			_tui_run_with_gauge "day2" "Day-2 Configuration"
			;;
		shutdown)
			_tui_run_with_confirm "shutdown" "Graceful Shutdown" \
				"Gracefully shut down the cluster?\n\n  Nodes: master-0, master-1, master-2"
			;;
		delete)
			_tui_run_with_confirm "delete" "Delete Cluster" \
				"Delete all virtual machines?\n\n  master-0, master-1, master-2\n\n  This cannot be undone!"
			;;
		status)
			status_msg=""
			if [[ -f .monitor-done ]]; then
				status_msg="\n  Cluster: demo1.example.com\n  Status:  Installed ✓\n  Since:   $(stat -c '%y' .monitor-done 2>/dev/null | cut -d. -f1)"
			elif [[ -f .preflight-done ]]; then
				status_msg="\n  Cluster: demo1.example.com\n  Status:  Partially installed\n\n  Run 'install' to continue."
			else
				status_msg="\n  Cluster: demo1.example.com\n  Status:  Not installed"
			fi
			dialog --no-shadow --backtitle "$BACKTITLE" --title " Cluster Status " \
				--msgbox "$status_msg" 10 55
			;;
		clean)
			make clean >/dev/null 2>&1
			dialog --no-shadow --backtitle "$BACKTITLE" --title " Clean " \
				--msgbox "\n  State files removed.\n  You can re-run 'install' now." 8 45
			;;
	esac
done

clear
