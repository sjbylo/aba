#!/bin/bash
# =============================================================================
# INTENT:      Monitor agent-based OpenShift install and report completion.
#              On success, externalize cluster state to ~/.aba/clusters/<name>/
#              (auth, config backups, state.sh) per ADR-007.
# CALLED BY:   Makefile.cluster (.install-complete, mon targets)
# CWD:         Cluster directory (e.g. ~/aba/sno/)
# REQUIRES:    include_all.sh, cluster-config.sh, openshift-install
# PRODUCES:    ~/.aba/clusters/<name>/state.sh (cluster identity)
#              ~/.aba/clusters/<name>/kubeconfig, kubeadmin-password (auth)
#              ~/.aba/clusters/<name>/backup/ (cluster.conf, YAMLs, macs.conf)
#              clusterstate symlink in cluster dir (human convenience)
# SIDE EFFECTS: Trusts nothing. Exits non-zero on install failure.
# IDEMPOTENT:  Yes (re-running overwrites state dir safely)
# ENV:         CLUSTER_NAME, BASE_DOMAIN, CP_NAMES, WORKER_NAMES (from cluster-config.sh)
#              platform (from aba.conf via Makefile)
# =============================================================================

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

trap - ERR  # We don't want to catch on error. error handling added below. 

if [ ! "$CLUSTER_NAME" ]; then
	scripts/cluster-config-check.sh
	eval "$(scripts/cluster-config.sh "$@")" || exit 1
fi

aba_info "================================================================================="

opts=
[ "$DEBUG_ABA" ] && opts="--log-level debug"

[ ! -f "$ASSETS_DIR/rendezvousIP" ] && aba_abort "Error: $ASSETS_DIR/rendezvousIP file missing.  Run 'aba iso' to create it."

[ "$no_proxy" ] && no_proxy="$(cat $ASSETS_DIR/rendezvousIP),$no_proxy"   # Needed since we're using the IP address to access
[ "$no_proxy" ] && aba_debug "Using: no_proxy=$no_proxy  opts=$opts"

# Ensure openshift-install is available (wait for background download/install)
if ! ensure_openshift_install >/dev/null; then
	error_msg=$(get_task_error "$TASK_INST_OPENSHIFT_INSTALL")
	aba_abort "Failed to install openshift-install:\n$error_msg"
fi

exec_cmd="openshift-install agent wait-for install-complete --dir $ASSETS_DIR $opts"
echo_yellow "[ABA] Running: $exec_cmd"
aba_debug "Running: $exec_cmd"
$exec_cmd
ret=$?
aba_debug openshift-install returned: $ret 

# All exit codes of openshift-install from source file: cmd/openshift-install/create.go
# Declare an associative array with exit codes as keys
declare -A wait_for_exit_reasons=(
    [3]="Installation configuration error"
    [4]="Infrastructure failed"
    [5]="Bootstrap failed"
    [6]="Install failed"
    [7]="Operator stability failed"
    [8]="Interrupted"
)

# ret = 8 means openshift-install was interrupted (e.g. Ctrl-c), for that we don't want to show any errors. 
[ $ret -eq 8 ] && exit 0

if [ $ret -ne 0 ]; then
	echo_red "[ABA] Something went wrong with the installation." >&2
	[ "${wait_for_exit_reasons[$ret]}" ] && echo_yellow "[ABA] Reason: '${wait_for_exit_reasons[$ret]} ($ret)'" || echo_yellow "[ABA] Reason: 'Unknown ($ret)'"
	echo_yellow "[ABA] The cluster may need more time. Re-run the same command to resume monitoring, example: aba -d $CLUSTER_NAME mon."
	echo_yellow "[ABA] If the problem persists, check the output above for clues."

	exit $ret
fi

aba_info_ok "The cluster has been successfully installed!"

# --- Externalize cluster state (ADR-007) ---
externalize_cluster_state

aba_info_ok "Run '. <(aba shell)' to access the cluster using the kubeconfig file (auth cert), or"
aba_info_ok "Run '. <(aba login)' to log into the cluster using kubeadmin's password."
if [ -f "$regcreds_dir/pull-secret-mirror.json" ]; then
	aba_info_ok "Run 'aba day2' to connect this cluster's OperatorHub to your mirror registry (run after adding any operators to your mirror)."
	aba_info_ok "Run 'aba day2-osus' to configure the OpenShift Update Service."
fi
aba_info_ok "Run 'aba day2-ntp' to configure NTP on this cluster."
aba_info_ok "Run 'aba info' to view this information again."
aba_info_ok "Run 'aba help' and 'aba -h' for more options."

if [ ! -f ~/.aba_first_cluster_success ]; then
	_bdr=$(printf '═%.0s' $(seq 1 64))
	_g=$(tput setaf 10 2>/dev/null)
	_r=$(tput sgr0 2>/dev/null)
	_boxl() { printf "  ${_g}║${_r}  %-62s${_g}║${_r}" "$1"; }
	_boxc() { printf "  ${_g}║${_r}  $(tput setaf "$1" 2>/dev/null)%-62s${_r}${_g}║${_r}" "$2"; }
	echo
	echo_bright_green  "  ╔${_bdr}╗"
	echo               "$(_boxl '')"
	echo               "$(_boxc 15 'Congratulations!')"
	echo               "$(_boxc 15 "You've installed your first OpenShift cluster using Aba!")"
	echo               "$(_boxl '')"
	echo               "$(_boxc 15 'Please consider giving our project a star to let us know:')"
	echo               "$(_boxc 14 'https://github.com/sjbylo/aba')"
	echo               "$(_boxl '')"
	echo               "$(_boxc 11 'Thank you! :)')"
	echo               "$(_boxl '')"
	echo_bright_green  "  ╚${_bdr}╝"
	echo

	touch ~/.aba_first_cluster_success
fi

exit 0
