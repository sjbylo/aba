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

# Phase 3 per-scope "object found" flags. Populated by _vsphere_probe_resources on
# each successful existence probe. _vsphere_probe_privileges reads them to skip
# privilege queries on missing objects (must not conflate "privilege not granted"
# with "object not found"). ROOT has no flag: '/' always exists when Layer 2
# auth is green.
_vsphere_dc_found=0
_vsphere_cluster_found=0
_vsphere_datastore_found=0
_vsphere_iso_datastore_found=0
_vsphere_network_found=0
_vsphere_folder_found=0
_vsphere_resource_pool_found=0

# Resolved absolute paths populated by Layer 3 and reused by Layer 4. When a
# user writes a bare name (e.g. GOVC_NETWORK='<portgroup>') or a nested value
# (e.g. GOVC_DATASTORE='folder/ds-name'), the Layer 3 resolver walks the
# inventory to find the matching object and stores its absolute path here.
# Layer 4 (_vsphere_probe_privileges) passes these paths to
# `govc permissions.ls` so RBAC queries use the same path OpenShift will,
# not a flat-path construction that may miss DVS-nested or bare-name objects.
_vsphere_datastore_path=""
_vsphere_iso_datastore_path=""
_vsphere_network_path=""
_vsphere_folder_path=""
_vsphere_resource_pool_path=""

# D-12 counter: number of privilege scopes where govc permissions.ls
# returned no DIRECT role binding for our user - typically because the
# privileges come from AD/LDAP group membership, which govc cannot
# expand. Tracked separately from _preflight_warnings so the summary
# footer can reassure the user that these are informational, not
# blockers. `aba install` proceeds; any real gap will surface later
# with a concrete privilege error.
_vsphere_d12_count=0

# --- Shared emit helpers (private to this file) ---------------------------
# Keep label and counter in sync. aba_warning prints with whatever prefix we
# pass via -p; the counter we bump is the matching parent-aggregated total.
# $_vsphere_label is "ESXi" or "vSphere" depending on whether VC is set.
_vsphere_err() {
	local main="$1"
	shift
	aba_warning -p Error "$_vsphere_label: $main" "$@"
	_preflight_errors=$(( _preflight_errors + 1 ))
}

_vsphere_warn() {
	local main="$1"
	shift
	aba_warning "$_vsphere_label: $main" "$@"
	_preflight_warnings=$(( _preflight_warnings + 1 ))
}

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
	read -r host port < <(_vsphere_parse_govc_url "$GOVC_URL")
	if timeout 3 bash -c "echo >/dev/tcp/$host/$port 2>/dev/null"; then
		aba_info_ok "$_vsphere_label: TCP reachable ($host:$port)"
		return 0
	fi
	_vsphere_err "cannot reach $host:$port (TCP) - check DNS/firewall/GOVC_URL"
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
			aba_info "$_vsphere_label: TLS trust check skipped (GOVC_INSECURE=$GOVC_INSECURE)"
			return 0
			;;
	esac

	local host port
	read -r host port < <(_vsphere_parse_govc_url "$GOVC_URL")

	# Belt-and-suspenders: rely on -verify_return_error exit code AND the stderr line.
	local tls_out tls_rc=0
	tls_out=$(timeout 5 openssl s_client \
		-verify_return_error \
		-connect "$host:$port" \
		-servername "$host" \
		</dev/null 2>&1) || tls_rc=$?

	if [ "$tls_rc" -eq 0 ]; then
		aba_info_ok "$_vsphere_label: TLS trust chain verified ($host)"
		return 0
	fi
	if echo "$tls_out" | grep -qE 'Verify return code:[[:space:]]*0[[:space:]]*\(ok\)'; then
		aba_info_ok "$_vsphere_label: TLS trust chain verified ($host)"
		return 0
	fi

	# D-03 two-option remediation - GOVC_INSECURE=1 listed FIRST, then CA install.
	_vsphere_err "TLS trust chain failure talking to $host" \
		"Set GOVC_INSECURE=1 in vmware.conf to skip trust validation (development/lab only)" \
		"OR add the vCenter CA certificate to the system trust store for production use"
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
		aba_info_ok "$_vsphere_label: authenticated as $GOVC_USERNAME"
		return 0
	fi
	# Trim to first line so we don't dump a multi-line error blob to the user.
	local first_line
	first_line=$(echo "$about_out" | head -1)
	_vsphere_err "authentication to $GOVC_URL as '$GOVC_USERNAME' failed" \
		"govc said: $first_line"
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
		aba_info_ok "$_vsphere_label: $kind '$path'"
		return 0
	fi
	_vsphere_err "$kind '$path' not found"
	return 1
}

# Resolve a vSphere inventory object by path OR bare name. Accepts the same
# input shapes OpenShift accepts (see templates/install-config.yaml.j2:48 and
# the install-config generator for datastore / folder / resource-pool):
#   - Absolute path:  /DC/network/dvSwitch-Foo/<portgroup>   (use verbatim)
#   - Nested path:    folder/datastore-name                (appended to search_root)
#   - Bare leaf:      <portgroup>, <resource-pool>          (searched under search_root)
#
# Algorithm:
#   1. Absolute path (starts with /): object.collect verbatim; no fallback.
#   2. Relative path or bare name: try flat-append <search_root>/<value> first
#      (fast path, preserves existing configs where the value already contains
#      folder prefixes). If that fails, fall back to `govc find <search_root>
#      -name <leaf>` where leaf = basename of the value. Exactly one hit =
#      resolved. Zero hits = not found. Multiple hits = ambiguous.
#
# $1 = human kind label ("network", "datastore", "folder", "resource pool")
# $2 = user-configured value
# $3 = search root for fallback ("/$DC/network", "/$DC/host/$CLUSTER", etc.)
# $4 = optional govc find -type flag (e.g. "p" to scope bare-name RP searches
#      to resource pools rather than any object sharing the leaf name)
#
# On success: writes the resolved absolute path to _vsphere_resolver_result and returns 0.
# On failure: emits one aba_warning, bumps _preflight_errors, returns 1.
#
# Important: the resolved path is returned via the module variable
# _vsphere_resolver_result, NOT via stdout. aba_warning / aba_debug helpers
# write to stdout, and capturing stdout from this function would swallow
# those messages instead of letting them reach the user.
#
# Note: `out=$(cmd 2>&1)` is the allowed stderr-capture idiom per CLAUDE.md
# (NOT the banned `cmd 2>&1 | grep` pipeline).
_vsphere_resolver_result=""
_vsphere_resolve_object() {
	local kind="$1" hint="$2" search_root="$3" find_type="${4:-}"
	local out rc=0
	_vsphere_resolver_result=""

	# Absolute path: verify verbatim, no fallback. Users who write absolute
	# paths have committed to a specific location; silently walking the tree
	# would mask typos.
	if [[ "$hint" = /* ]]; then
		out=$(govc object.collect -s "$hint" name 2>&1) || rc=$?
		if [ "$rc" -eq 0 ]; then
			aba_info_ok "$_vsphere_label: $kind '$hint'"
			_vsphere_resolver_result="$hint"
			return 0
		fi
		_vsphere_err "$kind '$hint' not found"
		return 1
	fi

	# Fast path: flat-append under search_root. Preserves the historical
	# behaviour where GOVC_DATASTORE='folder/DS' works because the flat
	# concatenation happens to land on the real object.
	local flat="$search_root/$hint"
	out=$(govc object.collect -s "$flat" name 2>&1) || rc=$?
	if [ "$rc" -eq 0 ]; then
		aba_info_ok "$_vsphere_label: $kind '$flat'"
		_vsphere_resolver_result="$flat"
		return 0
	fi

	# Fallback: name-based search under search_root. Handles DVS-nested
	# portgroups, bare-name resource pools, and any other case where the
	# user's value matches an object reachable from search_root but not at
	# the flat-appended path.
	local leaf="${hint##*/}"
	local find_out find_rc=0
	if [ -n "$find_type" ]; then
		find_out=$(govc find "$search_root" -type "$find_type" -name "$leaf" 2>&1) || find_rc=$?
	else
		find_out=$(govc find "$search_root" -name "$leaf" 2>&1) || find_rc=$?
	fi

	# Count lines starting with '/' - govc find emits one absolute path per
	# match; blank lines and stray output are ignored.
	local hits_count=0
	if [ "$find_rc" -eq 0 ]; then
		hits_count=$(printf "%s\n" "$find_out" | grep -c '^/' || true)
	fi

	if [ "$hits_count" -eq 1 ]; then
		local resolved
		resolved=$(printf "%s\n" "$find_out" | grep '^/' | head -1)
		aba_info_ok "$_vsphere_label: $kind '$hint' -> $resolved"
		_vsphere_resolver_result="$resolved"
		return 0
	fi

	if [ "$hits_count" -gt 1 ]; then
		_vsphere_err "$kind '$hint' matches $hits_count objects under '$search_root' (ambiguous; use an absolute path in vmware.conf)"
		return 1
	fi

	# Neither flat-path nor find found anything. Use the flat path in the
	# warning message for backward compatibility with existing tests /
	# tooling that matches on the old "$kind '$flat' not found" wording.
	_vsphere_err "$kind '$flat' not found"
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
	# Use the Layer 3 resolved network path so the attachment check reads the
	# actual object, not a flat-path construction that would miss DVS-nested
	# portgroups (the network existence probe above populated this variable).
	net_hosts=$(govc object.collect -s "$_vsphere_network_path" host 2>&1) || net_rc=$?
	cluster_hosts=$(govc find -i -type h "/$GOVC_DATACENTER/host/$GOVC_CLUSTER" 2>&1) || cluster_rc=$?

	# Normalize net_hosts to one moref per line. `govc object.collect -s <obj>
	# host` emits morefs newline-separated for simple portgroups but comma-
	# separated for DVS-backed portgroups (6+ hosts); the grep -xF overlap
	# check below requires newline-separated input to match via whole-line.
	net_hosts=$(printf '%s' "$net_hosts" | tr ',' '\n')

	if [ "$net_rc" -ne 0 ] || [ "$cluster_rc" -ne 0 ]; then
		aba_debug "$_vsphere_label: could not verify network-on-cluster attachment (govc read error)"
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
		_vsphere_err "network '$GOVC_NETWORK' is not attached to any host in cluster '$GOVC_CLUSTER'"
		return 1
	fi
	aba_info_ok "$_vsphere_label: network '$GOVC_NETWORK' attached to cluster '$GOVC_CLUSTER'"
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
	# ESXi (VC empty - set by normalize-vmware-conf via 'govc about' API-type probe):
	# no datacenter / cluster / resource pool, no per-host RBAC privilege model.
	# Probe datastore under /ha-datacenter; network via host.portgroup.info
	# (see network-check comment below for rationale);
	# folder still probed if VC_FOLDER is set; everything else short-circuits.
	if [ -z "${VC:-}" ]; then
		if _vsphere_resolve_object datastore "$GOVC_DATASTORE" "/ha-datacenter/datastore"; then
			_vsphere_datastore_path="$_vsphere_resolver_result"
			_vsphere_datastore_found=1
		fi
		if [ -n "${ISO_DATASTORE:-}" ] && [ "$ISO_DATASTORE" != "$GOVC_DATASTORE" ]; then
			if _vsphere_resolve_object datastore "$ISO_DATASTORE" "/ha-datacenter/datastore"; then
				_vsphere_iso_datastore_path="$_vsphere_resolver_result"
				_vsphere_iso_datastore_found=1
			fi
		fi
		# ESXi standalone: govc find may not list some port groups (observed
		# on freshly installed ESXi 7.0.3). host.portgroup.info queries
		# host config directly and works reliably.
		# See Troubleshooting.md "ESXi: Network not found" for details.
		_vsphere_network_path="/ha-datacenter/network/$GOVC_NETWORK"
		if govc host.portgroup.info "$GOVC_NETWORK" >/dev/null 2>&1; then
			aba_info_ok "$_vsphere_label: network '$_vsphere_network_path'"
			_vsphere_network_found=1
		else
			_vsphere_err "network '$_vsphere_network_path' not found"
		fi
		if [ -n "${VC_FOLDER:-}" ]; then
			if _vsphere_resolve_object folder "$VC_FOLDER" "/ha-datacenter/vm"; then
				_vsphere_folder_path="$_vsphere_resolver_result"
				_vsphere_folder_found=1
			fi
		else
			aba_info "$_vsphere_label: VC_FOLDER not set, installer will create the default folder per cluster"
		fi
		return 0
	fi

	# D-07: if DC is missing, emit cascade note and bail. The note is aba_info
	# (NOT aba_warning) and must NOT bump _preflight_errors - _vsphere_object_exists
	# already bumped once for the "not found" line, keeping the total at exactly 1.
	if ! _vsphere_object_exists datacenter "/$GOVC_DATACENTER"; then
		aba_info "$_vsphere_label: skipping cluster/datastore/network/folder/resource-pool checks until datacenter resolves"
		return 1
	fi
	_vsphere_dc_found=1

	# RES-02: cluster under DC. Flag-set runs only on success so Layer 4 skips
	# privilege queries when the cluster object is missing (D-08 + D-06).
	if _vsphere_object_exists cluster "/$GOVC_DATACENTER/host/$GOVC_CLUSTER"; then
		_vsphere_cluster_found=1
	fi

	# RES-03a: primary datastore. Values may be bare names, folder-prefixed
	# (e.g. 'Folder/DS'), or absolute paths; the resolver handles all three.
	# Resolver return convention: success -> _vsphere_resolver_result holds
	# the resolved absolute path; failure -> resolver has already emitted the
	# warning and bumped _preflight_errors.
	if _vsphere_resolve_object datastore "$GOVC_DATASTORE" "/$GOVC_DATACENTER/datastore"; then
		_vsphere_datastore_path="$_vsphere_resolver_result"
		_vsphere_datastore_found=1
	fi

	# RES-03b: optional ISO_DATASTORE - probe only if set, non-empty, AND different
	# from GOVC_DATASTORE (D-06 + Pitfall 5 dedup guard: don't double-probe same path).
	if [ -n "${ISO_DATASTORE:-}" ] && [ "$ISO_DATASTORE" != "$GOVC_DATASTORE" ]; then
		if _vsphere_resolve_object datastore "$ISO_DATASTORE" "/$GOVC_DATACENTER/datastore"; then
			_vsphere_iso_datastore_path="$_vsphere_resolver_result"
			_vsphere_iso_datastore_found=1
		fi
	fi

	# RES-04: network existence AND attachment-to-cluster cross-check (D-08).
	# Resolver accepts bare DVS portgroup names (<portgroup>), nested paths
	# (dvSwitch-Foo/<portgroup>), and absolute paths - matches how OpenShift
	# consumes networks in install-config.yaml.
	# The attachment probe only runs when the network exists; the probe reads
	# _vsphere_network_path which is populated here before the call.
	if _vsphere_resolve_object network "$GOVC_NETWORK" "/$GOVC_DATACENTER/network"; then
		_vsphere_network_path="$_vsphere_resolver_result"
		_vsphere_network_found=1
		_vsphere_probe_resources_network_on_cluster || :
	fi

	# RES-05: VM folder. VC_FOLDER is optional (commented-out config is valid;
	# the installer creates the default folder). Skip the probe when empty
	# rather than running the resolver with an empty hint, which would land on
	# '/<DC>/vm/' and falsely bump the error counter.
	if [ -z "${VC_FOLDER:-}" ]; then
		aba_info "$_vsphere_label: VC_FOLDER not set, installer will create the default folder per cluster"
	elif _vsphere_resolve_object folder "$VC_FOLDER" "/$GOVC_DATACENTER/vm"; then
		_vsphere_folder_path="$_vsphere_resolver_result"
		_vsphere_folder_found=1
	fi

	# RES-06: resource pool - configured OR implicit default (Phase 2).
	# When GOVC_RESOURCE_POOL is unset we use the cluster's always-present default
	# pool path and a custom warning wording: the broken link in that case is the
	# CLUSTER itself (not the RP field), and we specifically do NOT tell the user
	# "try setting GOVC_RESOURCE_POOL" - that would mislead them into masking a
	# genuine cluster-configuration problem.
	# When set, the resolver handles bare names ('<resource-pool>'), nested
	# paths, and absolute paths - matches how OpenShift resolves resourcePool.
	if [ -z "${GOVC_RESOURCE_POOL:-}" ]; then
		local default_rp_path="/$GOVC_DATACENTER/host/$GOVC_CLUSTER/Resources"
		local rp_out rp_rc=0
		rp_out=$(govc object.collect -s "$default_rp_path" name 2>&1) || rp_rc=$?
		if [ "$rp_rc" -eq 0 ]; then
			_vsphere_resource_pool_path="$default_rp_path"
			_vsphere_resource_pool_found=1
			aba_info_ok "$_vsphere_label: using default resource pool '$default_rp_path'"
		else
			_vsphere_err "default resource pool '$default_rp_path' not found - verify the cluster is properly configured."
		fi
	else
		# 'p' = resource pool type filter on govc find; scopes bare-name searches
		# so we don't accidentally match a same-named object of a different type.
		if _vsphere_resolve_object "resource pool" "$GOVC_RESOURCE_POOL" "/$GOVC_DATACENTER/host/$GOVC_CLUSTER" p; then
			_vsphere_resource_pool_path="$_vsphere_resolver_result"
			_vsphere_resource_pool_found=1
		fi
	fi

	return 0
}

# --- Phase 2 Layer 4 helpers (private to this file) -----------------------

# Per-scope privilege probe (Phase 3 privilege validation; reuses Phase 2's two-step RBAC algorithm verbatim):
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
# $1  = lowercase scope-kind label ('root', 'datacenter', 'cluster', 'datastore', 'network', 'folder', 'resource pool')
# $2  = absolute scope path (e.g. '/', '/$GOVC_DATACENTER', or the resolved resource-pool path)
# $@  = required privilege strings (allowlist)
_vsphere_check_privileges() {
	local kind="$1"
	local scope_path="$2"
	shift 2
	local -a required_privs=("$@")

	# Step 1: list permissions. `-a=true` (default) includes inherited.
	# `out=$(cmd 2>&1)` is allowed variable capture (NOT `cmd 2>&1 | grep` pipeline).
	local perms_out perms_rc=0
	perms_out=$(govc permissions.ls "$scope_path" 2>&1) || perms_rc=$?

	# Query itself failed - emit a warning and return without bumping _preflight_errors.
	if [ "$perms_rc" -ne 0 ]; then
		local first_line
		first_line=$(echo "$perms_out" | head -1)
		_vsphere_warn "cannot verify write-access on '$scope_path'" \
			"govc permissions.ls said: $first_line" \
			"User may lack 'Permissions.ModifyPermissions' or equivalent read right." \
			"Skipping RES-07 for this scope; Phase 3 privilege query may still catch gaps."
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
		_vsphere_warn "user '$GOVC_USERNAME' has no role assigned on '$scope_path' (D-12; group assignments not resolved)"
		_vsphere_d12_count=$(( _vsphere_d12_count + 1 ))
		return 0
	fi

	# Step 3a: Admin role fast-path - vCenter built-in Admin has all privs by construction.
	if [ "$role_name" = "Admin" ]; then
		aba_info_ok "$_vsphere_label: $kind '$scope_path' user '$GOVC_USERNAME' has Admin role"
		return 0
	fi

	# Step 3b: "No access" explicit-deny role - every required priv is missing.
	if [ "$role_name" = "No access" ]; then
		local req
		for req in "${required_privs[@]}"; do
			_vsphere_err "$kind '$scope_path' missing privilege '$req' (user has role 'No access')"
		done
		return 0
	fi

	# Step 3c: Resolve role -> privilege list. Query-failure -> warning (not error).
	local role_privs role_rc=0
	role_privs=$(govc role.ls "$role_name" 2>&1) || role_rc=$?
	if [ "$role_rc" -ne 0 ]; then
		_vsphere_warn "cannot resolve privileges for role '$role_name' on '$scope_path'"
		return 0
	fi

	# Step 4: for each required privilege, grep the role's privilege set.
	# grep -qxF: quiet, whole-line, fixed-string (privilege names are exact matches, not regex).
	local req
	for req in "${required_privs[@]}"; do
		if ! echo "$role_privs" | grep -qxF -- "$req"; then
			_vsphere_err "$kind '$scope_path' missing privilege '$req'"
		fi
	done
	return 0
}

# Layer 4 sequencer (Phase 3). Iterates the 7 curated privilege scopes from
# scripts/vmware-required-privileges.sh and dispatches each to
# _vsphere_check_privileges with the matching VSPHERE_PRIVS_<SCOPE> array.
#
# D-09: ROOT is unconditional (/ always exists if Layer 2 auth passed).
# D-08: other six scopes are gated on the per-scope found-flag; a missing
#       object emits ONE aba_debug skip line (no counter bump - Layer 3's
#       "not found" warning already bumped once).
# D-11: ISO_DATASTORE is checked as a second DATASTORE scope only when set,
#       different from GOVC_DATASTORE, and confirmed present by Layer 3.
# D-17: after all scopes processed, emit ONE multi-line aba_warning summary
#       when at least one gap was recorded; emit nothing on clean pass.
# D-18: summary does NOT bump _preflight_errors (presentation only; the
#       individual gap warnings already bumped once each).
_vsphere_probe_privileges() {
	# ESXi has no vCenter-style RBAC; the curated 7-scope Permission.Has model
	# does not apply (logins are typically as root with implicit full privileges).
	if [ -z "${VC:-}" ]; then
		aba_info "$_vsphere_label: skipping vCenter privilege scope checks"
		return 0
	fi

	# administrator@vsphere.local has full privileges via the built-in
	# Administrators group. govc permissions.ls cannot resolve group membership,
	# so per-scope queries return "no role assigned" (D-12) on every scope —
	# all noise, no signal. Short-circuit to avoid misleading warnings.
	if [[ "$GOVC_USERNAME" == "administrator@vsphere.local" ]]; then
		aba_info_ok "$_vsphere_label: '$GOVC_USERNAME' is the built-in admin — skipping privilege scope checks"
		return 0
	fi

	# Source the curated privilege arrays. Re-sourcing is idempotent.
	source scripts/vmware-required-privileges.sh

	# D-17 mechanism: diff _preflight_errors pre/post for gap count (N);
	# increment scopes_with_gaps in each scope block for (M).
	local errors_before="$_preflight_errors"
	local scopes_with_gaps=0
	local before_scope

	# D-09: ROOT check is unconditional.
	before_scope="$_preflight_errors"
	_vsphere_check_privileges "root" "/" "${VSPHERE_PRIVS_ROOT[@]}"
	if [ "$_preflight_errors" -gt "$before_scope" ]; then
		scopes_with_gaps=$(( scopes_with_gaps + 1 ))
	fi

	# DATACENTER - gated on Layer 3 "datacenter found" flag.
	if [ "${_vsphere_dc_found:-0}" -eq 1 ]; then
		before_scope="$_preflight_errors"
		_vsphere_check_privileges "datacenter" "/$GOVC_DATACENTER" "${VSPHERE_PRIVS_DATACENTER[@]}"
		if [ "$_preflight_errors" -gt "$before_scope" ]; then
			scopes_with_gaps=$(( scopes_with_gaps + 1 ))
		fi
	else
		aba_debug "$_vsphere_label: skipping privilege check for missing datacenter '/$GOVC_DATACENTER'"
	fi

	# CLUSTER - gated on Layer 3 "cluster found" flag.
	if [ "${_vsphere_cluster_found:-0}" -eq 1 ]; then
		before_scope="$_preflight_errors"
		_vsphere_check_privileges "cluster" "/$GOVC_DATACENTER/host/$GOVC_CLUSTER" "${VSPHERE_PRIVS_CLUSTER[@]}"
		if [ "$_preflight_errors" -gt "$before_scope" ]; then
			scopes_with_gaps=$(( scopes_with_gaps + 1 ))
		fi
	else
		aba_debug "$_vsphere_label: skipping privilege check for missing cluster '/$GOVC_DATACENTER/host/$GOVC_CLUSTER'"
	fi

	# Per-scope privilege paths: prefer the Layer 3 resolved path (handles
	# bare names / DVS-nested portgroups / cluster-scoped RPs); fall back to
	# the flat-path construction so callers that invoke Layer 4 directly
	# without a prior Layer 3 probe still work against predictable paths.
	local ds_scope="${_vsphere_datastore_path:-/$GOVC_DATACENTER/datastore/$GOVC_DATASTORE}"
	local iso_ds_scope="${_vsphere_iso_datastore_path:-/$GOVC_DATACENTER/datastore/${ISO_DATASTORE:-}}"
	local net_scope="${_vsphere_network_path:-/$GOVC_DATACENTER/network/$GOVC_NETWORK}"
	local folder_scope="${_vsphere_folder_path:-$VC_FOLDER}"
	local rp_scope="${_vsphere_resource_pool_path:-$(resolve-default-resource-pool)}"

	# DATASTORE (primary) - gated on Layer 3 "datastore found" flag.
	if [ "${_vsphere_datastore_found:-0}" -eq 1 ]; then
		before_scope="$_preflight_errors"
		_vsphere_check_privileges "datastore" "$ds_scope" "${VSPHERE_PRIVS_DATASTORE[@]}"
		if [ "$_preflight_errors" -gt "$before_scope" ]; then
			scopes_with_gaps=$(( scopes_with_gaps + 1 ))
		fi
	else
		aba_debug "$_vsphere_label: skipping privilege check for missing datastore '$ds_scope'"
	fi

	# D-11: ISO_DATASTORE only when set, different from primary, AND found.
	if [ -n "${ISO_DATASTORE:-}" ] \
			&& [ "$ISO_DATASTORE" != "$GOVC_DATASTORE" ] \
			&& [ "${_vsphere_iso_datastore_found:-0}" -eq 1 ]; then
		before_scope="$_preflight_errors"
		_vsphere_check_privileges "datastore" "$iso_ds_scope" "${VSPHERE_PRIVS_DATASTORE[@]}"
		if [ "$_preflight_errors" -gt "$before_scope" ]; then
			scopes_with_gaps=$(( scopes_with_gaps + 1 ))
		fi
	fi

	# NETWORK - gated on Layer 3 "network found" flag.
	if [ "${_vsphere_network_found:-0}" -eq 1 ]; then
		before_scope="$_preflight_errors"
		_vsphere_check_privileges "network" "$net_scope" "${VSPHERE_PRIVS_NETWORK[@]}"
		if [ "$_preflight_errors" -gt "$before_scope" ]; then
			scopes_with_gaps=$(( scopes_with_gaps + 1 ))
		fi
	else
		aba_debug "$_vsphere_label: skipping privilege check for missing network '$net_scope'"
	fi

	# FOLDER - gated on Layer 3 "folder found" flag.
	if [ "${_vsphere_folder_found:-0}" -eq 1 ]; then
		before_scope="$_preflight_errors"
		_vsphere_check_privileges "folder" "$folder_scope" "${VSPHERE_PRIVS_FOLDER[@]}"
		if [ "$_preflight_errors" -gt "$before_scope" ]; then
			scopes_with_gaps=$(( scopes_with_gaps + 1 ))
		fi
	else
		aba_debug "$_vsphere_label: skipping privilege check for missing folder '$folder_scope'"
	fi

	# RESOURCE_POOL - gated on Layer 3 "resource pool found" flag.
	if [ "${_vsphere_resource_pool_found:-0}" -eq 1 ]; then
		before_scope="$_preflight_errors"
		_vsphere_check_privileges "resource pool" "$rp_scope" "${VSPHERE_PRIVS_RESOURCE_POOL[@]}"
		if [ "$_preflight_errors" -gt "$before_scope" ]; then
			scopes_with_gaps=$(( scopes_with_gaps + 1 ))
		fi
	else
		aba_debug "$_vsphere_label: skipping privilege check for missing resource pool '$rp_scope'"
	fi

	# D-17 summary: emit ONLY when gaps recorded (D-14 quiet-on-success).
	# D-18: summary does NOT bump _preflight_errors.
	local gap_count=$(( _preflight_errors - errors_before ))
	if [ "$gap_count" -gt 0 ]; then
		aba_warning -p Error "$_vsphere_label: $gap_count privilege gap(s) across $scopes_with_gaps scope(s)" \
			"Next: review the curated list at scripts/vmware-required-privileges.sh and the OpenShift docs linked in its header." \
			"Grant the missing privileges to the vCenter user or role and re-run aba install."
	fi

	# D-12 footer: explain the 'no role assigned' warnings are informational.
	# These fire when govc permissions.ls returns no DIRECT role binding for
	# the user - on enterprise vCenter deployments that almost always means
	# privileges arrive via AD/LDAP group membership, which govc cannot
	# expand. The install still proceeds; if the groups don't actually grant
	# the required privileges, the installer will fail later with a clear
	# privilege error at the real failure point.
	if [ "$_vsphere_d12_count" -gt 0 ]; then
		aba_info "$_vsphere_label: $_vsphere_d12_count privilege check(s) could not be pre-verified" \
			"Your user's privileges likely come from AD/LDAP group membership (govc cannot introspect groups)." \
			"This is INFORMATIONAL - the $_vsphere_d12_count warning(s) above do NOT block the install." \
			"aba install will proceed; if the effective privileges are insufficient, the installer will fail with a concrete privilege error."
	fi

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

	# Set display label based on detected target type (ESXi vs vCenter)
	if [ -z "${VC:-}" ]; then
		_vsphere_label="ESXi"
	else
		_vsphere_label="vSphere"
	fi

	# govc presence probe. `command -v` writes only to stdout; >/dev/null suppresses
	# stdout, not stderr - so this is NOT a stderr-suppression-ban violation.
	if ! command -v govc >/dev/null; then
		aba_abort "$_vsphere_label: govc CLI not found on PATH" \
			"Run: make -C cli govc  (or: aba -d cli/ install)"
	fi

	# CON-03 (moved from Phase 2 per D-09): required-field presence check.
	# DC / Cluster are vCenter-only; normalize-vmware-conf strips them and sets
	# VC= when the target host advertises 'API type: HostAgent' (ESXi). Treat
	# them as optional on ESXi shapes so a standalone-host vmware.conf does not
	# fail preflight before the deeper checks ever run.
	local required_fields=(GOVC_URL GOVC_USERNAME GOVC_PASSWORD GOVC_DATASTORE GOVC_NETWORK)
	if [ -n "${VC:-}" ]; then
		required_fields+=(GOVC_DATACENTER GOVC_CLUSTER)
	fi
	local missing=()
	local f
	for f in "${required_fields[@]}"; do
		# Indirect expansion: ${!f} expands to the value of the variable NAMED by $f.
		# :- default tolerates any future set -u without relying on it being set.
		if [ -z "${!f:-}" ]; then
			missing+=("$f")
		fi
	done

	if [ ${#missing[@]} -gt 0 ]; then
		# Loud on failure (D-14): one error line per missing field.
		# Bump _preflight_errors once per missing field; parent summary aborts on count > 0.
		# Never call 'exit' here - let the parent aggregation decide.
		for f in "${missing[@]}"; do
			_vsphere_err "required field '$f' is missing from vmware.conf"
		done
		return 0
	fi

	# Success (UX-01 / D-10): one aba_info_ok line; tell the user which shape
	# (ESXi vs vCenter) was detected so the reduced ESXi probe set is not
	# mistaken for a regression.
	if [ -z "${VC:-}" ]; then
		aba_info_ok "ESXi: direct host detected (reduced preflight: TCP+TLS+auth+datastore+network)"
	else
		aba_info_ok "vSphere: vCenter detected, running full checks..."
	fi

	# Phase 2 Layer 1 + Layer 2: connectivity (TCP + TLS) + auth. Short-circuit the
	# function on any layer failure; the `return 0` is deliberate - preflight_check_vsphere
	# always returns 0; counters signal gaps for the parent to aggregate.
	_vsphere_probe_tcp         || return 0
	_vsphere_probe_tls         || return 0
	_vsphere_probe_auth        || return 0
	_vsphere_probe_resources   || return 0
	_vsphere_probe_privileges
}
