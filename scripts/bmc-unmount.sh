#!/bin/bash
# scripts/bmc-unmount.sh - Phase 6 best-effort post-install / cleanup unmount.
#
# Called from three sites:
#   1. scripts/monitor-install.sh success branch (D-14): after install completes OK.
#   2. templates/Makefile.cluster `clean` target (D-15): before rm -f on cluster files.
#   3. templates/Makefile.cluster `reset` target (D-15): before repo-reset cleanup.
#
# Idempotent:
#   - PATCH {"Boot":{"BootSourceOverrideEnabled":"Disabled"}} on already-disabled system
#     returns 2xx (no state change required; DSP0266 PATCH semantics).
#   - POST VirtualMedia.EjectMedia on nothing-mounted returns 2xx on compliant firmware,
#     or 409/500 which the adapter layer (bmc_eject_media in scripts/bmc-adapter-generic.sh)
#     translates to success.
#
# Exit 0 always (D-13 best-effort contract). Per-node failures emit aba_warning and continue.

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

# -----------------------------------------------------------------------------
# INT-03 gate: no bmc.conf or no bmc_host_* keys = nothing to do. Silent exit 0.
# -----------------------------------------------------------------------------
[ -f bmc.conf ] || exit 0
if ! grep -qE '^[[:space:]]*bmc_host_' bmc.conf; then
	exit 0
fi

# -----------------------------------------------------------------------------
# Load bmc.conf and source adapter stack. Mode-0600 enforcement via normalize-bmc-conf.
# -----------------------------------------------------------------------------
source <(normalize-bmc-conf)
source scripts/bmc-redfish.sh
source scripts/bmc-adapter-generic.sh

# -----------------------------------------------------------------------------
# Helper: list node names from bmc.conf in declaration order.
# -----------------------------------------------------------------------------
_bm_node_list() {
	[ -f bmc.conf ] || return 0
	grep -E '^[[:space:]]*bmc_host_[A-Za-z0-9_-]+=' bmc.conf \
		| sed -E 's/^[[:space:]]*bmc_host_([A-Za-z0-9_-]+)=.*/\1/'
}

# -----------------------------------------------------------------------------
# Per-node unmount sequence. Never returns non-zero to the caller; every failure
# surfaces as aba_warning and the loop continues.
# -----------------------------------------------------------------------------
total=0
ok_count=0
failed_list=""

# D-17: positional args = node filter for rollback dispatch (Phase 7 ERR-03).
# Unset/empty = iterate every bmc_host_* in bmc.conf (Phase 6 D-13 behavior preserved).
if [ "$#" -gt 0 ]; then
	node_list="$*"
else
	node_list=$(_bm_node_list)
fi

for node in $node_list; do
	total=$(( total + 1 ))
	type_var="bmc_type_${node}"
	adapter="${!type_var}"

	# Per-node sourced-overlay dispatch (D-01). Re-source generic to revert any prior
	# iRMC overlay before applying the current node's overlay.
	source scripts/bmc-adapter-generic.sh
	_bm_patch_if_match_required=false
	if [ "$adapter" = "irmc" ]; then
		source scripts/bmc-adapter-irmc.sh
	fi

	# Session login.
	if ! bmc_session_login "$node"; then
		# bmc_session_login already emitted the UX-02 line per D-10.
		failed_list="$failed_list $node"
		continue
	fi

	# Discover IDs (needed for both the PATCH and the EjectMedia targets).
	if ! bmc_discover_ids "$node"; then
		aba_warning "BMC: $node phase=discover (unmount) adapter=$adapter http=$_REDFISH_LAST_CODE reason=\"$_REDFISH_LAST_REASON\""
		bmc_session_logout "$node"
		failed_list="$failed_list $node"
		continue
	fi

	# Step A: BMC-06 - PATCH BootSourceOverrideEnabled=Disabled. Do NOT skip step B on failure.
	bso_rc=0
	if ! bmc_boot_override_disable "$node"; then
		aba_warning "BMC: $node phase=boot-override-disable (unmount) adapter=$adapter http=$_REDFISH_LAST_CODE reason=\"$_REDFISH_LAST_REASON\""
		bso_rc=1
	fi

	# Step B: BMC-07 - POST VirtualMedia.EjectMedia. Adapter layer tolerates nothing-to-eject.
	eject_rc=0
	if ! bmc_eject_media "$node"; then
		aba_warning "BMC: $node phase=eject (unmount) adapter=$adapter http=$_REDFISH_LAST_CODE reason=\"$_REDFISH_LAST_REASON\""
		eject_rc=1
	fi

	# Session logout (best-effort).
	bmc_session_logout "$node"

	if [ "$bso_rc" = "0" ] && [ "$eject_rc" = "0" ]; then
		ok_count=$(( ok_count + 1 ))
	else
		failed_list="$failed_list $node"
	fi
done

# Final summary line. Success line is quiet-on-success-ish; UX-04 says quiet is default
# but for a cleanup action an explicit confirmation helps operators know it ran.
if [ "$ok_count" = "$total" ]; then
	aba_info_ok "BMC: unmount $ok_count/$total nodes"
else
	aba_warning "BMC: unmount $ok_count/$total nodes (failed:$failed_list)"
fi

exit 0
