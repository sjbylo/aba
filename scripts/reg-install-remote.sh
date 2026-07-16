#!/bin/bash
# Generic SSH orchestrator for remote registry install.
# Called by reg-install.sh dispatcher with vendor name as first argument.
# Usage: reg-install-remote.sh <quay|docker> [args...]
#
# Handles all SSH pre-checks, copies vendor-specific files to the remote host,
# runs the install command remotely, and fetches back the CA certificate.

source scripts/reg-common.sh

vendor="$1"; shift

aba_debug "Starting: $0 vendor=$vendor $*"

reg_load_config
reg_detect_existing
reg_check_fqdn
reg_setup_data_dir "$vendor"
reg_generate_password

# --- SSH connectivity pre-checks ---
aba_info "Registry configured for *remote* install (reg_ssh_key is defined in mirror.conf)."
aba_info "Verifying SSH access to $reg_ssh_user@$reg_host ..."

_ssh="ssh -i $reg_ssh_key -F $ssh_conf_file $reg_ssh_user@$reg_host"

# Use /tmp/ directly — $ABA_TMP is user-specific and remote user may differ
flag_file="/tmp/.aba-ssh-probe-${reg_ssh_user}.$$.$RANDOM"
rm -f "$flag_file"

if ! $_ssh "touch $flag_file"; then
	aba_abort \
		"Cannot SSH to '$reg_ssh_user@$reg_host' using key '$reg_ssh_key'" \
		"Tested with command: ssh -i $reg_ssh_key $reg_ssh_user@$reg_host" \
		"Ensure password-less SSH to '$reg_ssh_user@$reg_host' is working." \
		"You might also need to set 'reg_ssh_user' in mirror.conf."
fi

# Verify the FQDN reaches a *remote* host, not this localhost
if [ -f $flag_file ]; then
	rm -f $flag_file
	aba_abort \
		"Registry configured for *remote* install (reg_ssh_key is defined)." \
		"But $reg_host ($fqdn_ip) reaches this localhost ($(hostname -s)) instead!" \
		"Options:" \
		"1. Undefine 'reg_ssh_key' in mirror.conf for local installation." \
		"2. Update DNS so '$reg_host' resolves to the actual remote host."
fi

$_ssh rm -f $flag_file
aba_info "SSH access to $reg_ssh_user@$reg_host is working."

# --- Ensure remote prerequisites ---
aba_info "Checking prerequisites on remote host $reg_host (see .remote_host_check.out) ..."

> .remote_host_check.out
$_ssh "set -x; ip a" >> .remote_host_check.out 2>&1

reg_ensure_remote_pkgs "$_ssh" podman jq hostname tar openssl

$_ssh "podman images" >> .remote_host_check.out 2>&1 || \
	aba_abort "podman is not working on remote host '$reg_host'." \
		"See .remote_host_check.out for details."

# Resolve reg_root on remote host (~ may expand differently than localhost)
reg_root=$($_ssh "echo $reg_root")

# Rebuild reg_root_opts with resolved path
if [ "$vendor" = "quay" ]; then
	reg_root_opts="--quayRoot $reg_root --quayStorage $reg_root/quay-storage --sqliteStorage $reg_root/sqlite-storage"
fi

aba_info "Using registry root dir on remote: $reg_root"

reg_open_firewall --ssh

# --- Vendor-specific install ---
# Use remote user's temp dir — $ABA_TMP is local-user-specific and may differ
remote_tmp="/tmp/.aba-${reg_ssh_user}"
remote_dir="$remote_tmp/reg-install-$$"
$_ssh "mkdir -p $remote_dir"
trap '$_ssh "rm -rf $remote_dir" 2>/dev/null' EXIT

_scp="scp -i $reg_ssh_key -F $ssh_conf_file"
_target="$reg_ssh_user@$reg_host"

case "$vendor" in
	quay)
		reg_check_quay_resources "$_ssh"

		# Pre-install assertion: detect stale state from a previous install that
		# was not fully uninstalled. Stale redis_pass secrets cause WRONGPASS on
		# the new install; stale containers hold ports and conflict with Ansible.
		_stale=""
		$_ssh "ss -tlnp | grep -q ':${reg_port} '" && _stale+="  Port $reg_port still listening"$'\n'
		$_ssh "podman secret ls --format '{{.Name}}' | grep -q redis_pass" && _stale+="  redis_pass podman secret exists"$'\n'
		$_ssh "podman ps -a --format '{{.Names}}' | grep -qE 'quay-app|quay-redis|quay-postgres'" && _stale+="  Quay containers still present"$'\n'
		if [ -n "$_stale" ]; then
			aba_abort \
				"Stale registry state detected on $reg_host before install:" \
				"$_stale" \
				"A previous install was not fully cleaned up." \
				"Run 'aba -d $(basename "$PWD") uninstall' first, or clean up manually."
		fi

		ask "Install Quay mirror registry on remote host ($reg_ssh_user@$reg_host:$reg_root), accessible via $reg_hostport" || exit 1

		aba_info "Installing Quay registry on remote host $reg_host ..."

		if ! ensure_quay_registry; then
			error_msg=$(get_task_error "$TASK_INST_QUAY_REG")
			aba_abort "Failed to extract mirror-registry:\n$error_msg"
		fi

		# mirror-registry's internal Ansible needs quay_installer to SSH back to
		# the same host. The binary creates the keypair but doesn't authorize it.
		$_ssh "if [ ! -s ~/.ssh/quay_installer ]; then mkdir -p ~/.ssh && chmod 700 ~/.ssh && ssh-keygen -t ed25519 -f ~/.ssh/quay_installer -N '' >/dev/null && cat ~/.ssh/quay_installer.pub >> ~/.ssh/authorized_keys; fi"

		aba_info "Copying mirror-registry tarball to remote host ..."
		$_scp mirror-registry-*.tar.gz "$_target:$remote_dir/"

		# printf '%q' safely escapes all shell metacharacters for remote evaluation
		_escaped_pw=$(printf '%q' "$reg_pw")
		cmd="cd $remote_dir && tar xvf mirror-registry-*.tar.gz && ./mirror-registry install -v --quayHostname $reg_hostport --initUser $reg_user --initPassword '\$_reg_pw' $reg_root_opts"

		aba_info "Extracting and installing Quay registry on remote host ..."
		aba_info "  ssh $reg_ssh_user@$reg_host: ./mirror-registry install -v --quayHostname $reg_hostport --initUser $reg_user --initPassword *** $reg_root_opts"
		if ! $_ssh "export _reg_pw=$_escaped_pw && $cmd"; then
			aba_abort "Quay mirror-registry install failed on remote host $reg_host." \
				"Check the output above for details."
		fi

		remote_ca="$reg_root/quay-rootCA/rootCA.pem"
		;;

	docker)
		# Pre-install assertion: detect stale Docker registry state.
		_stale=""
		$_ssh "ss -tlnp | grep -q ':${reg_port} '" && _stale+="  Port $reg_port still listening"$'\n'
		$_ssh "podman ps -a --format '{{.Names}}' | grep -q '^registry$'" && _stale+="  registry container still present"$'\n'
		if [ -n "$_stale" ]; then
			aba_abort \
				"Stale registry state detected on $reg_host before install:" \
				"$_stale" \
				"A previous install was not fully cleaned up." \
				"Run 'aba -d $(basename "$PWD") uninstall' first, or clean up manually."
		fi

		ask "Install Docker registry on remote host ($reg_ssh_user@$reg_host:$reg_root), accessible via $reg_hostport" || exit 1

		aba_info "Installing Docker registry on remote host $reg_host ..."

		# Ensure Docker image tarball exists (download if on connected host).
		# Unlike Quay's ensure_quay_registry()/run_once(), a simple make call
		# suffices here: the Docker image pull is fast and the tarball is small,
		# so there's no need for background extraction or deduplication.
		if [ ! -f docker-reg-image.tgz ]; then
			aba_info "Downloading Docker registry image ..."
			make -s docker-reg-image.tgz
		fi

		# Ensure openssl and htpasswd on remote
		$_ssh "rpm -q httpd-tools openssl || $SUDO dnf install httpd-tools openssl -y" >> .remote_host_check.out 2>&1

		aba_info "Copying Docker registry image to remote host ..."
		$_scp docker-reg-image.tgz "$_target:$remote_dir/"

		REGISTRY_DATA_DIR="$reg_root/data"
		REGISTRY_CERTS_DIR="$REGISTRY_DATA_DIR/.docker-certs"
		REGISTRY_AUTH_DIR="$REGISTRY_DATA_DIR/.docker-auth"

		# After ADR-007 Phase 3, $reg_host is already overridden from state.sh
		# by normalize-mirror-conf, so hostname drift is impossible here.
		# Remote cert check relies on the SAN match inside the heredoc below.
		_force_regen=""

		aba_info "Running Docker registry install on remote host ..."
		aba_info "  ssh $reg_ssh_user@$reg_host: podman run -d -p ${reg_port}:5000 --name registry docker.io/library/registry:latest"
		if ! $_ssh "
			set -e
			podman load -i $remote_dir/docker-reg-image.tgz
			mkdir -p '$REGISTRY_DATA_DIR' '$REGISTRY_CERTS_DIR' '$REGISTRY_AUTH_DIR'

			if [ ! -f '$REGISTRY_CERTS_DIR/ca.crt' ]; then
				openssl genrsa -out '$REGISTRY_CERTS_DIR/ca.key' 4096
				openssl req -x509 -new -nodes -key '$REGISTRY_CERTS_DIR/ca.key' \
					-sha256 -days 3650 -out '$REGISTRY_CERTS_DIR/ca.crt' -subj '/CN=ABA-RegistryCA'
			fi

			_need_cert=false
			if [ ! -f '$REGISTRY_CERTS_DIR/registry.crt' ] || [ ! -f '$REGISTRY_CERTS_DIR/registry.key' ]; then
				_need_cert=true
			elif [ '${_force_regen}' = true ]; then
				echo '[ABA] Hostname changed — regenerating certificate ...'
				_need_cert=true
			elif ! openssl x509 -noout -ext subjectAltName -in '$REGISTRY_CERTS_DIR/registry.crt' 2>/dev/null | grep -q 'DNS:${reg_host}$'; then
				echo '[ABA] Existing certificate does not match hostname ${reg_host} — regenerating ...'
				_need_cert=true
			fi
			if [ \"\$_need_cert\" = true ]; then
				openssl genrsa -out '$REGISTRY_CERTS_DIR/registry.key' 4096
				openssl req -new -key '$REGISTRY_CERTS_DIR/registry.key' \
					-out '$REGISTRY_CERTS_DIR/registry.csr' -subj '/CN=$reg_host'
				printf 'subjectAltName = DNS:$reg_host\nextendedKeyUsage = serverAuth\n' \
					> '$REGISTRY_CERTS_DIR/registry-ext.cnf'
				openssl x509 -req -in '$REGISTRY_CERTS_DIR/registry.csr' \
					-CA '$REGISTRY_CERTS_DIR/ca.crt' -CAkey '$REGISTRY_CERTS_DIR/ca.key' -CAcreateserial \
					-out '$REGISTRY_CERTS_DIR/registry.crt' -days 3650 -sha256 \
					-extfile '$REGISTRY_CERTS_DIR/registry-ext.cnf'
			fi

			htpasswd -Bbn '$reg_user' '$reg_pw' > '$REGISTRY_AUTH_DIR/htpasswd'

			podman rm -f registry 2>/dev/null || true
			podman run -d \
				-p ${reg_port}:5000 \
				--restart=always --name registry \
				-v '${REGISTRY_DATA_DIR}:/var/lib/registry:Z' \
				-v '${REGISTRY_CERTS_DIR}:/certs:Z' \
				-v '${REGISTRY_AUTH_DIR}:/auth:Z' \
				-e REGISTRY_HTTP_ADDR=0.0.0.0:5000 \
				-e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/registry.crt \
				-e REGISTRY_HTTP_TLS_KEY=/certs/registry.key \
				-e REGISTRY_AUTH=htpasswd \
				-e 'REGISTRY_AUTH_HTPASSWD_REALM=Registry Realm' \
				-e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
				docker.io/library/registry:latest

			# Ensure rootless podman containers with --restart=always survive VM reboot
			if [ \"\$(id -u)\" -ne 0 ] && command -v loginctl >/dev/null; then
				if ! loginctl show-user \"\$USER\" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
					echo 'Enabling loginctl linger for rootless podman restart persistence ...'
					$SUDO loginctl enable-linger \"\$USER\"
				fi
			fi
		"; then
			aba_abort "Docker registry install failed on remote host $reg_host." \
				"Check the output above for details."
		fi

		remote_ca="$REGISTRY_CERTS_DIR/ca.crt"
		;;

	*)
		aba_abort "Unknown registry vendor: $vendor"
		;;
esac

# --- Fetch CA and run local post-install ---
reg_post_install "$_target:$remote_ca" "$vendor" --ssh

# Verify remote Docker registry is reachable and authenticated from this host.
# Quay's mirror-registry handles its own post-install verification via Ansible.
# Docker needs an explicit check because 'podman run -d' returns immediately
# before the registry has fully loaded its auth config (htpasswd volume).
if [ "$vendor" = "docker" ]; then
	if ! try_cmd -n 3 -d 5 -m "Verify registry ${reg_host}:${reg_port}" -- \
		curl -k -fsSL --connect-timeout 10 -o /dev/null \
			"https://${reg_host}:${reg_port}/v2/" -u "$reg_user:$reg_pw"; then
		aba_abort \
			"Registry started on $reg_host but verification of ${reg_host}:${reg_port} failed after 3 attempts." \
			"Check firewall rules (port $reg_port), TLS certificates, and registry credentials." \
			"Credentials saved. After fixing: aba -d $(basename "$PWD") verify"
	fi
fi

# Leave breadcrumb on remote so the user knows how to manage this registry
$_ssh "cat > $reg_root/INSTALLED_BY_ABA.md" <<-BREADCRUMB
	Mirror registry installed by ABA: https://github.com/sjbylo/aba.git
	Installed from: $(hostname -f):$PWD
	Date: $(date '+%Y-%m-%d %H:%M:%S')

	On host $(hostname -f):
	To verify:    cd $PWD && aba verify
	To uninstall: cd $PWD && aba uninstall
BREADCRUMB

# Cleanup handled by EXIT trap
