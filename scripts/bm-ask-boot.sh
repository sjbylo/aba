#!/bin/bash
# INTENT:      BM-only gate after ISO: confirm servers are (or will be) booted
#              before BMC boot / monitor. Non-bm is a no-op.
# CALLED BY:   Makefile.cluster (.bm-bmc-boot-done recipe, before bmc-boot.sh)
# CWD:         Cluster directory
#
# ask=false + no BMC nodes uses --auto-no so continuous install does not
# race into monitor before the operator boots servers. Use interactive ask,
# `aba install -y` after booting, or `aba iso` then `aba mon`.

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

_platform=
[ -f ../aba.conf ] && _platform=$(grep -E '^[[:space:]]*platform=' ../aba.conf 2>/dev/null | head -1 | cut -d= -f2 | sed 's/#.*//;s/[[:space:]]//g')
_platform=${_platform:-bm}

if [ "$_platform" != "bm" ]; then
	aba_debug "bm-ask-boot: skip (platform=$_platform)"
	exit 0
fi

aba_progress "START|ci_boot"

_arch=$(uname -m)
_iso="$PWD/iso-agent-based/agent.${_arch}.iso"
_cluster_dir=$(basename "$PWD")
_nm=$(grep '^num_masters=' cluster.conf 2>/dev/null | cut -d= -f2 | awk '{print $1}')
_nw=$(grep '^num_workers=' cluster.conf 2>/dev/null | cut -d= -f2 | awk '{print $1}')
_total=$(( ${_nm:-1} + ${_nw:-0} ))
_bmc_nodes=0
[ -f bmc.conf ] && _bmc_nodes=$(grep -cE '^[[:space:]]*bmc_host_' bmc.conf || true)

if [ "${_bmc_nodes:-0}" -gt 0 ]; then
	aba_info "Boot your servers:"
	aba_info "  bmc.conf lists ${_bmc_nodes} node(s) — ABA will mount the ISO via BMC (Redfish)."
	aba_info "  ISO: $_iso"
	aba_info "  Serve the ISO over HTTP reachable from the BMCs and set iso_url= in bmc.conf."
	if ! ask -y "Proceed with BMC boot from the agent ISO"; then
		aba_progress "FAIL|ci_boot"
		aba_abort "Aborted. Set iso_url, then re-run: aba -d $_cluster_dir install"
	fi
	aba_progress "DONE|ci_boot"
	exit 0
fi

# Manual boot path
aba_info "Boot your servers from the ISO using one of:"
aba_info "  - Virtual media (iLO, iDRAC, BMC): mount $_iso over the management network"
aba_info "  - USB (raw/dd): sudo dd if=$_iso of=/dev/sdX bs=4M conv=fsync status=progress"
aba_info "    Or: aba -d $_cluster_dir write-usb"
if [ "$_total" -gt 1 ]; then
	aba_info "  Prepare one boot medium per server ($_total total); keep media attached during install."
fi
aba_info "  - PXE: serve the ISO via your PXE infrastructure"
aba_info "IMPORTANT: The ISO expires 24 hours after creation — boot and finish within that window."

# Interactive default yes; ask=false without -y refuses so we do not hang in mon
if ! ask -y --auto-no "Have you booted all servers from the ISO and ready to monitor installation"; then
	aba_progress "FAIL|ci_boot"
	aba_info "Boot the servers, then re-run: aba -d $_cluster_dir install   (or: aba -d $_cluster_dir mon)"
	aba_info "Tip: with ask=false use 'aba -d $_cluster_dir install -y' after booting, or 'aba mon'."
	exit 1
fi

aba_progress "DONE|ci_boot"
exit 0
