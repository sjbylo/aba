# HPE iLO 5/6 vendor overlay for Phase 8 BMC-driven boot.
# Sourced (not executed): no shebang, not chmod +x.
# MUST be sourced AFTER scripts/bmc-adapter-generic.sh.
#
# This overlay targets iLO 5 and iLO 6. iLO 4 is hard-failed at preflight by
# _bm_probe_l5_ilo (Redfish VirtualMedia is non-standard on iLO 4 - upgrade to
# iLO 5 or replace hardware is the operator's only recourse).
#
# Vendor-specific Redfish quirks:
#   - Launchpad bug 1958976: iLO can return Inserted=true after a failed mount.
#     Mitigation: re-GET the VirtualMedia resource after a successful POST and
#     confirm the .Image field matches the URL we POSTed. If .Image is empty
#     or differs, treat as InsertMedia failure (returns 1 from the verify hook).
#   - Standard /Managers and /Systems collections (no ID hardcoding).
#   - InsertMedia uses standard POST + Actions/VirtualMedia.InsertMedia (verb +
#     path inherited from generic).
#
# Hardcoded conventions per HPE iLO 5 Redfish API Reference:
#   ManagerId = standard discovery (typically iLO.Embedded.1)
#   MediaId   = standard discovery (CD/DVD MediaTypes)
#   SystemId  = standard discovery (typically 1)

_bm_insert_media_verify() {
	# D-08b: re-GET the VirtualMedia resource after a successful InsertMedia
	# POST. Confirm .Image equals iso_url (the URL we POSTed). If .Image is
	# empty or differs, treat as a false-success failure.
	local node="$1"
	local mgr media path image
	mgr=$(_bm_manager_id "$node")
	media=$(_bm_media_id "$node")
	path="/redfish/v1/Managers/$mgr/VirtualMedia/$media"
	_redfish_request "$node" GET "$path" || return 1
	if [ "${_REDFISH_LAST_CODE:0:1}" != "2" ]; then
		return 1
	fi
	image=$(jq -r '.Image // empty' "$_REDFISH_LAST_BODY")
	[ "$image" = "$iso_url" ]
}

# MAC discovery: generic _bm_get_ethernetinterfaces is sufficient (iLO 5/6 publishes standard EthernetInterfaces).
