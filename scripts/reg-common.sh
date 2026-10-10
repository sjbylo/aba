#!/bin/bash
# =============================================================================
# reg-common.sh -- Shared functions for registry install/uninstall
# =============================================================================
# Sourced by vendor-specific scripts (reg-install-quay.sh, reg-install-docker.sh,
# reg-install-quay-ng.sh, etc.) and dispatchers. Provides common pre-checks,
# post-install, firewall, and configuration functions so vendor scripts only
# contain vendor-specific logic.
#
# Functions:
#   reg_load_config        Load and validate mirror.conf, set common variables
#   reg_check_fqdn         Verify registry hostname resolves to an IP
#   reg_detect_existing     Check for existing credentials or running registry
#   reg_verify_localhost    Confirm reg_host points to this machine (local installs)
#   reg_check_quay_resources  Abort if host has <4 vCPUs or <8GB RAM (Quay only)
#   reg_setup_data_dir      Validate and normalize data_dir + vendor root path
#   reg_generate_password   Generate random password if reg_pw is empty
#   reg_open_firewall       Open firewall port (firewalld/iptables, local or SSH)
#   reg_close_firewall      Close firewall port at uninstall time (mirrors reg_open_firewall)
#   reg_post_install        Copy CA, generate pull secret, write state.sh, verify
#   reg_stale_report        Probe whether a registry is still present (local or remote)
#   reg_finish_uninstall    Clear regcreds after a verified-clean uninstall
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
	export regcreds_dir=$HOME/.aba/mirror/$(basename "$PWD")
	export regcreds_display="regcreds"

	verify-aba-conf || aba_abort "$_ABA_CONF_ERR"
	verify-mirror-conf || aba_abort "Invalid or incomplete mirror.conf. Check the errors above and fix mirror/mirror.conf."

	scripts/install-rpms.sh internal

	export reg_hostport="$reg_host:$reg_port"
	export reg_url="https://$reg_hostport"

	export reg_user=$(resolved_reg_user)
	if [ ! "$reg_ssh_user" ]; then reg_ssh_user=$(whoami); fi
}

# --- reg_check_fqdn ----------------------------------------------------------
# Verify reg_host resolves to an IPv4 address via DNS (dig).
# ABA only uses DNS resolution — not local system lookups (getent/myhostname)
# — because cluster nodes resolve the registry hostname via DNS.
# Sets: fqdn_ip (the resolved IPv4 address)
# Also adjusts no_proxy if a proxy is configured.
reg_check_fqdn() {
	aba_debug "Verifying DNS resolution of mirror hostname: $reg_host"

	install_rpms bind-utils   # provides dig

	local _ipv4_re='([0-9]{1,3}\.){3}[0-9]{1,3}'

	# Try default system DNS resolution (all nameservers in resolv.conf)
	aba_debug "Running: dig +short $reg_host"
	fqdn_ip=$(dig +short "$reg_host" 2>/dev/null \
		| grep -Eo "$_ipv4_re" | head -1) || true
	aba_debug "dig result for $reg_host: '${fqdn_ip:-<empty>}'"

	if [ "$fqdn_ip" ]; then
		# Add registry host to no_proxy when a proxy is in use
		if [ "$http_proxy" ]; then export no_proxy="${no_proxy:+$no_proxy,}$reg_host"; fi
		return
	fi

	# dig failed — diagnose by querying each nameserver individually
	local ns_list ns_results="" ns_found=""
	ns_list=$(grep '^nameserver' /etc/resolv.conf 2>/dev/null \
		| awk '{print $2}') || true

	aba_info "DNS lookup for '$reg_host' returned no result. Checking each nameserver ..."
	local ns ns_ip ns_status
	for ns in $ns_list; do
		# Query with verbose output to distinguish NOERROR/NXDOMAIN/timeout
		ns_ip=$(dig +short +time=5 +tries=1 "@$ns" "$reg_host" 2>/dev/null \
			| grep -Eo "$_ipv4_re" | head -1) || true
		if [ -n "$ns_ip" ]; then
			ns_results="${ns_results}${ns_results:+, }$ns -> $ns_ip"
			[ -z "$ns_found" ] && ns_found="$ns_ip"
			aba_info "  $ns  ->  $ns_ip"
		else
			ns_status=$(dig +time=5 +tries=1 "@$ns" "$reg_host" 2>/dev/null \
				| grep -o 'status: [A-Z]*' | head -1) || true
			ns_status="${ns_status#status: }"
			case "$ns_status" in
				NOERROR)  ns_results="${ns_results}${ns_results:+, }$ns -> no record"
				          aba_info "  $ns  ->  no record (NOERROR, no A record)" ;;
				NXDOMAIN) ns_results="${ns_results}${ns_results:+, }$ns -> domain not found"
				          aba_info "  $ns  ->  domain not found (NXDOMAIN)" ;;
				REFUSED)  ns_results="${ns_results}${ns_results:+, }$ns -> refused"
				          aba_info "  $ns  ->  query refused" ;;
				*)        ns_results="${ns_results}${ns_results:+, }$ns -> ${ns_status:-timed out}"
				          aba_info "  $ns  ->  ${ns_status:-timed out / unreachable}" ;;
			esac
		fi
	done

	if [ -n "$ns_found" ]; then
		fqdn_ip="$ns_found"
		aba_warn \
			"'$reg_host' not resolved by the first nameserver in /etc/resolv.conf." \
			"Resolved to $fqdn_ip after checking all nameservers:" \
			"$ns_results"
		if [ "$http_proxy" ]; then export no_proxy="${no_proxy:+$no_proxy,}$reg_host"; fi
		return
	fi

	# No nameserver returned an IPv4 address
	aba_abort \
		"Hostname '$reg_host' does not resolve to an IPv4 address via DNS!" \
		"Nameserver results: ${ns_results:-no nameservers found in /etc/resolv.conf}" \
		"The registry hostname must be resolvable via DNS — cluster nodes depend on it." \
		"OpenShift also requires DNS records for API and App ingress." \
		"Please add an A record for '$reg_host' in your DNS server and verify with:" \
		"  dig $reg_host +short"
}

# --- reg_detect_existing ------------------------------------------------------
# Safety check: abort if an unknown external registry is already running at
# reg_url.  This prevents ABA from blindly installing on top of a registry
# it did not create.
#
# Also aborts if ABA already manages a registry at this host (state.sh with
# matching reg_host).  There is no "reinstall" -- user must uninstall first.
reg_detect_existing() {
	# Skip install if ABA already manages a healthy registry at this host.
	# After Phase 3 (ADR-007), $reg_host is already overridden from state.sh
	# by normalize-mirror-conf, so no need to grep state.sh separately.
	if [ -s "$regcreds_dir/state.sh" ]; then
		if probe_host --any "$reg_url/v2/" "existing registry"; then
			aba_debug "Registry already installed and healthy at $reg_host -- skipping install"
			exit 0
		else
			aba_abort "Registry at $reg_host is unreachable but state.sh still exists." \
				"If the registry was removed externally, run 'aba -d $(basename "$PWD") uninstall' to clean up, then re-install." \
				"If the host is temporarily down, wait and retry."
		fi
	fi

	# Probe for Quay health endpoint (stderr suppressed -- probes are expected to fail)
	aba_info "Probing $reg_url/health/instance"
	if probe_host "$reg_url/health/instance" "Quay registry health endpoint" 2>/dev/null; then
		aba_abort \
			"Existing Quay registry found at $reg_url/health/instance" \
			"If this is your registry, register it with: aba -d $(basename "$PWD") register --pull-secret-mirror <file> --ca-cert <file>" \
			"The pull secret can also be created via 'aba -d $(basename "$PWD") password'" \
			"See the README.md for further information."
	fi

	# Probe for Docker registry V2 API (returns 200 or 401 if a registry exists)
	aba_info "Probing $reg_url/v2/"
	if probe_host --any "$reg_url/v2/" "Docker registry API" 2>/dev/null; then
		aba_abort \
			"Existing Docker registry found at $reg_url/v2/" \
			"If this is your registry, register it with: aba -d $(basename "$PWD") register --pull-secret-mirror <file> --ca-cert <file>" \
			"The pull secret can also be created via 'aba -d $(basename "$PWD") password'" \
			"See the README.md for further information."
	fi

	# Probe for any registry at the URL
	aba_info "Probing $reg_url/"
	if probe_host "$reg_url/" "registry root endpoint" 2>/dev/null; then
		aba_abort \
			"Endpoint found at $reg_url/" \
			"If this is your registry, register it with: aba -d $(basename "$PWD") register --pull-secret-mirror <file> --ca-cert <file>" \
			"The pull secret can also be created via 'aba -d $(basename "$PWD") password'" \
			"See the README.md for further information."
	fi
}

# --- reg_verify_localhost -----------------------------------------------------
# For local installs: verify that reg_host resolves to this machine's IP.
# Uses SSH flag-file trick first (definitive), falls back to IP check.
# Requires: fqdn_ip (call reg_check_fqdn first)
reg_verify_localhost() {
	local local_ips
	local_ips=$(hostname -I)

	aba_info "Verifying FQDN '$reg_host' (IP: $fqdn_ip) reaches this localhost ..."

	# SSH flag-file trick: definitive test. SSH to reg_host and create a temp
	# file. If the file appears locally, reg_host IS this host (NAT/LB is fine).
	# If the file doesn't appear, reg_host reaches a different machine.
	local flag_file="$ABA_TMP/flag.$RANDOM"
	rm -f "$flag_file"
	local _ssh_confirmed=""

	local remote_hostname
	if remote_hostname=$(ssh -F "$ssh_conf_file" "$reg_host" "mkdir -p $ABA_TMP && touch $flag_file && hostname" 2>/dev/null); then
		if [ -f "$flag_file" ]; then
			rm -f "$flag_file"
			aba_info "Confirmed: '$reg_host' reaches this localhost via SSH."
			_ssh_confirmed="local"
		else
			aba_abort \
				"Registry configured for *local* install (reg_ssh_key is not defined)." \
				"But $reg_host resolves to $fqdn_ip, which reaches remote host [$remote_hostname] via SSH!" \
				"Options:" \
				"1. Update DNS so '$reg_host' resolves to this localhost '$(hostname -s)'." \
				"2. Set 'reg_ssh_key' in mirror.conf for remote installation."
		fi
	fi

	# Fallback: if SSH couldn't confirm, check whether the IP is on a local interface.
	# The IP may still route here via NAT or load balancer — prompt the user.
	if [ -z "$_ssh_confirmed" ] && ! echo "$local_ips" | grep -qw "$fqdn_ip"; then
		aba_warn \
			"$reg_host resolves to $fqdn_ip which is not found on any local network interface." \
			"This host's IPs: $(echo $local_ips | xargs | tr ' ' ', ')" \
			"This may be fine if $fqdn_ip reaches this host via NAT or a load balancer." \
			"Could not verify via SSH — unable to confirm automatically."
		echo
		ask -n --auto-yes "Continue installing on this host anyway (e.g. NAT/LB in use)" || \
			aba_abort \
				"Install cancelled. To fix:" \
				"  - If $fqdn_ip should route here (NAT/LB), ensure the network path works and re-run." \
				"  - Otherwise, update DNS so '$reg_host' resolves to this host, or" \
				"  - Set 'reg_ssh_key' in mirror.conf to install on the remote host ($fqdn_ip) instead."
	fi
}

# --- reg_check_quay_resources -------------------------------------------------
# Warn if the target host lacks minimum resources for Quay (4 vCPUs, 8GB RAM).
# Usage: reg_check_quay_resources          # check localhost
#        reg_check_quay_resources "$_ssh"   # check remote host via SSH command
reg_check_quay_resources() {
	local run="${1:-}"
	local vcpus mem_kb mem_gb
	if [ -z "$run" ]; then
		vcpus=$(nproc)
		mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
	else
		vcpus=$($run nproc)
		mem_kb=$($run grep MemTotal /proc/meminfo | awk '{print $2}')
	fi
	mem_gb=$(( mem_kb / 1024 / 1024 ))
	if [ "$vcpus" -le 2 ] || [ "$mem_gb" -le 4 ]; then
		aba_warn \
			"Quay mirror registry requires at least 4 vCPUs and 8GB RAM." \
			"This host has ${vcpus} vCPU(s) and ~${mem_gb}GB RAM." \
			"Use a Docker registry instead: set reg_vendor=docker in mirror.conf."
		ask -n --auto-yes "Continue with Quay installation anyway" || exit 1
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
		if [ ! "$data_dir" ]; then data_dir="$HOME"; else data_dir=$(_expand_tilde "$data_dir"); fi
	fi

	case "$vendor" in
		quay)   reg_root="$data_dir/quay-install" ;;
		docker) reg_root="$data_dir/docker-reg" ;;
		$_QUAY_NG_VENDOR) reg_root="$data_dir/$_QUAY_NG_VENDOR" ;;
		*)      reg_root="$data_dir/$vendor" ;;
	esac

	# Validate path is absolute
	if [[ "$reg_root" != /* && "$reg_root" != ~* ]]; then
		aba_abort \
			"data_dir must be an absolute path (starting with '/' or '~')." \
			"Current value in mirror.conf: data_dir=$data_dir"
	fi

	# Build Quay-specific root options
	# Explicitly set --quayStorage and --sqliteStorage to subdirectories of reg_root.
	# Without these, mirror-registry defaults to Podman named volumes, which scatters
	# data outside the data dir and requires root to uninstall.
	if [ "$vendor" = "quay" ]; then
		reg_root_opts="--quayRoot $reg_root --quayStorage $reg_root/quay-storage --sqliteStorage $reg_root/sqlite-storage"
	else
		reg_root_opts=""
	fi

	# Quay's installer chmods the storage tree as the login user (`file: recurse`).
	# Blob and sqlite files are owned by the container's host UID, so that chmod
	# fails with PermissionError unless we give the tree back first. The sqlite
	# mount uses :U, which returns the database to the container when it starts.
	if [ -z "$reg_ssh_key" ] && [ -d "$reg_root" ] && \
	   [ "$(find "$reg_root" -maxdepth 2 ! -user "$(id -u)" -print -quit 2>/dev/null)" ]; then
		aba_info "Preparing existing registry data at $reg_root for reinstall ..."
		if ! $SUDO chown -R "$(id -un):$(id -gn)" "$reg_root"; then
			aba_abort \
				"Registry data at $reg_root has files owned by the container user, and chown failed." \
				"The installer cannot reuse that tree until those files belong to $(whoami)." \
				"Fix with:  sudo chown -R $(whoami) $reg_root"
		fi
	fi

	# Note other vendor data directories under the same data_dir.
	local _other_suffix _other_root _others=""
	local _all_suffixes="docker-reg quay-install $_QUAY_NG_VENDOR"
	for _other_suffix in $_all_suffixes; do
		_other_root="$data_dir/$_other_suffix"
		[ "$_other_root" = "$reg_root" ] && continue
		if [ -z "$reg_ssh_key" ]; then
			[ -d "$_other_root" ] && _others+=" $_other_root"
		else
			ssh -i "$reg_ssh_key" -F "$ssh_conf_file" "$reg_ssh_user@$reg_host" \
				"test -d '$_other_root'" 2>/dev/null && _others+=" $_other_root" || true
		fi
	done
	[ -n "$_others" ] && aba_info "Other registry data also under $data_dir:$_others"

	# Guard: detect if another mirror workdir already owns this reg_root on the
	# same host.  Different vendors under the same data_dir are fine because each
	# gets its own subdirectory (docker-reg, quay-install, etc.) — reg_root is
	# already vendor-qualified at this point.  Parse state.sh with grep rather
	# than sourcing it to avoid clobbering the caller's variables.
	local _current_mirror _sf _sf_mirror _sf_root _sf_host
	_current_mirror=$(basename "$PWD")
	for _sf in "$HOME/.aba/mirror"/*/state.sh; do
		[ -f "$_sf" ] || continue
		_sf_mirror=$(basename "$(dirname "$_sf")")
		[ "$_sf_mirror" = "$_current_mirror" ] && continue  # reinstall of same workdir is fine
		_sf_root=$(grep '^reg_root=' "$_sf" | head -1 | cut -d= -f2 | tr -d "'\"")
		_sf_host=$(grep '^reg_host=' "$_sf" | head -1 | cut -d= -f2 | tr -d "'\"")
		if [ "$_sf_root" = "$reg_root" ] && [ "$_sf_host" = "$reg_host" ]; then
			# For local installs, skip stale state.sh entries where the data dir
			# no longer exists (previous install was cleaned up or removed).
			if [ -z "$reg_ssh_key" ] && [ ! -d "$reg_root" ]; then
				continue
			fi
			aba_abort \
				"Data directory '$reg_root' on host '$reg_host' is already in use by mirror workdir '$_sf_mirror'." \
				"Each registry instance of the same vendor needs its own data directory." \
				"Use --data-dir to specify a unique path:" \
				"  aba -d $(basename "$PWD") install --data-dir ~/my-data-dir"
		fi
	done
}

# --- reg_generate_password ----------------------------------------------------
# Generate a random password if reg_pw is empty or unset.
# Sets: reg_pw
reg_generate_password() {
	local _saved _saved_user _saved_pw _ng_pw _stored_pw
	_saved="${reg_root:-}/.aba-reuse-creds"
	_ng_pw="${reg_root:-}/auth/admin-password"
	# Quay stores the user in its database. A new random password does not replace it.
	# Docker rewrites htpasswd, so an explicit new password is allowed to win.
	# quay-ng keeps the password in auth/admin-password and skips init when that file exists.
	if [ -s "$_saved" ]; then
		_saved_user=$(sed -n "s/^reg_user='\(.*\)'/\1/p" "$_saved" | head -1)
		_saved_pw=$(sed -n "s/^reg_pw='\(.*\)'/\1/p" "$_saved" | head -1)
	fi
	if [ -f "${reg_root}/sqlite-storage/quay_sqlite.db" ] && [ -n "$_saved_pw" ]; then
		if [ "$reg_pw" ] && [ "$reg_pw" != "$_saved_pw" ]; then
			aba_warn "Using the Quay login saved with the data directory. The existing database user is unchanged."
		fi
		[ -n "$_saved_user" ] && reg_user="$_saved_user"
		reg_pw="$_saved_pw"
		aba_info "Reusing the Quay login saved with the data directory."
	elif [ -s "$_ng_pw" ]; then
		_stored_pw=$(cat "$_ng_pw")
		if [ -n "$_stored_pw" ]; then
			if [ "$reg_pw" ] && [ "$reg_pw" != "$_stored_pw" ]; then
				aba_warn "Using the quay-ng login stored with the data directory. The existing database user is unchanged."
			fi
			[ -n "$_saved_user" ] && reg_user="$_saved_user"
			reg_pw="$_stored_pw"
			aba_info "Reusing the quay-ng login stored with the data directory."
		fi
	elif [ ! "$reg_pw" ] && [ -n "$_saved_pw" ]; then
		[ -n "$_saved_user" ] && reg_user="$_saved_user"
		reg_pw="$_saved_pw"
		aba_info "Reusing the registry login saved with the data directory."
	fi
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

	# Track whether ABA opened the port (written to state.sh by reg_post_install)
	_reg_fw_opened=""

	if [ "$via_ssh" ]; then
		# Remote: run firewall commands over SSH
		local _ssh="ssh -i $reg_ssh_key -F $ssh_conf_file $reg_ssh_user@$reg_host --"

		if $_ssh "rpm -q firewalld &>/dev/null && systemctl is-active firewalld &>/dev/null"; then
			$_ssh "$SUDO firewall-cmd --add-port=$reg_port/tcp --permanent >/dev/null && \
				$SUDO firewall-cmd --reload >/dev/null"
			_reg_fw_opened=1
		elif $_ssh "rpm -q firewalld &>/dev/null"; then
			$_ssh "$SUDO firewall-offline-cmd --add-port=$reg_port/tcp >/dev/null"
			_reg_fw_opened=1
		elif $_ssh "command -v iptables &>/dev/null && \
			$SUDO iptables -I INPUT 1 -p tcp --dport $reg_port -j ACCEPT 2>/dev/null"; then
			aba_info "firewalld not active on $reg_host, opened port $reg_port via iptables."
			_reg_fw_opened=1
		else
			aba_warn "Could not auto-open firewall port $reg_port on $reg_host." \
				"If the registry is unreachable, open the port manually on $reg_host, e.g.:" \
				"  sudo nft insert rule ip filter INPUT tcp dport $reg_port accept" \
				"  or: sudo iptables -I INPUT 1 -p tcp --dport $reg_port -j ACCEPT"
		fi
	else
		# Local: run firewall commands directly
		if rpm -q firewalld &>/dev/null && systemctl is-active firewalld &>/dev/null; then
			$SUDO bash -c "firewall-cmd --add-port=$reg_port/tcp --permanent && firewall-cmd --reload"
			_reg_fw_opened=1
		elif rpm -q firewalld &>/dev/null; then
			$SUDO firewall-offline-cmd --add-port=$reg_port/tcp >/dev/null
			_reg_fw_opened=1
		elif command -v iptables &>/dev/null && \
			$SUDO iptables -I INPUT 1 -p tcp --dport $reg_port -j ACCEPT 2>/dev/null; then
			aba_info "firewalld not active, opened port $reg_port via iptables."
			_reg_fw_opened=1
		else
			aba_warn "Could not auto-open firewall port $reg_port." \
				"If the registry is unreachable, open the port manually, e.g.:" \
				"  sudo nft insert rule ip filter INPUT tcp dport $reg_port accept" \
				"  or: sudo iptables -I INPUT 1 -p tcp --dport $reg_port -j ACCEPT"
		fi
	fi
}

# --- reg_close_firewall -------------------------------------------------------
# Close firewall port opened by reg_open_firewall at install time.
# Only acts if state.sh records reg_fw_opened=1 (i.e. ABA opened the port).
# Also checks uppercase REG_FW_OPENED for backward compat with pre-ADR-007 state.
# Usage:
#   reg_close_firewall           Close $reg_port on this host (local install)
#   reg_close_firewall --ssh     Close $reg_port via SSH on $reg_host (remote install)
#
# Mirrors reg_open_firewall: tries firewalld first, then iptables fallback.
# Silently succeeds if the port was never opened or the firewall is not active.
reg_close_firewall() {
	if [ "${reg_fw_opened:-${REG_FW_OPENED:-}}" != "1" ]; then
		aba_info "Firewall port $reg_port was not opened by ABA -- skipping close"
		return 0
	fi

	local via_ssh=""
	if [ "${1:-}" = "--ssh" ]; then via_ssh=1; fi

	local where="${via_ssh:+ on $reg_host}"
	aba_info "Closing firewall port $reg_port${where} ..."

	if [ "$via_ssh" ]; then
		local _ssh="ssh -i $reg_ssh_key -F $ssh_conf_file $reg_ssh_user@$reg_host --"

		if $_ssh "rpm -q firewalld &>/dev/null && systemctl is-active firewalld &>/dev/null"; then
			$_ssh "$SUDO firewall-cmd --query-port=$reg_port/tcp --permanent &>/dev/null && \
				$SUDO firewall-cmd --remove-port=$reg_port/tcp --permanent >/dev/null && \
				$SUDO firewall-cmd --reload >/dev/null" || true
		elif $_ssh "command -v iptables &>/dev/null"; then
			$_ssh "$SUDO iptables -D INPUT -p tcp --dport $reg_port -j ACCEPT 2>/dev/null" || true
		fi
	else
		if rpm -q firewalld &>/dev/null && systemctl is-active firewalld &>/dev/null; then
			$SUDO bash -c "firewall-cmd --query-port=$reg_port/tcp --permanent &>/dev/null && \
				firewall-cmd --remove-port=$reg_port/tcp --permanent >/dev/null && \
				firewall-cmd --reload >/dev/null" || true
		elif command -v iptables &>/dev/null; then
			$SUDO iptables -D INPUT -p tcp --dport $reg_port -j ACCEPT 2>/dev/null || true
		fi
	fi
}

# --- reg_ensure_remote_pkgs ---------------------------------------------------
# Ensure required packages are installed on a remote host via SSH.
# Usage: reg_ensure_remote_pkgs <ssh_cmd> <pkg1> [pkg2 ...]
reg_ensure_remote_pkgs() {
	local ssh_cmd="$1"; shift
	local pkgs="$*"

	local missing
	# SSH output is newline-separated; convert to spaces so it can be safely
	# interpolated into subsequent SSH commands (for loops, dnf install, etc.)
	missing=$($ssh_cmd "for pkg in $pkgs; do rpm -q \$pkg >/dev/null 2>&1 || echo \$pkg; done" | tr '\n' ' ')
	missing="${missing% }"  # trim trailing space

	if [ "$missing" ]; then
		aba_info "Installing missing packages on remote host: $missing"
		$ssh_cmd "$SUDO dnf install -y $missing" >> .remote_host_check.out 2>&1 || true
		local still_missing
		still_missing=$($ssh_cmd "for pkg in $missing; do rpm -q \$pkg >/dev/null 2>&1 || echo \$pkg; done" | tr '\n' ' ')
		still_missing="${still_missing% }"  # trim trailing space
		if [ "$still_missing" ]; then
			aba_abort "Failed to install on remote host: $still_missing" \
				"See .remote_host_check.out for details."
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
		# Use ssh+cat instead of scp: podman :Z relabels volume files to
		# container_file_t, which SELinux blocks sshd/sftp from reading.
		# ssh+cat runs as the user shell (not sshd subsystem) so it works.
		local _remote_host="${ca_source%%:*}"
		local _remote_path="${ca_source#*:}"
		if ! ssh -i "$reg_ssh_key" -F "$ssh_conf_file" "$_remote_host" "cat '$_remote_path'" > "$regcreds_dir/rootCA.pem"; then
			aba_abort "Failed to fetch root CA from remote host: $ca_source" \
				"The registry install may have failed — check the output above."
		fi
		if [ ! -s "$regcreds_dir/rootCA.pem" ]; then
			aba_abort "Root CA from $ca_source is empty — the registry may not have generated certificates."
		fi
	else
		cp "$ca_source" "$regcreds_dir/rootCA.pem"
	fi

	# Trust the CA system-wide (updates /etc/pki/ca-trust/)
	trust_root_ca "$regcreds_dir/rootCA.pem"

	# Default reg_user if empty
	if [ ! "$reg_user" ]; then reg_user=init; fi

	# Generate pull secret from template (uses enc_password, reg_host, reg_port)
	aba_info "Generating $regcreds_display/pull-secret-mirror.json"
	export enc_password
	enc_password=$(echo -n "$reg_user:$reg_pw" | base64 -w0)
	scripts/j2 ./templates/pull-secret-mirror.json.j2 > "$regcreds_dir/pull-secret-mirror.json"

	# Write persistent state for uninstall (survives aba clean/reset)
	cat > "$regcreds_dir/state.sh" <<-EOF
	reg_vendor=$vendor
	reg_host=$reg_host
	reg_port=$reg_port
	reg_user=$reg_user
	reg_pw='$reg_pw'
	reg_root=$reg_root
	reg_ssh_key=${reg_ssh_key:-}
	reg_ssh_user=${reg_ssh_user:-}
	reg_root_opts="${reg_root_opts:-}"
	reg_fw_opened=${_reg_fw_opened:-}
	reg_running=true
	last_action=install
	last_action_at='$(date '+%Y-%m-%d %H:%M:%S')'
	reg_installed_at='$(date '+%Y-%m-%d %H:%M:%S')'
	EOF
	aba_info "Saved registry state to $regcreds_display/state.sh"

	# Backup mirror.conf + marker files for dir recreation (ADR-007)
	mkdir -p "$regcreds_dir/backup"
	if [ -f mirror.conf ]; then cp -p mirror.conf "$regcreds_dir/backup/"; fi
	# .available is created by the Makefile after this function returns
	for _flag in .init .rpmsext .rpmsint; do
		if [ -f "$_flag" ]; then cp -p "$_flag" "$regcreds_dir/backup/"; fi
	done

	echo
	local _where="$reg_host:$reg_port"
	[ "${reg_ssh_key:-}" ] && _where+=" (remote, user: ${reg_ssh_user:-root})"
	aba_success "Registry installed/configured successfully!"
	aba_info "$vendor registry at $_where, root: $reg_root"
}

# --- _reg_host_run ------------------------------------------------------------
# Run a shell snippet locally (bash -c) or via an ssh command-prefix string.
# Usage: _reg_host_run [<ssh_cmd>] <shell_command>
_reg_host_run() {
	local ssh_cmd="$1"
	local cmd="$2"

	if [ -n "$ssh_cmd" ]; then
		# Intentional word-split: ssh_cmd is a prefix like "ssh -i key -F conf user@host"
		# shellcheck disable=SC2086
		$ssh_cmd "$cmd"
	else
		bash -c "$cmd"
	fi
}

# --- _reg_probe_set -----------------------------------------------------------
# Run a probe that uses exit 0 = present (stale), 1 = absent.
# Any other exit (SSH drop, missing tool, etc.) aborts -- never treat as gone.
# Usage: _reg_probe_set <ssh_cmd> <shell_command> <label> && stale+="..."
_reg_probe_set() {
	local ssh_cmd="$1"
	local cmd="$2"
	local label="$3"
	local rc=0

	_reg_host_run "$ssh_cmd" "$cmd" || rc=$?
	case "$rc" in
		0) return 0 ;;
		1) return 1 ;;
		*) aba_abort "Registry probe failed ($label, rc=$rc)" ;;
	esac
}

# --- reg_ask_delete_data — REMOVED -------------------------------------------
# Data directory is now preserved by default during uninstall.
# Deletion requires explicit --delete-data flag (sets REG_DELETE_DATA=1).
# See ADR: "uninstall should not destroy data by default."

# --- reg_rm_data_dir ----------------------------------------------------------
# Remove registry data directory, using sudo only for vendors that need it.
# Docker and quay-ng use rootless podman (all files user-owned); quay v2 uses
# Ansible with become:yes (root-owned + postgres-owned files).
#
# Usage: reg_rm_data_dir <vendor> <dir>
#        reg_rm_data_dir <vendor> <dir> <ssh_cmd>   (remote)
reg_rm_data_dir() {
	local vendor="$1" dir="$2" ssh_cmd="${3:-}"

	if [ "$ssh_cmd" ]; then
		$ssh_cmd "[ -d $dir ]" 2>/dev/null || return 0
		aba_info "Removing registry data at $dir on $reg_host ..."
		case "$vendor" in
			quay)  $ssh_cmd "$SUDO rm -rf $dir" ;;
			*)     $ssh_cmd "rm -rf $dir" ;;
		esac
	else
		[ -d "$dir" ] || return 0
		aba_info "Removing registry data at $dir ..."
		case "$vendor" in
			quay)  $SUDO rm -rf "$dir" ;;
			*)     rm -rf "$dir" ;;
		esac
	fi
}

# --- reg_stale_report ---------------------------------------------------------
# Probe whether a registry is still present. Prints a multi-line report of
# leftovers (empty string = fully gone). Requires reg_root + reg_port from
# state.sh. Optional ssh_cmd probes a remote host instead of localhost.
# Probe/tool/SSH failures abort (fail closed) -- they must not look like "gone".
#
# Usage: _stale=$(reg_stale_report quay|docker|quay-ng [ssh_cmd])
reg_stale_report() {
	local vendor="$1"
	local ssh_cmd="${2:-}"
	local port="${reg_port:-8443}"
	local stale=""
	local rc state

	# Probe snippets: capture tool output first, then grep.
	# Never `tool | grep` alone — grep's "no match" (1) masks tool failures (e.g. 127)
	# even under pipefail (rightmost non-zero wins).
	case "$vendor" in
		quay)
			# Data dir is preserved by default; only check if --delete-data was used
			if [ "${REG_DELETE_DATA:-}" ]; then
				_reg_probe_set "$ssh_cmd" "test -d $reg_root" "reg_root" && \
					stale+="  reg_root ($reg_root) still exists"$'\n'
			fi
			_reg_probe_set "$ssh_cmd" "_o=\$(ss -tlnp) || exit \$?; echo \"\$_o\" | grep -q ':$port '" "port $port" && \
				stale+="  Port $port still listening"$'\n'
			_reg_probe_set "$ssh_cmd" "_o=\$(podman ps -a --format '{{.Names}}') || exit \$?; echo \"\$_o\" | grep -qE 'quay-app|quay-redis|quay-postgres'" "quay containers" && \
				stale+="  Quay containers still present"$'\n'
			_reg_probe_set "$ssh_cmd" "_o=\$(podman secret ls --format '{{.Name}}') || exit \$?; echo \"\$_o\" | grep -q redis_pass" "redis_pass secret" && \
				stale+="  redis_pass podman secret still exists"$'\n'
			;;
		docker)
			if [ "${REG_DELETE_DATA:-}" ]; then
				_reg_probe_set "$ssh_cmd" "test -d $reg_root" "reg_root" && \
					stale+="  reg_root ($reg_root) still exists"$'\n'
			fi
			_reg_probe_set "$ssh_cmd" "_o=\$(ss -tlnp) || exit \$?; echo \"\$_o\" | grep -q ':$port '" "port $port" && \
				stale+="  Port $port still listening"$'\n'
			_reg_probe_set "$ssh_cmd" "_o=\$(podman ps -a --format '{{.Names}}') || exit \$?; echo \"\$_o\" | grep -qE '^registry(-$port)?$'" "registry container" && \
				stale+="  registry container still present"$'\n'
			;;
		"$_QUAY_NG_VENDOR"|quay-ng)
			if [ "${REG_DELETE_DATA:-}" ]; then
				_reg_probe_set "$ssh_cmd" "test -d $reg_root" "reg_root" && \
					stale+="  reg_root ($reg_root) still exists"$'\n'
			fi
			_reg_probe_set "$ssh_cmd" "_o=\$(ss -tlnp) || exit \$?; echo \"\$_o\" | grep -q ':$port '" "port $port" && \
				stale+="  Port $port still listening"$'\n'
			# systemctl is-active: 0 + "active" = present; 3/"inactive" = gone.
			# SSH failure (255) or missing systemctl (127) must not look like gone.
			# Check both user-level and system-level (root creates system Quadlets).
			# Output may be multiline (user prints "inactive", then system prints
			# "active"), so grep for any "active" line instead of exact match.
			rc=0
			state=$(_reg_host_run "$ssh_cmd" "systemctl --user is-active quay.service 2>/dev/null || sudo systemctl is-active quay.service 2>/dev/null") || rc=$?
			if [ "$rc" -eq 255 ] || [ "$rc" -eq 127 ]; then
				aba_abort "Registry probe failed (quay.service, rc=$rc)"
			fi
			echo "$state" | grep -qx "active" && stale+="  quay.service still active"$'\n'
			;;
		*)
			aba_abort "reg_stale_report: unknown vendor '$vendor'"
			;;
	esac

	# Always succeed after a completed probe run. Individual absent-checks return 1
	# via `&&`, which must not make this function (or its $() caller) fail under set -e.
	printf '%s' "$stale"
	return 0
}

# --- reg_pre_uninstall ---------------------------------------------------------
# Shared config setup for all uninstall scripts (local and remote).
# Loads config, sources state.sh, makes regcreds_dir available.
# Sets: regcreds_dir, regcreds_display, plus all state.sh variables.
# Usage: reg_pre_uninstall <vendor_label>
reg_pre_uninstall() {
	local vendor_label="${1:-registry}"

	source <(normalize-aba-conf)
	source <(normalize-mirror-conf)
	export regcreds_dir=$HOME/.aba/mirror/$(basename "$PWD")
	export regcreds_display="regcreds"

	if [ ! -s "$regcreds_dir/state.sh" ]; then
		aba_abort "No $vendor_label registry state found in $regcreds_display/state.sh"
	fi

	source "$regcreds_dir/state.sh"
}

# --- reg_remote_pre_uninstall -------------------------------------------------
# Shared setup for remote uninstall scripts: config + SSH verification.
# Extends reg_pre_uninstall with SSH connectivity check.
# Sets: $_ssh, ssh_conf_file (in addition to everything from reg_pre_uninstall)
# Usage: reg_remote_pre_uninstall <vendor_label>
reg_remote_pre_uninstall() {
	local vendor_label="${1:-registry}"

	reg_pre_uninstall "$vendor_label"

	ssh_conf_file=~/.aba/ssh.conf
	_ssh="ssh -i $reg_ssh_key -F $ssh_conf_file $reg_ssh_user@$reg_host"

	if ! $_ssh true; then
		aba_abort \
			"Cannot SSH to '$reg_ssh_user@$reg_host' using key '$reg_ssh_key'" \
			"The registry was installed remotely but SSH access has failed." \
			"Fix SSH connectivity and try again."
	fi
}

# =============================================================================
# Core vendor-specific uninstall helpers
# =============================================================================
# Stop the service, remove data (if approved), and verify clean.
# Called by both the per-vendor scripts and the fallback in reg-uninstall.sh.
#
# Each helper expects these globals to be set:
#   reg_root      Registry data directory
#   reg_port      Registry port (used by stale checks)
# For remote helpers, also: $_ssh (the SSH command prefix)
#
# Returns 0 on success, aborts on failure (stale state left behind).
# =============================================================================

# --- reg_docker_remove --------------------------------------------------------
# Core Docker uninstall: stop container + delete data + verify.
# Usage: reg_docker_remove [ssh_cmd]
reg_docker_remove() {
	local ssh_cmd="${1:-}"
	local _where="localhost"
	[ -n "$ssh_cmd" ] && _where="$reg_host"

	aba_info "Removing Docker registry on $_where ..."
	# Remove both new (registry-PORT) and legacy (registry) container names
	_reg_host_run "$ssh_cmd" "podman rm -f registry-${reg_port} 2>/dev/null; podman rm -f registry 2>/dev/null" || true

	if [ "${REG_DELETE_DATA:-}" ]; then
		reg_rm_data_dir docker "$reg_root" "$ssh_cmd"
	fi

	local _stale
	_stale=$(reg_stale_report docker "$ssh_cmd")
	if [ -n "$_stale" ]; then
		aba_abort \
			"Docker registry uninstall left stale state on $_where:" \
			"$_stale" \
			"Investigate and clean up manually before retrying."
	fi
}

# --- reg_quay_ng_remove -------------------------------------------------------
# Core quay-ng uninstall: call the tool's own 'uninstall' command.
# Same pattern as reg_quay_remove — use the tool, then verify clean.
# Usage: reg_quay_ng_remove [ssh_cmd]
reg_quay_ng_remove() {
	local ssh_cmd="${1:-}"
	local _where="localhost"
	[ -n "$ssh_cmd" ] && _where="$reg_host"

	aba_info "Uninstalling $_QUAY_NG_VENDOR registry on $_where ..."

	local _uninst_rc=0
	if [ -n "$ssh_cmd" ]; then
		# Remote: ensure mirror-registry binary is on remote host
		local _bin_dir="quay-ng"
		local _bin="$_bin_dir/mirror-registry"

		if ! $ssh_cmd "test -x $reg_root/../$_bin_dir/mirror-registry 2>/dev/null"; then
			aba_info "mirror-registry binary not found on remote host, uploading ..."
			if [ ! -x "$_bin" ]; then
				aba_abort "$_QUAY_NG_VENDOR binary '$_bin' not found locally." \
					"Run 'aba -d $(basename "$PWD") uninstall' so the Makefile provides it."
			fi
			local _scp="scp -i $reg_ssh_key -F $ssh_conf_file"
			local _target="$reg_ssh_user@$reg_host"
			$ssh_cmd "mkdir -p $reg_root/../$_bin_dir" || true
			$_scp "$_bin" "$_target:$reg_root/../$_bin_dir/" || \
				aba_abort "Failed to copy mirror-registry binary to $reg_host"
		fi

		local _remote_bin="$reg_root/../$_bin_dir/mirror-registry"
		aba_info "Running: mirror-registry uninstall on $reg_host ..."
		if [ "${REG_DELETE_DATA:-}" ]; then
			$ssh_cmd "$_remote_bin uninstall -data-dir $reg_root -auto-approve" || _uninst_rc=$?
		else
			$ssh_cmd "echo y | $_remote_bin uninstall -data-dir $reg_root" || _uninst_rc=$?
		fi
	else
		# Local
		local _bin="quay-ng/mirror-registry"
		if [ ! -x "$_bin" ]; then
			aba_abort "$_QUAY_NG_VENDOR binary '$_bin' not found." \
				"Run 'aba -d $(basename "$PWD") uninstall' so the Makefile provides it."
		fi

		aba_info "Running: mirror-registry uninstall -data-dir $reg_root ..."
		if [ "${REG_DELETE_DATA:-}" ]; then
			./"$_bin" uninstall -data-dir "$reg_root" -auto-approve || _uninst_rc=$?
		else
			echo y | ./"$_bin" uninstall -data-dir "$reg_root" || _uninst_rc=$?
		fi
	fi

	local _stale
	_stale=$(reg_stale_report "$_QUAY_NG_VENDOR" "$ssh_cmd")
	if [ -n "$_stale" ]; then
		if [ "$_uninst_rc" -ne 0 ]; then
			aba_abort \
				"mirror-registry uninstall failed (exit=$_uninst_rc) and left stale state on $_where:" \
				"$_stale" \
				"Investigate the uninstall failure above. Do not force-clean past an aba failure."
		fi
		aba_abort \
			"mirror-registry uninstall reported success but left stale state on $_where:" \
			"$_stale" \
			"Investigate and clean up manually before retrying."
	fi
}

# --- reg_quay_remove ----------------------------------------------------------
# Core Quay (mirror-registry) uninstall.
# Local: runs ./mirror-registry uninstall directly.
# Remote: ensures binary is on remote host, then runs via SSH.
# Usage: reg_quay_remove [ssh_cmd]
reg_quay_remove() {
	local ssh_cmd="${1:-}"
	local _where="localhost"
	[ -n "$ssh_cmd" ] && _where="$reg_host"

	aba_info "Uninstalling Quay registry on $_where ..."

	if [ -n "$ssh_cmd" ]; then
		# Remote: ensure mirror-registry binary + supporting files are on remote host
		local _mirror_dir
		_mirror_dir="$(dirname "$reg_root")"

		if ! $ssh_cmd "test -f $_mirror_dir/mirror-registry && test -f $_mirror_dir/execution-environment.tar"; then
			aba_info "mirror-registry or supporting files not found on remote host, uploading ..."
			local tarball=""
			for f in mirror-registry-*.tar.gz; do
				[ -f "$f" ] && tarball="$f" && break
			done
			if [ -z "$tarball" ]; then
				aba_abort "mirror-registry tarball not found in $(pwd). Run 'aba -d mirror uninstall' so the Makefile provides it."
			fi

			local remote_tmp="/tmp/.aba-${reg_ssh_user}/reg-uninstall-$$"
			$ssh_cmd "mkdir -p $remote_tmp" || aba_abort "Failed to create temp dir on $reg_host"
			trap '$ssh_cmd "rm -rf $remote_tmp" 2>/dev/null' EXIT

			local _scp="scp -i $reg_ssh_key -F $ssh_conf_file"
			$_scp "$tarball" "$reg_ssh_user@$reg_host:$remote_tmp/" || \
				aba_abort "Failed to copy mirror-registry tarball to $reg_host"
			$ssh_cmd "mkdir -p $_mirror_dir && tar -C $_mirror_dir --no-same-owner -xmzf $remote_tmp/$tarball" || \
				aba_abort "Failed to extract mirror-registry on $reg_host"
			$ssh_cmd "rm -rf $remote_tmp"
		fi

		# mirror-registry hardcodes --name ansible_runner_instance without --replace
		$ssh_cmd "podman rm -f ansible_runner_instance 2>/dev/null" || true

		aba_info "Running: mirror-registry uninstall on $reg_host ..."
		local _uninst_rc=0
		if [ "${REG_DELETE_DATA:-}" ]; then
			$ssh_cmd "cd $_mirror_dir && ./mirror-registry uninstall -v --autoApprove $reg_root_opts" || _uninst_rc=$?
		else
			$ssh_cmd "cd $_mirror_dir && printf 'n\n' | ./mirror-registry uninstall -v $reg_root_opts" || _uninst_rc=$?
		fi
	else
		# Local
		ensure_quay_registry
		podman rm -f ansible_runner_instance 2>/dev/null || true

		local _uninst_rc=0
		if [ "${REG_DELETE_DATA:-}" ]; then
			aba_info "Running command: ./mirror-registry uninstall -v --autoApprove $reg_root_opts"
			./mirror-registry uninstall -v --autoApprove $reg_root_opts || _uninst_rc=$?
		else
			aba_info "Running command: ./mirror-registry uninstall -v $reg_root_opts  (keeping data)"
			printf 'n\n' | ./mirror-registry uninstall -v $reg_root_opts || _uninst_rc=$?
		fi
	fi

	# mirror-registry's Ansible playbook does not remove podman secrets.
	# Clean up redis_pass to prevent stale-state detection on next install.
	if [ -n "$ssh_cmd" ]; then
		$ssh_cmd "podman secret rm redis_pass 2>/dev/null" || true
	else
		podman secret rm redis_pass 2>/dev/null || true
	fi

	local _stale
	_stale=$(reg_stale_report quay "$ssh_cmd")
	if [ -n "$_stale" ]; then
		if [ "$_uninst_rc" -ne 0 ]; then
			aba_abort \
				"mirror-registry uninstall failed (exit=$_uninst_rc) and left stale state on $_where:" \
				"$_stale" \
				"Investigate the uninstall failure above. Do not force-clean past an aba failure."
		fi
		aba_abort \
			"mirror-registry uninstall reported success but left stale state on $_where:" \
			"$_stale" \
			"Investigate why mirror-registry's Ansible playbook did not fully clean up."
	fi
	[ "${_uninst_rc:-0}" -ne 0 ] && \
		aba_info "mirror-registry uninstall exited $_uninst_rc but registry is fully gone -- treating as success"

	# When keeping data (no REG_DELETE_DATA), fix ownership of persisted files.
	# Quay containers run in a user namespace, creating files owned by mapped UIDs
	# (e.g. 101000) that the host user cannot modify.  Without this, re-install
	# fails with PermissionError on quay-storage/uploads.
	# Inside 'podman unshare', UID 0 maps to the host user — so chown 0:0 gives
	# the files back to the calling user.
	if [ -z "${REG_DELETE_DATA:-}" ]; then
		aba_debug "Fixing ownership of persisted data in $reg_root"
		if [ -n "$ssh_cmd" ]; then
			$ssh_cmd "podman unshare chown -R 0:0 $reg_root" 2>/dev/null || true
		else
			podman unshare chown -R 0:0 "$reg_root" 2>/dev/null || true
		fi
	fi
}

# --- reg_finish_uninstall -----------------------------------------------------
# Clear persistent regcreds after a verified-clean uninstall (or already-gone).
# Usage: reg_finish_uninstall <vendor> ["already uninstalled"|"uninstall successful"]
reg_finish_uninstall() {
	local vendor="$1"
	local msg="${2:-uninstall successful}"

	# Data dir is preserved by default.  Remember the login, because Quay will
	# not apply a newly generated password to a user that already exists.
	if [ -z "${REG_DELETE_DATA:-}" ] && [ -n "${reg_root:-}" ] && [ -d "$reg_root" ] && [ -n "${reg_pw:-}" ]; then
		printf "reg_user='%s'\nreg_pw='%s'\n" "$reg_user" "$reg_pw" > "$reg_root/.aba-reuse-creds"
		chmod 600 "$reg_root/.aba-reuse-creds"
		aba_info "Saved the registry login in $reg_root/.aba-reuse-creds for the next install."
	fi

	rm -rf "${regcreds_dir:?}/"*
	aba_success "${vendor} registry ${msg}"
}

# --- reg_check_v2_auth --------------------------------------------------------
# Verify registry is reachable and credentials are valid via /v2/.
# Handles both Basic auth (Docker) and Bearer token exchange (Quay/Quay-ng).
# Usage: reg_check_v2_auth <url> <user> <password>
#   url       Base registry URL, e.g. https://host:port
#   user      Registry username
#   password  Registry password
# Returns 0 on success, 1 on failure.
reg_check_v2_auth() {
	local url="$1" user="$2" pw="$3"

	# Try Basic auth first (works for Docker registry)
	local code
	code=$(curl -k -sS -o /dev/null -w "%{http_code}" \
		--connect-timeout 3 -u "$user:$pw" "$url/v2/" 2>/dev/null) || return 1
	if [ "$code" = "200" ]; then
		return 0
	fi

	# Basic auth returned 401 — try Bearer token exchange (Quay/Quay-ng)
	# Parse service from the challenge header but always use the known-reachable
	# registry URL for the token endpoint.  Quay-ng in port-mapped containers may
	# advertise a realm on port 443 which is unreachable externally.
	if [ "$code" = "401" ]; then
		local hdr service token
		hdr=$(curl -k -sS -D- -o /dev/null --connect-timeout 3 "$url/v2/" 2>/dev/null) || return 1
		service=$(printf '%s\n' "$hdr" | sed -n 's/.*service="\([^"]*\)".*/\1/p' | head -1)
		if [ -z "$service" ]; then
			return 1
		fi

		token=$(curl -k -fsS --connect-timeout 3 -u "$user:$pw" \
			"$url/v2/auth?service=${service}" 2>/dev/null \
			| sed -n 's/.*"token":"\([^"]*\)".*/\1/p') || return 1
		if [ -z "$token" ]; then
			return 1
		fi

		curl -k -fsS --connect-timeout 3 -o /dev/null \
			-H "Authorization: Bearer $token" "$url/v2/"
		return $?
	fi

	return 1
}

# --- reg_remote_pre_install ---------------------------------------------------
# Shared SSH pre-checks for all remote registry installs.
# Sets globals: _ssh, remote_dir, remote_tmp
# Usage: reg_remote_pre_install <vendor>
reg_remote_pre_install() {
	local vendor="$1"

	reg_load_config
	reg_detect_existing
	reg_check_fqdn
	reg_setup_data_dir "$vendor"
	reg_generate_password

	aba_info "Registry configured for *remote* install (reg_ssh_key is defined in mirror.conf)."
	aba_info "Verifying SSH access to $reg_ssh_user@$reg_host ..."

	_ssh="ssh -i $reg_ssh_key -F $ssh_conf_file $reg_ssh_user@$reg_host"

	local flag_file="/tmp/.aba-ssh-probe-${reg_ssh_user}.$$.$RANDOM"
	rm -f "$flag_file" 2>/dev/null || sudo rm -f "$flag_file" 2>/dev/null || true

	if ! $_ssh "touch $flag_file"; then
		aba_abort \
			"Cannot SSH to '$reg_ssh_user@$reg_host' using key '$reg_ssh_key'" \
			"Tested with command: ssh -i $reg_ssh_key $reg_ssh_user@$reg_host" \
			"Ensure password-less SSH to '$reg_ssh_user@$reg_host' is working." \
			"You might also need to set 'reg_ssh_user' in mirror.conf."
	fi

	if [ -f "$flag_file" ]; then
		rm -f "$flag_file" 2>/dev/null || sudo rm -f "$flag_file" 2>/dev/null || true
		aba_abort \
			"Registry configured for *remote* install (reg_ssh_key is defined)." \
			"But $reg_host ($fqdn_ip) reaches this localhost ($(hostname -s)) instead!" \
			"Options:" \
			"1. Undefine 'reg_ssh_key' in mirror.conf for local installation." \
			"2. Update DNS so '$reg_host' resolves to the actual remote host."
	fi

	$_ssh rm -f "$flag_file"
	aba_info "SSH access to $reg_ssh_user@$reg_host is working."

	aba_info "Checking prerequisites on remote host $reg_host (see .remote_host_check.out) ..."

	> .remote_host_check.out
	$_ssh "set -x; ip a" >> .remote_host_check.out 2>&1

	reg_ensure_remote_pkgs "$_ssh" podman jq hostname tar openssl

	$_ssh "podman images" >> .remote_host_check.out 2>&1 || \
		aba_abort "podman is not working on remote host '$reg_host'." \
			"See .remote_host_check.out for details."

	# Resolve reg_root on remote host (~ may expand differently than localhost)
	reg_root=$($_ssh "echo $reg_root")

	# Rebuild reg_root_opts with resolved path (see reg_setup_data_dir comment)
	if [ "$vendor" = "quay" ]; then
		reg_root_opts="--quayRoot $reg_root --quayStorage $reg_root/quay-storage --sqliteStorage $reg_root/sqlite-storage"
	fi

	aba_info "Using registry root dir on remote: $reg_root"

	reg_open_firewall --ssh

	# Create remote working directory
	remote_tmp="/tmp/.aba-${reg_ssh_user}"
	remote_dir="$remote_tmp/reg-install-$$"
	$_ssh "mkdir -p $remote_dir"
	trap '$_ssh "rm -rf $remote_dir" 2>/dev/null' EXIT

	_scp="scp -i $reg_ssh_key -F $ssh_conf_file"
	_target="$reg_ssh_user@$reg_host"
}

# --- reg_remote_post_install --------------------------------------------------
# Shared post-install for all remote registry installs.
# Fetches CA, generates pull secret, verifies connectivity, writes breadcrumb.
# Usage: reg_remote_post_install <vendor> <remote_ca_path>
reg_remote_post_install() {
	local vendor="$1"
	local remote_ca="$2"

	reg_post_install "$_target:$remote_ca" "$vendor" --ssh

	# Phase 1: Wait for the registry HTTP endpoint to respond (no auth = no
	# lockout risk).  Safe to retry freely — just checks connectivity + TLS.
	if ! try_cmd -n 12 -d 5 -m "Wait for registry on ${reg_host}:${reg_port}" -- \
		probe_host --any "https://${reg_host}:${reg_port}/v2/" "registry readiness"; then
		aba_abort \
			"Registry on $reg_host is not responding on port $reg_port after 60s." \
			"Check firewall rules and that the registry service started correctly." \
			"Credentials saved. After fixing: aba -d $(basename "$PWD") verify"
	fi

	# Phase 2: Single auth check — NO retry to avoid Quay brute-force lockout.
	# Quay locks accounts after ~5 failed login attempts; retrying auth when
	# the registry is slow to initialize burns through that budget fast.
	if ! reg_check_v2_auth "https://${reg_host}:${reg_port}" "$reg_user" "$reg_pw"; then
		aba_abort \
			"Registry on $reg_host is reachable but authentication failed." \
			"Check registry credentials (reg_user=$reg_user in mirror.conf)." \
			"Credentials saved. After fixing: aba -d $(basename "$PWD") verify"
	fi

	# Leave breadcrumb on remote
	$_ssh "cat > $reg_root/INSTALLED_BY_ABA.md" <<-BREADCRUMB
		Mirror registry installed by ABA: https://github.com/sjbylo/aba.git
		Installed from: $(hostname -f):$PWD
		Date: $(date '+%Y-%m-%d %H:%M:%S')

		On host $(hostname -f):
		To verify:    cd $PWD && aba verify
		To uninstall: cd $PWD && aba uninstall
	BREADCRUMB
}

# --- reg_stop_vendor ----------------------------------------------------------
# Stop a running registry without removing data or config.
# Idempotent: if already stopped, prints info and returns 0.
# Usage: reg_stop_vendor <vendor> [ssh_cmd]
reg_stop_vendor() {
	local vendor="$1"
	local ssh_cmd="${2:-}"
	local _where="localhost"
	[ -n "$ssh_cmd" ] && _where="$reg_host"

	local port="${reg_port:-8443}"

	# Already stopped?
	if ! _reg_host_run "$ssh_cmd" "ss -tlnp 2>/dev/null | grep -q ':${port} '"; then
		aba_info "Registry on $_where is already stopped (port $port not listening)"
		return 0
	fi

	aba_info "Stopping $vendor registry on $_where ..."

	case "$vendor" in
		docker)
			_reg_host_run "$ssh_cmd" "podman stop registry-${port} 2>/dev/null || podman stop registry 2>/dev/null" || true
			;;
		quay)
			_reg_host_run "$ssh_cmd" "podman stop quay-app quay-redis quay-postgres 2>/dev/null" || true
			;;
		"$_QUAY_NG_VENDOR"|quay-ng)
			_reg_host_run "$ssh_cmd" "systemctl --user stop quay.service 2>/dev/null || sudo systemctl stop quay.service 2>/dev/null" || true
			;;
		*)
			aba_abort "reg_stop_vendor: unknown vendor '$vendor'"
			;;
	esac

	# Verify stopped
	sleep 1
	if _reg_host_run "$ssh_cmd" "ss -tlnp 2>/dev/null | grep -q ':${port} '"; then
		aba_abort "Failed to stop $vendor registry on $_where — port $port still listening"
	fi

	aba_info "$vendor registry stopped on $_where"
}

# --- reg_start_vendor ---------------------------------------------------------
# Start a previously stopped registry.
# Idempotent: if already running, prints info and returns 0.
# Usage: reg_start_vendor <vendor> [ssh_cmd]
reg_start_vendor() {
	local vendor="$1"
	local ssh_cmd="${2:-}"
	local _where="localhost"
	[ -n "$ssh_cmd" ] && _where="$reg_host"

	local port="${reg_port:-8443}"

	# Already running?
	if _reg_host_run "$ssh_cmd" "ss -tlnp 2>/dev/null | grep -q ':${port} '"; then
		aba_info "Registry on $_where is already running (port $port listening)"
		return 0
	fi

	aba_info "Starting $vendor registry on $_where ..."

	case "$vendor" in
		docker)
			_reg_host_run "$ssh_cmd" "podman start registry-${port} 2>/dev/null || podman start registry 2>/dev/null"
			;;
		quay)
			_reg_host_run "$ssh_cmd" "podman start quay-postgres quay-redis quay-app"
			;;
		"$_QUAY_NG_VENDOR"|quay-ng)
			_reg_host_run "$ssh_cmd" "systemctl --user start quay.service 2>/dev/null || sudo systemctl start quay.service 2>/dev/null"
			;;
		*)
			aba_abort "reg_start_vendor: unknown vendor '$vendor'"
			;;
	esac

	# Wait for port to come up (registry may need a moment)
	local _attempts=0
	while ! _reg_host_run "$ssh_cmd" "ss -tlnp 2>/dev/null | grep -q ':${port} '"; do
		_attempts=$(( _attempts + 1 ))
		if [ "$_attempts" -ge 10 ]; then
			aba_abort "Failed to start $vendor registry on $_where — port $port not listening after 10s"
		fi
		sleep 1
	done

	aba_info "$vendor registry started on $_where (port $port)"
}
