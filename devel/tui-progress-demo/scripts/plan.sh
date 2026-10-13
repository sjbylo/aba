#!/bin/bash
# plan.sh — Emit PLAN events for a workflow
#
# Called from PHONY Make targets (_progress_plan-install, _progress_plan-sync, etc.).
# PHONY targets always run, even when file targets are cached.
#
# ─── Key design decisions ───────────────────────────────────────────
#
# 1. EACH PLAN TARGET ONLY KNOWS ITS OWN STEPS.
#    _progress_plan-install emits install PLANs.  _progress_plan-sync emits sync PLANs.
#    When "make sync" triggers install as a dependency, both plan
#    targets fire independently.  The progress dialog grows as new
#    PLANs arrive (two visible batches).
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
		# Uses GLOBAL step IDs so parent workflows (bundle) can pre-declare
		# the same IDs.  The receiver deduplicates by ID — first PLAN wins.
		aba_progress "PLAN|rpms_ext|Install required packages|3"
		aba_progress "PLAN|preflight|Pre-flight checks|2"
		aba_progress "PLAN|sv_tools|Download CLI tools|5"
		aba_progress "PLAN|sv_save|Save images to disk|70"
		aba_progress "PLAN|sv_cli_wait|Wait for CLI tools|5"
		aba_progress "PLAN|sv_finalize|Create transfer archive|3"
		;;

	bundle)
		# Bundle wraps save — pre-declares ALL shared IDs so save's
		# duplicate PLANs are silently absorbed by receiver dedup.
		# sv_finalize is included (save runs it) BEFORE bnd_pack.
		# Result: save's plan adds ZERO new rows — complete dedup.
		aba_progress "PLAN|rpms_ext|Install required packages|3"
		aba_progress "PLAN|preflight|Preflight checks|2"
		aba_progress "PLAN|sv_tools|Download CLI tools|5"
		aba_progress "PLAN|sv_save|Save images|70"
		aba_progress "PLAN|sv_cli_wait|Wait for CLI tools|5"
		aba_progress "PLAN|sv_finalize|Create transfer archive|3"
		aba_progress "PLAN|bnd_pack|Pack bundle|10"
		;;

	uninstall)
		aba_progress "PLAN|uninst_remove|Remove registry|10"
		aba_progress "PLAN|uninst_cleanup|Clean up|3"
		;;

	*)
		echo "[ABA] Unknown workflow: ${1:-<none>}" >&2
		exit 1
		;;
esac
