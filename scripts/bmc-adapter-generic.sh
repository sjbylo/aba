# Generic DSP0266-compliant Redfish adapter for Phase 6 BMC-driven boot.
# Sourced (not executed): no shebang, not chmod +x.
# Must be sourced AFTER scripts/bmc-redfish.sh (provides _redfish_request + session helpers).
#
# Provides the bmc_* action functions that scripts/bmc-boot.sh and scripts/bmc-unmount.sh call.
# Vendor overlays (scripts/bmc-adapter-irmc.sh and Phase 8 stretch vendors) redefine the
# _bm_<helper> path/body helpers below via bash function-redefine-wins semantics.
#
# VEN-02: this is the fallback adapter for bmc_type=redfish and the base for every vendor overlay.
#
# Invariants:
#   - Every HTTP call goes through _redfish_request (no direct invocations of curl).
#   - Every counter uses var=$(( var + 1 )).
#   - jq is called only after _REDFISH_LAST_CODE is a 2xx/3xx (wrapper gates body validity).
#   - UX-01 success lines and UX-02 failure lines are emitted by the ORCHESTRATOR (bmc-boot.sh),
#     not by this file. Action functions just populate _REDFISH_LAST_* and return 0/1.

# -----------------------------------------------------------------------------
# Overridable path helpers (D-02). Vendor overlays redefine these functions.
# Default implementations read from per-node discovery cache populated by
# bmc_discover_ids (printf -v MANAGER_ID_<node> / MEDIA_ID_<node> / SYSTEM_ID_<node>).
# -----------------------------------------------------------------------------

_bm_manager_id() {
	local node="$1"
	local v="MANAGER_ID_${node}"
	printf '%s' "${!v}"
}

_bm_media_id() {
	local node="$1"
	local v="MEDIA_ID_${node}"
	printf '%s' "${!v}"
}

_bm_system_id() {
	local node="$1"
	local v="SYSTEM_ID_${node}"
	printf '%s' "${!v}"
}

_bm_401_taxonomy() {
	# Phase 6 stub per CONTEXT assumption A3. Plan 03's iRMC adapter may override.
	# Takes a response body tempfile path; returns a short clause for UX-02 reason.
	printf '%s' "unknown"
}

# ETag auto-detect unless adapter overrides (D-04).
_bm_patch_if_match_required=false

# -----------------------------------------------------------------------------
# Verb + path helpers for InsertMedia (Phase 8 D-07; supports Lenovo PATCH-insert).
# Default: POST verb + the InsertMedia action path (preserves iRMC + generic behavior).
# Lenovo overlay overrides verb to PATCH and path to the resource itself.
# -----------------------------------------------------------------------------

_bm_insert_media_verb() { printf '%s' "POST"; }

_bm_insert_media_path() {
	local node="$1"
	local mgr media
	mgr=$(_bm_manager_id "$node")
	media=$(_bm_media_id "$node")
	printf '%s' "/redfish/v1/Managers/$mgr/VirtualMedia/$media/Actions/VirtualMedia.InsertMedia"
}

# Optional post-insert verification hook (D-08b). Default no-op; iLO redefines
# to re-GET .Image and confirm the URL we POSTed actually stuck (Launchpad 1958976).
_bm_insert_media_verify() { return 0; }

# -----------------------------------------------------------------------------
# Body helpers - write JSON to a tempfile path given as argument.
# -----------------------------------------------------------------------------

_bm_insert_media_body() {
	# Writes InsertMedia payload JSON to tempfile given as arg 2. iso_url given as arg 1.
	# Vendor overlays (Supermicro X12 in Phase 8) may strip Inserted + WriteProtected.
	local iso="$1" out="$2"
	jq -n --arg url "$iso" \
		'{Image:$url, Inserted:true, WriteProtected:true, TransferProtocolType:"HTTP"}' \
		> "$out"
}

_bm_boot_patch_body() {
	# Writes Boot PATCH payload JSON (set override to Cd/Once/UEFI) to tempfile given as arg 1.
	local out="$1"
	printf '%s' '{"Boot":{"BootSourceOverrideTarget":"Cd","BootSourceOverrideEnabled":"Once","BootSourceOverrideMode":"UEFI"}}' > "$out"
}

# -----------------------------------------------------------------------------
# bmc_discover_ids - populate per-node ID cache (MANAGER_ID_<node>, MEDIA_ID_<node>,
# SYSTEM_ID_<node>) via Redfish collection GETs. iRMC overlay short-circuits
# these GETs by redefining _bm_manager_id/_bm_media_id/_bm_system_id directly.
# -----------------------------------------------------------------------------

bmc_discover_ids() {
	local node="$1"

	# Managers collection -> first member.
	_redfish_request "$node" GET "/redfish/v1/Managers"
	if [ "${_REDFISH_LAST_CODE:0:1}" != "2" ]; then
		_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "HTTP ${_REDFISH_LAST_CODE} on /redfish/v1/Managers")
		return 1
	fi
	local mgr_link mgr_id
	mgr_link=$(jq -r '.Members[0]."@odata.id" // empty' "$_REDFISH_LAST_BODY")
	if [ -z "$mgr_link" ]; then
		_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "Managers collection empty")
		return 1
	fi
	mgr_id="${mgr_link##*/}"
	printf -v "MANAGER_ID_${node}" '%s' "$mgr_id"

	# VirtualMedia: walk members, pick first with CD/DVD in MediaTypes AND InsertMedia action target.
	_redfish_request "$node" GET "${mgr_link}/VirtualMedia"
	if [ "${_REDFISH_LAST_CODE:0:1}" != "2" ]; then
		_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "HTTP ${_REDFISH_LAST_CODE} on VirtualMedia collection")
		return 1
	fi
	local members m has_cd has_action media_id=""
	members=$(jq -r '.Members[]."@odata.id"' "$_REDFISH_LAST_BODY")
	for m in $members; do
		_redfish_request "$node" GET "$m" || continue
		if [ "${_REDFISH_LAST_CODE:0:1}" != "2" ]; then
			continue
		fi
		has_cd=$(jq -r '[.MediaTypes[]?] | map(select(. == "CD" or . == "DVD")) | length' "$_REDFISH_LAST_BODY")
		has_action=$(jq -r '.Actions["#VirtualMedia.InsertMedia"].target // empty' "$_REDFISH_LAST_BODY")
		case "$has_cd" in
			''|*[!0-9]*) has_cd=0 ;;
		esac
		if [ "$has_cd" -gt 0 ] && [ -n "$has_action" ]; then
			media_id="${m##*/}"
			break
		fi
	done
	if [ -z "$media_id" ]; then
		_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "no VirtualMedia slot accepts CD or DVD InsertMedia")
		return 1
	fi
	printf -v "MEDIA_ID_${node}" '%s' "$media_id"

	# Systems collection -> first member.
	_redfish_request "$node" GET "/redfish/v1/Systems"
	if [ "${_REDFISH_LAST_CODE:0:1}" != "2" ]; then
		_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "HTTP ${_REDFISH_LAST_CODE} on /redfish/v1/Systems")
		return 1
	fi
	local sys_link sys_id
	sys_link=$(jq -r '.Members[0]."@odata.id" // empty' "$_REDFISH_LAST_BODY")
	if [ -z "$sys_link" ]; then
		_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "Systems collection empty")
		return 1
	fi
	sys_id="${sys_link##*/}"
	printf -v "SYSTEM_ID_${node}" '%s' "$sys_id"
	aba_debug "BMC: $node discover ok (manager=$mgr_id media=$media_id system=$sys_id)"
	return 0
}

# -----------------------------------------------------------------------------
# bmc_eject_media - BMC-02 stale-media pre-check + conditional eject.
# Idempotent: skip if Inserted=false. Tolerates 409 and 500 as success (D-02).
# Poll ceiling: 10s at 1s interval.
# -----------------------------------------------------------------------------

bmc_eject_media() {
	local node="$1"
	local mgr media path
	mgr=$(_bm_manager_id "$node")
	media=$(_bm_media_id "$node")
	path="/redfish/v1/Managers/$mgr/VirtualMedia/$media"

	_redfish_request "$node" GET "$path" || return 1
	if [ "${_REDFISH_LAST_CODE:0:1}" != "2" ]; then
		_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "HTTP ${_REDFISH_LAST_CODE} on GET VirtualMedia")
		return 1
	fi
	local inserted
	inserted=$(jq -r '.Inserted // false' "$_REDFISH_LAST_BODY")
	if [ "$inserted" != "true" ]; then
		aba_debug "BMC: $node nothing to eject (Inserted=false)"
		return 0
	fi

	# POST EjectMedia with empty body.
	local body_tmp
	body_tmp=$(mktemp /tmp/bmc_eject_${node}.XXXXXX)
	printf '%s' '{}' > "$body_tmp"
	_redfish_request "$node" POST "$path/Actions/VirtualMedia.EjectMedia" "$body_tmp"
	rm -f "$body_tmp"

	# Per CONTEXT D-02 + research A6: some firmware returns 409 or 500 when nothing is
	# mounted (iRMC) or when the mount is partially-unclean (generic). Translate to success.
	case "$_REDFISH_LAST_CODE" in
		2??|3??|409|500) : ;;
		*)
			_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "HTTP ${_REDFISH_LAST_CODE} on EjectMedia")
			return 1
			;;
	esac

	# Poll until Inserted=false or 10s (D-20 equivalent ceiling for eject).
	local elapsed=0 interval=1 max=10
	while [ "$elapsed" -lt "$max" ]; do
		_redfish_request "$node" GET "$path" || return 1
		if [ "${_REDFISH_LAST_CODE:0:1}" != "2" ]; then
			_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "HTTP ${_REDFISH_LAST_CODE} on eject poll GET")
			return 1
		fi
		inserted=$(jq -r '.Inserted // false' "$_REDFISH_LAST_BODY")
		if [ "$inserted" = "false" ]; then
			aba_debug "BMC: $node stale media ejected (after ${elapsed}s)"
			return 0
		fi
		sleep "$interval"
		elapsed=$(( elapsed + interval ))
	done
	_REDFISH_LAST_CODE="0"
	_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "EjectMedia did not clear Inserted=false after 10s")
	return 1
}

# -----------------------------------------------------------------------------
# bmc_insert_media - POST VirtualMedia.InsertMedia with ISO URL body (BMC-01 step 4).
# iso_url global must be populated by bmc-boot.sh before calling this function.
# -----------------------------------------------------------------------------

bmc_insert_media() {
	local node="$1"
	local verb path body_tmp
	verb=$(_bm_insert_media_verb)
	path=$(_bm_insert_media_path "$node")

	# iso_url is a global populated by bmc-boot.sh (from bmc.conf or transient server derivation).
	if [ -z "${iso_url:-}" ]; then
		_REDFISH_LAST_CODE="0"
		_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "iso_url not set - orchestrator must populate before calling bmc_insert_media")
		return 1
	fi

	body_tmp=$(mktemp /tmp/bmc_insert_${node}.XXXXXX)
	_bm_insert_media_body "$iso_url" "$body_tmp"
	_redfish_request "$node" "$verb" "$path" "$body_tmp"
	rm -f "$body_tmp"

	if [ "${_REDFISH_LAST_CODE:0:1}" = "2" ] || [ "${_REDFISH_LAST_CODE:0:1}" = "3" ]; then
		_bm_insert_media_verify "$node" || {
			_REDFISH_LAST_CODE="0"
			_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "InsertMedia false-success - vendor verify hook reported mismatch")
			return 1
		}
		return 0
	fi
	# Decode common failure shapes for reason clarity. (Lines 233-247 unchanged.)
	case "$_REDFISH_LAST_CODE" in
		403)
			_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "VirtualMedia not licensed")
			;;
		400)
			_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "InsertMedia rejected (HTTP 400) - check TransferProtocolType and Image URL shape")
			;;
		500)
			_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "InsertMedia HTTP 500 - possibly already-mounted or stale media")
			;;
		*)
			_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "InsertMedia HTTP ${_REDFISH_LAST_CODE}")
			;;
	esac
	return 1
}

# -----------------------------------------------------------------------------
# bmc_wait_connected - poll VirtualMedia until Inserted=true AND Connected=true
# or 15s timeout (D-20 fixed 15s / 1s interval).
# -----------------------------------------------------------------------------

bmc_wait_connected() {
	local node="$1"
	local mgr media path
	mgr=$(_bm_manager_id "$node")
	media=$(_bm_media_id "$node")
	path="/redfish/v1/Managers/$mgr/VirtualMedia/$media"

	local elapsed=0 interval=1 max=15
	local inserted connected
	while [ "$elapsed" -lt "$max" ]; do
		_redfish_request "$node" GET "$path" || return 1
		if [ "${_REDFISH_LAST_CODE:0:1}" != "2" ]; then
			_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "HTTP ${_REDFISH_LAST_CODE} on VirtualMedia poll")
			return 1
		fi
		inserted=$(jq -r '.Inserted // false' "$_REDFISH_LAST_BODY")
		connected=$(jq -r '.Connected // false' "$_REDFISH_LAST_BODY")
		if [ "$inserted" = "true" ] && [ "$connected" = "true" ]; then
			aba_debug "BMC: $node VirtualMedia Connected=true (after ${elapsed}s)"
			return 0
		fi
		sleep "$interval"
		elapsed=$(( elapsed + interval ))
	done
	_REDFISH_LAST_CODE="0"
	_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "BIOS did not present block device (Connected=false after 15s)")
	return 1
}

# -----------------------------------------------------------------------------
# bmc_set_boot_override - PATCH /Systems/<sys> Boot Cd/Once/UEFI (BMC-01 step 7).
# ETag on PATCH handled transparently by the wrapper per D-04.
# -----------------------------------------------------------------------------

bmc_set_boot_override() {
	local node="$1"
	local sys
	sys=$(_bm_system_id "$node")
	local path="/redfish/v1/Systems/$sys"

	local body_tmp
	body_tmp=$(mktemp /tmp/bmc_boot_patch_${node}.XXXXXX)
	_bm_boot_patch_body "$body_tmp"
	_redfish_request "$node" PATCH "$path" "$body_tmp"
	rm -f "$body_tmp"

	if [ "${_REDFISH_LAST_CODE:0:1}" = "2" ] || [ "${_REDFISH_LAST_CODE:0:1}" = "3" ]; then
		return 0
	fi
	case "$_REDFISH_LAST_CODE" in
		412)
			_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "ETag precondition failed on PATCH /Systems/$sys")
			;;
		400)
			_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "Cd or Once not allowed by firmware (BootSourceOverrideTarget allowlist)")
			;;
		*)
			_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "boot-override PATCH HTTP ${_REDFISH_LAST_CODE}")
			;;
	esac
	return 1
}

# -----------------------------------------------------------------------------
# bmc_power_reset - power-state-aware reset (BMC-05).
# GET PowerState -> map to ResetType -> POST ComputerSystem.Reset.
# Force-cycle only: Off/PoweringOff -> ResetType:On; On/PoweringOn/Paused -> ResetType:ForceRestart.
# Unknown state falls back to ResetType:On (safe default per DSP0266).
# -----------------------------------------------------------------------------

bmc_power_reset() {
	local node="$1"
	local sys
	sys=$(_bm_system_id "$node")
	local sys_path="/redfish/v1/Systems/$sys"

	# Step 1: GET PowerState.
	_redfish_request "$node" GET "$sys_path"
	if [ "${_REDFISH_LAST_CODE:0:1}" != "2" ]; then
		_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "HTTP ${_REDFISH_LAST_CODE} on GET System for PowerState read")
		return 1
	fi
	local state
	state=$(jq -r '.PowerState // "Unknown"' "$_REDFISH_LAST_BODY")

	# Step 2: Map state -> ResetType (On or ForceRestart only - no graceful variant).
	local reset_type
	case "$state" in
		Off|PoweringOff)  reset_type="On" ;;
		On|PoweringOn)    reset_type="ForceRestart" ;;
		Paused)           reset_type="ForceRestart" ;;
		*)                reset_type="On" ;;   # Unknown and any other: safe fallback
	esac
	aba_debug "BMC: $node PowerState=$state -> Reset=$reset_type"

	# Step 3: POST Reset.
	local body_tmp
	body_tmp=$(mktemp /tmp/bmc_reset_${node}.XXXXXX)
	jq -n --arg t "$reset_type" '{ResetType:$t}' > "$body_tmp"
	_redfish_request "$node" POST "$sys_path/Actions/ComputerSystem.Reset" "$body_tmp"
	rm -f "$body_tmp"

	if [ "${_REDFISH_LAST_CODE:0:1}" = "2" ] || [ "${_REDFISH_LAST_CODE:0:1}" = "3" ]; then
		return 0
	fi
	case "$_REDFISH_LAST_CODE" in
		400)
			_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "ResetType $reset_type rejected (PowerState was $state)")
			;;
		*)
			_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "Reset POST HTTP ${_REDFISH_LAST_CODE}")
			;;
	esac
	return 1
}

# -----------------------------------------------------------------------------
# bmc_wait_power_on - poll PowerState=On (D-20 fixed 120s / 2s interval).
# -----------------------------------------------------------------------------

bmc_wait_power_on() {
	local node="$1"
	local sys
	sys=$(_bm_system_id "$node")
	local sys_path="/redfish/v1/Systems/$sys"

	local elapsed=0 interval=2 max=120
	local state
	while [ "$elapsed" -lt "$max" ]; do
		_redfish_request "$node" GET "$sys_path" || return 1
		if [ "${_REDFISH_LAST_CODE:0:1}" != "2" ]; then
			_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "HTTP ${_REDFISH_LAST_CODE} on PowerState poll")
			return 1
		fi
		state=$(jq -r '.PowerState // "Unknown"' "$_REDFISH_LAST_BODY")
		if [ "$state" = "On" ]; then
			aba_debug "BMC: $node PowerState=On (after ${elapsed}s)"
			return 0
		fi
		sleep "$interval"
		elapsed=$(( elapsed + interval ))
	done
	_REDFISH_LAST_CODE="0"
	_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "PowerState never reached On after 120s")
	return 1
}

# -----------------------------------------------------------------------------
# bmc_boot_override_disable - PATCH BootSourceOverrideEnabled=Disabled (BMC-06).
# Minimal body only; used by scripts/bmc-unmount.sh after install completes.
# -----------------------------------------------------------------------------

bmc_boot_override_disable() {
	local node="$1"
	local sys
	sys=$(_bm_system_id "$node")
	local path="/redfish/v1/Systems/$sys"

	local body_tmp
	body_tmp=$(mktemp /tmp/bmc_bso_disable_${node}.XXXXXX)
	printf '%s' '{"Boot":{"BootSourceOverrideEnabled":"Disabled"}}' > "$body_tmp"
	_redfish_request "$node" PATCH "$path" "$body_tmp"
	rm -f "$body_tmp"

	if [ "${_REDFISH_LAST_CODE:0:1}" = "2" ] || [ "${_REDFISH_LAST_CODE:0:1}" = "3" ]; then
		return 0
	fi
	_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "boot-override-disable PATCH HTTP ${_REDFISH_LAST_CODE}")
	return 1
}

# -----------------------------------------------------------------------------
# _bm_get_ethernetinterfaces - canonical DSP0266 EthernetInterfaces wrapper for
# Phase 10 MAC discovery (MAC-07).
#
# Generic-with-vendor-override pattern (Phase 6/8 D-02): this generic
# implementation is the source of truth; vendor overlays in
# scripts/bmc-adapter-<vendor>.sh may redefine via bash function-redefine-wins
# if a vendor needs to short-circuit collection traversal or transform fields.
#
# Walks /redfish/v1/Systems/<SystemId>/EthernetInterfaces and emits one stdout
# line per NIC in pipe-delimited form (caller in scripts/bmc-mac-discovery.sh
# reads with IFS='|'):
#   nic_id|mac|link_status|enabled|interface_type|name
#
# Returns 0 with NIC lines on stdout; returns 1 with empty stdout on any error.
# Uses _redfish_request (no direct HTTP). jq only after HTTP 2xx gate.
# -----------------------------------------------------------------------------

_bm_get_ethernetinterfaces() {
	local node="$1"
	local sys
	sys=$(_bm_system_id "$node")
	if [ -z "$sys" ]; then
		_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "SystemId not discovered for $node - bmc_discover_ids must run first")
		return 1
	fi

	# GET the EthernetInterfaces collection.
	_redfish_request "$node" GET "/redfish/v1/Systems/$sys/EthernetInterfaces"
	if [ "${_REDFISH_LAST_CODE:0:1}" != "2" ]; then
		_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "HTTP ${_REDFISH_LAST_CODE} on EthernetInterfaces collection for $node")
		return 1
	fi

	# jq is safe here: preceding HTTP 200 gate guarantees JSON body (UX-05).
	local members m
	members=$(jq -r '.Members[]?."@odata.id" // empty' "$_REDFISH_LAST_BODY")
	if [ -z "$members" ]; then
		# Empty collection is not an error; caller handles MAC-04 via filter.
		return 0
	fi

	local nic_id mac link enabled iftype name
	for m in $members; do
		_redfish_request "$node" GET "$m" || continue
		if [ "${_REDFISH_LAST_CODE:0:1}" != "2" ]; then
			continue
		fi
		nic_id=$(jq -r '.Id // empty' "$_REDFISH_LAST_BODY")
		mac=$(jq -r '.MACAddress // empty' "$_REDFISH_LAST_BODY")
		link=$(jq -r '.LinkStatus // empty' "$_REDFISH_LAST_BODY")
		enabled=$(jq -r '.InterfaceEnabled // false' "$_REDFISH_LAST_BODY")
		iftype=$(jq -r '.InterfaceType // empty' "$_REDFISH_LAST_BODY")
		name=$(jq -r '.Name // empty' "$_REDFISH_LAST_BODY")
		# Skip entries without an Id (malformed); pipe-delimit and emit.
		[ -z "$nic_id" ] && continue
		printf '%s|%s|%s|%s|%s|%s\n' "$nic_id" "$mac" "$link" "$enabled" "$iftype" "$name"
	done
	return 0
}
