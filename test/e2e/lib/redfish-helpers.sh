#!/usr/bin/env bash
# =============================================================================
# E2E Test Framework -- Redfish Helpers
# =============================================================================
# Thin wrapper for PowerState assertion in suite-bmc-preflight.sh.
# Sources scripts/preflight-check-bm.sh (READ-ONLY) for _bm_build_auth.
# =============================================================================

_E2E_LIB_DIR_RF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Assert PowerState=On for a node via direct Redfish GET.
# Returns 0 if PowerState=On, 1 otherwise.
# Args: <node>
# Reads: bmc_host_<node>, bmc_user_<node>, bmc_password_<node>, bmc_insecure_<node>
# Requires: scripts/preflight-check-bm.sh sourced (provides _bm_build_auth)
redfish_powerstate_on() {
	local node="$1"
	if [ -z "$node" ]; then
		echo "redfish_powerstate_on: node argument required" >&2
		return 1
	fi
	local host_var="bmc_host_${node}"
	local insecure_var="bmc_insecure_${node}"
	local host="${!host_var:-}"
	local insecure="${!insecure_var:-true}"
	if [ -z "$host" ]; then
		echo "redfish_powerstate_on: bmc_host_${node} not set" >&2
		return 1
	fi
	local auth
	auth=$(_bm_build_auth "$node") || {
		echo "redfish_powerstate_on: _bm_build_auth failed for ${node}" >&2
		return 1
	}
	local insecure_flag=""
	if [ "$insecure" = "true" ]; then
		insecure_flag="-k"
	fi
	local body
	body=$(curl -sf $insecure_flag \
		-H "Authorization: Basic $auth" \
		-H "Accept: application/json" \
		"https://${host}/redfish/v1/Systems/0") || {
		echo "redfish_powerstate_on: curl failed for ${node} on /redfish/v1/Systems/0" >&2
		return 1
	}
	# Match PowerState":"On" with optional whitespace
	echo "$body" | grep -qE '"PowerState"[[:space:]]*:[[:space:]]*"On"'
}
