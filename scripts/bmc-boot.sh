#!/bin/bash
# scripts/bmc-boot.sh - Phase 6 BMC-driven boot orchestrator.
#
# Called by the templates/Makefile.cluster .bm-bmc-boot-done stamp target on bare-metal
# clusters. Drives the BMC-01 sequence for every bmc_host_<node> in bmc.conf via Redfish.
#
# Behavior (D-19 stamp semantics):
#   (a) bmc.conf absent or no bmc_host_* keys  -> touch .bm-bmc-boot-done + exit 0.
#   (b) All configured nodes succeed            -> touch .bm-bmc-boot-done + exit 0.
#   (c) Any node fails                          -> NO stamp write + exit non-zero.
#
# Every operator-visible line begins with `BMC:` (UX-03). Counter bumps use `var=$(( var + 1 ))`.
# Session tokens are in-memory bash locals only (D-12).

# -----------------------------------------------------------------------------
# Phase 7 state-schema version. Bump manually in commits that change state-file
# schema (new last_step values, additional keys, or changed step semantics).
# _bm_state_invalidate_if_stale rm's any .bmc-state.<node> whose script_version
# mismatches this constant - stale state from old code never resumes.
#
# 1.2.0 (Phase 10 D-01): adds three new keys for MAC auto-discovery:
#   discovered_mac=<MAC>|disabled    written by _bm_state_write_mac
#   discovered_nic_id=<NIC.Id>       empty when discovered_mac=disabled
#   discovered_at=<ISO-8601 UTC>     timestamp of last discovery write
# 1.2.0 migration is non-destructive: _bm_state_invalidate_if_stale upgrades
# 1.1.0 sidecars in place (appends empty discovered_* keys) rather than
# discarding state - operators get cache continuity across the upgrade.
# -----------------------------------------------------------------------------
_BMC_BOOT_VERSION="1.2.0"

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

# -----------------------------------------------------------------------------
# INT-03 gate 1: bmc.conf absent. Write stamp (manual-mount fallback active) and exit 0.
# -----------------------------------------------------------------------------
if [ ! -f bmc.conf ]; then
	aba_info "BMC: bmc.conf absent - using manual virtual-media flow. Boot each node from the generated agent ISO (see bare-metal install instructions) via USB or BMC UI, then run aba mon."
	touch .bm-bmc-boot-done
	exit 0
fi

# -----------------------------------------------------------------------------
# INT-03 gate 2: bmc.conf present but no bmc_host_* keys. Manual fallback.
# -----------------------------------------------------------------------------
if ! grep -qE '^[[:space:]]*bmc_host_' bmc.conf; then
	aba_info "BMC: bmc.conf present but no bmc_host_* keys defined - using manual virtual-media flow."
	touch .bm-bmc-boot-done
	exit 0
fi

# -----------------------------------------------------------------------------
# D-10d: prior run fully succeeded (stamp present) - wipe stale state files.
# This is the happy-path state-reset: .bm-bmc-boot-done is written only by the
# all-nodes-ok branch at the tail of this script (Phase 6 D-19).
# -----------------------------------------------------------------------------
if [ -f .bm-bmc-boot-done ]; then
	rm -f .bmc-state.* .bmc-session.*
fi

# -----------------------------------------------------------------------------
# Load bmc.conf. Mode-0600 enforcement is inside normalize-bmc-conf (aba_abort on drift).
# After this line: bmc_host_*, bmc_user_*, bmc_password_*, bmc_type_*, bmc_insecure_*,
# iso_url, bmc_iso_port, bmc_insert_wait_seconds are all available via bash indirection.
# -----------------------------------------------------------------------------
source <(normalize-bmc-conf)

# -----------------------------------------------------------------------------
# Source the Redfish wrapper + the generic adapter. Per-node iRMC overlay is
# sourced inside _bm_boot_one_node when bmc_type_<node>=irmc (D-01).
# -----------------------------------------------------------------------------
source scripts/bmc-redfish.sh
source scripts/bmc-adapter-generic.sh

# -----------------------------------------------------------------------------
# Helper: list node names from bmc.conf in declaration order.
# Mirrors scripts/preflight-check-bm.sh lines 23-27 exactly.
# -----------------------------------------------------------------------------
_bm_node_list() {
	[ -f bmc.conf ] || return 0
	grep -E '^[[:space:]]*bmc_host_[A-Za-z0-9_-]+=' bmc.conf \
		| sed -E 's/^[[:space:]]*bmc_host_([A-Za-z0-9_-]+)=.*/\1/'
}

# -----------------------------------------------------------------------------
# _bm_stop_iso_server: trap handler. Kills the python3 -m http.server PID and
# removes the tempdir. Never suppresses stderr (UX-05); routes kill-stderr
# through aba_debug via 2>&1 capture into a local var.
# -----------------------------------------------------------------------------
_bm_stop_iso_server() {
	if [ -n "${_BMC_HTTP_PID:-}" ]; then
		# `kill` stderr is harmless ("No such process" if already gone). UX-05 bans
		# stderr suppression; capture it into a var instead so the operator sees it
		# under DEBUG_ABA.
		local kill_err
		kill_err=$(kill "$_BMC_HTTP_PID" 2>&1) || true
		if [ -n "$kill_err" ]; then
			aba_debug "BMC: http server kill: $kill_err"
		fi
	fi
	if [ -n "${_BMC_HTTP_TEMPDIR:-}" ]; then
		rm -rf "$_BMC_HTTP_TEMPDIR"
	fi
}

# -----------------------------------------------------------------------------
# _bm_cleanup: D-20 extended trap body. Runs on EXIT / INT / TERM. Order:
# (1) disable self at entry to prevent re-entry during own work,
# (2) best-effort DELETE of every persisted session via _bm_delete_session,
# (3) rm -f each .bmc-session.<node> after DELETE attempt,
# (4) tear down the transient HTTP server (_bm_stop_iso_server).
# Session DELETEs fire BEFORE HTTP-server teardown so we still have live
# network while the BMCs process the DELETE.
# -----------------------------------------------------------------------------
_bm_cleanup() {
	trap - EXIT INT TERM
	local f node
	for f in .bmc-session.*; do
		[ -f "$f" ] || continue
		node="${f#.bmc-session.}"
		_bm_delete_session "$node" || aba_debug "BMC: $node cleanup session DELETE failed"
		rm -f "$f"
	done
	_bm_stop_iso_server
}

# -----------------------------------------------------------------------------
# _bm_bmc_conf_hash <node>: SHA256 over host|user|type for this node.
# Password EXCLUDED per Phase 5 D-06 credential hygiene. Used as D-10a state
# invalidation trigger: operator changed host/user/type => state discarded.
# -----------------------------------------------------------------------------
_bm_bmc_conf_hash() {
	local node="$1"
	local host_var="bmc_host_${node}"
	local user_var="bmc_user_${node}"
	local type_var="bmc_type_${node}"
	printf '%s|%s|%s' "${!host_var}" "${!user_var}" "${!type_var}" | sha256sum | awk '{print $1}'
}

# -----------------------------------------------------------------------------
# _bm_state_write <node> <step>: atomically rewrite .bmc-state.<node>.
# Flat key=value schema (D-08). Standard content: last_step, bmc_conf_hash,
# iso_sha, script_version, last_updated. Never credentials, tokens, or URIs.
# Mode 0600 via parent umask 077 (include_all.sh:259); subshell umask is
# belt-and-braces. Atomic .new + mv -f prevents torn writes.
#
# Phase 10 D-01 preservation: when the sidecar already exists, any
# discovered_mac / discovered_nic_id / discovered_at keys written earlier
# (typically by preflight via _bm_state_write_mac) MUST be carried forward
# across the rewrite. Otherwise a single _bm_state_write call from inside
# the boot loop would strip the MAC discovery state and break the D-02
# cache + D-03 single-helper contract for any downstream consumer
# (cluster-config.sh override block, monitor-install, future re-runs).
# Presence (not just non-empty value) is preserved so that the 1.1.0 -> 1.2.0
# migration sentinel (empty discovered_mac= line meaning "cache miss") also
# survives the rewrite.
# -----------------------------------------------------------------------------
_bm_state_write() {
	local node="$1" step="$2"
	local f=".bmc-state.${node}"
	# Preserve Phase 10 D-01 discovery keys if present in the existing sidecar.
	# Capture both the value AND a presence flag via grep | cut (never source/eval).
	# `|| true` on the value capture ensures a no-match grep (rc=1) does not leak
	# rc into the caller's ERR trap path.
	local disc_mac_present=0 disc_nic_present=0 disc_at_present=0
	local disc_mac="" disc_nic="" disc_at=""
	if [ -f "$f" ]; then
		if grep -q '^discovered_mac=' "$f"; then
			disc_mac_present=1
			disc_mac=$(grep '^discovered_mac=' "$f" | cut -d= -f2- || true)
		fi
		if grep -q '^discovered_nic_id=' "$f"; then
			disc_nic_present=1
			disc_nic=$(grep '^discovered_nic_id=' "$f" | cut -d= -f2- || true)
		fi
		if grep -q '^discovered_at=' "$f"; then
			disc_at_present=1
			disc_at=$(grep '^discovered_at=' "$f" | cut -d= -f2- || true)
		fi
	fi
	( umask 077; {
		printf 'last_step=%s\n' "$step"
		printf 'bmc_conf_hash=%s\n' "$(_bm_bmc_conf_hash "$node")"
		printf 'iso_sha=%s\n' "${_BMC_ISO_SHA:-}"
		printf 'script_version=%s\n' "$_BMC_BOOT_VERSION"
		printf 'last_updated=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		# Phase 10 D-01: re-emit any discovery keys that were present, even with
		# empty values (the 1.1.0 -> 1.2.0 migration writes empty values as a
		# "force fresh Redfish call" sentinel; preserve that semantic).
		[ "$disc_mac_present" -eq 1 ] && printf 'discovered_mac=%s\n' "$disc_mac"
		[ "$disc_nic_present" -eq 1 ] && printf 'discovered_nic_id=%s\n' "$disc_nic"
		[ "$disc_at_present" -eq 1 ] && printf 'discovered_at=%s\n' "$disc_at"
		# Final no-op `:` guarantees the brace group exits with rc 0 regardless
		# of which optional re-emit branches were taken. Without this, a missing
		# discovered_at would leave `[ "$disc_at_present" -eq 1 ]` as the last
		# command (rc=1), causing the `&&` chain below to skip the mv and the
		# enclosing subshell to exit non-zero - which fires the caller's ERR
		# trap and aborts the boot loop mid-state-machine.
		:
	} > "${f}.new" && mv -f "${f}.new" "$f" )
}

# -----------------------------------------------------------------------------
# _bm_state_write_mac <node> <mac> <nic_id>: merge Phase 10 D-01 MAC discovery
# keys (discovered_mac, discovered_nic_id, discovered_at) into .bmc-state.<node>
# atomically. Called by preflight _bm_discover_macs (Plan 10-02 Task 1).
#
# Behavior:
#   - <mac> may be the literal string "disabled" (D-09 opt-out sentinel); in
#     that case <nic_id> is "".
#   - discovered_at uses ISO-8601 UTC with seconds resolution (matches existing
#     last_updated timestamp style).
#   - If the file exists: read existing key=value lines, strip any prior
#     discovered_mac / discovered_nic_id / discovered_at lines, append the new
#     three lines, write atomically via .new + mv -f under umask 077.
#   - If the file does NOT exist: bootstrap a full sidecar (last_step empty
#     because ISO has not yet been generated, bmc_conf_hash via _bm_bmc_conf_hash,
#     iso_sha empty, script_version, last_updated) PLUS the three new keys.
# -----------------------------------------------------------------------------
_bm_state_write_mac() {
	local node="$1" mac="$2" nic_id="$3"
	local f=".bmc-state.${node}"
	local ts
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	( umask 077; {
		if [ -f "$f" ]; then
			grep -vE '^(discovered_mac|discovered_nic_id|discovered_at)=' "$f"
		else
			printf 'last_step=%s\n' ""
			printf 'bmc_conf_hash=%s\n' "$(_bm_bmc_conf_hash "$node")"
			printf 'iso_sha=%s\n' "${_BMC_ISO_SHA:-}"
			printf 'script_version=%s\n' "$_BMC_BOOT_VERSION"
			printf 'last_updated=%s\n' "$ts"
		fi
		printf 'discovered_mac=%s\n' "$mac"
		printf 'discovered_nic_id=%s\n' "$nic_id"
		printf 'discovered_at=%s\n' "$ts"
	} > "${f}.new" && mv -f "${f}.new" "$f" )
}

# -----------------------------------------------------------------------------
# _bm_state_invalidate_if_stale <node>: rm -f .bmc-state.<node> on any of
# bmc_conf_hash / iso_sha / script_version mismatch. Called at top of
# _bm_boot_one_node before any state-file read. Per D-10 invalidation.
# Does NOT source the state file - grep + cut only.
#
# Phase 10 D-02 migration (1.1.0 -> 1.2.0): version mismatch from "1.1.0"
# to the current _BMC_BOOT_VERSION is treated as a non-destructive upgrade
# when bmc_conf_hash + iso_sha still match. We append empty discovered_*
# keys (so Plan 10-02 step 3 cache-check falls through to a fresh Redfish
# call) and rewrite script_version. Any other version mismatch (including
# downgrade or a future schema break) still rm's the file.
# -----------------------------------------------------------------------------
_bm_state_invalidate_if_stale() {
	local node="$1"
	local f=".bmc-state.${node}"
	[ -f "$f" ] || return 0
	local saved_hash saved_iso saved_ver
	saved_hash=$(grep '^bmc_conf_hash=' "$f" | cut -d= -f2)
	saved_iso=$(grep '^iso_sha=' "$f" | cut -d= -f2-)
	saved_ver=$(grep '^script_version=' "$f" | cut -d= -f2)
	local current_hash
	current_hash=$(_bm_bmc_conf_hash "$node")
	# Phase 10 D-01: a sidecar written by preflight carries iso_sha="" because
	# preflight runs before the ISO is generated. Treat that empty value as
	# "ISO not yet known" rather than a stale mismatch - otherwise the very
	# first invalidate call inside _bm_boot_one_node would rm -f the file and
	# wipe discovered_mac before any consumer (cluster-config override block,
	# monitor-install) can read it. Only invalidate on iso mismatch when both
	# sides are non-empty and actually differ.
	local iso_mismatch=0
	if [ -n "$saved_iso" ] && [ -n "${_BMC_ISO_SHA:-}" ] && [ "$saved_iso" != "${_BMC_ISO_SHA:-}" ]; then
		iso_mismatch=1
	fi
	if [ "$saved_hash" != "$current_hash" ] || [ "$iso_mismatch" -eq 1 ]; then
		rm -f "$f"
		return 0
	fi
	if [ "$saved_ver" = "$_BMC_BOOT_VERSION" ]; then
		return 0
	fi
	# Version mismatch with hash + iso intact: try Phase 10 non-destructive
	# migration for the documented 1.1.0 -> 1.2.0 upgrade path.
	if [ "$saved_ver" = "1.1.0" ] && [ "$_BMC_BOOT_VERSION" = "1.2.0" ]; then
		( umask 077; {
			# Drop the old script_version line; rewrite with the current one.
			# Append empty discovered_* keys so the Plan 10-02 cache check
			# treats the entry as a miss and runs a fresh Redfish call.
			grep -vE '^(script_version|discovered_mac|discovered_nic_id|discovered_at)=' "$f"
			printf 'script_version=%s\n' "$_BMC_BOOT_VERSION"
			printf 'discovered_mac=%s\n' ""
			printf 'discovered_nic_id=%s\n' ""
			printf 'discovered_at=%s\n' ""
		} > "${f}.new" && mv -f "${f}.new" "$f" )
		return 0
	fi
	# Unknown version delta: fall back to invalidation per the original D-10 contract.
	rm -f "$f"
}

# -----------------------------------------------------------------------------
# _bm_iso_url_guard: ERR-06 pre-loop chunked-transfer guard. One HEAD on $iso_url
# verifies (a) HTTP 200, (b) Content-Length present, (c) Transfer-Encoding:
# chunked ABSENT. Any failure = aba_abort. Runs for both operator-supplied
# iso_url and auto-derived iso_url; trust only after verification.
# -----------------------------------------------------------------------------
_bm_iso_url_guard() {
	local hdr_tmp http
	hdr_tmp=$(mktemp /tmp/bmc_iso_head.XXXXXX)
	http=$(curl -s -m 10 --fail -I \
		-o "$hdr_tmp" \
		-w '%{http_code}' \
		"$iso_url") || http="000"
	if [ "$http" != "200" ]; then
		rm -f "$hdr_tmp"
		aba_abort "BMC: iso_url runtime guard failed - HTTP $http on HEAD $iso_url"
	fi
	if ! grep -qi '^Content-Length:' "$hdr_tmp"; then
		rm -f "$hdr_tmp"
		aba_abort "BMC: iso_url runtime guard failed - Content-Length header missing (Redfish InsertMedia requires fixed-length body)"
	fi
	if grep -qiE '^Transfer-Encoding:[[:space:]]*chunked' "$hdr_tmp"; then
		rm -f "$hdr_tmp"
		aba_abort "BMC: iso_url runtime guard failed - Transfer-Encoding: chunked present (older iRMC and iLO firmware reject chunked transfer)"
	fi
	rm -f "$hdr_tmp"
}

# -----------------------------------------------------------------------------
# _bm_rollback: ERR-03 partial-failure cleanup. Scans .bmc-state.<node> files,
# collects nodes whose last_step is at or past `insert` (D-14 scope), builds
# a reverse-order list (D-15 symmetric undo), invokes scripts/bmc-unmount.sh
# with the node-list filter (Phase 7 plan 02 extension), then removes the
# state file for each node (D-18 post-rollback cleanup).
# Best-effort per D-16: bmc-unmount.sh always exits 0; rollback never masks
# the ORIGINAL per-node failure code (the caller does `_bm_rollback; exit 1`).
# Phase 10 note: discovered_mac/discovered_nic_id/discovered_at keys are not
# relevant to rollback - last_step is the sole gate. Whole-file rm on rollback
# is the existing D-18 behavior and is the right semantic for MAC keys too
# (operator can re-run preflight to repopulate them on the next attempt).
# -----------------------------------------------------------------------------
_bm_rollback() {
	local mounted_nodes="" node last_step
	local f
	for f in .bmc-state.*; do
		[ -f "$f" ] || continue
		node="${f#.bmc-state.}"
		last_step=$(grep '^last_step=' "$f" | cut -d= -f2)
		case "$last_step" in
			insert|wait-connected|boot-override|reset|wait-power|session-logout)
				# D-15: prepend for reverse-of-bmc.conf order.
				mounted_nodes="$node $mounted_nodes"
				;;
		esac
	done
	if [ -n "$mounted_nodes" ]; then
		aba_warning "BMC: partial-failure rollback - ejecting media from:$mounted_nodes"
		# Unquoted $mounted_nodes: intentional IFS split of space-separated node names.
		# Values are alphanumeric + underscore + hyphen only (bmc_host_ regex at source).
		scripts/bmc-unmount.sh $mounted_nodes
		# D-18: remove state for successfully-rolled-back nodes so the next run
		# starts them fresh at session-login.
		for node in $mounted_nodes; do
			rm -f ".bmc-state.${node}"
		done
	fi
}

# -----------------------------------------------------------------------------
# _bm_start_iso_server: spawn python3 -m http.server bound to the Phase 5
# PRE-06 auto-derived src_ip. Skipped entirely when operator set iso_url= (D-08).
# Heterogeneous BMC subnets abort fatally (D-07). Trap installed immediately
# after spawn (BMC-09).
# -----------------------------------------------------------------------------
_bm_start_iso_server() {
	if [ -n "${iso_url:-}" ]; then
		aba_debug "BMC: iso_url is operator-provided ($iso_url), skipping transient HTTP server"
		_BMC_ISO_SHA="$iso_url"
		export _BMC_ISO_SHA
		return 0
	fi

	# D-07: re-run ip route get for every BMC host; abort on heterogeneous subnets.
	local first_host="" src_ip="" other_src=""
	local node host_var host
	for node in $(_bm_node_list); do
		host_var="bmc_host_${node}"
		host="${!host_var}"
		if [ -z "$first_host" ]; then
			first_host="$host"
			src_ip=$(ip route get "$host" | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
			if [ -z "$src_ip" ]; then
				aba_abort "BMC: cannot derive bastion src IP from 'ip route get $host' (no src field) - set explicit iso_url= in bmc.conf"
			fi
			continue
		fi
		other_src=$(ip route get "$host" | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
		if [ "$other_src" != "$src_ip" ]; then
			aba_abort "BMC: heterogeneous BMC subnets detected ($first_host uses $src_ip, $host uses $other_src); set explicit iso_url= in bmc.conf for multi-subnet deployments"
		fi
	done

	# Bindability re-check: src_ip must be present on a local interface.
	local addr_list
	addr_list=$(ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1)
	if ! printf '%s\n' "$addr_list" | grep -qxF "$src_ip"; then
		aba_abort "BMC: derived bastion src IP $src_ip is not present on any local interface; set explicit iso_url= in bmc.conf"
	fi

	# Tempdir with ISO symlinked in (serves http://<src_ip>:<port>/agent.<arch>.iso cleanly).
	_BMC_HTTP_TEMPDIR=$(mktemp -d /tmp/bmc_iso_serve.XXXXXX)
	local arch_value="${ARCH:-x86_64}"
	local iso_source="iso-agent-based/agent.${arch_value}.iso"
	if [ ! -f "$iso_source" ]; then
		aba_abort "BMC: agent ISO not found at $iso_source - run 'aba iso' first"
	fi
	# D-10b: hash the ISO content so state invalidates when the ISO changes.
	_BMC_ISO_SHA=$(sha256sum "$iso_source" | awk '{print $1}')
	export _BMC_ISO_SHA
	ln -s "$(pwd)/$iso_source" "$_BMC_HTTP_TEMPDIR/agent.${arch_value}.iso"

	local port="${bmc_iso_port:-8000}"

	# Spawn. Trap installed immediately so EXIT/INT/TERM cleans up regardless of what fails next.
	python3 -m http.server --directory "$_BMC_HTTP_TEMPDIR" --bind "$src_ip" "$port" &
	_BMC_HTTP_PID=$!
	trap '_bm_cleanup' EXIT INT TERM

	# Export derived iso_url for bmc_insert_media.
	iso_url="http://$src_ip:$port/agent.${arch_value}.iso"
	export iso_url
	aba_debug "BMC: iso_url=$iso_url (pid=$_BMC_HTTP_PID, tempdir=$_BMC_HTTP_TEMPDIR)"
	return 0
}

# -----------------------------------------------------------------------------
# _bm_boot_one_node <node>: run the full BMC-01 sequence for one node.
# On success: emit UX-01 line + return 0.
# On failure: emit UX-02 line (phase=<name>), best-effort session_logout, return 1.
#
# Session token lifetime (D-12, W3):
#   bmc_session_login writes SESSION_TOKEN_<node> and SESSION_URI_<node> into the
#   ENCLOSING shell scope via `printf -v` with a dynamic name (bash limitation:
#   dynamic-name printf -v cannot target a `local` - it writes to the first
#   enclosing non-local scope). Consequently these per-node globals persist in
#   memory past function return, for the duration of the orchestrator process.
#   They leave memory only on process exit. Phase 7 ERR-04 adds persistent-tempfile
#   tracking for crash-resilient cleanup; for Phase 6 MVP this in-memory-only
#   residence is the D-12 locked contract (no disk spill).
# -----------------------------------------------------------------------------
_bm_boot_one_node() {
	local node="$1"
	local type_var="bmc_type_${node}"
	local adapter="${!type_var}"

	# D-23: ERR-05 one-shot re-auth guard. Set to true AFTER bmc_power_reset succeeds;
	# a subsequent 401 triggers one-shot bmc_session_login, then flag is cleared to
	# prevent a second re-auth attempt within the same node.
	local _reset_completed=false

	# D-10: state invalidation before any resume logic reads the file.
	_bm_state_invalidate_if_stale "$node"

	# D-01 per-node sourced overlay: iRMC redefines _bm_manager_id / _bm_media_id /
	# _bm_system_id and sets _bm_patch_if_match_required=true. On non-iRMC nodes we
	# ensure the generic definitions are the active ones by re-sourcing the generic
	# adapter (bash function-redefine-wins; re-sourcing generic reverts any prior
	# iRMC overlay for subsequent generic nodes). Also reset the ETag flag.
	source scripts/bmc-adapter-generic.sh
	_bm_patch_if_match_required=false
	if [ "$adapter" = "irmc" ]; then
		source scripts/bmc-adapter-irmc.sh
	fi

	# Step 1: session login. On success, SESSION_TOKEN_<node> / SESSION_URI_<node>
	# are populated in the enclosing shell scope (see W3 comment block above).
	if ! bmc_session_login "$node"; then
		# bmc_session_login already emitted the UX-02 line per D-10.
		return 1
	fi
	_bm_state_write "$node" "session-login"

	# Step 2: discover IDs (cached into MANAGER_ID_<node> / MEDIA_ID_<node> / SYSTEM_ID_<node>).
	if ! bmc_discover_ids "$node"; then
		aba_warning "BMC: $node phase=discover adapter=$adapter http=$_REDFISH_LAST_CODE reason=\"$_REDFISH_LAST_REASON\""
		bmc_session_logout "$node"
		return 1
	fi
	_bm_state_write "$node" "discover"

	# Step 3: stale-media eject (BMC-02).
	if ! bmc_eject_media "$node"; then
		aba_warning "BMC: $node phase=eject-stale adapter=$adapter http=$_REDFISH_LAST_CODE reason=\"$_REDFISH_LAST_REASON\""
		bmc_session_logout "$node"
		return 1
	fi
	_bm_state_write "$node" "eject-stale"

	# Step 4: insert media.
	if ! bmc_insert_media "$node"; then
		aba_warning "BMC: $node phase=insert adapter=$adapter http=$_REDFISH_LAST_CODE reason=\"$_REDFISH_LAST_REASON\""
		bmc_session_logout "$node"
		return 1
	fi
	_bm_state_write "$node" "insert"

	# Step 5: post-insert wait (BMC-04 - operator-configurable, default 15s per D-20).
	local wait_secs="${bmc_insert_wait_seconds:-15}"
	aba_debug "BMC: $node post-insert sleep ${wait_secs}s"
	sleep "$wait_secs"

	# Step 6: wait Connected:true (fixed 15s at 1s interval per D-20).
	if ! bmc_wait_connected "$node"; then
		aba_warning "BMC: $node phase=wait-connected adapter=$adapter http=$_REDFISH_LAST_CODE reason=\"$_REDFISH_LAST_REASON\""
		bmc_session_logout "$node"
		return 1
	fi
	_bm_state_write "$node" "wait-connected"

	# Step 7: set boot override Cd / Once / UEFI (PATCH; ETag handled by wrapper per D-04).
	if ! bmc_set_boot_override "$node"; then
		aba_warning "BMC: $node phase=boot-override adapter=$adapter http=$_REDFISH_LAST_CODE reason=\"$_REDFISH_LAST_REASON\""
		bmc_session_logout "$node"
		return 1
	fi
	_bm_state_write "$node" "boot-override"

	# Step 8: power-state-aware reset (BMC-05).
	if ! bmc_power_reset "$node"; then
		aba_warning "BMC: $node phase=reset adapter=$adapter http=$_REDFISH_LAST_CODE reason=\"$_REDFISH_LAST_REASON\""
		bmc_session_logout "$node"
		return 1
	fi
	_reset_completed=true
	_bm_state_write "$node" "reset"

	# Step 9: poll PowerState=On (fixed 120s at 2s interval per D-20).
	# ERR-05 (D-23): on 401 after reset, one-shot re-auth and retry.
	if ! bmc_wait_power_on "$node"; then
		if [ "$_reset_completed" = "true" ] && [ "$_REDFISH_LAST_CODE" = "401" ]; then
			# BMC firmware (iRMC S4, some iLO) drops sessions on power cycle.
			# Best-effort DELETE of stale session, then POST new session. Credentials
			# are re-read from env via bash indirection inside bmc_session_login per
			# Phase 5 D-06; nothing is cached here.
			aba_debug "BMC: $node 401 after reset, re-authenticating (ERR-05 one-shot)"
			_bm_delete_session "$node" || true
			_reset_completed=false
			if bmc_session_login "$node" && bmc_wait_power_on "$node"; then
				_bm_state_write "$node" "wait-power"
			else
				aba_warning "BMC: $node phase=wait-power adapter=$adapter http=$_REDFISH_LAST_CODE reason=\"$_REDFISH_LAST_REASON\""
				bmc_session_logout "$node"
				return 1
			fi
		else
			aba_warning "BMC: $node phase=wait-power adapter=$adapter http=$_REDFISH_LAST_CODE reason=\"$_REDFISH_LAST_REASON\""
			bmc_session_logout "$node"
			return 1
		fi
	else
		_bm_state_write "$node" "wait-power"
	fi

	# Step 10: session logout (best-effort; never fails the node per D-17).
	# bmc_session_logout DELETEs the session on the BMC but does NOT unset the
	# shell-scope SESSION_TOKEN_<node> / SESSION_URI_<node> vars; those remain in
	# memory for this orchestrator process lifetime (D-12, see block comment above).
	bmc_session_logout "$node"
	_bm_state_write "$node" "session-logout"

	# UX-01 success per D-17.
	aba_info_ok "BMC: $node booted from ISO (adapter=$adapter)"
	return 0
}

# -----------------------------------------------------------------------------
# Main: start ISO server, loop serially over nodes, emit summary, write stamp.
# -----------------------------------------------------------------------------
_bm_start_iso_server

# ERR-06 (D-06): chunked-transfer / Content-Length runtime guard. One HEAD on
# $iso_url before the serial node loop. Fires for both operator-supplied and
# auto-derived iso_url; trust only after verification.
_bm_iso_url_guard

total=0
ok_count=0
failed_list=""
for node in $(_bm_node_list); do
	total=$(( total + 1 ))
	if _bm_boot_one_node "$node"; then
		ok_count=$(( ok_count + 1 ))
	else
		failed_list="$failed_list $node"
	fi
done

# Final summary + D-19 stamp decision.
if [ "$total" = "0" ]; then
	# Defensive: _bm_node_list was non-empty at the INT-03 gate but empty now.
	# Treat as manual-fallback; write stamp, exit 0.
	touch .bm-bmc-boot-done
	exit 0
fi

if [ "$ok_count" = "$total" ]; then
	aba_info_ok "BMC: $ok_count/$total nodes booted from ISO"
	touch .bm-bmc-boot-done
	exit 0
fi

# D-19 branch (c): any node failed. Stamp NOT written; exit non-zero so make halts.
# Phase 7 D-14..D-18: ERR-03 rollback of state-file-identified mounted nodes
# BEFORE exit 1. _bm_rollback best-effort; never masks the original failure code.
aba_warning "BMC: $ok_count/$total nodes booted from ISO; failed:$failed_list"
_bm_rollback
exit 1
