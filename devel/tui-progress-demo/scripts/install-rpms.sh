#!/bin/bash
# install-rpms.sh — Install required packages (conditional)
# Emits START/DONE only when packages actually need installing.
# When all packages are present, does nothing — the PLAN step
# becomes "Skipped" in the progress dialog.
source "$(dirname "$0")/progress.sh"

mode="${1:-external}"

# Determine plan ID based on mode
[[ "$mode" == "internal" ]] && plan_id="rpms_int" || plan_id="rpms_ext"

# Simulate: check if FORCE_RPM_INSTALL is set to simulate needing packages
if [ -n "${FORCE_RPM_INSTALL:-}" ]; then
	aba_progress "START|$plan_id"
	printf '\033[1;34m[ABA]\033[0m Installing required packages (%s) ...\n' "$mode"
	sleep 1.5
	printf '\033[1;32m[ABA]\033[0m Packages installed.\n'
	aba_progress "DONE|$plan_id"
else
	# Packages already installed — no START/DONE → shows as "Skipped"
	printf '\033[0;90m[ABA] All required packages already installed (%s)\033[0m\n' "$mode"
fi
