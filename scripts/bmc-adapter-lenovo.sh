# Lenovo XCC (XClarity Controller) vendor overlay for Phase 8 BMC-driven boot.
# Sourced (not executed): no shebang, not chmod +x.
# MUST be sourced AFTER scripts/bmc-adapter-generic.sh.
#
# This overlay targets Lenovo ThinkSystem servers running XCC firmware.
#
# Vendor-specific Redfish quirks:
#   - InsertMedia uses PATCH on the VirtualMedia resource itself, NOT POST
#     to a /Actions/VirtualMedia.InsertMedia endpoint. Per Lenovo XCC REST API
#     Guide, PATCH semantics merge the Image and TransferProtocolType fields
#     into the existing resource state.
#   - PATCH semantics mean Inserted and WriteProtected must NOT be sent (they
#     conflict with the BMC-managed current state).
#   - ETag-on-PATCH: inherited transparently via Phase 6 D-04. _redfish_request
#     dispatches PATCH through _redfish_patch which handles If-Match.
#   - Phase 7 D-01 retry envelope wraps the inner curl call regardless of verb.
#   - Enterprise license required for VirtualMedia (Red Hat KCS 6958685).
#     Enforced in _bm_probe_l5_lenovo (preflight; not adapter).
#
# Hardcoded conventions per Lenovo XCC REST API Guide:
#   ManagerId = standard discovery (typically 1)
#   MediaId   = standard discovery (CD MediaTypes; XCC uses EXT slot mapping
#               EXT1-EXT4 for remote-mount slots).
#   SystemId  = standard discovery (typically 1)

_bm_insert_media_verb() { printf '%s' "PATCH"; }

_bm_insert_media_path() {
	# Resource path itself (no /Actions/VirtualMedia.InsertMedia suffix).
	printf '%s' "/redfish/v1/Managers/$(_bm_manager_id "$1")/VirtualMedia/$(_bm_media_id "$1")"
}

_bm_insert_media_body() {
	# PATCH semantics: send only Image + TransferProtocolType; Inserted and
	# WriteProtected are managed by XCC and conflict if sent.
	local iso="$1" out="$2"
	jq -n --arg url "$iso" '{Image:$url, TransferProtocolType:"HTTP"}' > "$out"
}

# MAC discovery: generic _bm_get_ethernetinterfaces is sufficient (XCC publishes standard EthernetInterfaces).
