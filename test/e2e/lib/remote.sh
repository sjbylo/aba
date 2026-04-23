#!/usr/bin/env bash
# =============================================================================
# E2E Test Framework v2 -- Remote / SSH helpers
# =============================================================================
# Canonical SSH wrapper used by all framework modules.
# Defines _essh (the ONLY SSH function) and host-resolution helpers.
#
# Dependencies: constants.sh (for VM_BASE_DOMAIN fallback)
# =============================================================================

# SSH options: suppress host-key noise, fail fast, non-interactive, keepalive.
_E2E_SSH_OPTS="-o LogLevel=ERROR -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30 -o ServerAliveCountMax=3"

# Canonical SSH wrapper -- the ONLY SSH function in the framework.
# Usage:
#   _essh user@host "command"
#   _essh user@host "command" < /dev/null   (inside while-read loops)
_essh() {
	ssh $_E2E_SSH_OPTS "$@"
}

# SCP with the same options as _essh.
_escp() {
	scp -q $_E2E_SSH_OPTS "$@"
}

# Resolve conN pool number to user@fqdn.
# Usage: _con_target 2          -> steve@con2.example.com
#        _con_target 2 root     -> root@con2.example.com
_con_target() {
	local pool_num="$1"
	local user="${2:-${CON_SSH_USER:-steve}}"
	local domain="${VM_BASE_DOMAIN:-example.com}"
	echo "${user}@con${pool_num}.${domain}"
}

# Resolve disN pool number to user@fqdn.
_dis_target() {
	local pool_num="$1"
	local user="${2:-${DIS_SSH_USER:-steve}}"
	local domain="${VM_BASE_DOMAIN:-example.com}"
	echo "${user}@dis${pool_num}.${domain}"
}

# SSH to conN for a given pool (convenience wrapper).
# Usage: _ssh_con 2 "hostname"
_ssh_con() {
	local pool_num="$1"; shift
	_essh "$(_con_target "$pool_num")" "$@"
}

# SSH to disN for a given pool.
_ssh_dis() {
	local pool_num="$1"; shift
	_essh "$(_dis_target "$pool_num")" "$@"
}

# Wait for SSH to become available on a host.
# Usage: _wait_for_ssh user@host [timeout_seconds]
_wait_for_ssh() {
	local target="$1"
	local timeout="${2:-${SSH_WAIT_TIMEOUT:-300}}"
	local deadline=$(( $(date +%s) + timeout ))

	while [ "$(date +%s)" -lt "$deadline" ]; do
		if _essh "$target" "true" 2>/dev/null; then
			return 0
		fi
		sleep 5
	done
	echo "ERROR: SSH to $target not available after ${timeout}s" >&2
	return 1
}
