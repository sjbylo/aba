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
reg_check_fqdn
reg_detect_existing
reg_setup_data_dir "$vendor"
reg_generate_password

# --- SSH connectivity pre-checks ---
aba_info "Registry configured for *remote* install (reg_ssh_key is defined in mirror.conf)."
aba_info "Verifying SSH access to $reg_ssh_user@$reg_host ..."

_ssh="ssh -i $reg_ssh_key -F $ssh_conf_file $reg_ssh_user@$reg_host"

flag_file=/tmp/.$(whoami).$RANDOM
rm -f $flag_file

if ! $_ssh touch $flag_file; then
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
remote_dir="/tmp/aba-reg-install-$$"
$_ssh "mkdir -p $remote_dir"
trap '$_ssh "rm -rf $remote_dir" 2>/dev/null' EXIT

_scp="scp -i $reg_ssh_key -F $ssh_conf_file"
_target="$reg_ssh_user@$reg_host"

case "$vendor" in
	quay)
		ask "Install Quay mirror registry on remote host ($reg_ssh_user@$reg_host:$reg_root), accessible via $reg_hostport" || exit 1

		aba_info "Installing Quay registry on remote host $reg_host ..."

		if ! ensure_quay_registry; then
			error_msg=$(get_task_error "$TASK_QUAY_REG")
			aba_abort "Failed to extract mirror-registry:\n$error_msg"
		fi

		aba_info "Copying mirror-registry tarball to remote host ..."
		$_scp mirror-registry-*.tar.gz "$_target:$remote_dir/"

		cmd="cd $remote_dir && tar xvf mirror-registry-*.tar.gz && ./mirror-registry install -v --quayHostname $reg_host --initUser $reg_user --initPassword '\$REG_PW' $reg_root_opts"

		aba_info "Extracting and installing Quay registry on remote host ..."
		aba_info "  ssh $reg_ssh_user@$reg_host: ./mirror-registry install -v --quayHostname $reg_host --initUser $reg_user --initPassword *** $reg_root_opts"
		if ! $_ssh "export REG_PW='$reg_pw' && $cmd"; then
			aba_abort "Quay mirror-registry install failed on remote host $reg_host." \
				"Check the output above for details."
		fi

		remote_ca="$reg_root/quay-rootCA/rootCA.pem"
		;;

	docker)
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

			if [ ! -f '$REGISTRY_CERTS_DIR/registry.crt' ]; then
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
