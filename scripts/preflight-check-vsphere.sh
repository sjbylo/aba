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

	# Phase 2 will add connectivity/TLS/resource checks here.
	# Phase 3 will add privilege validation here (sources scripts/vmware-required-privileges.sh).
}
