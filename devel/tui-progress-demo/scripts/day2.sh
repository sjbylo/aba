#!/bin/bash
# Day-2 object. `day2.sh plan` prints this object's steps.
# The caller submits them. This script does not know about upgrade.

source "$(dirname "$0")/progress.sh"

day2_plan() {
	cat <<'EOF'
PLAN|access|Accessing cluster|3
PLAN|credentials|Registry credentials|5
PLAN|trustca|Registry trust CA|5
PLAN|resources|IDMS/ITMS resources|10
PLAN|catalogs|CatalogSources|10
PLAN|signatures|Release signatures|5
PLAN|manifests|Custom manifests|5
PLAN|stabilize|Cluster stabilization|20
EOF
}

if [ "${1:-}" = "plan" ]; then
	day2_plan
	exit 0
fi

_step() {
	local id="$1" msg="$2" secs="$3"
	aba_progress "START|$id"
	printf '\033[1;34m[ABA]\033[0m %s\n' "$msg"
	sleep "$secs"
	printf '\033[1;32m[ABA]\033[0m Done.\n'
	aba_progress "DONE|$id"
}

_step access "Accessing the cluster ..." 0.4
_step credentials "Writing registry credentials ..." 0.4
_step trustca "Installing the registry CA ..." 0.4
_step resources "Applying IDMS and ITMS ..." 0.5
_step catalogs "Applying CatalogSources ..." 0.5
_step signatures "Applying release signatures ..." 0.4
printf '\033[1;34m[ABA]\033[0m No custom manifests.\n'
aba_progress "NOOP|manifests"
_step stabilize "Waiting for cluster operators to settle ..." 1.4
