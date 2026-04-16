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

	# RES-06 resource pool is wired by Plan 02-03 (after the resolve-default-resource-pool
	# helper lands in include_all.sh).

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
	_vsphere_probe_tcp       || return 0
	_vsphere_probe_tls       || return 0
	_vsphere_probe_auth      || return 0
	_vsphere_probe_resources || return 0

	# (Plan 02-03 inserts the resource-pool probe INSIDE _vsphere_probe_resources above;
	#  Plan 02-04 appends _vsphere_probe_writeaccess here.)
	# Phase 3 will add privilege validation here (sources scripts/vmware-required-privileges.sh).
}
