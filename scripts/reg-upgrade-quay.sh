#!/bin/bash
# Upgrade the Quay mirror registry on localhost and renew its server cert.
# Called by reg-upgrade.sh dispatcher; reads state from $regcreds_dir/state.sh.
#
# Do not skip when the registry answers on /v2/: install does that to resume,
# and here it would leave the old release in place.

source scripts/reg-common.sh

aba_debug "Starting: $0 $* in $PWD"

aba_progress "START|reg_config"

reg_load_state "Quay"

# A CA near expiry stops here, before any download.
reg_quay_check_ca

aba_progress "DONE|reg_config"

ask "Upgrade Quay registry on localhost at $reg_host:$reg_port (the registry restarts)" || exit 1

aba_progress "START|reg_download"

reg_quay_prepare_tarball

aba_info "Extracting $quay_tarball into $PWD ..."
if ! tar xmzf "$quay_tarball"; then
	aba_abort "Failed to extract $quay_tarball. The file may be corrupt or truncated."
fi

aba_progress "DONE|reg_download"
aba_progress "START|reg_cert"

mkdir -p "$ABA_TMP"
leaf_dir=$(mktemp -d "$ABA_TMP/quay-leaf.XXXXXX")
trap 'rm -rf "$leaf_dir"' EXIT
reg_quay_issue_leaf "" "$leaf_days" "$leaf_dir"

aba_progress "DONE|reg_cert"
aba_progress "START|reg_upgrade"

reg_quay_ensure_local_ssh
reg_quay_installer_key

# Do not chown the data tree here (install does, before a reinstall): Quay
# writes it as the container uid, and the upgrade playbook does not give it back.

# mirror-registry hardcodes --name ansible_runner_instance without
# --replace.  A prior interrupted run leaves it behind.
podman rm -f ansible_runner_instance 2>/dev/null || true

aba_info "Upgrading mirror registry with command:"
aba_info "./mirror-registry upgrade -v --quayHostname $reg_host:$reg_port $reg_root_opts --sslCert $leaf_dir/ssl.cert --sslKey $leaf_dir/ssl.key"

# $reg_root_opts is intentionally unquoted - it expands to multiple arguments.
# shellcheck disable=SC2086
if ! ./mirror-registry upgrade -v --quayHostname "$reg_host:$reg_port" $reg_root_opts \
	--sslCert "$leaf_dir/ssl.cert" --sslKey "$leaf_dir/ssl.key"; then
	aba_progress "FAIL|reg_upgrade"
	aba_abort "Quay mirror-registry upgrade failed. Check the output above for details."
fi

aba_progress "DONE|reg_upgrade"
aba_progress "START|reg_postcfg"

reg_post_upgrade "$reg_root/quay-rootCA/rootCA.pem"

aba_progress "DONE|reg_postcfg"
aba_progress "START|reg_verify"

reg_wait_and_check_auth

aba_progress "DONE|reg_verify"

aba_success "Quay registry upgraded at $reg_host:$reg_port, root: $reg_root"
