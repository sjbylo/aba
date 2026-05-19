#!/bin/bash
# Shared Redfish stub for functional tests.
# Source this file; do NOT execute directly.
# Provides: _bmc_stub_curl() - argument-dispatch function that maps
#           URL + HTTP verb pairs to canned JSON bodies and synthetic
#           HTTP status codes via a case statement on the URL pattern.
#
# Usage:
#   source test/func/lib/bmc-redfish-stub.sh
#   curl() { _bmc_stub_curl "$@"; }   # override in each Path setup block
#
# Stub config globals (set before each Path):
#   _STUB_AUTH_FAIL=true              # 401 on SessionService/Sessions POST
#   _STUB_LICENSE_MISSING=true        # 403 on VirtualMedia collection GET
#   _STUB_FORBID_TARGET=Cd            # remove this target from AllowableValues
#   _STUB_L1_UNREACHABLE=true         # return non-zero exit (TCP fail simulation)
#   _STUB_CHUNKED=true                # curl -I returns Transfer-Encoding: chunked
#   _STUB_RESET_401=true              # 401 on Systems/*/Actions/ComputerSystem.Reset
#   _STUB_STALE_SESSION=true          # 401 on SessionService/Sessions/* DELETE
#   _STUB_NODE_FAIL=<node>            # 500 on VirtualMedia member for this node
#   _STUB_VENDOR_MODEL=<string>       # override Manager Model field
#   _STUB_FIRMWARE_VERSION=<string>   # override Manager FirmwareVersion field
#   _STUB_POWER_STATE=Off             # ComputerSystem PowerState override
#   _STUB_MEDIA_INSERTED=true         # VirtualMedia member Inserted=true
#   _STUB_MEDIA_CONNECTED=true        # VirtualMedia member Connected=true (post-insert polling)
#   _STUB_202_TASK=true               # InsertMedia returns 202 async task
#   _STUB_MANAGER_ID=<string>         # override Manager ID (default: iRMC)
#   _STUB_USBCD_TARGET=true           # AllowableValues has UsbCd instead of Cd
#
# Phase 10 EthernetInterfaces control flags (TEST-06 MAC discovery scenarios):
#   _STUB_NIC_SCENARIO=<name>         # one of: happy | ambiguous | no-linkup |
#                                     #         bond-entry | http500 |
#                                     #         linkdown-match-op |
#                                     #         empty-collection |
#                                     #         firmware-omits-link-status
#                                     # Drives the EthernetInterfaces collection
#                                     # + per-NIC resource shape. Default: "happy".
#   _STUB_NIC_MACS=<csv>              # comma-separated MAC list to override the
#                                     # scenario-default MACs (zip-aligned with
#                                     # _STUB_NIC_IDS). Default: scenario picks.
#   _STUB_NIC_IDS=<csv>               # comma-separated NIC id list. Default:
#                                     # "NIC.Integrated.1" for happy/single-NIC.
#   _STUB_SYSTEM_ID=<id>              # SystemId path component for the
#                                     # /redfish/v1/Systems/<id>/EthernetInterfaces
#                                     # URIs. Default "0" (matches iRMC + generic);
#                                     # iDRAC scenarios may set "System.Embedded.1".
#
# Output globals (match scripts/bmc-redfish.sh names verbatim):
#   _REDFISH_LAST_CODE                # HTTP status string: "200", "401", etc.
#   _REDFISH_LAST_BODY                # path to temp file holding response body
#   _REDFISH_LAST_REASON              # human-readable reason string
#   _REDFISH_LAST_LOCATION            # Location header value (for 202 task dispatch)
#
# Call log:
#   _STUB_CALL_LOG                    # file path; each call appends "VERB URL\n"
#                                     # set to $(mktemp) before each Path to enable
#                                     # vendor-trace assertions; defaults to /dev/null
#
# curl() interface compatibility:
#   The stub parses -o FILE, -D FILE, -X VERB, -I (HEAD) from the curl argument
#   list. It writes the response body to both _REDFISH_LAST_BODY and the -o FILE
#   target (when present). For session creation (201), it writes X-Auth-Token and
#   Location response headers to the -D FILE target. It prints _REDFISH_LAST_CODE
#   to stdout (satisfying the -w '%{http_code}' capture pattern used by the scripts
#   under test). For -I (HEAD) requests, it writes ISO headers to the -o FILE.

_REDFISH_LAST_CODE=""
_REDFISH_LAST_BODY=""
_REDFISH_LAST_REASON=""
_REDFISH_LAST_LOCATION=""
_STUB_CALL_LOG="${_STUB_CALL_LOG:-/dev/null}"
# _STUB_STATE_FILE: optional path to a temp file used for stateful insert/eject
# tracking across subshell invocations (curl is called inside $(...) so shell
# variable changes are lost). Set to $(mktemp) in _path_setup to enable stateful
# behaviour. When unset, falls back to _STUB_MEDIA_INSERTED/_STUB_MEDIA_CONNECTED.
_STUB_STATE_FILE="${_STUB_STATE_FILE:-}"

# ---------------------------------------------------------------------------
# _stub_emit_* helpers - write DSP0266-conformant JSON to _REDFISH_LAST_BODY
# ---------------------------------------------------------------------------

_stub_emit_empty_body() {
	_REDFISH_LAST_BODY=$(mktemp)
	: > "$_REDFISH_LAST_BODY"
}

_stub_emit_service_root() {
	_REDFISH_LAST_BODY=$(mktemp)
	cat > "$_REDFISH_LAST_BODY" <<'EOF'
{
  "@odata.type": "#ServiceRoot.v1_15_0.ServiceRoot",
  "@odata.id": "/redfish/v1/",
  "Id": "RootService",
  "Name": "Root Service",
  "RedfishVersion": "1.15.0",
  "Managers": { "@odata.id": "/redfish/v1/Managers" },
  "Systems": { "@odata.id": "/redfish/v1/Systems" },
  "SessionService": { "@odata.id": "/redfish/v1/SessionService" }
}
EOF
}

_stub_emit_session_created() {
	_REDFISH_LAST_BODY=$(mktemp)
	cat > "$_REDFISH_LAST_BODY" <<'EOF'
{
  "@odata.id": "/redfish/v1/SessionService/Sessions/1",
  "Id": "1",
  "UserName": "stub-user"
}
EOF
}

_stub_emit_session_collection() {
	_REDFISH_LAST_BODY=$(mktemp)
	cat > "$_REDFISH_LAST_BODY" <<'EOF'
{
  "@odata.id": "/redfish/v1/SessionService/Sessions",
  "Members@odata.count": 0,
  "Members": []
}
EOF
}

_stub_emit_managers_collection() {
	_REDFISH_LAST_BODY=$(mktemp)
	local mgr_id="${_STUB_MANAGER_ID:-iRMC}"
	cat > "$_REDFISH_LAST_BODY" <<EOF
{
  "@odata.id": "/redfish/v1/Managers",
  "Members@odata.count": 1,
  "Members": [{ "@odata.id": "/redfish/v1/Managers/${mgr_id}" }]
}
EOF
}

_stub_emit_manager_resource() {
	_REDFISH_LAST_BODY=$(mktemp)
	local mgr_id="${_STUB_MANAGER_ID:-iRMC}"
	local model="${_STUB_VENDOR_MODEL:-iRMC S6}"
	local fwver="${_STUB_FIRMWARE_VERSION:-3.00P}"
	# _STUB_LENOVO_LICENSE_TIER: when set, inject Oem.Lenovo.LicenseFeatures array.
	# Use "Basic" (no RemoteMedia) to trigger the Lenovo Enterprise license hard-fail.
	# Leave unset (default) to omit the Oem block entirely (aba_debug path, no error).
	local oem_block=""
	if [ -n "${_STUB_LENOVO_LICENSE_TIER:-}" ]; then
		oem_block=",
  \"Oem\": { \"Lenovo\": { \"LicenseFeatures\": [\"${_STUB_LENOVO_LICENSE_TIER}\"] } }"
	fi
	cat > "$_REDFISH_LAST_BODY" <<EOF
{
  "@odata.id": "/redfish/v1/Managers/${mgr_id}",
  "Id": "${mgr_id}",
  "Model": "${model}",
  "FirmwareVersion": "${fwver}",
  "VirtualMedia": { "@odata.id": "/redfish/v1/Managers/${mgr_id}/VirtualMedia" }${oem_block}
}
EOF
}

_stub_emit_virtual_media_collection() {
	_REDFISH_LAST_BODY=$(mktemp)
	local mgr_id="${_STUB_MANAGER_ID:-iRMC}"
	cat > "$_REDFISH_LAST_BODY" <<EOF
{
  "@odata.id": "/redfish/v1/Managers/${mgr_id}/VirtualMedia",
  "Members@odata.count": 1,
  "Members": [{ "@odata.id": "/redfish/v1/Managers/${mgr_id}/VirtualMedia/CD" }]
}
EOF
}

_stub_emit_virtual_media_member() {
	_REDFISH_LAST_BODY=$(mktemp)
	local mgr_id="${_STUB_MANAGER_ID:-iRMC}"
	local inserted="false"
	local connected="false"
	local image=""

	# Determine inserted/connected state. Prefer _STUB_STATE_FILE (survives subshell
	# boundaries via file I/O) over plain shell globals (lost in $(...) subshells).
	local state_inserted="${_STUB_MEDIA_INSERTED:-false}"
	local state_connected="${_STUB_MEDIA_CONNECTED:-false}"
	if [ -n "${_STUB_STATE_FILE:-}" ] && [ -f "$_STUB_STATE_FILE" ]; then
		local sf_ins sf_con
		sf_ins=$(grep '^media_inserted=' "$_STUB_STATE_FILE" | cut -d= -f2)
		sf_con=$(grep '^media_connected=' "$_STUB_STATE_FILE" | cut -d= -f2)
		[ -n "$sf_ins" ] && state_inserted="$sf_ins"
		[ -n "$sf_con" ] && state_connected="$sf_con"
	fi

	if [ "$state_inserted" = "true" ]; then
		inserted="true"
		image="${iso_url:-http://bastion.lab.example:8080/agent.x86_64.iso}"
	fi
	if [ "$state_connected" = "true" ]; then
		connected="true"
		# Connected implies Inserted (media must be present to be connected)
		inserted="true"
		if [ -z "$image" ]; then
			image="${iso_url:-http://bastion.lab.example:8080/agent.x86_64.iso}"
		fi
	fi
	cat > "$_REDFISH_LAST_BODY" <<EOF
{
  "@odata.id": "/redfish/v1/Managers/${mgr_id}/VirtualMedia/CD",
  "Id": "CD",
  "MediaTypes": ["CD", "DVD"],
  "Inserted": ${inserted},
  "Connected": ${connected},
  "Image": "${image}",
  "Actions": {
    "#VirtualMedia.InsertMedia": {
      "target": "/redfish/v1/Managers/${mgr_id}/VirtualMedia/CD/Actions/VirtualMedia.InsertMedia"
    },
    "#VirtualMedia.EjectMedia": {
      "target": "/redfish/v1/Managers/${mgr_id}/VirtualMedia/CD/Actions/VirtualMedia.EjectMedia"
    }
  }
}
EOF
}

_stub_emit_systems_collection() {
	_REDFISH_LAST_BODY=$(mktemp)
	cat > "$_REDFISH_LAST_BODY" <<'EOF'
{
  "@odata.id": "/redfish/v1/Systems",
  "Members@odata.count": 1,
  "Members": [{ "@odata.id": "/redfish/v1/Systems/0" }]
}
EOF
}

_stub_emit_computer_system() {
	_REDFISH_LAST_BODY=$(mktemp)
	local power_state="${_STUB_POWER_STATE:-On}"
	# BootSourceOverrideTarget AllowableValues; honor _STUB_FORBID_TARGET (omit Cd) for L4 negative test
	local allowable_targets='["None", "Cd", "Pxe", "Hdd"]'
	if [ "${_STUB_FORBID_TARGET:-}" = "Cd" ]; then
		allowable_targets='["None", "Pxe", "Hdd"]'
	fi
	if [ "${_STUB_USBCD_TARGET:-false}" = "true" ]; then
		allowable_targets='["None", "UsbCd", "Pxe", "Hdd"]'
	fi
	cat > "$_REDFISH_LAST_BODY" <<EOF
{
  "@odata.id": "/redfish/v1/Systems/0",
  "Id": "0",
  "PowerState": "${power_state}",
  "Boot": {
    "BootSourceOverrideTarget": "None",
    "BootSourceOverrideEnabled": "Disabled",
    "BootSourceOverrideTarget@Redfish.AllowableValues": ${allowable_targets},
    "BootSourceOverrideEnabled@Redfish.AllowableValues": ["Disabled", "Once", "Continuous"]
  }
}
EOF
}

_stub_emit_task_location_body() {
	_REDFISH_LAST_BODY=$(mktemp)
	: > "$_REDFISH_LAST_BODY"
	# Note: real curl emits Location: header; consumer reads from _REDFISH_LAST_LOCATION
	_REDFISH_LAST_LOCATION="/redfish/v1/TaskService/Tasks/1"
}

_stub_emit_task_completed() {
	_REDFISH_LAST_BODY=$(mktemp)
	cat > "$_REDFISH_LAST_BODY" <<'EOF'
{
  "@odata.id": "/redfish/v1/TaskService/Tasks/1",
  "Id": "1",
  "TaskState": "Completed",
  "TaskStatus": "OK"
}
EOF
}

_stub_emit_iso_head() {
	_REDFISH_LAST_BODY=$(mktemp)
	cat > "$_REDFISH_LAST_BODY" <<'EOF'
HTTP/1.1 200 OK
Content-Length: 1073741824
Content-Type: application/octet-stream
EOF
}

_stub_emit_chunked_head() {
	_REDFISH_LAST_BODY=$(mktemp)
	# Include Content-Length so _bm_iso_url_guard's Content-Length check passes
	# and the Transfer-Encoding: chunked check fires (which is the ERR-06 assertion token).
	cat > "$_REDFISH_LAST_BODY" <<'EOF'
HTTP/1.1 200 OK
Content-Length: 1073741824
Transfer-Encoding: chunked
Content-Type: application/octet-stream
EOF
}

# ---------------------------------------------------------------------------
# Phase 10 EthernetInterfaces fixture defaults (TEST-06).
# Each scenario picks MAC and NIC-id lists; tests may override per-Path via
# _STUB_NIC_MACS / _STUB_NIC_IDS for finer control (D-04, D-06, D-10 coverage).
#
# Default MAC pool (DSP0266-conformant lowercase hex):
#   aa:bb:cc:dd:ee:01  primary NIC (happy + linkdown-match-op operator mac_node)
#   aa:bb:cc:dd:ee:02  secondary physical NIC (ambiguous scenario)
#   aa:bb:cc:dd:ee:03  third physical NIC (bond-entry scenario - LinkDown)
# Default NIC-id pool (mirrors iDRAC9 NIC.Integrated.<n> convention; iRMC may
# override via _STUB_NIC_IDS for iLO-bond0 tests per Phase 10 specifics block):
#   NIC.Integrated.1   primary
#   NIC.Integrated.2   secondary
#   iLO-bond0          bond entry (iRMC oddity; D-06 filter drops this)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# _stub_emit_ethernetinterfaces_collection - DSP0266 collection (Members[]).
# Emits one /redfish/v1/Systems/<sys>/EthernetInterfaces/<nic_id> URI per
# entry in the scenario-selected NIC-id list (or _STUB_NIC_IDS override).
# Honors _STUB_SYSTEM_ID (default "0").
# ---------------------------------------------------------------------------

_stub_emit_ethernetinterfaces_collection() {
	_REDFISH_LAST_BODY=$(mktemp)
	local sys="${_STUB_SYSTEM_ID:-0}"
	local ids_csv
	ids_csv=$(_stub_nic_ids_csv)
	local count members="" id
	count=0
	local IFS=','
	for id in $ids_csv; do
		[ -z "$id" ] && continue
		if [ -z "$members" ]; then
			members="{ \"@odata.id\": \"/redfish/v1/Systems/${sys}/EthernetInterfaces/${id}\" }"
		else
			members="${members}, { \"@odata.id\": \"/redfish/v1/Systems/${sys}/EthernetInterfaces/${id}\" }"
		fi
		count=$(( count + 1 ))
	done
	unset IFS
	cat > "$_REDFISH_LAST_BODY" <<EOF
{
  "@odata.id": "/redfish/v1/Systems/${sys}/EthernetInterfaces",
  "Members@odata.count": ${count},
  "Members": [ ${members} ]
}
EOF
}

# ---------------------------------------------------------------------------
# _stub_emit_ethernetinterface_resource <nic_id> <mac> <link_status> <enabled> [interface_type] [name]
# Writes a DSP0266 EthernetInterface resource. When interface_type is "Bond",
# emits InterfaceType: "Bond" so the D-06 filter sees it. When omitted, the
# field is left out (typical physical NIC shape).
# ---------------------------------------------------------------------------

_stub_emit_ethernetinterface_resource() {
	_REDFISH_LAST_BODY=$(mktemp)
	local nic_id="$1"
	local mac="$2"
	local link="$3"
	local enabled="$4"
	local iftype="${5:-}"
	local name="${6:-$nic_id}"
	local sys="${_STUB_SYSTEM_ID:-0}"
	local iftype_block=""
	if [ -n "$iftype" ]; then
		iftype_block=",
  \"InterfaceType\": \"${iftype}\""
	fi
	local link_block=""
	# firmware-omits-link-status path: caller passes empty string for link to
	# request the field be omitted entirely (parser must default to LinkDown).
	if [ -n "$link" ]; then
		link_block=",
  \"LinkStatus\": \"${link}\""
	fi
	cat > "$_REDFISH_LAST_BODY" <<EOF
{
  "@odata.id": "/redfish/v1/Systems/${sys}/EthernetInterfaces/${nic_id}",
  "Id": "${nic_id}",
  "Name": "${name}",
  "MACAddress": "${mac}",
  "InterfaceEnabled": ${enabled}${link_block}${iftype_block}
}
EOF
}

# ---------------------------------------------------------------------------
# _stub_nic_ids_csv / _stub_nic_macs_csv - scenario-aware default list helpers.
# Honors _STUB_NIC_IDS / _STUB_NIC_MACS overrides; otherwise picks scenario
# defaults per the Phase 10 matrix above.
# ---------------------------------------------------------------------------

_stub_nic_ids_csv() {
	if [ -n "${_STUB_NIC_IDS:-}" ]; then
		printf '%s' "$_STUB_NIC_IDS"
		return
	fi
	case "${_STUB_NIC_SCENARIO:-happy}" in
		happy|http500|firmware-omits-link-status)
			printf '%s' "NIC.Integrated.1" ;;
		ambiguous)
			printf '%s' "NIC.Integrated.1,NIC.Integrated.2" ;;
		no-linkup)
			printf '%s' "NIC.Integrated.1,NIC.Integrated.2" ;;
		bond-entry)
			# 3 entries: 1 physical LinkUp + 1 Bond LinkUp (iLO-bond0 iRMC oddity)
			# + 1 physical LinkDown. D-06 drops bond + LinkDown -> singleton survivor.
			printf '%s' "NIC.Integrated.1,iLO-bond0,NIC.Integrated.2" ;;
		linkdown-match-op)
			printf '%s' "NIC.Integrated.1,NIC.Integrated.2" ;;
		empty-collection)
			printf '%s' "" ;;
		*)
			printf '%s' "NIC.Integrated.1" ;;
	esac
}

_stub_nic_macs_csv() {
	if [ -n "${_STUB_NIC_MACS:-}" ]; then
		printf '%s' "$_STUB_NIC_MACS"
		return
	fi
	case "${_STUB_NIC_SCENARIO:-happy}" in
		happy|http500|firmware-omits-link-status)
			printf '%s' "aa:bb:cc:dd:ee:01" ;;
		ambiguous)
			printf '%s' "aa:bb:cc:dd:ee:01,aa:bb:cc:dd:ee:02" ;;
		no-linkup)
			printf '%s' "aa:bb:cc:dd:ee:01,aa:bb:cc:dd:ee:02" ;;
		bond-entry)
			printf '%s' "aa:bb:cc:dd:ee:01,aa:bb:cc:dd:ee:bb,aa:bb:cc:dd:ee:03" ;;
		linkdown-match-op)
			# Operator mac_node aa:bb:cc:dd:ee:01 is on the LinkDown NIC (D-16
			# behavior change: previously-working install can now hard-fail at
			# preflight if the operator-supplied MAC is on a LinkDown NIC).
			printf '%s' "aa:bb:cc:dd:ee:01,aa:bb:cc:dd:ee:02" ;;
		empty-collection)
			printf '%s' "" ;;
		*)
			printf '%s' "aa:bb:cc:dd:ee:01" ;;
	esac
}

# ---------------------------------------------------------------------------
# _stub_nic_resource_for_id - dispatcher: given a nic_id, write the per-NIC
# resource JSON appropriate for the current _STUB_NIC_SCENARIO. Walks the
# zipped (ids, macs) lists to determine which slot this id is in, then picks
# link_status / enabled / interface_type per the scenario row.
# ---------------------------------------------------------------------------

_stub_nic_resource_for_id() {
	local want_id="$1"
	local ids_csv macs_csv
	ids_csv=$(_stub_nic_ids_csv)
	macs_csv=$(_stub_nic_macs_csv)
	local -a ids macs
	local IFS=','
	read -r -a ids <<<"$ids_csv"
	read -r -a macs <<<"$macs_csv"
	unset IFS
	local idx=-1 i
	for i in "${!ids[@]}"; do
		if [ "${ids[$i]}" = "$want_id" ]; then
			idx=$i
			break
		fi
	done
	if [ "$idx" -lt 0 ]; then
		# Unknown id: emit empty body; caller already set 200 code.
		_stub_emit_empty_body
		return
	fi
	local mac="${macs[$idx]}"
	local link="LinkUp" enabled="true" iftype="" name="$want_id"
	case "${_STUB_NIC_SCENARIO:-happy}" in
		happy)
			link="LinkUp"; enabled="true" ;;
		ambiguous)
			link="LinkUp"; enabled="true" ;;
		no-linkup)
			# Both NICs reported LinkDown (D-04 filter drops them -> MAC-04).
			link="LinkDown"; enabled="true" ;;
		bond-entry)
			# Slot 0 physical LinkUp; slot 1 iLO-bond0 (Bond, LinkUp - dropped
			# by D-06); slot 2 physical LinkDown (dropped by D-04). Survivor is
			# slot 0 -> singleton -> happy resolution.
			case "$idx" in
				0) link="LinkUp"; enabled="true"; iftype=""; name="$want_id" ;;
				1) link="LinkUp"; enabled="true"; iftype="Bond"; name="iLO-bond0" ;;
				2) link="LinkDown"; enabled="true"; iftype=""; name="$want_id" ;;
			esac ;;
		linkdown-match-op)
			# Slot 0 (operator's mac_node) is LinkDown -> dropped by D-04.
			# Slot 1 is LinkUp with a different MAC -> survives as singleton.
			# Operator mismatch then triggers MAC-03 in _bm_discover_macs.
			case "$idx" in
				0) link="LinkDown"; enabled="true" ;;
				1) link="LinkUp"; enabled="true" ;;
			esac ;;
		firmware-omits-link-status)
			# LinkStatus key absent; parser defaults to empty -> filter drops it.
			link=""; enabled="true" ;;
		*)
			link="LinkUp"; enabled="true" ;;
	esac
	_stub_emit_ethernetinterface_resource "$want_id" "$mac" "$link" "$enabled" "$iftype" "$name"
}

# ---------------------------------------------------------------------------
# _bmc_stub_reset_globals - call between Paths to clear all _STUB_* config
# ---------------------------------------------------------------------------

_bmc_stub_reset_globals() {
	unset _STUB_AUTH_FAIL _STUB_LICENSE_MISSING _STUB_FORBID_TARGET _STUB_L1_UNREACHABLE
	unset _STUB_CHUNKED _STUB_RESET_401 _STUB_STALE_SESSION _STUB_NODE_FAIL
	unset _STUB_VENDOR_MODEL _STUB_FIRMWARE_VERSION _STUB_POWER_STATE
	unset _STUB_MEDIA_INSERTED _STUB_MEDIA_CONNECTED _STUB_202_TASK _STUB_MANAGER_ID _STUB_USBCD_TARGET
	unset _STUB_LENOVO_LICENSE_TIER _STUB_POST_RESET_401
	# Phase 10 EthernetInterfaces fixture flags (TEST-06).
	unset _STUB_NIC_SCENARIO _STUB_NIC_MACS _STUB_NIC_IDS _STUB_SYSTEM_ID
	# Clear _STUB_STATE_FILE content (reset stateful insert/eject tracking) but keep the path
	# so the next Path can reuse the same file.
	if [ -n "${_STUB_STATE_FILE:-}" ] && [ -f "$_STUB_STATE_FILE" ]; then
		: > "$_STUB_STATE_FILE"
	fi
	_REDFISH_LAST_CODE=""
	_REDFISH_LAST_BODY=""
	_REDFISH_LAST_REASON=""
	_REDFISH_LAST_LOCATION=""
}

# ---------------------------------------------------------------------------
# _bmc_stub_curl - main dispatch function
# ---------------------------------------------------------------------------
# Signature mirrors curl: parses -X VERB, -I (HEAD), -o FILE, -D FILE,
# and the positional URL (http*/https*).
# Sets _REDFISH_LAST_CODE / _REDFISH_LAST_BODY / _REDFISH_LAST_REASON on every
# call. Appends "VERB URL" to $_STUB_CALL_LOG for vendor-trace assertions.
# Prints _REDFISH_LAST_CODE to stdout (satisfying -w '%{http_code}' captures).
# Writes body to the -o FILE target when present (satisfying -o file_path).
# Writes fake response headers to -D FILE when present (satisfying -D header_dump).

_bmc_stub_curl() {
	local verb="GET" url="" head_only="false"
	local write_code="false" out_file="" hdr_file="" has_data="false"
	# Parse $@ scanning for the curl flags actually passed by preflight-check-bm.sh,
	# bmc-redfish.sh, and bmc-boot.sh:
	#   -X VERB                 explicit method
	#   -I  / -sI / combined    HEAD request (handles -I, -sI, and other -*I* forms)
	#   -w '%{http_code}'       request HTTP code on stdout
	#   -o FILE                 body output file
	#   -D FILE                 response-header dump file
	#   --data-binary | -d      request body (auto-POST when -X is absent, mirrors real curl)
	while [ $# -gt 0 ]; do
		case "$1" in
			-X) verb="$2"; shift 2 ;;
			-I|-*I|-*I*) head_only="true"; verb="HEAD"; shift ;;
			-w)
				case "$2" in
					*http_code*) write_code="true" ;;
				esac
				shift 2
				;;
			-o) out_file="$2"; shift 2 ;;
			-D) hdr_file="$2"; shift 2 ;;
			--data-binary|-d) has_data="true"; shift 2 ;;
			http*|https*) url="$1"; shift ;;
			*) shift ;;
		esac
	done
	# Real curl defaults to POST when a request body is given and no -X is set
	if [ "$has_data" = "true" ] && [ "$verb" = "GET" ]; then
		verb="POST"
	fi

	# Append to call log for vendor-trace assertions
	printf '%s %s\n' "$verb" "$url" >> "$_STUB_CALL_LOG"

	# Dispatch on URL pattern (case preferred over key-value lookup for grep-ability)
	case "$url" in
		*/redfish/v1/)
			# _bm_probe_l2 uses Basic-auth GET /redfish/v1/ as its auth check.
			# When _STUB_AUTH_FAIL=true, return 401 here so the L2 auth-fail path fires.
			if [ "${_STUB_AUTH_FAIL:-false}" = "true" ]; then
				_REDFISH_LAST_CODE=401
				_REDFISH_LAST_REASON="Unauthorized"
				_stub_emit_empty_body
			else
				_REDFISH_LAST_CODE=200
				_REDFISH_LAST_REASON=""
				_stub_emit_service_root
			fi
			;;
		*/SessionService/Sessions)
			if [ "${_STUB_AUTH_FAIL:-false}" = "true" ]; then
				_REDFISH_LAST_CODE=401
				_REDFISH_LAST_REASON="Unauthorized"
				_stub_emit_empty_body
			elif [ "$verb" = "POST" ]; then
				_REDFISH_LAST_CODE=201
				_REDFISH_LAST_REASON=""
				_stub_emit_session_created
			else
				_REDFISH_LAST_CODE=200
				_REDFISH_LAST_REASON=""
				_stub_emit_session_collection
			fi
			;;
		*/SessionService/Sessions/*)
			# Session DELETE for stale-session test
			if [ "$verb" = "DELETE" ] && [ "${_STUB_STALE_SESSION:-false}" = "true" ]; then
				_REDFISH_LAST_CODE=401
				_REDFISH_LAST_REASON="Unauthorized (stale session)"
				_stub_emit_empty_body
			else
				_REDFISH_LAST_CODE=204
				_REDFISH_LAST_REASON=""
				_stub_emit_empty_body
			fi
			;;
		*/Managers)
			_REDFISH_LAST_CODE=200
			_REDFISH_LAST_REASON=""
			_stub_emit_managers_collection
			;;
		*/Managers/*/VirtualMedia)
			if [ "${_STUB_LICENSE_MISSING:-false}" = "true" ]; then
				_REDFISH_LAST_CODE=403
				_REDFISH_LAST_REASON="VirtualMedia not licensed"
				_stub_emit_empty_body
			else
				_REDFISH_LAST_CODE=200
				_REDFISH_LAST_REASON=""
				_stub_emit_virtual_media_collection
			fi
			;;
		*/Managers/*/VirtualMedia/*/Actions/VirtualMedia.InsertMedia)
			if [ "${_STUB_202_TASK:-false}" = "true" ]; then
				_REDFISH_LAST_CODE=202
				_REDFISH_LAST_REASON="Accepted"
				_stub_emit_task_location_body
			else
				_REDFISH_LAST_CODE=204
				_REDFISH_LAST_REASON=""
				_stub_emit_empty_body
			fi
			# Stateful: after insert succeeds, write to _STUB_STATE_FILE (survives subshell).
			# Also set shell globals for callers that read them directly (non-subshell paths).
			if [ "${_REDFISH_LAST_CODE:0:1}" = "2" ]; then
				_STUB_MEDIA_INSERTED=true
				_STUB_MEDIA_CONNECTED=true
				if [ -n "${_STUB_STATE_FILE:-}" ]; then
					printf 'media_inserted=true\nmedia_connected=true\n' > "$_STUB_STATE_FILE"
				fi
			fi
			;;
		*/Managers/*/VirtualMedia/*/Actions/VirtualMedia.EjectMedia)
			_REDFISH_LAST_CODE=204
			_REDFISH_LAST_REASON=""
			_stub_emit_empty_body
			# Stateful: after eject, clear inserted+connected.
			_STUB_MEDIA_INSERTED=false
			_STUB_MEDIA_CONNECTED=false
			if [ -n "${_STUB_STATE_FILE:-}" ]; then
				printf 'media_inserted=false\nmedia_connected=false\n' > "$_STUB_STATE_FILE"
			fi
			;;
		*/Managers/*/VirtualMedia/*)
			# VirtualMedia member resource - dispatch by verb
			if [ "$verb" = "PATCH" ]; then
				# Lenovo PATCH-insert path: PATCH on resource (not action endpoint)
				_REDFISH_LAST_CODE=204
				_REDFISH_LAST_REASON=""
				_stub_emit_empty_body
				# Stateful: Lenovo PATCH-insert marks media inserted+connected
				_STUB_MEDIA_INSERTED=true
				_STUB_MEDIA_CONNECTED=true
				if [ -n "${_STUB_STATE_FILE:-}" ]; then
					printf 'media_inserted=true\nmedia_connected=true\n' > "$_STUB_STATE_FILE"
				fi
			elif [ "${_STUB_NODE_FAIL:-}" != "" ] && echo "$url" | grep -q "$_STUB_NODE_FAIL"; then
				_REDFISH_LAST_CODE=500
				_REDFISH_LAST_REASON="stub: forced failure for node $_STUB_NODE_FAIL"
				_stub_emit_empty_body
			else
				_REDFISH_LAST_CODE=200
				_REDFISH_LAST_REASON=""
				_stub_emit_virtual_media_member
			fi
			;;
		*/Managers/*)
			# Manager resource GET (must come after VirtualMedia branches)
			_REDFISH_LAST_CODE=200
			_REDFISH_LAST_REASON=""
			_stub_emit_manager_resource
			;;
		*/TaskService/Tasks/*)
			_REDFISH_LAST_CODE=200
			_REDFISH_LAST_REASON=""
			_stub_emit_task_completed
			;;
		*/Systems)
			_REDFISH_LAST_CODE=200
			_REDFISH_LAST_REASON=""
			_stub_emit_systems_collection
			;;
		*/Systems/*/EthernetInterfaces)
			# Phase 10 TEST-06: EthernetInterfaces COLLECTION GET.
			# Scenario "http500" simulates BMC firmware failure on the collection
			# endpoint (Plan 10-02 MAC-08 path). All other scenarios return 200 +
			# the scenario-default Members[].
			if [ "${_STUB_NIC_SCENARIO:-happy}" = "http500" ]; then
				_REDFISH_LAST_CODE=500
				_REDFISH_LAST_REASON="Internal Server Error (stubbed EthernetInterfaces failure)"
				_stub_emit_empty_body
			else
				_REDFISH_LAST_CODE=200
				_REDFISH_LAST_REASON=""
				_stub_emit_ethernetinterfaces_collection
			fi
			;;
		*/Systems/*/EthernetInterfaces/*)
			# Phase 10 TEST-06: per-NIC EthernetInterface resource GET.
			# Scenario-aware dispatch: extracts the trailing nic_id from the URL
			# and emits the resource body shape per the active scenario.
			# (http500 short-circuits at the collection level; individual NIC
			# GETs are not reached.)
			_REDFISH_LAST_CODE=200
			_REDFISH_LAST_REASON=""
			local _nic_id="${url##*/}"
			_stub_nic_resource_for_id "$_nic_id"
			;;
		*/Systems/*/Actions/ComputerSystem.Reset)
			if [ "${_STUB_RESET_401:-false}" = "true" ]; then
				_REDFISH_LAST_CODE=401
				_REDFISH_LAST_REASON="Unauthorized"
				_stub_emit_empty_body
			else
				_REDFISH_LAST_CODE=204
				_REDFISH_LAST_REASON=""
				_stub_emit_empty_body
				# ERR-05 support: if _STUB_POST_RESET_401=true, arm one-shot 401 on next
				# Systems/* GET (simulates firmware session drop after power cycle).
				# Write to _STUB_STATE_FILE so the flag survives subshell boundaries.
				if [ "${_STUB_POST_RESET_401:-false}" = "true" ]; then
					if [ -n "${_STUB_STATE_FILE:-}" ]; then
						printf 'post_reset_401=true\n' >> "$_STUB_STATE_FILE"
					fi
				fi
			fi
			;;
		*/Systems/*)
			# Bare ComputerSystem GET or PATCH on Boot.
			# ERR-05 support: if post_reset_401=true in state file, return 401 ONCE
			# (one-shot: immediately clear the flag so subsequent polls return 200).
			local _sf_post_reset=""
			if [ -n "${_STUB_STATE_FILE:-}" ] && [ -f "$_STUB_STATE_FILE" ]; then
				_sf_post_reset=$(grep '^post_reset_401=' "$_STUB_STATE_FILE" | cut -d= -f2)
			fi
			if [ "$_sf_post_reset" = "true" ] && [ "$verb" = "GET" ]; then
				# Clear the one-shot flag before returning
				if [ -n "${_STUB_STATE_FILE:-}" ]; then
					sed -i '/^post_reset_401=/d' "$_STUB_STATE_FILE"
				fi
				_REDFISH_LAST_CODE=401
				_REDFISH_LAST_REASON="Unauthorized (session dropped after power cycle)"
				_stub_emit_empty_body
			else
				_REDFISH_LAST_CODE=200
				_REDFISH_LAST_REASON=""
				_stub_emit_computer_system
			fi
			;;
		*)
			# Catch-all for HEAD on iso_url (ERR-06 chunked-transfer guard)
			if [ "$head_only" = "true" ] && [ "${_STUB_CHUNKED:-false}" = "true" ]; then
				_REDFISH_LAST_CODE=200
				_REDFISH_LAST_REASON="Transfer-Encoding: chunked"
				_stub_emit_chunked_head
			elif [ "$head_only" = "true" ]; then
				_REDFISH_LAST_CODE=200
				_REDFISH_LAST_REASON=""
				_stub_emit_iso_head
			elif [ "${_STUB_L1_UNREACHABLE:-false}" = "true" ]; then
				# Simulate TCP failure: curl exit non-zero, no body
				_REDFISH_LAST_CODE="000"
				_REDFISH_LAST_REASON="Connection refused (stubbed L1 unreachable)"
				_stub_emit_empty_body
				# Route body/headers before returning non-zero
				[ -n "$out_file" ] && [ "$out_file" != "/dev/null" ] && \
					cp "$_REDFISH_LAST_BODY" "$out_file"
				printf '%s' "$_REDFISH_LAST_CODE"
				return 7
			else
				_REDFISH_LAST_CODE=404
				_REDFISH_LAST_REASON="stub: no match for $url"
				_stub_emit_empty_body
			fi
			;;
	esac

	# ---------------------------------------------------------------------------
	# Output routing emulates real curl behaviour expected by callers:
	#
	# 1. -o FILE: copy body to the caller-supplied file. For HEAD requests, this
	#    receives the HTTP header block (preflight-check-bm.sh writes ISO HEAD output here).
	# 2. -D FILE: write fake response headers. Session creation gets X-Auth-Token +
	#    Location; patchable-resource GETs get an ETag so the If-Match round-trip in
	#    _redfish_patch_inner succeeds. Everything else gets a minimal status line.
	# 3. Stdout:
	#    - HEAD request without -o and without -w: emit header block (head_out=$(curl -sI ...))
	#    - All other cases: print HTTP code (covers -w '%{http_code}' and code=$(curl ...))
	# ---------------------------------------------------------------------------
	if [ -n "$out_file" ] && [ "$out_file" != "/dev/null" ]; then
		# Both HEAD and GET responses route the body (header block for HEAD) to -o FILE
		cp "$_REDFISH_LAST_BODY" "$out_file"
	fi

	if [ -n "$hdr_file" ] && [ "$hdr_file" != "/dev/null" ]; then
		if [ "$_REDFISH_LAST_CODE" = "201" ] && printf '%s' "$url" | grep -q 'SessionService/Sessions$'; then
			printf 'HTTP/1.1 201 Created\r\nX-Auth-Token: stub-token-abc123\r\nLocation: /redfish/v1/SessionService/Sessions/1\r\nContent-Type: application/json\r\n\r\n' > "$hdr_file"
		elif [ "$verb" = "GET" ] && printf '%s' "$url" | grep -qE '/Systems/[^/]+$|/VirtualMedia/[^/]+$'; then
			printf 'HTTP/1.1 200 OK\r\nETag: "stub-etag-v1"\r\nContent-Type: application/json\r\n\r\n' > "$hdr_file"
		else
			printf 'HTTP/1.1 %s\r\nContent-Type: application/json\r\n\r\n' "$_REDFISH_LAST_CODE" > "$hdr_file"
		fi
	fi

	if [ "$head_only" = "true" ] && [ -z "$out_file" ] && [ "$write_code" = "false" ]; then
		cat "$_REDFISH_LAST_BODY"
	else
		printf '%s' "$_REDFISH_LAST_CODE"
	fi
	return 0
}
