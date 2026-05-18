# Supermicro X12/X13 vendor overlay for Phase 8 BMC-driven boot.
# Sourced (not executed): no shebang, not chmod +x.
# MUST be sourced AFTER scripts/bmc-adapter-generic.sh.
#
# This overlay targets Supermicro X12 and X13 server platforms.
#
# Vendor-specific Redfish quirks:
#   - Bugzilla 1986238: X12 rejects InsertMedia payloads that include
#     Inserted or WriteProtected fields. Override _bm_insert_media_body to
#     strip them; only Image + TransferProtocolType are sent.
#   - Supermicro X-series exposes the virtual CD as a USB CD device. Override
#     _bm_boot_patch_body to use BootSourceOverrideTarget=UsbCd (Phase 5 L4
#     already accepts UsbCd in BootSourceOverrideTarget@Redfish.AllowableValues).
#   - SFT-DCMS-SINGLE / SFT-OOB-LIC license: VirtualMedia 403 already surfaces
#     at L3 with "VirtualMedia not licensed" (Phase 5 D-14). No L5 license
#     probe added.
#   - AMI MegaRAC OEM 404 fallback (.../Actions/Oem/Ami/VirtualMedia.InsertMedia
#     on 404) is NOT included in v1.1. If lab testing surfaces an AMI MegaRAC
#     board that needs it, a follow-up plan can add an adapter-level redefine
#     of bmc_insert_media. See CONTEXT D-09.
#
# Hardcoded conventions per Supermicro Redfish Reference Guide:
#   ManagerId = standard discovery (typically 1)
#   MediaId   = standard discovery (CD MediaTypes)
#   SystemId  = standard discovery

_bm_insert_media_body() {
	# Strip Inserted + WriteProtected (X12 rejects them per Bugzilla 1986238).
	local iso="$1" out="$2"
	jq -n --arg url "$iso" '{Image:$url, TransferProtocolType:"HTTP"}' > "$out"
}

_bm_boot_patch_body() {
	# UsbCd instead of Cd (X-series exposes virtual CD as USB CD).
	local out="$1"
	printf '%s' '{"Boot":{"BootSourceOverrideTarget":"UsbCd","BootSourceOverrideEnabled":"Once","BootSourceOverrideMode":"UEFI"}}' > "$out"
}

# MAC discovery: generic _bm_get_ethernetinterfaces is sufficient (X12/X13 publishes standard EthernetInterfaces).
