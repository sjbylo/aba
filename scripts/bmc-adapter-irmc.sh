# Fujitsu iRMC vendor overlay for Phase 6 BMC-driven boot.
# Sourced (not executed): no shebang, not chmod +x.
# MUST be sourced AFTER scripts/bmc-adapter-generic.sh. Bash function-redefine-wins
# semantics cause these definitions to replace the generic adapter's discovery-cache
# readers. Apply iRMC-only; generic nodes continue to use the generic helpers.
#
# Hardcoded IDs per DMTF-Redfish-on-iRMC conventions + OpenStack Ironic iRMC driver:
#   ManagerId = iRMC
#   MediaId   = CD
#   SystemId  = 0
#
# Resulting paths on iRMC:
#   /redfish/v1/Managers/iRMC/VirtualMedia/CD
#   /redfish/v1/Managers/iRMC/VirtualMedia/CD/Actions/VirtualMedia.InsertMedia
#   /redfish/v1/Managers/iRMC/VirtualMedia/CD/Actions/VirtualMedia.EjectMedia
#   /redfish/v1/Systems/0
#   /redfish/v1/Systems/0/Actions/ComputerSystem.Reset
#
# ETag-on-PATCH: iRMC strictly requires If-Match on PATCH /Systems/0.
# _bm_patch_if_match_required=true causes _redfish_patch (scripts/bmc-redfish.sh)
# to abort with a synthetic failure instead of issuing an un-If-Match PATCH
# (which iRMC would answer with HTTP 412 Precondition Required).

_bm_manager_id() { printf '%s' "iRMC"; }
_bm_media_id()   { printf '%s' "CD"; }
_bm_system_id()  { printf '%s' "0"; }

_bm_patch_if_match_required=true

# MAC discovery: generic _bm_get_ethernetinterfaces is sufficient; D-06 bond filter handles iRMC's iLO-bond0 entries.
