#!/bin/bash
# plan.sh — Emit PLAN events for a workflow
#
# Called from PHONY Make targets (_plan-install, _plan-sync, etc.).
# PHONY targets always run, even when file targets are cached.
#
# ─── Key design decisions ───────────────────────────────────────────
#
# 1. EACH PLAN TARGET ONLY KNOWS ITS OWN STEPS.
#    _plan-install emits install PLANs.  _plan-sync emits sync PLANs.
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
#    _plan-install checks .available.  If the registry is already
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
#   PLAN|id|text    — declare a step (this file)
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
		aba_progress "PLAN|rpms_ext|Install required packages"
		aba_progress "PLAN|reg_config|Validate configuration"
		aba_progress "PLAN|reg_env|Check environment"
		aba_progress "PLAN|reg_firewall|Configure firewall"
		aba_progress "PLAN|reg_download|Download registry software"
		aba_progress "PLAN|reg_install|Install registry"
		aba_progress "PLAN|reg_trust|Configure trust"
		;;

	sync)
		# Sync only knows about its own steps — never install steps.
		# If install is needed, _plan-install (prereq of install) handles that.
		#
		# Order matches Make's execution of sync prerequisites:
		#   .rpmsint → install → _plan-sync → status-preflight → sync-images.sh
		# So: rpms_int first (Make prereq), then preflight (Make prereq),
		# then catalogs_dl/versions/etc. (inside sync-images.sh).
		aba_progress "PLAN|rpms_int|Install required packages"
		aba_progress "PLAN|preflight|Pre-flight checks"
		# Background CLI download. sync-images.sh kicks it with run_once -i
		# and waits with run_once -w. Both rows stay on the dialog.
		if [ -n "${SIMULATE_BG_DOWNLOAD:-}" ]; then
			aba_progress "PLAN|cli_dl|Download CLI tools"
		fi
		aba_progress "PLAN|catalogs_dl|Download operator catalogs"
		aba_progress "PLAN|versions|Verify release versions"
		aba_progress "PLAN|tools|Prepare tools"
		aba_progress "PLAN|registry|Registry access"
		aba_progress "PLAN|sync|Mirror images"
		aba_progress "PLAN|finalize|Finalize"
		if [ -n "${SIMULATE_BG_DOWNLOAD:-}" ]; then
			aba_progress "PLAN|cli_wait|Wait for CLI tools"
		fi
		;;

	save)
		# Order matches Make's execution:
		#   .rpmsext → status-preflight → save.sh
		# catalogs_dl and preflight are inside save.sh (not Make prereqs).
		aba_progress "PLAN|rpms_ext|Install required packages"
		aba_progress "PLAN|catalogs_dl|Download operator catalogs"
		aba_progress "PLAN|preflight|Pre-flight checks"
		aba_progress "PLAN|sv_tools|Prepare tools"
		aba_progress "PLAN|sv_save|Save images"
		aba_progress "PLAN|sv_finalize|Create transfer archive"
		;;

	uninstall)
		aba_progress "PLAN|uninst_remove|Remove registry"
		aba_progress "PLAN|uninst_cleanup|Clean up"
		;;

	*)
		echo "[ABA] Unknown workflow: ${1:-<none>}" >&2
		exit 1
		;;
esac
