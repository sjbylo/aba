#!/bin/bash
# plan.sh — Emit PLAN events for a workflow
#
# Called from PHONY Make targets (_progress_plan-install, _progress_plan-sync, etc.).
# PHONY targets always run, even when file targets are cached.
#
# ─── Key design decisions ───────────────────────────────────────────
#
# 1. A PARENT ASKS THE CHILD FOR ITS PLAN.
#    The child owns its steps and prints them when called as `script plan`.
#    It does not know who asked.  The parent submits one combined list
#    before any work, so the dialog shows the full task list up front.
#    Upgrade asks day2 (preflight, then day-2, then trigger and wait).
#    Bundle asks save (save's steps, then Pack bundle).
#    Sync does not ask install: install runs only when the mirror is
#    missing, so those two plans still arrive as separate batches.
#
# 2. PLAN ORDER = EXECUTION ORDER.
#    The order of PLANs must match the order Make actually executes
#    the steps.  The auto-complete engine marks predecessors of the
#    active step — if a step appears before the active step in the
#    PLAN list but hasn't run yet, it gets marked Skipped.  If that
#    step later runs (flipping to In Progress), the user sees a
#    confusing Skipped→In Progress transition.
#
#    Example: preflight.sh runs as a Make prerequisite BEFORE
#    sync-images.sh (which contains catalogs_dl).  So the PLAN for
#    preflight must come BEFORE catalogs_dl.
#
# 3. CONDITIONAL EMISSION — check marker files.
#    _progress_plan-install checks .available.  If the registry is already
#    installed, no PLANs are emitted (nothing to show).  This keeps
#    the dialog clean when sync runs with a cached install.
#
# 4. OVER-GENEROUS — declare every step that MIGHT run.
#    Steps that don't actually execute (e.g. RPMs already installed)
#    never receive START/DONE from the scripts and get marked
#    "Skipped" by the TUI engine.
#
# ─── Event protocol ────────────────────────────────────────────────
#
#   PLAN|id|text[|weight] — declare a step (this file); weight defaults to 1
#   START|id        — step began (emitted by work scripts)
#   DONE|id         — step completed (emitted by work scripts)
#   FAIL|id         — step failed (emitted by work scripts)
#   ERROR|id|msg    — error details
#   DETAIL|msg      — extra diagnostic info
#   NEXT|msg        — suggested next step for the user
#   ABORT|msg       — workflow aborted (user said no, etc.)
#   PROMPT|msg      — script is waiting for user input
#   PROMPT_DONE     — input received, script continuing

source "$(dirname "$0")/progress.sh"

# Submit a child's plan.  The child prints PLAN lines and does not
# write the FIFO itself, so the parent controls when they are sent.
_emit_child_plan() {
	local _line
	while IFS= read -r _line; do
		if [ -n "$_line" ]; then
			aba_progress "$_line"
		fi
	done < <(bash "$1" plan)
	return 0
}

# Show PTY info banner (appears first in output log)
echo
echo "┌───────────────────────────────────────────┐"
echo "│  ABA — TUI Progress Demo                  │"
echo "│                                           │"
if [ -t 1 ]; then
	printf '│  isatty(stdout) = \033[1;32mtrue\033[0m                      │\n'
else
	printf '│  isatty(stdout) = \033[1;31mfalse\033[0m                     │\n'
fi
printf '│  Workflow        = %-22s│\n' "${1:-unknown}"
echo "└───────────────────────────────────────────┘"
echo

case "$1" in
	install)
		# Only emit PLANs when install will actually run.
		# When .available exists, the registry is already installed — nothing to do.
		# This prevents 7 Skipped items cluttering the dialog for a cached sync.
		[ -f "${WORK_DIR:-.}/.available" ] && exit 0
		aba_progress "PLAN|rpms_ext|Install required packages|5"
		aba_progress "PLAN|reg_config|Validate configuration|2"
		aba_progress "PLAN|reg_env|Check environment|2"
		aba_progress "PLAN|reg_firewall|Configure firewall|2"
		aba_progress "PLAN|reg_download|Download registry software|10"
		aba_progress "PLAN|reg_install|Install registry|15"
		aba_progress "PLAN|reg_trust|Configure trust|3"
		;;

	sync)
		# Sync only knows about its own steps — never install steps.
		# If install is needed, _progress_plan-install (prereq of install) handles that.
		#
		# Order matches Make's execution of sync prerequisites:
		#   .rpmsint → install → _progress_plan-sync → status-preflight → sync-images.sh
		# So: rpms_int first (Make prereq), then preflight (Make prereq),
		# then catalogs_dl/versions/etc. (inside sync-images.sh).
		aba_progress "PLAN|rpms_int|Install required packages|5"
		aba_progress "PLAN|preflight|Pre-flight checks|2"
		# Background CLI download. sync-images.sh kicks it with run_once -i
		# and waits with run_once -w. Both rows stay on the dialog.
		if [ -n "${SIMULATE_BG_DOWNLOAD:-}" ]; then
			aba_progress "PLAN|cli_dl|Download CLI tools|5"
		fi
		aba_progress "PLAN|catalogs_dl|Download operator catalogs|10"
		aba_progress "PLAN|versions|Verify release versions|2"
		aba_progress "PLAN|tools|Prepare tools|3"
		aba_progress "PLAN|registry|Registry access|2"
		aba_progress "PLAN|sync|Mirror images|70"
		aba_progress "PLAN|finalize|Finalize|2"
		if [ -n "${SIMULATE_BG_DOWNLOAD:-}" ]; then
			aba_progress "PLAN|cli_wait|Wait for CLI tools|5"
		fi
		;;

	save)
		# Order matches Make's execution:
		#   .rpmsext → status-preflight → save.sh
		# The step list lives in save.sh.  Bundle asks for the same list.
		_emit_child_plan "$(dirname "$0")/save.sh"
		;;

	bundle)
		# Bundle always runs save.  Ask save for its plan, then append
		# the pack step.  Save does not know about bundle.
		_emit_child_plan "$(dirname "$0")/save.sh"
		aba_progress "PLAN|bnd_pack|Pack bundle|10"
		;;

	uninstall)
		aba_progress "PLAN|uninst_remove|Remove registry|10"
		aba_progress "PLAN|uninst_cleanup|Clean up|3"
		;;

	day2)
		_emit_child_plan "$(dirname "$0")/day2.sh"
		;;

	upgrade)
		# Upgrade always runs day-2.  Ask day2 for its plan and submit
		# the whole list before any work.  Order matches execution, so
		# auto-complete does not mark Trigger or Wait as No-op while
		# day-2 is still running.  Day-2 does not know about upgrade.
		aba_progress "PLAN|ug_preflight|Preflight checks|2"
		_emit_child_plan "$(dirname "$0")/day2.sh"
		aba_progress "PLAN|ug_trigger|Trigger upgrade|5"
		aba_progress "PLAN|ug_progress|Wait for upgrade|70"
		;;

	*)
		echo "[ABA] Unknown workflow: ${1:-<none>}" >&2
		exit 1
		;;
esac
