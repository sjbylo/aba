# Pre-flight bare-metal-specific checks: sourced by scripts/preflight-check.sh
# when platform=bm. Exports a single public function, preflight_check_bm.
#
# Sourced (not executed): no shebang, not chmod +x.
# Strict mode (set -e, ERR trap) and aba_* output helpers are inherited
# from the parent preflight-check.sh and scripts/include_all.sh.
#
# Runtime behaviour (Phase 5):
#   1. INT-03 silent-skip gates (bmc.conf absent or no bmc_host_* keys).
#   2. Load bmc.conf via normalize-bmc-conf (mode-0600 enforced there).
#   3. Required-field + bmc_type allowlist check per node (collect-all).
#   4. Fleet-level iso_url validation (explicit PRE-05 or auto PRE-06).
#   5. Per-node L1-L4 loop (node-first, per-node short-circuit).
#   6. Final summary line.
#
# Every operator-visible line begins with `BMC:` (UX-03). Counter bumps
# use `var=$(( var + 1 ))` form (UX-05; avoids ERR trap on pre-value 0).

# -----------------------------------------------------------------------------
# Shipped-vendor allowlist (VEN-07). Single source of truth for which bmc_type
# values are certified in this release. Plan 08-01 sets initial value; Plan 08-06
# expands based on which vendor adapter plans (08-02..08-05) passed the D-01
# <=30-line override-budget audit.
#
# Operators with bmc_type set to a syntactically allowed but unshipped value get
# the VEN-07 message at preflight time and aba install aborts (no auto-fallback).
# Audit grep target: ^_BM_SHIPPED_VENDORS=
# -----------------------------------------------------------------------------
_BM_SHIPPED_VENDORS="irmc redfish idrac ilo supermicro lenovo"

# -----------------------------------------------------------------------------
# Node listing: extract the <node> suffix from every bmc_host_<node>= line.
# Declaration order is preserved because grep + sed reads bmc.conf top-to-bottom.
# -----------------------------------------------------------------------------
_bm_node_list() {
	[ -f bmc.conf ] || return 0
	grep -E '^[[:space:]]*bmc_host_[A-Za-z0-9_-]+=' bmc.conf \
		| sed -E 's/^[[:space:]]*bmc_host_([A-Za-z0-9_-]+)=.*/\1/'
}

# -----------------------------------------------------------------------------
# Required-field + bmc_type allowlist check. Per CONTEXT.md D-12 step 2:
# for each bmc_host_<node>, confirm bmc_user_<node>, bmc_password_<node>,
# bmc_type_<node> are present; validate bmc_type_<node> against the allowlist.
# Collect all gaps across all nodes; do NOT short-circuit.
# -----------------------------------------------------------------------------
_bm_required_fields() {
	local node user_var pass_var type_var user pass btype
	for node in $(_bm_node_list); do
		user_var="bmc_user_${node}"
		pass_var="bmc_password_${node}"
		type_var="bmc_type_${node}"
		user="${!user_var}"
		pass="${!pass_var}"
		btype="${!type_var}"
		if [ -z "$user" ]; then
			aba_warning "BMC: $node missing required field bmc_user_${node} in bmc.conf"
			_preflight_errors=$(( _preflight_errors + 1 ))
		fi
		if [ -z "$pass" ]; then
			aba_warning "BMC: $node missing required field bmc_password_${node} in bmc.conf"
			_preflight_errors=$(( _preflight_errors + 1 ))
		fi
		if [ -z "$btype" ]; then
			aba_warning "BMC: $node missing required field bmc_type_${node} in bmc.conf"
			_preflight_errors=$(( _preflight_errors + 1 ))
		else
			case "$btype" in
				irmc|redfish|idrac|ilo|supermicro|lenovo)
					aba_debug "BMC: $node bmc_type=$btype (allowed)"
					;;
				*)
					aba_warning "BMC: $node bmc_type_${node}='$btype' not in allowlist {irmc, redfish, idrac, ilo, supermicro, lenovo}"
					_preflight_errors=$(( _preflight_errors + 1 ))
					;;
			esac
		fi
	done
}

# -----------------------------------------------------------------------------
# VEN-07 gate: per-node check that bmc_type is in $_BM_SHIPPED_VENDORS.
# Runs AFTER _bm_required_fields (which gates the syntactic allowlist).
# Collect-all: emits one warning per non-shipped node; bumps _preflight_errors.
# Verbatim message per REQUIREMENTS VEN-07.
# -----------------------------------------------------------------------------
_bm_check_shipped_vendors() {
	local node type_var btype
	for node in $(_bm_node_list); do
		type_var="bmc_type_${node}"
		btype="${!type_var}"
		[ -z "$btype" ] && continue
		case " $_BM_SHIPPED_VENDORS " in
			*" $btype "*)
				aba_debug "BMC: $node bmc_type=$btype (shipped in this release)"
				;;
			*)
				aba_warning "BMC: $node bmc_type $btype: not certified in this release; set bmc_type=redfish to try the generic adapter at your own risk"
				_preflight_errors=$(( _preflight_errors + 1 ))
				;;
		esac
	done
}

# -----------------------------------------------------------------------------
# Plan 04 implementations for PRE-05 and PRE-06 (replaces Plan 03 stubs).
# Plan 05 stubs (below) remain for _bm_build_auth, _bm_probe_l1..l4.
# -----------------------------------------------------------------------------
_bm_validate_iso_url() {
	# PRE-05 four sub-checks on an operator-supplied iso_url. Any failure blocks install.
	# Called once per preflight run (iso_url is cluster-level, not per-node).

	# Sub-check 1: scheme must be exactly http://
	if [[ "$iso_url" != http://* ]]; then
		aba_warning "BMC: iso_url must use http:// scheme (https:// rejected in v1.1; opt-in deferred)"
		_preflight_errors=$(( _preflight_errors + 1 ))
		return 1
	fi

	# Sub-check 2: no ? or & (iDRAC and iRMC reject special chars in InsertMedia).
	if [[ "$iso_url" == *"?"* ]] || [[ "$iso_url" == *"&"* ]]; then
		aba_warning "BMC: iso_url must not contain '?' or '&' (iDRAC/iRMC reject special chars in InsertMedia)"
		_preflight_errors=$(( _preflight_errors + 1 ))
		return 1
	fi

	# Sub-check 3: hostname resolves OR is a literal IPv4/IPv6.
	local rest hostport host
	rest="${iso_url#http://}"
	hostport="${rest%%/*}"
	host="${hostport%%:*}"
	if [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || [[ "$host" =~ ^\[.*\]$ ]]; then
		aba_debug "BMC: iso_url host '$host' is a literal IP"
	else
		local getent_tmp
		getent_tmp=$(mktemp /tmp/bmc_getent.XXXXXX)
		if getent hosts "$host" > "$getent_tmp"; then
			rm -f "$getent_tmp"
			aba_debug "BMC: iso_url host '$host' resolves via getent"
		else
			rm -f "$getent_tmp"
			aba_warning "BMC: iso_url host '$host' does not resolve (check /etc/hosts or DNS)"
			_preflight_errors=$(( _preflight_errors + 1 ))
			return 1
		fi
	fi

	# Sub-check 4: HEAD returns 200 with Content-Length and without chunked.
	# Captures stderr into a variable via 2>&1 (allowed pattern; not a stderr-suppression).
	local head_out rc=0
	head_out=$(curl -sI --fail --max-time 10 "$iso_url" 2>&1) || rc=$?
	if [ "$rc" -ne 0 ]; then
		aba_warning "BMC: iso_url HEAD failed: $(printf '%s' "$head_out" | head -1)"
		_preflight_errors=$(( _preflight_errors + 1 ))
		return 1
	fi
	if ! printf '%s' "$head_out" | grep -qi '^Content-Length:'; then
		aba_warning "BMC: iso_url HEAD has no Content-Length header (some BMC firmware will reject - serve via python3 -m http.server or nginx)"
		_preflight_errors=$(( _preflight_errors + 1 ))
		return 1
	fi
	if printf '%s' "$head_out" | grep -qi '^Transfer-Encoding:[[:space:]]*chunked'; then
		aba_warning "BMC: iso_url HEAD has Transfer-Encoding: chunked (older BMC firmware rejects chunked; serve via python3 -m http.server)"
		_preflight_errors=$(( _preflight_errors + 1 ))
		return 1
	fi
	# Sub-check 5 (D-05c): iDRAC URL <=255 char guard. Runs only if any node has
	# bmc_type=idrac. Dell iDRAC9 truncates Image URLs above 255 chars silently,
	# producing a false-success InsertMedia that fails to mount.
	local has_idrac=0 node type_var btype
	for node in $(_bm_node_list); do
		type_var="bmc_type_${node}"
		btype="${!type_var}"
		[ "$btype" = "idrac" ] && { has_idrac=1; break; }
	done
	if [ "$has_idrac" = "1" ]; then
		if [ "${#iso_url}" -gt 255 ]; then
			aba_warning "BMC: iso_url length ${#iso_url} exceeds 255 chars (Dell iDRAC9 limit); shorten the URL or move to a shorter hostname"
			_preflight_errors=$(( _preflight_errors + 1 ))
			return 1
		fi
		aba_debug "BMC: iso_url length ${#iso_url} chars (within iDRAC9 255 limit)"
	fi
	aba_debug "BMC: iso_url PRE-05 all 4 sub-checks passed"
	return 0
}

_bm_derive_iso_url() {
	# PRE-06 auto-derive bastion src IP per unique bmc_host. Called when iso_url is absent.
	# Arg: bmc_host
	# D-15: kernel routing picks the correct src IP based on the route table.
	# D-16a: derived src_ip MUST be bindable on this bastion (belt-and-braces sanity check).
	# D-16b: iso file existence is conditional - first run skips, re-runs validate readability.

	local bmc_host="$1"

	# Capture ip route get output (stderr allowed - we want the error in route_out).
	local route_out rc=0
	route_out=$(ip route get "$bmc_host" 2>&1) || rc=$?
	if [ "$rc" -ne 0 ]; then
		aba_warning "BMC: cannot derive bastion src IP - 'ip route get $bmc_host' failed: $(printf '%s' "$route_out" | head -1)"
		_preflight_errors=$(( _preflight_errors + 1 ))
		return 1
	fi

	# Awk token-walk: find 'src' keyword, print the next token, exit on first match.
	# Ignores the 'cache' continuation line naturally.
	local src_ip
	src_ip=$(printf '%s\n' "$route_out" | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
	if [ -z "$src_ip" ]; then
		aba_warning "BMC: cannot derive bastion src IP from 'ip route get $bmc_host' output (no 'src' token found - check default route)"
		_preflight_errors=$(( _preflight_errors + 1 ))
		return 1
	fi

	# D-16a: src_ip MUST be bindable (present on a local interface).
	local addr_list
	addr_list=$(ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1)
	if ! printf '%s\n' "$addr_list" | grep -qxF "$src_ip"; then
		aba_warning "BMC: $bmc_host auto-derived bastion src IP $src_ip is not present on any local interface"
		_preflight_errors=$(( _preflight_errors + 1 ))
		return 1
	fi
	aba_debug "BMC: $bmc_host auto-derived bastion src IP $src_ip (will serve at http://$src_ip:<port>/ in Phase 6)"

	# D-16b: conditional ISO file check. First run: skip. Re-run: validate readability.
	local iso_path="iso-agent-based/agent.${ARCH:-x86_64}.iso"
	if [ ! -f "$iso_path" ]; then
		aba_debug "BMC: $bmc_host iso file $iso_path not yet generated - deferring existence check to Phase 6 server-start"
	elif [ ! -r "$iso_path" ]; then
		aba_warning "BMC: iso file $iso_path exists but is not readable"
		_preflight_errors=$(( _preflight_errors + 1 ))
		return 1
	fi
	return 0
}

_bm_build_auth() {
	# Credential construction for BMC Authorization header. Single grep-able audit surface.
	# Arg: node name (bmc_host_<node> suffix).
	# Stdout: base64(user:pass) with NO trailing newline and NO line wrap.
	# Return: 0 on success; 1 on missing user/pass (with aba_warning).
	#
	# D-06 invariants:
	# - Every password read uses ${!pass_var} indirection (grep-auditable).
	# - printf (not echo) avoids trailing newline in the base64 input.
	# - base64 -w0 (not default) avoids 76-char line wrap breaking Authorization header.
	# - The plaintext password is local to this function's frame; bash discards it on return.

	local node="$1"
	local user_var="bmc_user_${node}"
	local pass_var="bmc_password_${node}"
	local user pass
	user="${!user_var}"
	pass="${!pass_var}"
	if [ -z "$user" ] || [ -z "$pass" ]; then
		aba_warning "BMC: $node bmc_user_${node} or bmc_password_${node} not set in bmc.conf"
		_preflight_errors=$(( _preflight_errors + 1 ))
		return 1
	fi
	printf '%s:%s' "$user" "$pass" | base64 -w0
}

_bm_probe_l1() {
	# Layer 1: TCP reachability probe to BMC Redfish port.
	# Uses bash /dev/tcp redirect inside a `timeout 3 bash -c ...` invocation.
	# UX-05 compliance: bash's own "connect: Connection refused" noise is CAPTURED
	# via 2>&1 into a local `err` variable (NOT suppressed). On failure, the captured
	# stderr is surfaced to the operator in the aba_warning message, so the underlying
	# kernel/network reason is visible. On success, `err` is discarded.

	local node="$1"
	local host_var="bmc_host_${node}"
	local host="${!host_var}"
	local err rc
	# Run the probe; capture BOTH stdout and stderr from the subshell into `err`.
	# `echo >/dev/tcp/...` prints nothing on stdout; all output on the failure path
	# is bash's own stderr message, which we want the operator to see if L1 fails.
	err=$(timeout 3 bash -c "echo >/dev/tcp/$host/443" 2>&1)
	rc=$?
	if [ "$rc" = "0" ]; then
		aba_debug "BMC: $node L1 TCP reach to $host:443 ok"
		return 0
	fi
	# Sanitize: collapse internal newlines into single-space so the warning stays
	# one line. Strip any leading/trailing whitespace. Never emit credentials
	# (this probe has none), so the captured stderr is safe to echo.
	local err_one
	err_one=$(printf '%s' "$err" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')
	if [ -z "$err_one" ]; then
		err_one="timeout or unknown error (rc=$rc)"
	fi
	aba_warning "BMC: $node L1=FAIL reason=\"cannot reach $host:443 (TCP): $err_one - check DNS/firewall/bmc_host_${node}\""
	_preflight_errors=$(( _preflight_errors + 1 ))
	return 1
}

_bm_probe_l2() {
	# Layer 2: Redfish root auth at GET /redfish/v1/ (PRE-02).
	# PRE-07 piggy-backs: counts open sessions on the same curl connection.
	# UX-05 invariant: jq is called ONLY after the body has been confirmed to
	# come back with HTTP 200. If the status is not 200, we skip jq entirely
	# (setting safe defaults) so we never feed non-JSON to jq. This avoids the
	# need for jq parse-error stderr suppression entirely (UX-05).

	local node="$1"
	local host_var="bmc_host_${node}"
	local insecure_var="bmc_insecure_${node}"
	local host="${!host_var}"
	local insecure="${!insecure_var}"
	local auth
	auth=$(_bm_build_auth "$node") || return 1

	local insecure_flag=""
	case "$insecure" in
		1|true|True|TRUE|yes|YES) insecure_flag="-k" ;;
	esac

	# 2a - Redfish root auth (PRE-02). Capture body in tmpfile + status code on stdout.
	local root_tmp code
	root_tmp=$(mktemp /tmp/bmc_root_${node}.XXXXXX)
	code=$(curl -s $insecure_flag -m 10 \
		-H "Authorization: Basic $auth" \
		-H "Accept: application/json" \
		-o "$root_tmp" \
		-w '%{http_code}' \
		"https://$host/redfish/v1/") || code="000"
	rm -f "$root_tmp"
	if [ "$code" != "200" ]; then
		aba_warning "BMC: $node L2=FAIL reason=\"HTTP $code on /redfish/v1/\""
		_preflight_errors=$(( _preflight_errors + 1 ))
		return 1
	fi
	aba_debug "BMC: $node L2 auth ok (HTTP 200 on /redfish/v1/)"

	# 2b - PRE-07 session count piggy-back. Same auth; connection reuse via keep-alive.
	# Fetch Sessions collection: capture status + body in tmpfile. jq runs ONLY if 200.
	local sess_tmp sess_code used=0
	sess_tmp=$(mktemp /tmp/bmc_sess_${node}.XXXXXX)
	sess_code=$(curl -s $insecure_flag -m 5 \
		-H "Authorization: Basic $auth" \
		-H "Accept: application/json" \
		-o "$sess_tmp" \
		-w '%{http_code}' \
		"https://$host/redfish/v1/SessionService/Sessions") || sess_code="000"
	if [ "$sess_code" = "200" ]; then
		# Body is a well-formed JSON object (HTTP 200 gate). Parse count; defensive
		# fallback handles firmware that omits Members@odata.count.
		used=$(jq -r '."Members@odata.count" // (.Members | length) // 0' "$sess_tmp")
	else
		aba_debug "BMC: $node SessionService/Sessions returned HTTP $sess_code (PRE-07 count skipped)"
	fi
	rm -f "$sess_tmp"
	# Defensive coerce to integer (jq could emit '' or 'null' on a weird-but-valid body).
	case "$used" in
		''|*[!0-9]*) used=0 ;;
	esac

	# Fetch SessionService: capture status + body. jq runs ONLY if 200.
	local svc_tmp svc_code max=""
	svc_tmp=$(mktemp /tmp/bmc_svc_${node}.XXXXXX)
	svc_code=$(curl -s $insecure_flag -m 5 \
		-H "Authorization: Basic $auth" \
		-H "Accept: application/json" \
		-o "$svc_tmp" \
		-w '%{http_code}' \
		"https://$host/redfish/v1/SessionService") || svc_code="000"
	if [ "$svc_code" = "200" ]; then
		max=$(jq -r '.MaxSessions // empty' "$svc_tmp")
	else
		aba_debug "BMC: $node SessionService returned HTTP $svc_code (MaxSessions lookup skipped)"
	fi
	rm -f "$svc_tmp"
	if [ -z "$max" ] || ! [[ "$max" =~ ^[0-9]+$ ]]; then
		aba_debug "BMC: $node MaxSessions absent on this firmware, using fallback 16"
		max=16
	fi

	local half=$(( max / 2 ))
	if [ "$used" -ge "$half" ] && [ "$half" -gt 0 ]; then
		aba_warning "BMC: $node $used/$max Redfish sessions in use (near limit)"
		_preflight_warnings=$(( _preflight_warnings + 1 ))
	else
		aba_debug "BMC: $node session count $used/$max (ok)"
	fi

	return 0
}

_bm_probe_l3() {
	# Layer 3: VirtualMedia collection + InsertMedia action discovery (PRE-03).
	# Distinguishes license-gate (403/404 on collection) from other failures with
	# a distinct operator message per D-14.
	# UX-05: every jq call is gated by a preceding HTTP 200 status check.

	local node="$1"
	local host_var="bmc_host_${node}"
	local insecure_var="bmc_insecure_${node}"
	local host="${!host_var}"
	local insecure="${!insecure_var}"
	local auth
	auth=$(_bm_build_auth "$node") || return 1

	local insecure_flag=""
	case "$insecure" in
		1|true|True|TRUE|yes|YES) insecure_flag="-k" ;;
	esac

	# Managers collection: capture status + body; jq only on HTTP 200.
	local mgr_tmp mgr_code mgr_link=""
	mgr_tmp=$(mktemp /tmp/bmc_mgr_${node}.XXXXXX)
	mgr_code=$(curl -s $insecure_flag -m 5 \
		-H "Authorization: Basic $auth" \
		-H "Accept: application/json" \
		-o "$mgr_tmp" \
		-w '%{http_code}' \
		"https://$host/redfish/v1/Managers") || mgr_code="000"
	if [ "$mgr_code" = "200" ]; then
		mgr_link=$(jq -r '.Members[0]."@odata.id" // empty' "$mgr_tmp")
	fi
	rm -f "$mgr_tmp"
	if [ -z "$mgr_link" ]; then
		aba_warning "BMC: $node L3=FAIL reason=\"Managers collection (HTTP $mgr_code) has no members\""
		_preflight_errors=$(( _preflight_errors + 1 ))
		return 1
	fi

	# VirtualMedia collection: 403/404 = license gate (distinct message); other codes = generic.
	local vm_tmp vm_code
	vm_tmp=$(mktemp /tmp/bmc_vm_${node}.XXXXXX)
	vm_code=$(curl -s $insecure_flag -m 5 \
		-H "Authorization: Basic $auth" \
		-H "Accept: application/json" \
		-o "$vm_tmp" \
		-w '%{http_code}' \
		"https://$host${mgr_link}/VirtualMedia") || vm_code="000"

	if [ "$vm_code" = "403" ] || [ "$vm_code" = "404" ]; then
		rm -f "$vm_tmp"
		aba_warning "BMC: $node L3=FAIL reason=\"VirtualMedia not licensed on this BMC\""
		_preflight_errors=$(( _preflight_errors + 1 ))
		return 1
	fi
	if [ "$vm_code" != "200" ]; then
		rm -f "$vm_tmp"
		aba_warning "BMC: $node L3=FAIL reason=\"HTTP $vm_code on VirtualMedia collection\""
		_preflight_errors=$(( _preflight_errors + 1 ))
		return 1
	fi

	# Collection body is a well-formed 200 JSON; jq is safe here.
	local members
	members=$(jq -r '.Members[]."@odata.id"' "$vm_tmp")
	rm -f "$vm_tmp"
	if [ -z "$members" ]; then
		aba_warning "BMC: $node L3=FAIL reason=\"VirtualMedia collection empty\""
		_preflight_errors=$(( _preflight_errors + 1 ))
		return 1
	fi

	# Walk members; first slot with CD or DVD in MediaTypes AND an InsertMedia action target wins.
	local m mem_tmp mem_code has_cd has_action found_cd=0
	for m in $members; do
		mem_tmp=$(mktemp /tmp/bmc_vmm_${node}.XXXXXX)
		mem_code=$(curl -s $insecure_flag -m 5 \
			-H "Authorization: Basic $auth" \
			-H "Accept: application/json" \
			-o "$mem_tmp" \
			-w '%{http_code}' \
			"https://$host$m") || mem_code="000"
		if [ "$mem_code" != "200" ]; then
			aba_debug "BMC: $node VirtualMedia member $m returned HTTP $mem_code (skip)"
			rm -f "$mem_tmp"
			continue
		fi
		has_cd=$(jq -r '[.MediaTypes[]?] | map(select(. == "CD" or . == "DVD")) | length' "$mem_tmp")
		has_action=$(jq -r '.Actions["#VirtualMedia.InsertMedia"].target // empty' "$mem_tmp")
		rm -f "$mem_tmp"
		case "$has_cd" in
			''|*[!0-9]*) has_cd=0 ;;
		esac
		if [ "$has_cd" -gt 0 ] && [ -n "$has_action" ]; then
			aba_debug "BMC: $node L3 VirtualMedia slot $m accepts CD/DVD inserts"
			found_cd=1
			break
		fi
	done

	if [ "$found_cd" = "0" ]; then
		aba_warning "BMC: $node L3=FAIL reason=\"no VirtualMedia slot accepts CD/DVD inserts with InsertMedia action\""
		_preflight_errors=$(( _preflight_errors + 1 ))
		return 1
	fi
	return 0
}

_bm_probe_l4() {
	# Layer 4: BootSourceOverride allowables probe (PRE-04).
	# Cd is the standard; Supermicro uses UsbCd. Either is acceptable at this layer -
	# the per-vendor adapter (Phase 6) picks the right one when performing the PATCH.
	# UX-05: every jq is gated behind an HTTP 200 status check.

	local node="$1"
	local host_var="bmc_host_${node}"
	local insecure_var="bmc_insecure_${node}"
	local host="${!host_var}"
	local insecure="${!insecure_var}"
	local auth
	auth=$(_bm_build_auth "$node") || return 1

	local insecure_flag=""
	case "$insecure" in
		1|true|True|TRUE|yes|YES) insecure_flag="-k" ;;
	esac

	# Systems collection: capture status + body; jq only on HTTP 200.
	local sys_tmp sys_code sys_link=""
	sys_tmp=$(mktemp /tmp/bmc_sys_${node}.XXXXXX)
	sys_code=$(curl -s $insecure_flag -m 5 \
		-H "Authorization: Basic $auth" \
		-H "Accept: application/json" \
		-o "$sys_tmp" \
		-w '%{http_code}' \
		"https://$host/redfish/v1/Systems") || sys_code="000"
	if [ "$sys_code" = "200" ]; then
		sys_link=$(jq -r '.Members[0]."@odata.id" // empty' "$sys_tmp")
	fi
	rm -f "$sys_tmp"
	if [ -z "$sys_link" ]; then
		aba_warning "BMC: $node L4=FAIL reason=\"Systems collection (HTTP $sys_code) has no members\""
		_preflight_errors=$(( _preflight_errors + 1 ))
		return 1
	fi

	# System resource: capture status + body; jq only on HTTP 200.
	local one_tmp one_code
	one_tmp=$(mktemp /tmp/bmc_sys1_${node}.XXXXXX)
	one_code=$(curl -s $insecure_flag -m 5 \
		-H "Authorization: Basic $auth" \
		-H "Accept: application/json" \
		-o "$one_tmp" \
		-w '%{http_code}' \
		"https://$host$sys_link") || one_code="000"
	if [ "$one_code" != "200" ]; then
		rm -f "$one_tmp"
		aba_warning "BMC: $node L4=FAIL reason=\"HTTP $one_code on $sys_link\""
		_preflight_errors=$(( _preflight_errors + 1 ))
		return 1
	fi

	# target_ok is the index of "Cd" or "UsbCd" if found, else empty.
	# enabled_ok is the index of "Once" if found, else empty.
	local target_ok enabled_ok
	target_ok=$(jq -r '.Boot."BootSourceOverrideTarget@Redfish.AllowableValues" // [] | (index("Cd") // index("UsbCd")) // empty' "$one_tmp")
	enabled_ok=$(jq -r '.Boot."BootSourceOverrideEnabled@Redfish.AllowableValues" // [] | index("Once") // empty' "$one_tmp")
	rm -f "$one_tmp"

	if [ -z "$target_ok" ]; then
		aba_warning "BMC: $node L4=FAIL reason=\"neither Cd nor UsbCd in BootSourceOverrideTarget allowables\""
		_preflight_errors=$(( _preflight_errors + 1 ))
		return 1
	fi
	if [ -z "$enabled_ok" ]; then
		aba_warning "BMC: $node L4=FAIL reason=\"Once not in BootSourceOverrideEnabled allowables\""
		_preflight_errors=$(( _preflight_errors + 1 ))
		return 1
	fi
	aba_debug "BMC: $node L4 BootSourceOverride allowables ok"
	return 0
}

# -----------------------------------------------------------------------------
# Layer 5 (vendor-specific) probes. Dispatched from preflight_check_bm
# per-node loop AFTER L4 succeeds. Each probe targets vendor-specific gates
# that L1-L4 cannot express (firmware version floors, model-string detection,
# license tiers). Per CONTEXT D-02: L5 code is unbudgeted; <=30 lines per
# helper is an informal target.
# -----------------------------------------------------------------------------

_bm_probe_l5_idrac() {
	# D-05a: iDRAC10 hard-fail (Manager Model contains "iDRAC10" or FirmwareVersion starts with "7.").
	# D-05b: iDRAC9 firmware floor (>= 4.40.10.00 Intel / >= 6.00.00.00 AMD; CPU vendor inferred from major).
	local node="$1"
	local host_var="bmc_host_${node}"
	local insecure_var="bmc_insecure_${node}"
	local host="${!host_var}"
	local insecure="${!insecure_var}"
	local auth
	auth=$(_bm_build_auth "$node") || return 1

	local insecure_flag=""
	case "$insecure" in
		1|true|True|TRUE|yes|YES) insecure_flag="-k" ;;
	esac

	# Step 1: discover Manager link.
	local mgr_tmp mgr_code mgr_link=""
	mgr_tmp=$(mktemp /tmp/bmc_l5_idrac_${node}.XXXXXX)
	mgr_code=$(curl -s $insecure_flag -m 10 \
		-H "Authorization: Basic $auth" \
		-H "Accept: application/json" \
		-o "$mgr_tmp" \
		-w '%{http_code}' \
		"https://$host/redfish/v1/Managers") || mgr_code="000"
	if [ "$mgr_code" = "200" ]; then
		mgr_link=$(jq -r '.Members[0]."@odata.id" // empty' "$mgr_tmp")
	fi
	rm -f "$mgr_tmp"
	if [ -z "$mgr_link" ]; then
		aba_warning "BMC: $node L5=FAIL reason=\"HTTP $mgr_code on /redfish/v1/Managers\""
		_preflight_errors=$(( _preflight_errors + 1 ))
		return 1
	fi

	# Step 2: GET Manager resource and parse Model + FirmwareVersion.
	local m_tmp m_code model fwver=""
	m_tmp=$(mktemp /tmp/bmc_l5_idrac_${node}.XXXXXX)
	m_code=$(curl -s $insecure_flag -m 10 \
		-H "Authorization: Basic $auth" \
		-H "Accept: application/json" \
		-o "$m_tmp" \
		-w '%{http_code}' \
		"https://$host$mgr_link") || m_code="000"
	if [ "$m_code" = "200" ]; then
		model=$(jq -r '.Model // empty' "$m_tmp")
		fwver=$(jq -r '.FirmwareVersion // empty' "$m_tmp")
	fi
	rm -f "$m_tmp"
	if [ -z "$fwver" ]; then
		aba_warning "BMC: $node L5=FAIL reason=\"HTTP $m_code on Manager resource (FirmwareVersion missing)\""
		_preflight_errors=$(( _preflight_errors + 1 ))
		return 1
	fi

	# Step 3: iDRAC10 hard-fail (D-05a). Check BEFORE firmware floor so the message
	# is accurate ("not yet supported" instead of misleading "below minimum").
	if echo "$model" | grep -qi "iDRAC10" || [[ "$fwver" == 7.* ]]; then
		aba_warning "BMC: $node L5=FAIL reason=\"iDRAC10 not yet supported - bmc_type=idrac targets iDRAC9 only in v1.1; downgrade to iDRAC9 or set bmc_type=redfish to try the generic adapter at your own risk\""
		_preflight_errors=$(( _preflight_errors + 1 ))
		return 1
	fi

	# Step 4: iDRAC9 firmware floor (D-05b).
	# CPU vendor inferred from firmware major: 4-5 = Intel (>= 4.40.10.00); 6 = AMD (>= 6.00.00.00).
	local major minor patch build
	IFS=. read -r major minor patch build <<<"$fwver"
	case "$major" in
		''|*[!0-9]*)
			aba_warning "BMC: $node L5=FAIL reason=\"iDRAC FirmwareVersion '$fwver' not parseable as N.N.N.N\""
			_preflight_errors=$(( _preflight_errors + 1 ))
			return 1
			;;
	esac
	local floor_ok=0
	if [ "$major" -ge 6 ]; then
		# AMD floor: >= 6.00.00.00 (any 6.x considered satisfying floor).
		floor_ok=1
	elif [ "$major" -ge 4 ]; then
		# Intel floor: >= 4.40.10.00. Compare minor.patch.build numerically.
		case "$minor" in ''|*[!0-9]*) minor=0 ;; esac
		case "$patch" in ''|*[!0-9]*) patch=0 ;; esac
		case "$build" in ''|*[!0-9]*) build=0 ;; esac
		if [ "$major" -ge 5 ]; then
			floor_ok=1
		elif [ "$minor" -gt 40 ]; then
			floor_ok=1
		elif [ "$minor" -eq 40 ] && [ "$patch" -gt 10 ]; then
			floor_ok=1
		elif [ "$minor" -eq 40 ] && [ "$patch" -eq 10 ] && [ "$build" -ge 0 ]; then
			floor_ok=1
		fi
	fi
	if [ "$floor_ok" = "0" ]; then
		aba_warning "BMC: $node L5=FAIL reason=\"iDRAC firmware $fwver below v1.1 minimum (4.40.10.00 Intel / 6.00.00.00 AMD); upgrade or set bmc_type=redfish at your own risk\""
		_preflight_errors=$(( _preflight_errors + 1 ))
		return 1
	fi

	aba_debug "BMC: $node L5 iDRAC firmware $fwver (model=\"$model\") (ok)"
	return 0
}

_bm_probe_l5_ilo() {
	# D-08: iLO 4 hard-fail. Match Manager Model containing "iLO 4" or
	# "Integrated Lights-Out 4" (case-insensitive). HPE's Redfish API Reference
	# documents Model as "Integrated Lights-Out N" (N=4,5,6) consistently.
	# FirmwareVersion-based detection is rejected (D-08a): iLO 5 also has 2.x
	# firmware lines.
	local node="$1"
	local host_var="bmc_host_${node}"
	local insecure_var="bmc_insecure_${node}"
	local host="${!host_var}"
	local insecure="${!insecure_var}"
	local auth
	auth=$(_bm_build_auth "$node") || return 1

	local insecure_flag=""
	case "$insecure" in
		1|true|True|TRUE|yes|YES) insecure_flag="-k" ;;
	esac

	# Step 1: discover Manager link.
	local mgr_tmp mgr_code mgr_link=""
	mgr_tmp=$(mktemp /tmp/bmc_l5_ilo_${node}.XXXXXX)
	mgr_code=$(curl -s $insecure_flag -m 10 \
		-H "Authorization: Basic $auth" \
		-H "Accept: application/json" \
		-o "$mgr_tmp" \
		-w '%{http_code}' \
		"https://$host/redfish/v1/Managers") || mgr_code="000"
	if [ "$mgr_code" = "200" ]; then
		mgr_link=$(jq -r '.Members[0]."@odata.id" // empty' "$mgr_tmp")
	fi
	rm -f "$mgr_tmp"
	if [ -z "$mgr_link" ]; then
		aba_warning "BMC: $node L5=FAIL reason=\"HTTP $mgr_code on /redfish/v1/Managers\""
		_preflight_errors=$(( _preflight_errors + 1 ))
		return 1
	fi

	# Step 2: GET Manager and parse Model.
	local m_tmp m_code model=""
	m_tmp=$(mktemp /tmp/bmc_l5_ilo_${node}.XXXXXX)
	m_code=$(curl -s $insecure_flag -m 10 \
		-H "Authorization: Basic $auth" \
		-H "Accept: application/json" \
		-o "$m_tmp" \
		-w '%{http_code}' \
		"https://$host$mgr_link") || m_code="000"
	if [ "$m_code" = "200" ]; then
		model=$(jq -r '.Model // empty' "$m_tmp")
	fi
	rm -f "$m_tmp"
	if [ -z "$model" ]; then
		aba_warning "BMC: $node L5=FAIL reason=\"HTTP $m_code on Manager resource (Model missing)\""
		_preflight_errors=$(( _preflight_errors + 1 ))
		return 1
	fi

	# Step 3: iLO 4 hard-fail (case-insensitive substring match per D-08a).
	if echo "$model" | grep -qiE 'iLO 4|Integrated Lights-Out 4'; then
		aba_warning "BMC: $node L5=FAIL reason=\"iLO 4 not supported - Redfish VirtualMedia non-standard; upgrade to iLO 5 or replace hardware\""
		_preflight_errors=$(( _preflight_errors + 1 ))
		return 1
	fi

	aba_debug "BMC: $node L5 iLO model=\"$model\" (ok)"
	return 0
}

_bm_probe_l5_supermicro() {
	# D-09 (Claude's discretion): X12/X13 model sanity check. Older X11 boards
	# may work via the generic adapter's standard path but are not certified.
	# X11 nodes get a non-blocking warning (no _preflight_errors bump) so the
	# operator can proceed at their own risk; X12/X13 pass silently.
	# License gate: SFT-DCMS-SINGLE / SFT-OOB-LIC absence already surfaces at
	# L3 ("VirtualMedia not licensed") per Phase 5 D-14; no L5 license probe.
	local node="$1"
	local host_var="bmc_host_${node}"
	local insecure_var="bmc_insecure_${node}"
	local host="${!host_var}"
	local insecure="${!insecure_var}"
	local auth
	auth=$(_bm_build_auth "$node") || return 1

	local insecure_flag=""
	case "$insecure" in
		1|true|True|TRUE|yes|YES) insecure_flag="-k" ;;
	esac

	# Step 1: discover Manager link.
	local mgr_tmp mgr_code mgr_link=""
	mgr_tmp=$(mktemp /tmp/bmc_l5_smc_${node}.XXXXXX)
	mgr_code=$(curl -s $insecure_flag -m 10 \
		-H "Authorization: Basic $auth" \
		-H "Accept: application/json" \
		-o "$mgr_tmp" \
		-w '%{http_code}' \
		"https://$host/redfish/v1/Managers") || mgr_code="000"
	if [ "$mgr_code" = "200" ]; then
		mgr_link=$(jq -r '.Members[0]."@odata.id" // empty' "$mgr_tmp")
	fi
	rm -f "$mgr_tmp"
	if [ -z "$mgr_link" ]; then
		aba_warning "BMC: $node L5=FAIL reason=\"HTTP $mgr_code on /redfish/v1/Managers\""
		_preflight_errors=$(( _preflight_errors + 1 ))
		return 1
	fi

	# Step 2: GET Manager and parse Model.
	local m_tmp m_code model=""
	m_tmp=$(mktemp /tmp/bmc_l5_smc_${node}.XXXXXX)
	m_code=$(curl -s $insecure_flag -m 10 \
		-H "Authorization: Basic $auth" \
		-H "Accept: application/json" \
		-o "$m_tmp" \
		-w '%{http_code}' \
		"https://$host$mgr_link") || m_code="000"
	if [ "$m_code" = "200" ]; then
		model=$(jq -r '.Model // empty' "$m_tmp")
	fi
	rm -f "$m_tmp"
	if [ -z "$model" ]; then
		# Manager Model field absent on this firmware - non-fatal; proceed.
		aba_debug "BMC: $node L5 Supermicro Model field absent (HTTP $m_code) - proceeding"
		return 0
	fi

	# Step 3: X12/X13 sanity (case-insensitive substring match). Older X11 gets
	# a non-blocking warning; X12/X13 pass silently.
	if echo "$model" | grep -qiE 'X12|X13'; then
		aba_debug "BMC: $node L5 Supermicro model=\"$model\" (X12/X13 ok)"
		return 0
	fi
	aba_warning "BMC: $node L5 Supermicro model=\"$model\" not in tested set {X12, X13}; proceeding at operator risk"
	return 0
}

_bm_probe_l5_lenovo() {
	# D-09 Claude's discretion: Lenovo XCC Enterprise license check via
	# Oem.Lenovo.LicenseFeatures in Manager resource. Per Red Hat KCS 6958685,
	# Enterprise tier is required for VirtualMedia ZTP. The license-features
	# array contains feature flag names; "RemoteMedia" or "VirtualMedia" in
	# the array means the tier supports remote ISO mounting.
	# If the Oem.Lenovo path is absent (older firmware or non-Lenovo BMC),
	# emit a non-blocking warning and proceed at operator risk.
	local node="$1"
	local host_var="bmc_host_${node}"
	local insecure_var="bmc_insecure_${node}"
	local host="${!host_var}"
	local insecure="${!insecure_var}"
	local auth
	auth=$(_bm_build_auth "$node") || return 1

	local insecure_flag=""
	case "$insecure" in
		1|true|True|TRUE|yes|YES) insecure_flag="-k" ;;
	esac

	# Step 1: discover Manager link.
	local mgr_tmp mgr_code mgr_link=""
	mgr_tmp=$(mktemp /tmp/bmc_l5_lnv_${node}.XXXXXX)
	mgr_code=$(curl -s $insecure_flag -m 10 \
		-H "Authorization: Basic $auth" \
		-H "Accept: application/json" \
		-o "$mgr_tmp" \
		-w '%{http_code}' \
		"https://$host/redfish/v1/Managers") || mgr_code="000"
	if [ "$mgr_code" = "200" ]; then
		mgr_link=$(jq -r '.Members[0]."@odata.id" // empty' "$mgr_tmp")
	fi
	rm -f "$mgr_tmp"
	if [ -z "$mgr_link" ]; then
		aba_warning "BMC: $node L5=FAIL reason=\"HTTP $mgr_code on /redfish/v1/Managers\""
		_preflight_errors=$(( _preflight_errors + 1 ))
		return 1
	fi

	# Step 2: GET Manager and parse Oem.Lenovo.LicenseFeatures.
	local m_tmp m_code features=""
	m_tmp=$(mktemp /tmp/bmc_l5_lnv_${node}.XXXXXX)
	m_code=$(curl -s $insecure_flag -m 10 \
		-H "Authorization: Basic $auth" \
		-H "Accept: application/json" \
		-o "$m_tmp" \
		-w '%{http_code}' \
		"https://$host$mgr_link") || m_code="000"
	if [ "$m_code" = "200" ]; then
		features=$(jq -r '.Oem.Lenovo.LicenseFeatures // [] | join(",")' "$m_tmp")
	fi
	rm -f "$m_tmp"
	if [ "$m_code" != "200" ]; then
		aba_warning "BMC: $node L5=FAIL reason=\"HTTP $m_code on Manager resource\""
		_preflight_errors=$(( _preflight_errors + 1 ))
		return 1
	fi
	if [ -z "$features" ]; then
		# Older XCC firmware may not publish the LicenseFeatures array; log and proceed.
		aba_debug "BMC: $node L5 Lenovo Oem.Lenovo.LicenseFeatures absent - proceeding (license enforcement will fall to L3 VirtualMedia 403 if tier is insufficient)"
		return 0
	fi

	# Step 3: confirm RemoteMedia or VirtualMedia is in the feature list (case-insensitive).
	if echo "$features" | grep -qiE 'RemoteMedia|VirtualMedia'; then
		aba_debug "BMC: $node L5 Lenovo license features=\"$features\" (RemoteMedia/VirtualMedia ok)"
		return 0
	fi
	aba_warning "BMC: $node L5=FAIL reason=\"Lenovo XCC license tier missing RemoteMedia/VirtualMedia feature; Enterprise license required (per Red Hat KCS 6958685); upgrade license or set bmc_type=redfish at your own risk\""
	_preflight_errors=$(( _preflight_errors + 1 ))
	return 1
}

# -----------------------------------------------------------------------------
# Phase 10 MAC discovery: post-L4/L5 per-node step (D-08 default, D-09 opt-out).
#
# Sources the vendor-agnostic MAC discovery helpers (D-03) and the Redfish
# wrapper + canonical EthernetInterfaces wrapper that this helper relies on.
# Sourcing is idempotent (re-source is a no-op for bash functions).
#
# _bm_get_ethernetinterfaces resolves at call time via bash function-redefine-
# wins, so the canonical generic implementation in bmc-adapter-generic.sh is
# used unless a vendor overlay has been sourced (none do in v1.1).
# -----------------------------------------------------------------------------
[ -f scripts/bmc-redfish.sh ]          && source scripts/bmc-redfish.sh
[ -f scripts/bmc-adapter-generic.sh ]  && source scripts/bmc-adapter-generic.sh
[ -f scripts/bmc-mac-discovery.sh ]    && source scripts/bmc-mac-discovery.sh

_bm_discover_macs() {
	# Phase 10 MAC discovery (D-08 default; D-09 opt-out via mac_discovery_<node>=disabled).
	# Returns 0 on success (sidecar updated or operator MAC validated); 1 on any
	# MAC-* error (caller `continue`s the per-node loop). Bumps _preflight_errors
	# on hard-fail paths so the final summary reflects the failure.
	#
	# Error namespace (D-10):
	#   MAC-03: operator-supplied mac_<node> not in BMC EthernetInterfaces report.
	#   MAC-04: no enabled NIC with link reported (emitted inside _bm_resolve_mac).
	#   MAC-05: ambiguous - >1 candidate after filter (emitted inside _bm_resolve_mac).
	#   MAC-08: Redfish call failed during discovery (with underlying ERR-01 reason).
	#   MAC-09: mac_discovery_<node>=disabled but mac_<node> not set.
	local node="$1"

	# Step 1: opt-out check (D-09).
	local mac_disc_var="mac_discovery_${node}"
	local mac_disc="${!mac_disc_var:-}"
	local op_mac_var="mac_${node}"
	local op_mac="${!op_mac_var:-}"
	if [ "$mac_disc" = "disabled" ]; then
		if [ -z "$op_mac" ]; then
			aba_warning "BMC: $node MAC-09: mac_discovery_${node}=disabled but mac_${node} not set; set mac_${node} in bmc.conf or remove the opt-out"
			_preflight_errors=$(( _preflight_errors + 1 ))
			return 1
		fi
		# Persist the disabled sentinel so _bm_get_mac sees it explicitly (D-09).
		_bm_state_write_mac "$node" "disabled" ""
		aba_debug "BMC: $node MAC discovery skipped (mac_discovery_${node}=disabled, mac_${node}=$op_mac)"
		return 0
	fi

	# Step 2: force-refresh hook (D-02; WARNING 1 from revision-iteration-2 plan-checker).
	# D-02 force-refresh hook (reserved for v1.2; v1.1 aba install does NOT
	# expose a --force flag, so this branch is unreachable in v1.1.
	# Documented per revision-iteration-2 plan-checker WARNING 1.)
	local _bm_disc_bypass_cache=0
	local force="${ABA_FORCE:-}"
	case "$force" in
		1|true|TRUE|True|yes|YES|Yes) _bm_disc_bypass_cache=1 ;;
	esac

	# Step 3: cache check (D-02), skipped when force-refresh is set.
	if [ "$_bm_disc_bypass_cache" -eq 0 ]; then
		local sidecar=".bmc-state.${node}"
		if [ -f "$sidecar" ] && [ -f bmc.conf ]; then
			local cached
			cached=$(grep '^discovered_mac=' "$sidecar" | cut -d= -f2)
			if [ -n "$cached" ] && [ "$cached" != "disabled" ] \
				&& [ "$sidecar" -nt bmc.conf ]; then
				if [ -z "$op_mac" ]; then
					aba_debug "BMC: $node MAC discovery cache hit (discovered_mac=$cached)"
					return 0
				fi
				if [ "${op_mac,,}" = "${cached,,}" ]; then
					aba_debug "BMC: $node MAC discovery cache hit (discovered_mac=$cached)"
					return 0
				fi
				# Operator changed mac_<node> since the last cached run; fall
				# through to a fresh Redfish call so validation re-runs.
			fi
		fi
	fi

	# Step 4: fresh Redfish call.
	# Ensure _bm_system_id "$node" resolves to a non-empty value. Vendor overlays
	# (e.g. iRMC) may hard-code the return value; the generic adapter reads
	# SYSTEM_ID_<node> from env, which is populated by bmc_discover_ids. Only the
	# generic-adapter path needs the discover fallback.
	if [ -z "$(_bm_system_id "$node")" ]; then
		if ! bmc_discover_ids "$node"; then
			aba_warning "BMC: $node MAC-08: discovery preflight failed - $_REDFISH_LAST_REASON"
			_preflight_errors=$(( _preflight_errors + 1 ))
			return 1
		fi
	fi

	local nic_lines rc=0
	nic_lines=$(_bm_get_ethernetinterfaces "$node") || rc=$?
	if [ "$rc" -ne 0 ]; then
		aba_warning "BMC: $node MAC-08: Redfish EthernetInterfaces call failed - $_REDFISH_LAST_REASON"
		_preflight_errors=$(( _preflight_errors + 1 ))
		return 1
	fi

	_bm_resolve_mac "$node" "$nic_lines"
	rc=$?
	case "$rc" in
		0)  : ;;  # _BM_DISCOVERED_MAC + _BM_DISCOVERED_NIC_ID populated
		4)  _preflight_errors=$(( _preflight_errors + 1 )); return 1 ;;  # MAC-04 emitted inside helper
		5)  _preflight_errors=$(( _preflight_errors + 1 )); return 1 ;;  # MAC-05 emitted inside helper
		*)  aba_warning "BMC: $node MAC-08: unexpected resolver rc=$rc"
			_preflight_errors=$(( _preflight_errors + 1 ))
			return 1 ;;
	esac

	# Step 5: validate-or-populate (D-08, MAC-03).
	if [ -n "$op_mac" ]; then
		if [ "${op_mac,,}" = "${_BM_DISCOVERED_MAC,,}" ]; then
			aba_debug "BMC: $node MAC validated against operator mac_${node}=$op_mac"
		else
			# Build full NIC summary (unfiltered) so operator sees the BMC report
			# including LinkDown / disabled NICs.
			local nic_summary="" line nic_id mac rest
			while IFS= read -r line; do
				[ -z "$line" ] && continue
				IFS='|' read -r nic_id mac rest <<<"$line"
				if [ -z "$nic_summary" ]; then
					nic_summary="${nic_id}=${mac}"
				else
					nic_summary="${nic_summary}, ${nic_id}=${mac}"
				fi
			done <<<"$nic_lines"
			aba_warning "BMC: $node MAC-03: operator mac_${node}=$op_mac not in BMC EthernetInterfaces report; reported NICs: [$nic_summary]"
			_preflight_errors=$(( _preflight_errors + 1 ))
			return 1
		fi
	else
		aba_info_ok "BMC: $node MAC discovered=$_BM_DISCOVERED_MAC (nic=$_BM_DISCOVERED_NIC_ID)"
	fi

	# Step 6: persist to sidecar via Task 2 helper (D-16 cache benefit on re-run).
	_bm_state_write_mac "$node" "$_BM_DISCOVERED_MAC" "$_BM_DISCOVERED_NIC_ID"
	return 0
}

# -----------------------------------------------------------------------------
# Public entry point. Returns 0 always; signals via shared counters.
# -----------------------------------------------------------------------------
preflight_check_bm() {
	# Defensive double-gate: protect against direct sourcing on non-BM platforms.
	[ "$platform" != "bm" ] && return 0

	# INT-03 silent-skip: bmc.conf absent. Operator uses existing manual-mount flow.
	[ -f bmc.conf ] || {
		aba_info "BMC: bmc.conf absent - using manual virtual-media flow. Boot each node from the generated agent ISO (see README.md bare-metal install section) via USB or BMC UI, then run aba mon."
		return 0
	}

	# INT-03 silent-skip: bmc.conf present but no bmc_host_* keys defined.
	if ! grep -qE '^[[:space:]]*bmc_host_' bmc.conf; then
		aba_info "BMC: bmc.conf present but no bmc_host_* keys defined - using manual virtual-media flow."
		return 0
	fi

	# Load bmc.conf: mode-0600 enforcement runs inside normalize-bmc-conf (aba_abort on failure).
	# The eval inside normalize-bmc-conf populates the process env; the stdout (password-filtered)
	# is sourced so export lines for non-password vars populate this subshell as well.
	source <(normalize-bmc-conf)

	# Step 2: required-field + allowlist (collect-all, no short-circuit).
	_bm_required_fields

	# Step 2b: VEN-07 shipped-vendor gate (collect-all). Emits per-node warning
	# for any bmc_type that is in the syntactic allowlist but not in $_BM_SHIPPED_VENDORS.
	_bm_check_shipped_vendors

	# Step 3: fleet-level iso_url validation.
	if [ -n "${iso_url:-}" ]; then
		_bm_validate_iso_url
	else
		local seen_hosts=""
		local node host_var host
		for node in $(_bm_node_list); do
			host_var="bmc_host_${node}"
			host="${!host_var}"
			case " $seen_hosts " in
				*" $host "*) continue ;;
			esac
			seen_hosts="$seen_hosts $host"
			_bm_derive_iso_url "$host"
		done
	fi

	# Step 4: per-node L1-L4 (+ optional L5) loop (node-first, per-node short-circuit).
	# D-04b: skip L1-L4 entirely for unshipped bmc_type values (cheap fail-fast;
	# VEN-07 message has already been emitted by _bm_check_shipped_vendors).
	# D-06: per-vendor L5 dispatch case is wired empty here; Plans 08-02..08-05
	# add their case arms when they ship their _bm_probe_l5_<vendor> functions.
	local total=0 ok_count=0
	local node type_var btype
	for node in $(_bm_node_list); do
		total=$(( total + 1 ))
		type_var="bmc_type_${node}"
		btype="${!type_var}"
		case " $_BM_SHIPPED_VENDORS " in
			*" $btype "*) : ;;
			*) continue ;;
		esac
		_bm_probe_l1 "$node" || { continue; }
		_bm_probe_l2 "$node" || { continue; }
		_bm_probe_l3 "$node" || { continue; }
		_bm_probe_l4 "$node" || { continue; }
		# D-06: per-vendor L5 dispatch (Plans 08-02..08-05 add case arms here).
		case "$btype" in
			irmc|redfish) : ;;
			idrac)        _bm_probe_l5_idrac "$node"      || continue ;;
			ilo)          _bm_probe_l5_ilo "$node"        || continue ;;
			supermicro)   _bm_probe_l5_supermicro "$node" || continue ;;
			lenovo)       _bm_probe_l5_lenovo "$node"     || continue ;;
		esac
		# Phase 10: MAC discovery runs AFTER L1-L4 (+ L5 for vendor-gated types).
		# Failure short-circuits this node (counter already bumped inside helper).
		_bm_discover_macs "$node" || continue
		ok_count=$(( ok_count + 1 ))
		case "$btype" in
			irmc|redfish) aba_info_ok "BMC: $node L1=ok L2=ok L3=ok L4=ok MAC=ok" ;;
			*)            aba_info_ok "BMC: $node L1=ok L2=ok L3=ok L4=ok L5=ok MAC=ok" ;;
		esac
	done

	# Step 5: final summary line (D-19).
	if [ "$total" = "0" ]; then
		# All bmc_host_* keys rejected in required-field layer; nothing to summarize.
		return 0
	fi
	if [ "$ok_count" = "$total" ]; then
		aba_info_ok "BMC: preflight $ok_count/$total nodes ready"
	else
		aba_warning "BMC: preflight $ok_count/$total nodes ready ($(( total - ok_count )) failed - see BMC: messages above)"
	fi
	return 0
}
