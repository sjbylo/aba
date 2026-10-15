#!/bin/bash
# Install Docker registry on a remote host via SSH.
# Called by reg-install.sh dispatcher; not intended for direct invocation.

source scripts/reg-common.sh

aba_debug "Starting: $0 $*"

reg_remote_pre_install "docker"

aba_progress "DONE|reg_config"
aba_progress "START|reg_env"

# Pre-install assertion: detect stale Docker registry state.
# Skip on resume — if the registry is responding, these are our resources.
if ! probe_host --any "$reg_url/v2/" "existing registry" 2>/dev/null; then
	_stale=""
	$_ssh "ss -tlnp | grep -q ':${reg_port} '" && _stale+="  Port $reg_port still listening"$'\n'
	# Only flag a running container as stale — stopped containers are cleaned up during install
	$_ssh "podman ps --format '{{.Names}}' | grep -q -E '^registry(-${reg_port})?$'" && _stale+="  registry container still running"$'\n'
	if [ -n "$_stale" ]; then
		aba_abort \
			"Stale registry state detected on $reg_host before install:" \
			"$_stale" \
			"A previous install was not fully cleaned up." \
			"Run 'aba -d $(basename "$PWD") uninstall' first, or clean up manually."
	fi
fi

ask "Install Docker registry on remote host ($reg_ssh_user@$reg_host:$reg_root), accessible via $reg_hostport" || exit 1

aba_progress "DONE|reg_env"
aba_progress "START|reg_download"

aba_info "Installing Docker registry on remote host $reg_host ..."

# Ensure Docker image tarball exists
if [ ! -f docker-reg-image.tgz ]; then
	aba_info "Downloading Docker registry image ..."
	make -s docker-reg-image.tgz
fi

# Ensure openssl and htpasswd on remote
$_ssh "rpm -q httpd-tools openssl || $SUDO dnf install httpd-tools openssl -y" >> .remote_host_check.out 2>&1

aba_info "Copying Docker registry image to remote host ..."
$_scp docker-reg-image.tgz "$_target:$remote_dir/"

aba_progress "DONE|reg_download"
aba_progress "START|reg_install"

# --- Skip install if registry already running (idempotent resume) ---
if probe_host --any "$reg_url/v2/" "existing registry" 2>/dev/null; then
	aba_info "Registry already running at $reg_host:$reg_port — skipping install"
else
	# Mark state as "installing" so a retry can detect and recover from a partial install
	reg_mark_installing docker

	REGISTRY_DATA_DIR="$reg_root/data"
	REGISTRY_CERTS_DIR="$REGISTRY_DATA_DIR/.docker-certs"
	REGISTRY_AUTH_DIR="$REGISTRY_DATA_DIR/.docker-auth"

	_force_regen=""

	aba_info "Running Docker registry install on remote host ..."
	aba_info "  ssh $reg_ssh_user@$reg_host: podman run -d -p ${reg_port}:5000 --name registry-${reg_port} docker.io/library/registry:latest"
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

		if podman ps --format '{{.Names}}' | grep -q '^registry-${reg_port}\$'; then
			echo '[ABA] Registry container registry-${reg_port} already running — skipping install' >&2
		else
			if podman ps -a --format '{{.Names}}' | grep -q '^registry-${reg_port}\$'; then
				echo '[ABA] Removing stale container registry-${reg_port} from a previous failed install ...' >&2
				podman rm -f registry-${reg_port}
			fi
			podman run -d \
				-p ${reg_port}:5000 \
				--restart=always --name registry-${reg_port} \
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

			# Ensure podman containers with --restart=always survive VM reboot
			if [ \"\$(id -u)\" -ne 0 ]; then
				if command -v loginctl >/dev/null; then
					if ! loginctl show-user \"\$USER\" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
						echo 'Enabling loginctl linger for rootless podman restart persistence ...'
						$SUDO loginctl enable-linger \"\$USER\"
					fi
				fi
				if ! systemctl --user is-enabled podman-restart.service >/dev/null 2>&1; then
					echo 'Enabling podman-restart service ...'
					systemctl --user enable podman-restart.service
				fi
			else
				if ! systemctl is-enabled podman-restart.service >/dev/null 2>&1; then
					echo 'Enabling podman-restart service ...'
					systemctl enable podman-restart.service
				fi
			fi
		fi
	"; then
		aba_abort "Docker registry install failed on remote host $reg_host." \
			"Check the output above for details."
	fi
fi

aba_progress "DONE|reg_install"
aba_progress "START|reg_firewall"
aba_progress "DONE|reg_firewall"
aba_progress "START|reg_postcfg"
aba_progress "DONE|reg_postcfg"
aba_progress "START|reg_verify"

REGISTRY_DATA_DIR="$reg_root/data"
REGISTRY_CERTS_DIR="$REGISTRY_DATA_DIR/.docker-certs"

reg_remote_post_install "docker" "$REGISTRY_CERTS_DIR/ca.crt"

reg_cleanup_backup
aba_progress "DONE|reg_verify"
