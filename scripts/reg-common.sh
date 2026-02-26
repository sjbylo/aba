#!/bin/bash
# =============================================================================
# reg-common.sh -- Shared functions for registry install/uninstall
# =============================================================================
# Sourced by vendor-specific scripts (reg-install-quay.sh, reg-install-docker.sh,
# etc.) and dispatchers. Provides common pre-checks, post-install, firewall,
# and configuration functions so vendor scripts only contain vendor-specific logic.
#
# Functions:
#   reg_load_config        Load and validate mirror.conf, set common variables
#   reg_check_fqdn         Verify registry hostname resolves to an IP
#   reg_detect_existing     Check for existing credentials or running registry
#   reg_verify_localhost    Confirm reg_host points to this machine (local installs)
#   reg_setup_data_dir      Validate and normalize data_dir + vendor root path
#   reg_generate_password   Generate random password if reg_pw is empty
#   reg_open_firewall       Open firewall port (firewalld/iptables, local or SSH)
#   reg_post_install        Copy CA, generate pull secret, write state.sh, verify
# =============================================================================

# Guard against double-sourcing
if [ "${_REG_COMMON_LOADED:-}" ]; then return 0; fi
_REG_COMMON_LOADED=1

# Enable INFO messages when called from make (unless parent set --quiet)
if [ -z "${INFO_ABA+x}" ]; then export INFO_ABA=1; fi

source scripts/include_all.sh

umask 077

# SSH config file used by all registry SSH operations
ssh_conf_file=~/.aba/ssh.conf

# --- reg_load_config ----------------------------------------------------------
# Normalize and verify both aba.conf and mirror.conf, set standard variables.
# aba.conf is needed for the ask= mode, ocp_version, etc.
# Installs required RPMs (podman, jq, etc.) for registry operations.
# Sets: reg_hostport, reg_url, reg_ssh_user (defaults to current user)
reg_load_config() {
	source <(normalize-aba-conf)
	source <(normalize-mirror-conf)

	verify-aba-conf || exit 1
	verify-mirror-conf || exit 1

	scripts/install-rpms.sh internal

	export reg_hostport="$reg_host:$reg_port"
	export reg_url="https://$reg_hostport"

	if [ ! "$reg_ssh_user" ]; then reg_ssh_user=$(whoami); fi
}

# --- reg_check_fqdn ----------------------------------------------------------
# Verify reg_host resolves to an IP address. Uses dig with getent as fallback.
# Sets: fqdn_ip (the resolved IP)
# Also adjusts no_proxy if a proxy is configured.
# Aborts with a clear error if the hostname cannot be resolved.
reg_check_fqdn() {
	aba_debug "Verifying resolution of mirror hostname: $reg_host"

	# Primary: dig (most common on RHEL systems)
	fqdn_ip=$(dig +short "$reg_host" 2>/dev/null \
		| grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1) || true

	# Fallback: getent (works when dig is unavailable, e.g. minimal installs)
	if [ ! "$fqdn_ip" ]; then
		fqdn_ip=$(getent hosts "$reg_host" 2>/dev/null \
			| awk '{print $1}' | head -1) || true
	fi

	if [ ! "$fqdn_ip" ]; then
		aba_abort \
			"Hostname '$reg_host' does not resolve to an IP address!" \
			"Commands tried: dig $reg_host +short; getent hosts $reg_host" \
			"The registry requires a valid DNS record (FQDN)." \
			"OpenShift itself also requires DNS records for API and App ingress." \
			"Please add/correct your DNS entries or update $PWD/mirror.conf and try again."
	fi

	# Add registry host to no_proxy when a proxy is in use
	if [ "$http_proxy" ]; then export no_proxy="${no_proxy:+$no_proxy,}$reg_host"; fi
}

# --- reg_detect_existing ------------------------------------------------------
# Check if registry credentials already exist (fast-path) or if a registry
# is already running at reg_url.
#
# If credentials exist: run verify and exit (nothing to install).
# If a registry is detected at the URL: abort with instructions to provide
# credentials rather than installing on top of it.
reg_detect_existing() {
	# Fast-path: credentials already exist and we have install state -- just verify and exit
	# If pull-secret exists but state.sh is missing/stale, do not fast-path; proceed with install so reg_post_install can refresh creds.
	if [ -s "$regcreds_dir/pull-secret-mirror.json" ] && [ -s "$regcreds_dir/state.sh" ]; then
		aba_debug "Found existing pull secret and state at $regcreds_dir"
		scripts/reg-verify.sh
		exit
	fi

	# Probe for Quay health endpoint
	aba_info "Probing $reg_url/health/instance"
	if probe_host "$reg_url/health/instance" "Quay registry health endpoint"; then
		aba_abort \
			"Existing Quay registry found at $reg_url/health/instance" \
			"To use this registry, copy its pull secret and root CA into '$regcreds_dir/' and try again." \
			"Files needed: 'pull-secret-mirror.json' and 'rootCA.pem'" \
			"The pull secret can also be created via 'aba -d mirror password'" \
			"See the README.md for further information."
	fi

	# Probe for any registry at the URL
	aba_info "Probing $reg_url/"
	if probe_host "$reg_url/" "registry root endpoint"; then
		aba_abort \
			"Endpoint found at $reg_url/" \
			"If this is your existing registry, copy its pull secret and root CA into '$regcreds_dir/' and try again." \
			"Files needed: 'pull-secret-mirror.json' and 'rootCA.pem'" \
			"The pull secret can also be created via 'aba -d mirror password'" \
			"See the README.md for further information."
	fi
}

# --- reg_verify_localhost -----------------------------------------------------
# For local installs: verify that reg_host resolves to this machine's IP.
# Also uses an SSH flag-file trick to detect when reg_host unexpectedly
# reaches a remote machine (catches cases where IP matches a local interface
# but SSH still lands elsewhere, or vice versa).
# The IP mismatch check is a warning (NAT/LB setups are common), but the
# SSH flag-file check aborts since it positively confirms a remote host.
# Requires: fqdn_ip (call reg_check_fqdn first)
reg_verify_localhost() {
	local local_ips
	local_ips=$(hostname -I)

	aba_info "Verifying FQDN '$reg_host' (IP: $fqdn_ip) reaches this localhost ..."

	if ! echo "$local_ips" | grep -qw "$fqdn_ip"; then
		aba_warning \
			"$reg_host resolves to $fqdn_ip which is not found on any local network interface." \
			"Ignore this warning if expected, e.g. when $fqdn_ip is an external/NAT IP."
		sleep 1
	fi

	# SSH flag-file trick: SSH to reg_host and create a temp file. If the file
	# does NOT appear on localhost, reg_host reaches a remote machine by mistake.
	local flag_file="/tmp/.$(whoami).$RANDOM"
	rm -f "$flag_file"

	local remote_hostname
	if remote_hostname=$(ssh -F "$ssh_conf_file" "$reg_host" "touch $flag_file && hostname") >/dev/null 2>&1; then
		if [ ! -f "$flag_file" ]; then
			aba_abort \
				"Registry configured for *local* install (reg_ssh_key is not defined)." \
				"But $reg_host resolves to $fqdn_ip, which reaches remote host [$remote_hostname] via SSH!" \
				"Options:" \
				"1. Update DNS so '$reg_host' resolves to this localhost '$(hostname -s)'." \
				"2. Set 'reg_ssh_key' in mirror.conf for remote installation."
		else
			rm -f "$flag_file"
			aba_info "SSH access to localhost via '$reg_host' is working."
		fi
	fi
}

# --- reg_setup_data_dir -------------------------------------------------------
# Validate and normalize data_dir from mirror.conf. Compute vendor-specific
# root directory.
# Usage: reg_setup_data_dir quay    -> reg_root=$data_dir/quay-install
#        reg_setup_data_dir docker  -> reg_root=$data_dir/docker-reg
# Sets: data_dir (expanded), reg_root, reg_root_opts (Quay only)
reg_setup_data_dir() {
	local vendor="${1:-quay}"

	# Remote (reg_ssh_key set): keep literal ~ so remote host expands it; do not expand here.
	# Local: default to home dir and expand ~ for absolute path.
	if [ "$reg_ssh_key" ]; then
		if [ ! "$data_dir" ]; then data_dir='~'; fi
	else
		if [ ! "$data_dir" ]; then data_dir=~; else data_dir=$(eval echo "$data_dir"); fi
	fi

	case "$vendor" in
		quay)   reg_root="$data_dir/quay-install" ;;
		docker) reg_root="$data_dir/docker-reg" ;;
		*)      reg_root="$data_dir/$vendor" ;;
	esac

	# Validate path is absolute
	if [[ "$reg_root" != /* && "$reg_root" != ~* ]]; then
		aba_abort \
			"data_dir must be an absolute path (starting with '/' or '~')." \
			"Current value in mirror.conf: data_dir=$data_dir"
	fi

	# Build Quay-specific root options
	if [ "$vendor" = "quay" ]; then
		reg_root_opts="--quayRoot $reg_root --quayStorage $reg_root/quay-storage --sqliteStorage $reg_root/sqlite-storage"
	else
		reg_root_opts=""
	fi
}

# --- reg_generate_password ----------------------------------------------------
# Generate a random password if reg_pw is empty or unset.
# Sets: reg_pw
reg_generate_password() {
	if [ ! "$reg_pw" ]; then
		reg_pw=$(openssl rand -base64 12)
		aba_info "Generated random registry password."
	fi
}

# --- reg_open_firewall --------------------------------------------------------
# Open firewall port for registry access.
# Usage:
#   reg_open_firewall           Open $reg_port on this host (local install)
#   reg_open_firewall --ssh     Open $reg_port via SSH on $reg_host (remote install)
#
# Tries firewalld first, then iptables as fallback. If neither works, warns
# with manual instructions. Handles platforms where firewalld is installed
# but not running (offline mode).
reg_open_firewall() {
	local via_ssh=""
	if [ "${1:-}" = "--ssh" ]; then via_ssh=1; fi

	local where="${via_ssh:+ on $reg_host}"
	aba_info "Opening firewall port $reg_port${where} ..."

	if [ "$via_ssh" ]; then
		# Remote: run firewall commands over SSH
		local _ssh="ssh -i $reg_ssh_key -F $ssh_conf_file $reg_ssh_user@$reg_host --"

		if $_ssh "rpm -q firewalld &>/dev/null && systemctl is-active firewalld &>/dev/null"; then
			$_ssh "$SUDO firewall-cmd --add-port=$reg_port/tcp --permanent >/dev/null && \
				$SUDO firewall-cmd --reload >/dev/null"
		elif $_ssh "rpm -q firewalld &>/dev/null"; then
			$_ssh "$SUDO firewall-offline-cmd --add-port=$reg_port/tcp >/dev/null"
		elif $_ssh "command -v iptables &>/dev/null && \
			$SUDO iptables -I INPUT 1 -p tcp --dport $reg_port -j ACCEPT 2>/dev/null"; then
			aba_info "firewalld not active on $reg_host, opened port $reg_port via iptables."
		else
			aba_warning "Could not auto-open firewall port $reg_port on $reg_host."
			aba_warning "If the registry is unreachable, open the port manually on $reg_host, e.g.:"
			aba_warning "  sudo nft insert rule ip filter INPUT tcp dport $reg_port accept"
			aba_warning "  or: sudo iptables -I INPUT 1 -p tcp --dport $reg_port -j ACCEPT"
		fi
	else
		# Local: run firewall commands directly
		if rpm -q firewalld &>/dev/null && systemctl is-active firewalld &>/dev/null; then
			$SUDO firewall-cmd --add-port=$reg_port/tcp --permanent && \
				$SUDO firewall-cmd --reload
		elif rpm -q firewalld &>/dev/null; then
			$SUDO firewall-offline-cmd --add-port=$reg_port/tcp >/dev/null
		elif command -v iptables &>/dev/null && \
			$SUDO iptables -I INPUT 1 -p tcp --dport $reg_port -j ACCEPT 2>/dev/null; then
			aba_info "firewalld not active, opened port $reg_port via iptables."
		else
			aba_warning "Could not auto-open firewall port $reg_port."
			aba_warning "If the registry is unreachable, open the port manually, e.g.:"
			aba_warning "  sudo nft insert rule ip filter INPUT tcp dport $reg_port accept"
			aba_warning "  or: sudo iptables -I INPUT 1 -p tcp --dport $reg_port -j ACCEPT"
		fi
	fi
}

# --- reg_post_install ---------------------------------------------------------
# Post-install steps common to all registry vendors:
#   1. Back up old regcreds directory (if any)
#   2. Copy CA certificate into regcreds
#   3. Trust the CA system-wide
#   4. Generate pull secret from template
#   5. Write state.sh (persistent, survives clean/reset)
#   6. Print success message
#
# Usage:
#   reg_post_install <ca_source> <vendor>
#   reg_post_install <user@host:ca_path> <vendor> --ssh
#
# Arguments:
#   ca_source  Local path to CA cert, or "user@host:path" for SSH fetch
#   vendor     "quay" or "docker"
#   --ssh      Fetch CA via scp instead of local cp
reg_post_install() {
	local ca_source="$1"
	local vendor="$2"
	local via_ssh=""
	if [ "${3:-}" = "--ssh" ]; then via_ssh=1; fi

	# Back up existing regcreds if present
	if [ -d "$regcreds_dir" ]; then
		rm -rf "${regcreds_dir}.bk"
		mv "$regcreds_dir" "${regcreds_dir}.bk"
	fi
	mkdir -p "$regcreds_dir"

	# Copy CA certificate to regcreds
	if [ "$via_ssh" ]; then
		aba_info "Fetching root CA from remote host: $ca_source"
		scp -i "$reg_ssh_key" -F "$ssh_conf_file" -p "$ca_source" "$regcreds_dir/rootCA.pem"
	else
		# eval handles ~ in paths
		eval cp "$ca_source" "$regcreds_dir/rootCA.pem"
	fi

	# Trust the CA system-wide (updates /etc/pki/ca-trust/)
	trust_root_ca "$regcreds_dir/rootCA.pem"

	# Default reg_user if empty
	if [ ! "$reg_user" ]; then reg_user=init; fi

	# Generate pull secret from template (uses enc_password, reg_host, reg_port)
	aba_info "Generating $regcreds_dir/pull-secret-mirror.json"
	export enc_password
	enc_password=$(echo -n "$reg_user:$reg_pw" | base64 -w0)
	scripts/j2 ./templates/pull-secret-mirror.json.j2 > "$regcreds_dir/pull-secret-mirror.json"

	# Write persistent state for uninstall (survives aba clean/reset)
	cat > "$regcreds_dir/state.sh" <<-EOF
	REG_VENDOR=$vendor
	REG_HOST=$reg_host
	REG_PORT=$reg_port
	REG_USER=$reg_user
	REG_PW=$reg_pw
	REG_ROOT=$reg_root
	REG_SSH_KEY=${reg_ssh_key:-}
	REG_SSH_USER=${reg_ssh_user:-}
	REG_ROOT_OPTS="${reg_root_opts:-}"
	REG_INSTALLED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
	EOF
	aba_info "Saved registry state to $regcreds_dir/state.sh"

	echo
	aba_info_ok "Registry installed/configured successfully!"
}
