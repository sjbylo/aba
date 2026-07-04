#!/bin/bash -e
# INTENT:       Bounce pods that aren't fully ready (recovery for stuck installs).
# CALLED BY:    aba unstick (via aba.sh dispatch)
# CWD:          Cluster directory (e.g. ~/aba/sno/)
# REQUIRES:     cluster.conf, kubeconfig, oc CLI, cluster API reachable
# PRODUCES:     Deletes not-ready pods (excluding Completed, etcd, kube-apiserver)
# SIDE EFFECTS: Pods are force-deleted; controllers will reschedule them
# IDEMPOTENT:   Yes (no-op if all pods are healthy)

source scripts/include_all.sh

source <(normalize-cluster-conf)

_kc=$(cluster_kubeconfig)
[ -z "$_kc" ] && aba_abort "kubeconfig not found for this cluster"

cluster_api_reachable "$_kc" || aba_abort "Cluster API is not reachable. Is the cluster running?"

OC="oc --kubeconfig $_kc"

aba_info "Finding pods that are not fully ready (excluding Completed)..."
_stuck=$($OC get po -A --no-headers 2>/dev/null | awk '{split($3, arr, "/"); if (arr[1] != arr[2] && $4 != "Completed") print $1, $2}')

if [ -z "$_stuck" ]; then
	aba_info_ok "No stuck pods found — cluster looks healthy."
	exit 0
fi

_count=$(echo "$_stuck" | wc -l)
aba_warning "Found $_count stuck pod(s):"
echo "$_stuck" | awk '{printf "  %s/%s\n", $1, $2}' >&2

ask -n "Delete these pods to trigger a reschedule" || exit 0

echo "$_stuck" | while read _ns _pod; do
	case "$_pod" in
		etcd-*|kube-apiserver-*)
			echo "  SKIP (critical): $_ns/$_pod" >&2
			continue
			;;
	esac
	echo "  Deleting: $_ns/$_pod" >&2
	$OC delete pod "$_pod" -n "$_ns" --grace-period=0 --force || true
done

aba_info_ok "Done. Pods will be rescheduled by their controllers."
