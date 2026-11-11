#!/bin/bash
# okd-fixture-lib.sh -- scratch tree shared by the OKD state and lifecycle tests (sourced, not run).
#
# The real scripts run in a reflink copy of the tree with a sandbox HOME. Only the transport
# boundaries are replaced: registry probes, release lookups, oc-mirror, oc and openshift-install.
# Nothing here touches the network, a registry or the live tree.

# Same helper names as the other func tests; the sourcing test sets ABA_ROOT.
FX_OKD_VER="${FX_OKD_VER:-9.8.7-okd-scos.6}"
FX_OKD_VER2="${FX_OKD_VER2:-9.8.6-okd-scos.3}"
FX_OCP_VER="${FX_OCP_VER:-7.6.5}"
FX_DIGEST="sha256:$(printf '1a2b3c4d%.0s' 1 2 3 4 5 6 7 8)"
FX_DIGEST2="sha256:$(printf '0f9e8d7c%.0s' 1 2 3 4 5 6 7 8)"
FX_HOST=registry.example.test
FX_PORT=8443
FX_REGPATH=/mapcfg

fx_init() {
	FX_ROOT=$(mktemp -d)
	FX_REPO="$FX_ROOT/repo"
	FX_HOME="$FX_ROOT/home"
	FX_BIN="$FX_ROOT/bin"
	FX_CALLS="$FX_ROOT/calls"
	mkdir -p "$FX_REPO" "$FX_HOME/.aba/mirror/mirror" "$FX_HOME/.aba/clusters" "$FX_BIN"
	: > "$FX_CALLS"
	local _n
	for _n in scripts templates cli Makefile VERSION others; do
		[ -e "$ABA_ROOT/$_n" ] && cp -a --reflink=auto "$ABA_ROOT/$_n" "$FX_REPO/$_n"
	done

	# Transport boundaries (appended, so these definitions win over the real ones).
	cat >> "$FX_REPO/scripts/include_all.sh" <<-'EOF'

	# ---- test fixture: transports only ----
	require_internet_and_pull_secret() { return 0; }
	verify_release_version_exists() { return 0; }
	verify_upgrade_path_exists() { return 0; }
	ensure_oc_mirror() { return 0; }
	ensure_sigstore_mirror_config() { return 0; }
	cli_download_extra_clis() { return 0; }
	probe_host() { return 0; }
	_run_oc_mirror_with_retry() {
		echo "oc-mirror $1" >> "$FX_CALLS"
		mkdir -p data/working-dir/cluster-resources
		return "${FX_OCM_RC:-0}"
	}
	EOF
	local _s
	for _s in cli-download-all.sh create-containers-auth.sh mirror-status.sh reg-create-imageset-config.sh; do
		printf '#!/bin/bash\necho "%s $*" >> "$FX_CALLS"\nexit 0\n' "$_s" > "$FX_REPO/scripts/$_s"
		chmod +x "$FX_REPO/scripts/$_s"
	done

	# Anything that would leave the box is a test failure: log and fail.
	local _t
	for _t in curl skopeo oc openshift-install; do
		printf '#!/bin/bash\necho "%s $*" >> "$FX_CALLS"\nexit 1\n' "$_t" > "$FX_BIN/$_t"
		chmod +x "$FX_BIN/$_t"
	done

	FX_MIR="$FX_REPO/mirror"
	mkdir -p "$FX_MIR/data"
	ln -s ../scripts "$FX_MIR/scripts"
	ln -s ../templates "$FX_MIR/templates"
	ln -s ../cli "$FX_MIR/cli"
	ln -s ../aba.conf "$FX_MIR/aba.conf"
	ln -s ../templates/Makefile.mirror "$FX_MIR/Makefile"
	printf 'reg_host=%s\nreg_port=%s\nreg_path=%s\nreg_vendor=docker\n' "$FX_HOST" "$FX_PORT" "$FX_REGPATH" > "$FX_MIR/mirror.conf"
	touch "$FX_MIR/.available"
	FX_STATE="$FX_HOME/.aba/mirror/mirror/state.sh"
	printf '{"auths":{"%s:%s":{"auth":"%s"}}}\n' "$FX_HOST" "$FX_PORT" "$(printf 'mirror:fixture' | base64 -w0)" > "$FX_HOME/.aba/mirror/mirror/pull-secret-mirror.json"
	fx_conf ocp
}

fx_cleanup() { [ -n "${FX_ROOT:-}" ] && rm -rf "$FX_ROOT"; }

# fx_conf <distribution> [key=value ...] -- aba.conf of the scratch tree
fx_conf() {
	local _dist="$1"; shift
	local _ver="$FX_OCP_VER"
	[ "$_dist" = okd ] && _ver="$FX_OKD_VER"
	{
		[ "$_dist" = okd ] && echo "distribution=okd"
		[ "$_dist" = ocp-explicit ] && echo "distribution=ocp"
		echo "ocp_version=$_ver"
		echo "ocp_channel=stable"
		echo "platform=bm"
		echo "domain=example.test"
		echo "verify_conf=off"
		echo "ask=false"
		echo "editor=none"
		echo "pull_secret_file=$FX_HOME/.pull-secret.json"
		local _kv
		for _kv in "$@"; do echo "$_kv"; done
	} > "$FX_REPO/aba.conf"
	echo '{}' > "$FX_HOME/.pull-secret.json"
}

# fx_state [key=value ...] -- mirror state.sh as left by an installed registry
fx_state() {
	{
		echo "reg_status=installed"
		echo "reg_vendor=docker"
		echo "reg_host=$FX_HOST"
		echo "reg_port=$FX_PORT"
		echo "reg_path=$FX_REGPATH"
		echo "reg_running=true"
		local _kv
		for _kv in "$@"; do echo "$_kv"; done
	} > "$FX_STATE"
}

# fx_isc okd|ocp [digest] -- data/imageset-config.yaml
fx_isc() {
	local _kind="$1" _dig="${2:-$FX_DIGEST}"
	if [ "$_kind" = okd ]; then
		cat > "$FX_MIR/data/imageset-config.yaml" <<-EOF
		kind: ImageSetConfiguration
		apiVersion: mirror.openshift.io/v2alpha1
		mirror:
		  platform:
		    release: quay.io/okd/scos-release@${_dig}
		    graph: false
		    architectures:
		    - amd64
		EOF
	else
		cat > "$FX_MIR/data/imageset-config.yaml" <<-EOF
		kind: ImageSetConfiguration
		apiVersion: mirror.openshift.io/v2alpha1
		mirror:
		  platform:
		    channels:
		    - name: stable-7.6
		      minVersion: ${FX_OCP_VER}
		      maxVersion: ${FX_OCP_VER}
		    graph: true
		EOF
	fi
}

# fx_run <script> [args] -- run a real script from the mirror dir; sets FX_OUT FX_RC
fx_run() {
	FX_OUT=$(cd "$FX_MIR" && env -i HOME="$FX_HOME" PATH="$FX_BIN:/usr/sbin:/usr/bin:/bin" PLAIN_OUTPUT=1 INFO_ABA=1 \
		ABA_DO_NOT_UPDATE=1 RUN_ONCE_CLEANED=1 FX_CALLS="$FX_CALLS" TMPDIR="$FX_ROOT" LC_ALL=C.UTF-8 \
		${FX_ENV:-} timeout 120 bash "scripts/$1" "${@:2}" 2>&1 </dev/null)
	FX_RC=$?
}

# fx_fn <code> [dir] -- run shell code with include_all.sh sourced (dir defaults to the mirror dir)
fx_fn() {
	FX_OUT=$(cd "${2:-$FX_MIR}" && env -i HOME="$FX_HOME" PATH="$FX_BIN:/usr/sbin:/usr/bin:/bin" PLAIN_OUTPUT=1 INFO_ABA=1 \
		FX_CALLS="$FX_CALLS" TMPDIR="$FX_ROOT" LC_ALL=C.UTF-8 ${FX_ENV:-} \
		timeout 60 bash -c "source $FX_REPO/scripts/include_all.sh noerr 2>/dev/null; trap - ERR; $1" 2>&1 </dev/null)
	FX_RC=$?
}

fx_calls() { cat "$FX_CALLS"; }
fx_calls_reset() { : > "$FX_CALLS"; }
