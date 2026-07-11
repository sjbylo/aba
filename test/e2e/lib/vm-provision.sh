#!/usr/bin/env bash
# =============================================================================
# E2E Test Framework -- VM Provisioning Operations
# =============================================================================
# dnf update, package install, user creation, SSH keys, golden verify,
# cleanup, config deploy. Split from vm-ops.sh.
#
# IMPORTANT -- heredoc + stdin hazard:
#   Every _vm_* helper pipes a heredoc into 'ssh ... bash', so the remote
#   bash reads its script from stdin.  Commands like dnf/yum (Python-based)
#   can read from the same stdin even with -y, consuming lines that bash
#   has not yet executed.  To avoid this:
#     - Keep dnf/yum calls as the LAST command in a heredoc, or
#     - Redirect their stdin: dnf install -y ... < /dev/null
#   Never add new commands after a dnf/yum call in a heredoc block.
# =============================================================================

_E2E_LIB_DIR_VMPROV="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source remote helpers if not already loaded
if ! type _wait_for_ssh &>/dev/null; then
	source "$_E2E_LIB_DIR_VMPROV/remote.sh"
fi
if ! type pool_domain &>/dev/null; then
	source "$_E2E_LIB_DIR_VMPROV/config-helpers.sh"
fi

# --- _vm_wait_ssh -----------------------------------------------------------
# Wait for a VM to become reachable via SSH after power-on.
# Requires 2 consecutive successful probes to confirm SSH is truly stable
# (a single probe can succeed right before sshd/firewall state settles).

_vm_wait_ssh() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"
	local timeout="${3:-${SSH_WAIT_TIMEOUT:-300}}"
	local start=$(date +%s)

	echo "  [vm] Waiting for SSH on ${user}@${host} (timeout: ${timeout}s) ..."
	local consecutive=0
	while true; do
		if _essh -o BatchMode=yes "${user}@${host}" -- "date"; then
			consecutive=$(( consecutive + 1 ))
			if [ $consecutive -ge 2 ]; then
				echo "  [vm] SSH ready on ${user}@${host}"
				return 0
			fi
			sleep 2
			continue
		fi
		consecutive=0

		local elapsed=$(( $(date +%s) - start ))
		if [ $elapsed -ge $timeout ]; then
			echo "  [vm] ERROR: SSH timeout after ${timeout}s for ${user}@${host}" >&2
			return 1
		fi
		sleep 3
	done
}

# --- _vm_setup_ssh_keys -----------------------------------------------------
# Copy coordinator's SSH keys to the VM. Set up root + user access.

_vm_setup_ssh_keys() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"
	local pub_key
	pub_key=$(cat ~/.ssh/id_rsa.pub)

	echo "  [vm] Setting up SSH keys on $host ..."

	cat <<-SSHEOF | _essh "${user}@${host}" -- sudo bash
		set -ex
		mkdir -p /root/.ssh
		chmod 700 /root/.ssh
		grep -qF '${pub_key}' /root/.ssh/authorized_keys 2>/dev/null || echo '${pub_key}' >> /root/.ssh/authorized_keys
		chmod 600 /root/.ssh/authorized_keys

		mkdir -p /home/${user}/.ssh
		grep -qF '${pub_key}' /home/${user}/.ssh/authorized_keys 2>/dev/null || echo '${pub_key}' >> /home/${user}/.ssh/authorized_keys
		chmod 600 /home/${user}/.ssh/authorized_keys
		chown -R ${user}:${user} /home/${user}/.ssh

		if [ ! -f /home/${user}/.ssh/config ]; then
			printf '%s\n' 'StrictHostKeyChecking no' 'UserKnownHostsFile=/dev/null' 'ConnectTimeout=15' 'LogLevel=ERROR' > /home/${user}/.ssh/config
			chmod 600 /home/${user}/.ssh/config
			chown ${user}:${user} /home/${user}/.ssh/config
		fi
		[ ! -f /root/.ssh/config ] && cp /home/${user}/.ssh/config /root/.ssh/config

		sed -i '/^ClientAliveInterval/d; /^ClientAliveCountMax/d' /etc/ssh/sshd_config
		echo "ClientAliveInterval 60"  >> /etc/ssh/sshd_config
		echo "ClientAliveCountMax 5"   >> /etc/ssh/sshd_config

		sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
		systemctl restart sshd
		echo "SSH setup complete (PermitRootLogin=prohibit-password)."
	SSHEOF
}

# --- _vm_install_packages ---------------------------------------------------
# Install all packages needed by conN and disN. Retry loop handles transient
# dnf failures (network glitches, mirror issues).
# Used on the GOLDEN VM only -- pool VMs inherit packages from the golden
# snapshot and skip this step (see _vm_dnf_update_pool for pool updates).

_vm_install_packages() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"

	echo "  [vm] Installing required packages on $host ..."

	# Configure dnf + RHSM proxy (required for disN VMs behind a firewall)
	local _proxy_url="${https_proxy:-${HTTPS_PROXY:-${http_proxy:-${HTTP_PROXY:-}}}}"
	if [ -z "$_proxy_url" ] && [ -f "$HOME/.proxy-set.sh" ]; then
		_proxy_url=$(grep -i '^export HTTPS_PROXY=' "$HOME/.proxy-set.sh" 2>/dev/null | head -1 | sed 's/.*=//;s/"//g')
	fi
	if [ -n "$_proxy_url" ]; then
		local _proxy_host _proxy_port
		_proxy_host=$(echo "$_proxy_url" | sed 's|https\?://||;s|:.*||')
		_proxy_port=$(echo "$_proxy_url" | sed 's|.*:||;s|/.*||')
		echo "  [vm] Configuring dnf + RHSM proxy (${_proxy_host}:${_proxy_port}) on $host ..."
		_essh "${user}@${host}" -- "sudo subscription-manager config \
			--server.proxy_hostname='${_proxy_host}' \
			--server.proxy_port='${_proxy_port}'" || true
		_essh "${user}@${host}" -- "grep -q '^proxy=' /etc/dnf/dnf.conf 2>/dev/null \
			|| echo 'proxy=${_proxy_url}' | sudo tee -a /etc/dnf/dnf.conf >/dev/null" || true
	fi

	# Re-register if consumer identity is missing and credentials are available
	if [ -n "${SUB_USERNAME:-}" ] && [ -n "${SUB_PASSWORD:-}" ]; then
		local _su="$SUB_USERNAME" _sp="$SUB_PASSWORD"
		cat <<-REGEOF | _essh "${user}@${host}" -- sudo bash
			if ! subscription-manager identity &>/dev/null; then
				echo "  [vm] Not registered -- registering as ${_su} ..."
				subscription-manager register --username='${_su}' --password='${_sp}' 2>&1 || echo "  WARNING: registration failed"
			else
				subscription-manager refresh || true
			fi
		REGEOF
	fi

	cat <<-'PKGEOF' | _essh "${user}@${host}" -- sudo bash
		set -ex
		subscription-manager refresh 2>/dev/null || true
		dnf clean all

		for attempt in 1 2 3; do
			if dnf install -y \
				tmux git make \
				podman rsync \
				dnsmasq bind-utils \
				chrony firewalld; then
				echo "package-install exit=0 (attempt $attempt)"
				break
			fi
			if [ "$attempt" -eq 3 ]; then
				echo "package-install FAILED after 3 attempts" >&2
				exit 1
			fi
			echo "package-install attempt $attempt failed -- retrying in 30s ..."
			dnf clean all
			sleep 30
		done
	PKGEOF
}

# --- _vm_setup_time ---------------------------------------------------------

_vm_setup_time() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"
	local ntp_server="${NTP_SERVER:-10.0.1.8}"
	local timezone="${TIMEZONE:-Asia/Singapore}"

	echo "  [vm] Configuring time/NTP on $host ..."

	local allow_net="${NTP_ALLOW_NETWORK:-10.0.0.0/20}"

	cat <<-TIMEEOF | _essh "${user}@${host}" -- sudo bash
		set -ex
		cat > /etc/chrony.conf <<-CHRONYEOF
		server $ntp_server iburst
		driftfile /var/lib/chrony/drift
		makestep 1.0 3
		rtcsync
		allow ${allow_net}
		logdir /var/log/chrony
		CHRONYEOF

		systemctl restart chronyd
		timedatectl set-timezone $timezone
		chronyc -a makestep
		firewall-cmd --permanent --add-service=ntp
		firewall-cmd --reload
		sleep 3
		chronyc sources -v
		timedatectl
	TIMEEOF
}

# --- _vm_dnf_update ---------------------------------------------------------
# Run dnf update via nohup so RPM scriptlets that restart sshd don't kill
# the transaction. Polls for completion marker file.
# Used on the GOLDEN VM: full dnf clean + update + unconditional reboot.
# For pool VMs (cloned from golden), use _vm_dnf_update_pool instead.

_vm_dnf_update() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"
	local poll_timeout=900
	local poll_interval=20

	echo "  [vm] Running dnf clean + update on $host (detached) ..."

	cat <<-'SCRIPT' | _essh "${user}@${host}" -- "sudo tee /tmp/dnf-update.sh >/dev/null"
		#!/bin/bash
		rm -f /tmp/dnf-update.rc
		for attempt in 1 2 3; do
			dnf clean all
			if dnf update -y >>/tmp/dnf-update.log 2>&1; then
				echo 0 > /tmp/dnf-update.rc
				break
			fi
			if [ "$attempt" -eq 3 ]; then
				echo 1 > /tmp/dnf-update.rc
				exit 1
			fi
			echo "dnf-update attempt $attempt failed -- retrying in 30s" >> /tmp/dnf-update.log
			sleep 30
		done
		dnf clean all >>/tmp/dnf-update.log 2>&1
		[ ! -f /tmp/dnf-update.rc ] && echo 0 > /tmp/dnf-update.rc
	SCRIPT

	_essh "${user}@${host}" -- \
		"sudo bash -c 'rm -f /tmp/dnf-update.rc /tmp/dnf-update.log; nohup bash /tmp/dnf-update.sh </dev/null >>/tmp/dnf-update.log 2>&1 &'"

	local elapsed=0
	echo "  [vm] Polling for dnf update completion (timeout: ${poll_timeout}s) ..."
	while [ $elapsed -lt $poll_timeout ]; do
		sleep "$poll_interval"
		elapsed=$(( elapsed + poll_interval ))

		local rc
		rc=$(_essh "${user}@${host}" -- "cat /tmp/dnf-update.rc 2>/dev/null" 2>/dev/null) || true

		if [ -n "$rc" ]; then
			if [ "$rc" = "0" ]; then
				echo "  [vm] dnf update succeeded after ~${elapsed}s"
			else
				echo "  [vm] dnf update FAILED (rc=$rc) after ~${elapsed}s" >&2
				_essh "${user}@${host}" -- "tail -30 /tmp/dnf-update.log" 2>/dev/null || true
				return 1
			fi
			break
		fi

		if [ $(( elapsed % 60 )) -eq 0 ]; then
			echo "  [vm] dnf update still running (~${elapsed}s) ..."
		fi
	done

	if [ $elapsed -ge $poll_timeout ]; then
		echo "  [vm] ERROR: dnf update did not complete within ${poll_timeout}s" >&2
		_essh "${user}@${host}" -- "tail -30 /tmp/dnf-update.log" 2>/dev/null || true
		return 1
	fi

	echo "  [vm] Rebooting $host ..."
	_essh "${user}@${host}" -- "sudo reboot" || true
	# Stagger post-reboot CDN activity across parallel VMs and ensure the VM
	# has started shutting down before the caller polls SSH.
	sleep 20
}

# --- _vm_dnf_update_pool ---------------------------------------------------
# Lightweight dnf update for POOL VMs (cloned from golden).
# Skips dnf clean all and dnf install (packages already on golden).
# Refreshes entitlement certs (golden snapshot may be old), checks for
# available updates, and only reboots if packages were actually updated.
# Returns 0 if reboot happened (caller must _vm_wait_ssh).
# Returns 2 if no updates were needed (caller can skip _vm_wait_ssh).

_vm_dnf_update_pool() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"
	local poll_timeout=900
	local poll_interval=20

	echo "  [vm] Checking for OS updates on $host (pool VM) ..."

	cat <<-'SCRIPT' | _essh "${user}@${host}" -- "sudo tee /tmp/dnf-update.sh >/dev/null"
		#!/bin/bash
		rm -f /tmp/dnf-update.rc /tmp/dnf-update.log

		# Refresh entitlement certs -- golden snapshot may be weeks/months old
		# and clones inherit those potentially stale certs.
		subscription-manager refresh || true

		# Probe for available updates before running a full dnf update.
		# Exit 0 = no updates; exit 100 = updates available; other = error.
		dnf check-update >>/tmp/dnf-update.log 2>&1
		rc=$?
		if [ "$rc" -eq 0 ]; then
			echo "no-updates" > /tmp/dnf-update.rc
			exit 0
		fi
		if [ "$rc" -ne 100 ]; then
			echo "error-$rc" > /tmp/dnf-update.rc
			exit "$rc"
		fi

		# Updates available -- apply them
		for attempt in 1 2 3; do
			if dnf update -y >>/tmp/dnf-update.log 2>&1; then
				echo "updated" > /tmp/dnf-update.rc
				exit 0
			fi
			if [ "$attempt" -eq 3 ]; then
				echo "failed" > /tmp/dnf-update.rc
				exit 1
			fi
			echo "dnf-update attempt $attempt failed -- retrying in 30s" >> /tmp/dnf-update.log
			sleep 30
		done
	SCRIPT

	_essh "${user}@${host}" -- \
		"sudo bash -c 'rm -f /tmp/dnf-update.rc /tmp/dnf-update.log; nohup bash /tmp/dnf-update.sh </dev/null >>/tmp/dnf-update.log 2>&1 &'"

	local elapsed=0
	echo "  [vm] Polling for update check/apply on $host (timeout: ${poll_timeout}s) ..."
	while [ $elapsed -lt $poll_timeout ]; do
		sleep "$poll_interval"
		elapsed=$(( elapsed + poll_interval ))

		local rc
		rc=$(_essh "${user}@${host}" -- "cat /tmp/dnf-update.rc 2>/dev/null" 2>/dev/null) || true

		if [ -n "$rc" ]; then
			case "$rc" in
				no-updates)
					echo "  [vm] No updates available on $host -- skipping reboot"
					return 2
					;;
				updated)
					echo "  [vm] Updates applied on $host after ~${elapsed}s -- rebooting ..."
					_essh "${user}@${host}" -- "sudo reboot" || true
					# Stagger post-reboot CDN activity across parallel VMs and
					# ensure the VM has started shutting down before caller polls SSH.
					sleep 20
					return 0
					;;
				failed)
					echo "  [vm] dnf update FAILED on $host after ~${elapsed}s" >&2
					_essh "${user}@${host}" -- "tail -30 /tmp/dnf-update.log" 2>/dev/null || true
					return 1
					;;
		*)
			echo "  [vm] dnf update ERROR on $host (rc=$rc) after ~${elapsed}s" >&2
			_essh "${user}@${host}" -- "tail -30 /tmp/dnf-update.log" 2>/dev/null || true
			return 1
			;;
			esac
		fi

		if [ $(( elapsed % 60 )) -eq 0 ]; then
			echo "  [vm] Update check still running on $host (~${elapsed}s) ..."
		fi
	done

	echo "  [vm] ERROR: dnf update did not complete on $host within ${poll_timeout}s" >&2
	_essh "${user}@${host}" -- "tail -30 /tmp/dnf-update.log" 2>/dev/null || true
	return 1
}

# --- _vm_cleanup_caches -----------------------------------------------------

_vm_cleanup_caches() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"

	echo "  [vm] Cleaning caches on $host ..."

	cat <<-CACHEEOF | _essh "${user}@${host}" -- bash
		set -ex
		pkill -f 'oc-mirror' || true
		sleep 1
		rm -vrf ~/.cache/agent/
		rm -f ~/bin/{oc,kubectl,oc-mirror,openshift-install,govc,butane,aba}
		rm -f ~/.ssh/quay_installer*
		rm -rf ~/.oc-mirror/.cache
		rm -rf ~/*/.oc-mirror/.cache
		if [ -s ~/.vmware.conf ]; then
		    sed -i "s#^VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER:-/Datacenter/vm/aba-e2e}#g" ~/.vmware.conf
		    [ -n "${VM_DATASTORE:-}" ] && sed -i "s#^GOVC_DATASTORE=.*#GOVC_DATASTORE=${VM_DATASTORE}#g" ~/.vmware.conf
		fi
	CACHEEOF
}

# --- _vm_cleanup_podman -----------------------------------------------------

_vm_cleanup_podman() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"

	echo "  [vm] Cleaning podman on $host ..."

	cat <<-'PODEOF' | _essh "${user}@${host}" -- bash
		set -ex
		podman system prune --all --force
		podman rmi --all --force || true
		rm -rf ~/test
	PODEOF
}

# --- _vm_cleanup_home -------------------------------------------------------
# Stop containers and clean up home directory on a VM.
# Uses sudo for rm so root-owned container data files are removed.

_vm_cleanup_home() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"

	echo "  [vm] Cleaning home directory on $host ..."
	cat <<-'HOMEEOF' | _essh "${user}@${host}" -- bash
		set -ex
		podman stop -a || true
		podman rm -af || true
		command -v docker >/dev/null && docker stop $(docker ps -q) || true
		command -v docker >/dev/null && docker rm -f $(docker ps -aq) || true
		sudo rm -rf ~/*
		echo "=== Home directory after cleanup ==="
		ls -la ~/
	HOMEEOF
}

# --- _vm_setup_vmware_conf -------------------------------------------------
# Copy vmware.conf to the VM (both user and root accounts).

_vm_setup_vmware_conf() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"
	local vf="${VMWARE_CONF:-$HOME/.vmware.conf}"

	echo "  [vm] Copying vmware.conf to $host ..."
	if [ -f "$vf" ]; then
		_escp "$vf" "${user}@${host}:"
		_essh "${user}@${host}" -- "sudo cp /home/${user}/.vmware.conf /root/.vmware.conf && sudo chmod 600 /root/.vmware.conf"
	fi
}

# --- _vm_setup_kvm_conf ----------------------------------------------------
# Copy kvm.conf to the VM (both user and root accounts).

_vm_setup_kvm_conf() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"
	local kf="${KVM_CONF:-$HOME/.kvm.conf}"

	if [ -f "$kf" ]; then
		echo "  [vm] Copying kvm.conf to $host ..."
		_escp "$kf" "${user}@${host}:"
		_essh "${user}@${host}" -- "sudo cp /home/${user}/.kvm.conf /root/.kvm.conf && sudo chmod 600 /root/.kvm.conf"
	fi
}

# --- _vm_authorize_root_on_kvm_host -----------------------------------------
# Ensure root's SSH key from the golden VM is authorized on the KVM hypervisor.

_vm_authorize_root_on_kvm_host() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"
	local kf="${KVM_CONF:-$HOME/.kvm.conf}"

	[ ! -f "$kf" ] && return 0

	local _kvm_uri
	_kvm_uri=$(grep '^LIBVIRT_URI=' "$kf" | head -1 | cut -d= -f2- | sed 's/[[:space:]]*#.*//')
	[ -z "$_kvm_uri" ] && return 0

	local _kvm_userhost
	_kvm_userhost=$(echo "$_kvm_uri" | sed -n 's|.*ssh://\([^/]*\)/.*|\1|p')
	[ -z "$_kvm_userhost" ] && return 0

	echo "  [vm] Authorizing root's SSH key on KVM host ($_kvm_userhost) ..."

	local _root_pub
	_root_pub=$(_essh "${user}@${host}" -- "sudo cat /root/.ssh/id_rsa.pub")
	[ -z "$_root_pub" ] && { echo "  [vm] WARNING: no root SSH key found on $host"; return 0; }

	if ssh -F "${SSH_CONF:-$HOME/.aba/ssh.conf}" "$_kvm_userhost" \
		"grep -qF '$_root_pub' ~/.ssh/authorized_keys 2>/dev/null || echo '$_root_pub' >> ~/.ssh/authorized_keys"; then
		echo "  [vm] Root key authorized on $_kvm_userhost"
	else
		echo "  [vm] WARNING: could not authorize root key on $_kvm_userhost"
	fi
}

# --- _vm_deploy_pull_secret -------------------------------------------------
# Copies bastion's pull-secret to both the default user and root on the VM.

_vm_deploy_pull_secret() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"

	local ps="$HOME/.pull-secret.json"
	if [ -f "$ps" ]; then
		echo "  [vm] Deploying pull-secret on $host ..."
		_escp "$ps" "${user}@${host}:~/.pull-secret.json"
		_essh "${user}@${host}" -- "chmod 600 ~/.pull-secret.json"
		_escp "$ps" "${user}@${host}:/tmp/.pull-secret-root.json"
		_essh "${user}@${host}" -- "sudo cp /tmp/.pull-secret-root.json /root/.pull-secret.json && sudo chmod 600 /root/.pull-secret.json && sudo chown root:root /root/.pull-secret.json && rm -f /tmp/.pull-secret-root.json"
	else
		echo "  [vm] WARNING: $ps not found on bastion -- pull-secret not deployed"
	fi
}

# --- _vm_deploy_proxy_scripts -----------------------------------------------
# Copies bastion's .proxy-set.sh and .proxy-unset.sh to both the default user
# and root on the VM.  Called on the golden VM so all clones inherit them.

_vm_deploy_proxy_scripts() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"

	local ps="$HOME/.proxy-set.sh"
	local pu="$HOME/.proxy-unset.sh"
	if [ -f "$ps" ] && [ -f "$pu" ]; then
		echo "  [vm] Deploying proxy scripts on $host ..."
		_escp "$ps" "${user}@${host}:~/.proxy-set.sh"
		_escp "$pu" "${user}@${host}:~/.proxy-unset.sh"
		_essh "${user}@${host}" -- "chmod 600 ~/.proxy-set.sh ~/.proxy-unset.sh"
		_essh "${user}@${host}" -- "sudo bash -c '
			cp /home/${user}/.proxy-set.sh /root/.proxy-set.sh
			cp /home/${user}/.proxy-unset.sh /root/.proxy-unset.sh
			chmod 600 /root/.proxy-set.sh /root/.proxy-unset.sh
		'"
	else
		echo "  [vm] WARNING: proxy scripts not found on bastion -- not deployed"
	fi
}

# --- _vm_remove_pull_secret -------------------------------------------------

_vm_remove_pull_secret() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"

	echo "  [vm] Removing pull-secret on $host ..."
	_essh "${user}@${host}" -- "rm -fv ~/.pull-secret.json"
}

# --- _vm_deploy_tmux_conf ---------------------------------------------------
# Deploys bastion's ~/.tmux.conf to both the default user and root on the VM.

_vm_deploy_tmux_conf() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"

	echo "  [vm] Deploying .tmux.conf to $host ..."

	local src="$HOME/.tmux.conf"
	if [ ! -f "$src" ]; then
		echo "    WARNING: $src not found on bastion -- skipping tmux config"
		return 0
	fi

	_escp "$src" "${user}@${host}:~/.tmux.conf"
	echo "    .tmux.conf -> ~${user}/"

	_escp "$src" "${user}@${host}:/tmp/.tmux-root.conf"
	_essh "${user}@${host}" -- "sudo cp /tmp/.tmux-root.conf /root/.tmux.conf && sudo chown root:root /root/.tmux.conf && rm -f /tmp/.tmux-root.conf"
	echo "    .tmux.conf -> /root/"
}

# --- _vm_provision_root_user ------------------------------------------------
# Provisions /root/ on the golden VM with files that root-user test runs need.
# Called once during golden VM creation; clones inherit everything.

_vm_provision_root_user() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"

	echo "  [vm] Provisioning root user environment on $host ..."

	local ps="$HOME/.pull-secret.json"
	if [ -f "$ps" ]; then
		_escp "$ps" "${user}@${host}:/tmp/.pull-secret-root.json"
		_essh "${user}@${host}" -- "sudo cp /tmp/.pull-secret-root.json /root/.pull-secret.json && sudo chmod 600 /root/.pull-secret.json && sudo chown root:root /root/.pull-secret.json && rm -f /tmp/.pull-secret-root.json"
		echo "    pull-secret.json -> /root/"
	else
		echo "    WARNING: $ps not found on bastion -- root test runs needing pull-secret will fail"
	fi

	local vf="${VMWARE_CONF:-$HOME/.vmware.conf}"
	if [ -f "$vf" ]; then
		_escp "$vf" "${user}@${host}:/tmp/.vmware-root.conf"
		_essh "${user}@${host}" -- "sudo cp /tmp/.vmware-root.conf /root/.vmware.conf && sudo chmod 600 /root/.vmware.conf && sudo chown root:root /root/.vmware.conf && rm -f /tmp/.vmware-root.conf"
		echo "    vmware.conf -> /root/"
	fi

	local govc_bin="$HOME/bin/govc"
	if [ -x "$govc_bin" ]; then
		_escp "$govc_bin" "${user}@${host}:/tmp/govc-root"
		_essh "${user}@${host}" -- "sudo mkdir -p /root/bin && sudo cp /tmp/govc-root /root/bin/govc && sudo chmod 755 /root/bin/govc && rm -f /tmp/govc-root"
		echo "    govc -> /root/bin/"
	else
		echo "    WARNING: $govc_bin not found on bastion -- govc will be bootstrapped at runtime"
	fi

	_essh "${user}@${host}" -- "sudo bash -c '
		for f in .proxy-set.sh .proxy-unset.sh; do
			[ -f /home/${user}/\$f ] && [ ! -f /root/\$f ] && cp /home/${user}/\$f /root/\$f
		done
	'"
	echo "    proxy scripts -> /root/"

	echo "  [vm] Root user provisioning complete on $host"
}

# --- _vm_create_test_user_and_key_on_host ------------------------------------
# Used on the GOLDEN VM only.  Generates a fresh testy_rsa key pair in the
# default user's ~/.ssh/ on the host, creates the testy user with that public
# key, and verifies SSH locally on the host.  Also sets up cross-host SSH keys
# so root@conN -> root@disN and steve@conN -> steve@disN work.

_vm_create_test_user_and_key_on_host() {
	local host="$1"
	local def_user="${2:-$VM_DEFAULT_USER}"
	local test_user_name="testy"

	echo "  [vm] Creating testy key and user on $host ..."

	_essh "${def_user}@${host}" -- "mkdir -p ~/.ssh && chmod 700 ~/.ssh && rm -f ~/.ssh/testy_rsa* && ssh-keygen -t rsa -f ~/.ssh/testy_rsa -N '' -C testy"

	local pub_key
	pub_key=$(_essh "${def_user}@${host}" -- "cat ~/.ssh/testy_rsa.pub")

	cat <<-USEREOF | _essh "${def_user}@${host}" -- sudo bash
		set -ex
		id $test_user_name && userdel $test_user_name -r -f || true
		useradd $test_user_name -p not-used
		mkdir -p ~${test_user_name}/.ssh
		chmod 700 ~${test_user_name}/.ssh
		echo "$pub_key" > ~${test_user_name}/.ssh/authorized_keys
		chmod 600 ~${test_user_name}/.ssh/authorized_keys
		chown -R ${test_user_name}.${test_user_name} ~${test_user_name}
		restorecon -R /home/${test_user_name} || true
		echo '${test_user_name} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/${test_user_name}

		if grep "^AllowUsers" /etc/ssh/sshd_config; then
		    if ! grep "^AllowUsers" /etc/ssh/sshd_config | grep -w ${test_user_name}; then
		        sed -i "/^AllowUsers/s/\$/ ${test_user_name}/" /etc/ssh/sshd_config
		        systemctl restart sshd
		    fi
		fi
	USEREOF

	_vm_wait_ssh "$host" "$def_user"

	echo "  [vm] Verifying testy SSH locally on $host ..."
	local who
	who=$(_essh "${def_user}@${host}" -- "ssh -i ~/.ssh/testy_rsa -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR ${test_user_name}@localhost whoami")
	if [ "$who" != "$test_user_name" ]; then
		echo "  [vm] ERROR: local SSH as $test_user_name failed (got: '$who')" >&2
		return 1
	fi
	echo "  [vm] testy key created and SSH to $test_user_name@localhost verified on $host"

	# Cross-host keypairs: both conN and disN are cloned from this golden image,
	# so both inherit the same keys for root@conN -> root@disN etc.
	# Use the bastion's key so VMs can SSH back (e.g. notification relay).
	if [ ! -f "$HOME/.ssh/id_rsa" ] || [ ! -f "$HOME/.ssh/id_rsa.pub" ]; then
		echo "  [vm] FATAL: bastion SSH keypair missing (~/.ssh/id_rsa)" >&2
		echo "  [vm] Generate one with: ssh-keygen -t rsa -f ~/.ssh/id_rsa" >&2
		return 1
	fi

	echo "  [vm] Deploying bastion SSH keypair to $host ..."
	_escp "$HOME/.ssh/id_rsa" "${def_user}@${host}:~/.ssh/id_rsa"
	_escp "$HOME/.ssh/id_rsa.pub" "${def_user}@${host}:~/.ssh/id_rsa.pub"
	_essh "${def_user}@${host}" -- "chmod 600 ~/.ssh/id_rsa"

	echo "  [vm] Setting up cross-host SSH keys for root and $def_user ..."

	cat <<-CROSSEOF | _essh "${def_user}@${host}" -- sudo bash
		set -ex

		# Root shares the SAME keypair as the default user
		cp /home/${def_user}/.ssh/id_rsa /root/.ssh/id_rsa
		cp /home/${def_user}/.ssh/id_rsa.pub /root/.ssh/id_rsa.pub
		chmod 600 /root/.ssh/id_rsa

		USER_PUB=\$(cat /home/${def_user}/.ssh/id_rsa.pub)

		# Authorize the shared key for both users
		grep -qF "\$USER_PUB" /root/.ssh/authorized_keys 2>/dev/null || echo "\$USER_PUB" >> /root/.ssh/authorized_keys
		grep -qF "\$USER_PUB" /home/${def_user}/.ssh/authorized_keys 2>/dev/null || echo "\$USER_PUB" >> /home/${def_user}/.ssh/authorized_keys

		chmod 600 /root/.ssh/authorized_keys
		chmod 600 /home/${def_user}/.ssh/authorized_keys
		chown -R ${def_user}:${def_user} /home/${def_user}/.ssh

		[ -f /home/${def_user}/.ssh/config ] && [ ! -f /root/.ssh/config ] && cp /home/${def_user}/.ssh/config /root/.ssh/config

		if [ -f /home/${def_user}/.ssh/testy_rsa ] && [ ! -f /root/.ssh/testy_rsa ]; then
			cp /home/${def_user}/.ssh/testy_rsa /root/.ssh/testy_rsa
			cp /home/${def_user}/.ssh/testy_rsa.pub /root/.ssh/testy_rsa.pub
			chmod 600 /root/.ssh/testy_rsa
		fi

		echo "Cross-host SSH keys configured (shared keypair)."
	CROSSEOF

	echo "  [vm] Cross-host SSH keys set up for root and $def_user on $host"
}

# --- _vm_create_test_user ---------------------------------------------------
# (Re-)create the testy user using the key pair already present in the default
# user's ~/.ssh/testy_rsa on the host (placed there during golden VM setup).

_vm_create_test_user() {
	local host="$1"
	local def_user="${2:-$VM_DEFAULT_USER}"
	local test_user_name="testy"

	echo "  [vm] Creating test user '$test_user_name' on $host ..."

	local pub_key
	pub_key=$(_essh "${def_user}@${host}" -- "cat ~/.ssh/testy_rsa.pub")

	cat <<-USEREOF | _essh "${def_user}@${host}" -- sudo bash
		set -ex
		id $test_user_name && userdel $test_user_name -r -f || true
		useradd $test_user_name -p not-used
		mkdir -p ~${test_user_name}/.ssh
		chmod 700 ~${test_user_name}/.ssh
		echo "$pub_key" > ~${test_user_name}/.ssh/authorized_keys
		chmod 600 ~${test_user_name}/.ssh/authorized_keys
		chown -R ${test_user_name}.${test_user_name} ~${test_user_name}
		restorecon -R /home/${test_user_name} || true
		echo '${test_user_name} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/${test_user_name}

		if grep "^AllowUsers" /etc/ssh/sshd_config; then
		    if ! grep "^AllowUsers" /etc/ssh/sshd_config | grep -w ${test_user_name}; then
		        sed -i "/^AllowUsers/s/\$/ ${test_user_name}/" /etc/ssh/sshd_config
		        systemctl restart sshd
		    fi
		fi
	USEREOF

	_vm_wait_ssh "$host" "$def_user"

	echo "  [vm] Verifying testy SSH locally on $host ..."
	local who
	who=$(_essh "${def_user}@${host}" -- "ssh -i ~/.ssh/testy_rsa -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR ${test_user_name}@localhost whoami")
	if [ "$who" != "$test_user_name" ]; then
		echo "  [vm] ERROR: local SSH as $test_user_name failed (got: '$who')" >&2
		return 1
	fi
	echo "  [vm] SSH to $test_user_name@localhost verified on $host"
}

# --- _vm_set_aba_testing ----------------------------------------------------

_vm_set_aba_testing() {
	local host="$1"
	local def_user="${2:-$VM_DEFAULT_USER}"

	echo "  [vm] Setting ABA_TESTING=1 on $host (root, $def_user, testy) ..."

	cat <<-'TESTEOF' | _essh "${def_user}@${host}" -- sudo bash
		set -e
		sed -i '/^ABA_TESTING=/d' /etc/environment
		echo 'ABA_TESTING=1' >> /etc/environment

		for home_dir in /root "/home/$SUDO_USER" /home/testy; do
		    [ -d "$home_dir" ] || continue
		    user_name=$(basename "$home_dir")
		    [ "$home_dir" = "/root" ] && user_name=root

		    for rcfile in .bashrc .bash_profile; do
		        rc="$home_dir/$rcfile"
		        touch "$rc"
		        sed -i '/^export ABA_TESTING=/d' "$rc"
		        echo 'export ABA_TESTING=1' >> "$rc"
		        chown "$user_name":"$user_name" "$rc"
		    done
		done
	TESTEOF
}

# --- _vm_install_aba --------------------------------------------------------

_vm_install_aba() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"
	local branch
	branch="${E2E_GIT_BRANCH:-$(git -C "${_ABA_ROOT:-$HOME/aba}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo dev)}"
	local repo_url
	repo_url="${E2E_GIT_REPO:-$(git -C "${_ABA_ROOT:-$HOME/aba}" remote get-url origin 2>/dev/null || echo https://github.com/sjbylo/aba.git)}"

	echo "  [vm] Installing aba on ${user}@${host} (branch: $branch) ..."

	local attempt
	for attempt in 1 2 3; do
		if _essh "${user}@${host}" -- "
			rm -rf ~/aba
			git clone --depth 1 --branch $branch $repo_url ~/aba
			cd ~/aba && ./install
		"; then
			return 0
		fi
		echo "  [vm] git clone attempt $attempt failed on ${host}, retrying in 10s ..."
		sleep 10
	done
	echo "  [vm] FATAL: git clone failed after 3 attempts on ${host}" >&2
	return 1
}

# --- _vm_verify_golden ------------------------------------------------------

_vm_verify_golden() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"

	echo "  [golden] Verifying golden VM state on $host ..."

	_vm_wait_ssh "$host" "$user"

	cat <<-'VERIFYEOF' | _essh "${user}@${host}" -- sudo bash
		set -ex
		grep "^ClientAliveInterval" /etc/ssh/sshd_config
		firewall-cmd --query-masquerade
		[ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ]
		systemctl is-active chronyd
		ping -c 3 -W 5 -i0.2 10.0.1.8
		dnf check-update || { rc=$?; [ "$rc" -eq 100 ] && exit 1; exit "$rc"; }
		! podman images -q | grep . || { echo "ERROR: podman images remain"; exit 1; }
		[ -z "$(ls ~$SUDO_USER)" ] || { echo "ERROR: stale files in ~$SUDO_USER"; exit 1; }
		id testy
		grep "ABA_TESTING=1" /etc/environment
		test -f /etc/systemd/system/expand-root.service || { echo "ERROR: expand-root.service missing"; exit 1; }
		test -f /usr/local/bin/expand-root.sh || { echo "ERROR: expand-root.sh script missing"; exit 1; }
		grep -q 'proxy_hostname *=.*[0-9]' /etc/rhsm/rhsm.conf || { echo "ERROR: RHSM proxy not configured"; exit 1; }
		grep -q '^proxy=.*[0-9]' /etc/dnf/dnf.conf || { echo "ERROR: dnf proxy not configured"; exit 1; }

		echo "All golden VM checks passed."
	VERIFYEOF

	if [ $? -ne 0 ]; then
		echo "  [golden] ERROR: verification FAILED" >&2
		return 1
	fi
}
