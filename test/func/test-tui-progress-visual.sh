#!/bin/bash
# Visual test: run a simulated day2 workflow through the real TUI progress engine.
# Run this interactively on a terminal (needs dialog).
# Usage: bash test/func/test-tui-progress-visual.sh

set -e

cd "$(cd "$(dirname "$0")/../.." && pwd -P)"

source scripts/include_all.sh
source tui/v2/tui-progress.sh

# Simulated day2 script — emits the same events real day2.sh would
_sim_day2() {
	source scripts/include_all.sh

	aba_progress "PLAN|access|Accessing cluster"
	aba_progress "PLAN|credentials|Registry credentials"
	aba_progress "PLAN|trustca|Registry trust CA"
	aba_progress "PLAN|resources|IDMS/ITMS resources"
	aba_progress "PLAN|catalogs|CatalogSources"
	aba_progress "PLAN|signatures|Release signatures"
	aba_progress "PLAN|manifests|Custom manifests"
	aba_progress "PLAN|stabilize|Cluster stabilization"

	echo "[ABA] Simulating day2 workflow..."
	sleep 0.5

	aba_progress "START|access"
	echo "[ABA] Resolving kubeconfig..."
	sleep 1
	echo "[ABA] Checking cluster API..."
	sleep 0.5
	echo "[ABA] oc whoami: system:admin"
	aba_progress "DONE|access"

	aba_progress "START|credentials"
	echo "[ABA] Checking cluster pull secret..."
	sleep 0.8
	echo "[ABA] Disabled default catalog sources (disconnected mode)"
	aba_progress "DONE|credentials"

	aba_progress "START|trustca"
	echo "[ABA] Adding mirror registry CA to cluster trust store..."
	sleep 1.5
	echo "[ABA] Patching image.config.openshift.io..."
	sleep 1
	echo "[ABA] Waiting for imagestream API..."
	sleep 0.5
	aba_progress "DONE|trustca"

	aba_progress "START|resources"
	echo "[ABA] Applying idms-oc-mirror.yaml..."
	sleep 0.8
	echo "[ABA] Applying itms-oc-mirror.yaml..."
	sleep 0.5
	aba_progress "DONE|resources"

	aba_progress "START|catalogs"
	echo "[ABA] Applying CatalogSource: redhat-operators"
	sleep 1
	echo "[ABA] Applying CatalogSource: certified-operators"
	sleep 0.5
	echo "[ABA] Waiting for CatalogSources to become READY..."
	sleep 2
	echo "[ABA] CatalogSource redhat-operators is ready!"
	echo "[ABA] CatalogSource certified-operators is ready!"
	aba_progress "DONE|catalogs"

	aba_progress "START|signatures"
	echo "[ABA] Applying release signatures..."
	sleep 0.8
	aba_progress "DONE|signatures"

	aba_progress "START|manifests"
	echo "[ABA] No custom manifests directory found (this is optional)"
	sleep 0.3
	aba_progress "DONE|manifests"

	aba_progress "START|stabilize"
	echo "[ABA] Day-2 configuration applied. Waiting for cluster to stabilize..."
	sleep 2
	echo "[ABA] Cluster operators are stable."
	sleep 0.5
	aba_progress "DONE|stabilize"

	echo "[ABA] Day-2 configuration completed successfully."
}

export -f _sim_day2

echo "=== TUI Progress Visual Test ==="
echo "This will show the day2 progress dialog."
echo "Controls: [O] = view output, [Q] = quit"
echo
echo "Press Enter to start..."
read -r

_exec_with_progress "bash -c _sim_day2" "Day-2: Configure OperatorHub"
rc=$?

echo
if [ "$rc" -eq 0 ]; then
	echo "Result: SUCCESS (rc=0)"
elif [ "$rc" -eq 2 ]; then
	echo "Result: FALLBACK (rc=2) — no PLAN events received"
else
	echo "Result: FAILURE (rc=$rc)"
fi
