# Pre-flight vSphere-specific checks: sourced by scripts/preflight-check.sh
# when platform=vmw. Exports a single public function, preflight_check_vsphere.
#
# Sourced (not executed): no shebang, not chmod +x.
# Strict mode (set -e, ERR trap) and aba_* output helpers are inherited
# from the parent preflight-check.sh and scripts/include_all.sh.
#
# Runtime behaviour (Phase 1):
#   1. Double-gate on platform=vmw (belt-and-suspenders; parent already gates).
#   2. Load vmware.conf via normalize-vmware-conf.
#   3. Probe that govc is on PATH (abort with remediation hint if not).
#   4. Verify the seven required GOVC_* fields are present.
#      On failure: emit one aba_warning per missing field + bump _preflight_errors.
#      The parent summary block at preflight-check.sh:209-212 aborts on error count.
#   5. On success: single aba_info_ok line.
#
# Phase 2 will extend this function with connectivity / TLS / resource checks.
# Phase 3 will extend it with privilege validation using VSPHERE_PRIVS_* arrays
# from scripts/vmware-required-privileges.sh.

# --- Phase 2 Layer 1 helpers (private to this file) -----------------------

# Extract host + port from GOVC_URL into two fields echoed on stdout.
# Accepts: hostname | hostname:port | https://hostname | https://hostname:port | https://hostname:port/sdk
# Defaults port to 443 (vCenter standard). IPv6 bracket form ([::1]:443) is NOT supported -
# aba's templates/vmware.conf only documents hostname forms. If a user supplies an IPv6
# literal anyway, the TCP probe will legitimately fail with "cannot reach".
# Out: echoes "<host> <port>" on stdout. Callers: read host port < <(_vsphere_parse_govc_url "$GOVC_URL").
_vsphere_parse_govc_url() {
	local url="$1"
	url="${url#http://}"
	url="${url#https://}"
	url="${url%%/*}"
	local h p
	if [[ "$url" == *:* ]]; then
		h="${url%:*}"
		p="${url##*:}"
	else
		h="$url"
		p=443
	fi
	echo "$h $p"
}

# Layer 1 Stage 1: TCP reachability probe.
# Matches the NTP UDP probe idiom at scripts/preflight-check.sh:75 - the 2>/dev/null
# is INSIDE the `bash -c` subshell to suppress bash's own "connect: Connection refused"
# stderr noise that /dev/tcp prints on failure. It does NOT suppress stderr of anything
# the caller runs; it is the documented narrow exception (see CLAUDE.md rule + Pitfall 6 in RESEARCH.md).
# Returns 0 on success; on failure emits one aba_warning, bumps _preflight_errors, returns 1.
_vsphere_probe_tcp() {
	local host port
	read host port < <(_vsphere_parse_govc_url "$GOVC_URL")
	if timeout 3 bash -c "echo >/dev/tcp/$host/$port 2>/dev/null"; then
		aba_debug "vSphere: TCP reach to $host:$port ok"
		return 0
	fi
	aba_warning "vSphere: cannot reach $host:$port (TCP) - check DNS/firewall/GOVC_URL"
	_preflight_errors=$(( _preflight_errors + 1 ))
	return 1
}

# Layer 1 Stage 2: TLS trust-chain probe.
# Skipped entirely when GOVC_INSECURE is truthy (D-02). Uses openssl s_client with
# BOTH -verify_return_error (makes exit code meaningful on chain failure) AND a
# belt-and-suspenders parse of "Verify return code: 0 (ok)" in the captured output -
# some RHEL openssl builds exit 0 even on trust failure (openssl/openssl#8079).
# The `out=$(cmd 2>&1)` idiom captures stderr into a variable for inspection; this is
# an ALLOWED pattern per CLAUDE.md (it is NOT the banned `cmd 2>&1 | grep` pipeline).
# Returns 0 on success; on failure emits one multi-line aba_warning with D-03 remediation.
_vsphere_probe_tls() {
	case "${GOVC_INSECURE:-}" in
		1|true|True|TRUE|yes|YES)
			aba_debug "vSphere: skipping TLS check (GOVC_INSECURE=$GOVC_INSECURE)"
			return 0
			;;
	esac

	local host port
	read host port < <(_vsphere_parse_govc_url "$GOVC_URL")

	# Belt-and-suspenders: rely on -verify_return_error exit code AND the stderr line.
	local tls_out tls_rc=0
	tls_out=$(timeout 5 openssl s_client \
		-verify_return_error \
		-connect "$host:$port" \
		-servername "$host" \
		</dev/null 2>&1) || tls_rc=$?

	if [ "$tls_rc" -eq 0 ]; then
		aba_debug "vSphere: TLS trust chain ok for $host"
		return 0
	fi
	if echo "$tls_out" | grep -qE 'Verify return code:[[:space:]]*0[[:space:]]*\(ok\)'; then
		aba_debug "vSphere: TLS trust chain ok for $host (parsed)"
		return 0
	fi

	# D-03 two-option remediation - GOVC_INSECURE=1 listed FIRST, then CA install.
	aba_warning "vSphere: TLS trust chain failure talking to $host" \
		"Set GOVC_INSECURE=1 in vmware.conf to skip trust validation (development/lab only)" \
		"OR add the vCenter CA certificate to the system trust store for production use"
	_preflight_errors=$(( _preflight_errors + 1 ))
	return 1
}

# Layer 2: vCenter credential probe via `govc about`.
# Assumes Layer 1 (TCP + TLS) already green, so any failure here is authentication or
# vCenter-API-level. Captures stderr into a variable (allowed; not a `2>&1 | grep` pipeline).
# Never includes the password in output (T-02-01-01 information-disclosure mitigation).
_vsphere_probe_auth() {
	local about_out about_rc=0
	about_out=$(govc about 2>&1) || about_rc=$?
	if [ "$about_rc" -eq 0 ]; then
		aba_debug "vSphere: auth ok"
		return 0
	fi
	# Trim to first line so we don't dump a multi-line error blob to the user.
	local first_line
	first_line=$(echo "$about_out" | head -1)
	aba_warning "vSphere: authentication to $GOVC_URL as '$GOVC_USERNAME' failed" \
		"govc said: $first_line"
	_preflight_errors=$(( _preflight_errors + 1 ))
	return 1
}

# --- Phase 2 Layer 3 helpers (private to this file) -----------------------

# Generic single-object existence probe (D-05 canonical pattern).
# Uses `govc object.collect -s <absolute path> name`. Exit 0 = object exists.
# Non-zero covers both "object not found" and permission-denied; the write-access
# layer (RES-07) clarifies permission edge cases, so here we report as "not found".
# $1 = human kind label (e.g. "datacenter", "cluster", "datastore", "network",
#      "folder", "resource pool").
# $2 = absolute vSphere inventory path.
# Returns 0 on success; on failure emits one aba_warning + bumps _preflight_errors + returns 1.
# Note: `out=$(cmd 2>&1)` captures stderr INTO a variable; this is an allowed idiom
# per CLAUDE.md - it is NOT the banned `cmd 2>&1 | grep` pipeline.
_vsphere_object_exists() {
	local kind="$1" path="$2"
	local out rc=0
	out=$(govc object.collect -s "$path" name 2>&1) || rc=$?
	if [ "$rc" -eq 0 ]; then
		aba_debug "vSphere: $kind '$path' exists"
		return 0
	fi
	aba_warning "vSphere: $kind '$path' not found"
	_preflight_errors=$(( _preflight_errors + 1 ))
	return 1
}

# RES-04 attachment cross-check (D-08): the named portgroup must be visible to at
# least one host of GOVC_CLUSTER. This is an ADDITIONAL check on top of the basic
# existence probe - "right-name, wrong-cluster" would otherwise silently pass RES-04.
# Uses `govc object.collect -s <network> host` to list HostSystem morefs seeing the
# portgroup, and `govc find -i -type h <cluster>` to list the cluster's host morefs.
# Set-intersect via per-line grep -xF. If either query errors (non-zero rc), soft-skip
# with an aba_debug: the basic existence probes already covered the "missing" case and
# we don't want to double-count an error here.
# Returns 0 on success (overlap found OR soft-skip); 1 if the attachment gap is real.
_vsphere_probe_resources_network_on_cluster() {
	local net_hosts cluster_hosts net_rc=0 cluster_rc=0
	net_hosts=$(govc object.collect -s "/$GOVC_DATACENTER/network/$GOVC_NETWORK" host 2>&1) || net_rc=$?
	cluster_hosts=$(govc find -i -type h "/$GOVC_DATACENTER/host/$GOVC_CLUSTER" 2>&1) || cluster_rc=$?

	if [ "$net_rc" -ne 0 ] || [ "$cluster_rc" -ne 0 ]; then
		aba_debug "vSphere: could not verify network-on-cluster attachment (govc read error)"
		return 0
	fi

	local h overlap=0
	for h in $cluster_hosts; do
		if echo "$net_hosts" | grep -qxF -- "$h"; then
			overlap=1
			break
		fi
	done

	if [ "$overlap" -eq 0 ]; then
		aba_warning "vSphere: network '$GOVC_NETWORK' is not attached to any host in cluster '$GOVC_CLUSTER'"
		_preflight_errors=$(( _preflight_errors + 1 ))
		return 1
	fi
	aba_debug "vSphere: network '$GOVC_NETWORK' attached to cluster '$GOVC_CLUSTER'"
	return 0
}

# Layer 3 sequencer. Probes each referenced vSphere object in turn; collects all
# failures within the layer (D-04) except for the DC-missing cascade (D-07) which
# short-circuits the rest of Layer 3 and emits one informational cascade note.
# Resource pool (RES-06) is probed by a separate helper added by Plan 02-03.
# Return contract:
#   0 - DC exists (some siblings may have failed; counters carry the signal)
#   1 - DC missing (Layer 3 short-circuited; caller should stop)
_vsphere_probe_resources() {
	# D-07: if DC is missing, emit cascade note and bail. The note is aba_info
	# (NOT aba_warning) and must NOT bump _preflight_errors - _vsphere_object_exists
	# already bumped once for the "not found" line, keeping the total at exactly 1.
	if ! _vsphere_object_exists datacenter "/$GOVC_DATACENTER"; then
		aba_info "vSphere: skipping cluster/datastore/network/folder/resource-pool checks until datacenter resolves"
		return 1
	fi

	# RES-02: cluster under DC. `|| :` keeps the layer in collect-all mode (D-04).
	_vsphere_object_exists cluster "/$GOVC_DATACENTER/host/$GOVC_CLUSTER" || :

	# RES-03a: primary datastore.
	_vsphere_object_exists datastore "/$GOVC_DATACENTER/datastore/$GOVC_DATASTORE" || :

	# RES-03b: optional ISO_DATASTORE - probe only if set, non-empty, AND different
	# from GOVC_DATASTORE (D-06 + Pitfall 5 dedup guard: don't double-probe same path).
	if [ -n "${ISO_DATASTORE:-}" ] && [ "$ISO_DATASTORE" != "$GOVC_DATASTORE" ]; then
		_vsphere_object_exists datastore "/$GOVC_DATACENTER/datastore/$ISO_DATASTORE" || :
	fi

	# RES-04: network existence AND attachment-to-cluster cross-check (D-08).
	# The attachment probe only runs when the network exists - no point cross-checking
	# a portgroup that isn't there; the basic probe already warned about it.
	if _vsphere_object_exists network "/$GOVC_DATACENTER/network/$GOVC_NETWORK"; then
		_vsphere_probe_resources_network_on_cluster || :
	fi

	# RES-05: VM folder (absolute path from VC_FOLDER).
	_vsphere_object_exists folder "$VC_FOLDER" || :

	# RES-06: resource pool - configured OR implicit default (Phase 2).
	# resolve-default-resource-pool lives in scripts/include_all.sh; this caller invokes it
	# and branches the warning wording when the UNSET-path case fails vs the SET-path case.
	# We use a custom probe inline instead of _vsphere_object_exists so we can swap the
	# error wording: when the DEFAULT path is missing, the broken link is the CLUSTER
	# (not the RP field) - we specifically do NOT tell the user "try setting GOVC_RESOURCE_POOL".
	local pool_path pool_is_default=0
	pool_path=$(resolve-default-resource-pool)
	if [ -z "${GOVC_RESOURCE_POOL:-}" ]; then
		pool_is_default=1
	fi

	# Note: `out=$(cmd 2>&1)` captures stderr INTO a variable; allowed idiom per CLAUDE.md
	# (NOT the banned `cmd 2>&1 | grep` pipeline).
	local rp_out rp_rc=0
	rp_out=$(govc object.collect -s "$pool_path" name 2>&1) || rp_rc=$?

	if [ "$rp_rc" -eq 0 ]; then
		if [ "$pool_is_default" -eq 1 ]; then
			# Debug-only announcement that the default is in use (NOT aba_info -
			# quiet-on-success convention from Phase 1).
			aba_debug "vSphere: using default resource pool '$pool_path'"
		else
			aba_debug "vSphere: resource pool '$pool_path' exists"
		fi
	else
		if [ "$pool_is_default" -eq 1 ]; then
			# Custom wording when the default path is missing: the cluster itself is the
			# broken link (the cluster always ships a default "Resources" pool). Do NOT hint
			# at setting GOVC_RESOURCE_POOL - that would mislead the user into masking a
			# genuine cluster-configuration problem.
			aba_warning "vSphere: default resource pool '$pool_path' not found - verify the cluster is properly configured."
		else
			aba_warning "vSphere: resource pool '$pool_path' not found"
		fi
		_preflight_errors=$(( _preflight_errors + 1 ))
	fi

	return 0
}

# --- Phase 2 Layer 4 helpers (private to this file) -----------------------

# Per-scope write-access probe (RES-07, Phase 2 corrected two-step algorithm per 02-RESEARCH.md):
#   1. `govc permissions.ls <scope>`  - 4-col tab-separated output:
#        Role | Entity | Principal | Propagate   (header row NR=1 must be skipped)
#   2. awk-filter rows where Principal column equals $GOVC_USERNAME; read Role from col 1.
#      (permissions.ls has no principal-filter flag - verified upstream in cli/permissions/ls.go.)
#   3. If role is "Admin" - fast-path: vCenter built-in Admin has all privileges.
#      If role is "No access" - explicit deny; every required priv is missing.
#      Else: `govc role.ls <roleName>` - one privilege per line - and grep each required string.
#   4. Query-level failures emit ONE warning and increment `_preflight_warnings`
#      (NOT `_preflight_errors`); Phase 3 may still catch gaps.
#
# $1  = absolute scope path (VC_FOLDER or resolved resource-pool path)
# $@  = required privilege strings (allowlist)
_vsphere_check_writeaccess() {
	local scope_path="$1"
	shift
	local -a required_privs=("$@")

	# Step 1: list permissions. `-a=true` (default) includes inherited.
	# `out=$(cmd 2>&1)` is allowed variable capture (NOT `cmd 2>&1 | grep` pipeline).
	local perms_out perms_rc=0
	perms_out=$(govc permissions.ls "$scope_path" 2>&1) || perms_rc=$?

	# Query itself failed - emit a warning and return without bumping _preflight_errors.
	if [ "$perms_rc" -ne 0 ]; then
		local first_line
		first_line=$(echo "$perms_out" | head -1)
		aba_warning "vSphere: cannot verify write-access on '$scope_path'" \
			"govc permissions.ls said: $first_line" \
			"User may lack 'Permissions.ModifyPermissions' or equivalent read right." \
			"Skipping RES-07 for this scope; Phase 3 privilege query may still catch gaps."
		_preflight_warnings=$(( _preflight_warnings + 1 ))
		return 0
	fi

	# Step 2: find role assigned to the configured user. Skip header row (NR>1).
	# Use default awk whitespace split to tolerate both literal-tab and
	# tabwriter-expanded-space outputs. Principal is typically field 3, Role field 1.
	# However: default splitting breaks if Role name contains a space (e.g. "No access").
	# Compromise: try tab-split FIRST, fall back to default whitespace split.
	local role_name
	role_name=$(echo "$perms_out" | awk -F'\t' 'NR>1 && $3 == u { print $1; exit }' u="$GOVC_USERNAME")
	if [ -z "$role_name" ]; then
		role_name=$(echo "$perms_out" | awk 'NR>1 && $3 == u { print $1; exit }' u="$GOVC_USERNAME")
	fi

	if [ -z "$role_name" ]; then
		aba_warning "vSphere: user '$GOVC_USERNAME' has no role assigned on '$scope_path' (D-12; group assignments not resolved)"
		_preflight_warnings=$(( _preflight_warnings + 1 ))
		return 0
	fi

	# Step 3a: Admin role fast-path - vCenter built-in Admin has all privs by construction.
	if [ "$role_name" = "Admin" ]; then
		aba_debug "vSphere: '$scope_path' user '$GOVC_USERNAME' has Admin role (all privileges granted)"
		return 0
	fi

	# Step 3b: "No access" explicit-deny role - every required priv is missing.
	if [ "$role_name" = "No access" ]; then
		local req
		for req in "${required_privs[@]}"; do
			aba_warning "vSphere: $scope_path missing VM-create privilege '$req' (user has role 'No access')"
			_preflight_errors=$(( _preflight_errors + 1 ))
		done
		return 0
	fi

	# Step 3c: Resolve role -> privilege list. Query-failure -> warning (not error).
	local role_privs role_rc=0
	role_privs=$(govc role.ls "$role_name" 2>&1) || role_rc=$?
	if [ "$role_rc" -ne 0 ]; then
		aba_warning "vSphere: cannot resolve privileges for role '$role_name' on '$scope_path'"
		_preflight_warnings=$(( _preflight_warnings + 1 ))
		return 0
	fi

	# Step 4: for each required privilege, grep the role's privilege set.
	# grep -qxF: quiet, whole-line, fixed-string (privilege names are exact matches, not regex).
	local req
	for req in "${required_privs[@]}"; do
		if ! echo "$role_privs" | grep -qxF -- "$req"; then
			aba_warning "vSphere: $scope_path missing VM-create privilege '$req'"
			_preflight_errors=$(( _preflight_errors + 1 ))
		fi
	done
	return 0
}

# Layer 4 sequencer. Runs _vsphere_check_writeaccess against VC_FOLDER with the
# folder VM-create allowlist, then against the resolved resource-pool path with
# the RP VM-create allowlist. Per-scope failures collect all; query-level failures
# become warnings and don't short-circuit the other scope. Phase 2's allowlists
# are the narrow VM-create subset; Phase 3 will iterate the full VSPHERE_PRIVS_*
# arrays for its broader privilege query.
_vsphere_probe_writeaccess() {
	local pool_path
	pool_path=$(resolve-default-resource-pool)

	# Folder VM-create allowlist.
	_vsphere_check_writeaccess "$VC_FOLDER" \
		VirtualMachine.Inventory.Create \
		VirtualMachine.Config.AddNewDisk

	# Resource-pool VM-create allowlist.
	_vsphere_check_writeaccess "$pool_path" \
		Resource.AssignVMToPool

	return 0
}

preflight_check_vsphere() {
	# Double-gate: parent at scripts/preflight-check.sh:202 already checks platform=vmw,
	# but this short-circuit protects against direct sourcing.
	[ "$platform" != "vmw" ] && return 0

	# Load vmware.conf through the authoritative normaliser (INT-05 / D-08).
	# Note: normalize-vmware-conf at include_all.sh:~664 calls 'govc about' internally
	# as part of its ESXi-vs-vCenter detection. In the normal aba install flow, vCenter
	# reachability is already established by install-vmware.conf.sh before this point.
	# Phase 2 (CON-01, CON-02) will surface distinct connectivity / auth failures.
	# aba.conf already normalized by parent preflight-check.sh:9 - $platform is available here
	source <(normalize-vmware-conf)

	# govc presence probe. `command -v` writes only to stdout; >/dev/null suppresses
	# stdout, not stderr - so this is NOT a stderr-suppression-ban violation.
	if ! command -v govc >/dev/null; then
		aba_abort "vSphere: govc CLI not found on PATH" \
			"Run: make -C cli govc  (or: aba -d cli install)"
	fi

	# CON-03 (moved from Phase 2 per D-09): required-field presence check.
	local missing=()
	local f
	for f in GOVC_URL GOVC_USERNAME GOVC_PASSWORD GOVC_DATACENTER GOVC_CLUSTER GOVC_DATASTORE GOVC_NETWORK; do
		# Indirect expansion: ${!f} expands to the value of the variable NAMED by $f.
		# :- default tolerates any future set -u without relying on it being set.
		if [ -z "${!f:-}" ]; then
			missing+=("$f")
		fi
	done

	if [ ${#missing[@]} -gt 0 ]; then
		# Loud on failure (D-14): one aba_warning line per missing field.
		# Bump _preflight_errors once per missing field; parent summary aborts on count > 0.
		# Never call 'exit' here - let the parent aggregation decide.
		for f in "${missing[@]}"; do
			aba_warning "vSphere: required field '$f' is missing from vmware.conf"
			_preflight_errors=$(( _preflight_errors + 1 ))
		done
		return 0
	fi

	# Success (UX-01 / D-10): one aba_info_ok line. Forward-compatible wording so
	# Phase 2/3 can append connectivity / privilege check lines without rewording.
	aba_info_ok "vSphere: configuration fields present, running checks..."

	# Phase 2 Layer 1 + Layer 2: connectivity (TCP + TLS) + auth. Short-circuit the
	# function on any layer failure; the `return 0` is deliberate - preflight_check_vsphere
	# always returns 0; counters signal gaps for the parent to aggregate.
	_vsphere_probe_tcp         || return 0
	_vsphere_probe_tls         || return 0
	_vsphere_probe_auth        || return 0
	_vsphere_probe_resources   || return 0
	_vsphere_probe_writeaccess

	# Phase 3 will add privilege validation here (sources scripts/vmware-required-privileges.sh).
}
