#!/bin/bash
# INTENT:      BM-only gate after ISO: confirm servers are (or will be) booted
#              before BMC boot / monitor. Non-bm is a no-op.
# CALLED BY:   Makefile.cluster (.bm-bmc-boot-done recipe, before bmc-boot.sh)
# CWD:         Cluster directory
#
# BM gates always prompt (ask --always), even when ask=false in aba.conf —
# the operator must confirm boot before mon. Automation: aba install -y.

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

# Cluster dirs symlink aba.conf → ../aba.conf
source <(normalize-aba-conf)
source <(normalize-cluster-conf)
platform=${platform:-bm}

if [ "$platform" != "bm" ]; then
	aba_debug "bm-ask-boot: skip (platform=$platform)"
	exit 0
fi

aba_progress "START|ci_boot"

_arch=$(uname -m)
_iso="$PWD/iso-agent-based/agent.${_arch}.iso"
_total=$(( ${num_masters:-1} + ${num_workers:-0} ))
# Derived count — not a normalize*() output (ADR-005)
_bmc_nodes=$(bmc_host_count)

if [ "${_bmc_nodes:-0}" -gt 0 ]; then
	aba_info "Boot your servers:"
	aba_info "  bmc.conf lists ${_bmc_nodes} node(s) — ABA will mount the ISO via BMC (Redfish)."
	aba_info "  ISO: $_iso"
	aba_info "  Serve the ISO over HTTP reachable from the BMCs and set iso_url= in bmc.conf."
	# Prompt text is what the TUI progress dialog shows (aba_info is log-only).
	if ! ask -y --always "BMC boot ($_bmc_nodes node(s) in bmc.conf)

ISO file:
  $_iso

Yes: ABA mounts the ISO via Redfish and powers nodes.
     Ensure iso_url= in bmc.conf is reachable from each BMC.
No: stop this run only. Fix iso_url / BMC access, then re-run the SAME command (safe to repeat):
    $(aba_cmd install)"; then
		aba_progress "FAIL|ci_boot"
		aba_abort "Aborted. Fix iso_url / BMC, then re-run the same command: $(aba_cmd install)"
	fi
	aba_progress "DONE|ci_boot"
	exit 0
fi

# Manual boot path
aba_info "Boot your servers from the ISO using one of:"
aba_info "  - Virtual media (iLO, iDRAC, BMC): mount $_iso over the management network"
aba_info "  - USB (raw/dd): sudo dd if=$_iso"
aba_info "                  of=/dev/sdX bs=4M conv=fsync status=progress"
aba_info "    Or: $(aba_cmd write-usb)"
if [ "$_total" -gt 1 ]; then
	aba_info "  Prepare one boot medium per server ($_total total); keep media attached during install."
fi
aba_info "  - PXE: serve the ISO via your PXE infrastructure"
aba_info "IMPORTANT: The ISO expires 24 hours after creation — boot and finish within that window."

_multi=""
[ "$_total" -gt 1 ] && _multi="
Boot all $_total servers (one medium each); keep media attached during install."

# --always: prompt even when ask=false (mandatory BM gate). aba -y still skips.
# Prompt text is what the TUI progress dialog shows (aba_info is log-only).
if ! ask -y --always "Boot servers from the agent ISO, then continue to monitor.

ISO file:
  $_iso

How (use another terminal / BMC console / USB writer):
  - Virtual media (iLO/iDRAC/BMC): mount the ISO over the mgmt network
  - USB:  sudo dd if=$_iso
          of=/dev/sdX bs=4M conv=fsync status=progress
          or: $(aba_cmd write-usb)
  - PXE: serve the ISO from your PXE infrastructure$_multi

IMPORTANT: ISO expires 24h after creation — finish install in that window.

Yes: servers are booting (or booted) — start monitoring installation.
No: stop this run only. Boot the servers, then re-run the SAME command (safe to repeat):
    $(aba_cmd install)
    (or continue later with: $(aba_cmd mon))"; then
	aba_progress "FAIL|ci_boot"
	aba_info "Boot the servers, then re-run the same command: $(aba_cmd install)   (or: $(aba_cmd mon))"
	aba_info "Tip: for non-interactive automation use '$(aba_cmd install -y)' after booting, or '$(aba_cmd mon)'."
	exit 1
fi

aba_progress "DONE|ci_boot"
exit 0
