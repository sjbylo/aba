#!/bin/bash
# plan.sh — Emit PLAN events for a workflow
# Called from a .PHONY Make target (_plan-save, _plan-load, etc.)
# which always runs — even when other targets are cached.

source "$(dirname "$0")/progress.sh"

# Show PTY info banner (appears first in output log)
echo
echo "┌───────────────────────────────────────────┐"
echo "│  ABA Mirror — PTY + Make Demo             │"
echo "│                                           │"
if [ -t 1 ]; then
	printf '│  isatty(stdout) = \033[1;32mtrue\033[0m                      │\n'
else
	printf '│  isatty(stdout) = \033[1;31mfalse\033[0m                     │\n'
fi
printf '│  TERM            = %-22s│\n' "${TERM:-unset}"
printf '│  Columns         = %-22s│\n' "$(tput cols 2>/dev/null || echo unknown)"
echo "└───────────────────────────────────────────┘"
echo

case "$1" in
	save)
		aba_progress "PLAN|init|Initialize workspace"
		aba_progress "PLAN|rpms|Install required packages"
		aba_progress "PLAN|isc|Generate image set config"
		aba_progress "PLAN|preflight|Pre-flight checks"
		aba_progress "PLAN|mirror|Mirror images (oc-mirror)"
		aba_progress "PLAN|catalog|Build operator catalog"
		aba_progress "PLAN|verify|Verify mirror content"
		;;
	*)
		echo "[ABA] Unknown workflow: ${1:-<none>}" >&2
		exit 1
		;;
esac
