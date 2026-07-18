#!/bin/bash -e
# INTENT:       Bounce pods that are stuck (not ready for >5 min or in error state).
# CALLED BY:    aba unstick (via aba.sh dispatch)
# CWD:          Cluster directory (e.g. ~/aba/sno/)
# REQUIRES:     cluster.conf, kubeconfig, oc CLI, cluster API reachable
# PRODUCES:     Deletes stuck/errored pods (excluding etcd/kube-apiserver static pods)
# SIDE EFFECTS: Pods are gracefully deleted (normal grace period)
# IDEMPOTENT:   Yes (no-op if all pods are healthy or still starting)

source scripts/include_all.sh

source <(normalize-cluster-conf)

_kc=$(cluster_kubeconfig)
[ -z "$_kc" ] && aba_abort "kubeconfig not found for this cluster"

cluster_api_reachable "$_kc" || aba_abort "Cluster API is not reachable. Is the cluster running?"

OC="oc --kubeconfig $_kc"

STUCK_THRESHOLD=300  # 5 minutes in seconds

aba_info "Finding stuck pods (not ready for >$((STUCK_THRESHOLD/60)) min)..."

# Single pass: find all pods that are not ready and older than the threshold.
# Covers all stuck states: Error, CrashLoopBackOff, ImagePullBackOff,
# ContainerCreating, Pending, etc. — no hardcoded status list needed.
# Uses time.strptime (Python 3.6+) instead of datetime.fromisoformat (3.7+).
_stuck=$($OC get po -A -o json 2>/dev/null | python3 -c "
import json, sys, time, calendar

def parse_ts(ts):
    ts = ts.rstrip('Z').split('+')[0]
    return calendar.timegm(time.strptime(ts[:19], '%Y-%m-%dT%H:%M:%S'))

data = json.load(sys.stdin)
now = time.time()

for pod in data.get('items', []):
    if pod.get('status', {}).get('phase', '') == 'Succeeded':
        continue

    spec_ct = pod.get('spec', {}).get('containers', [])
    if not spec_ct:
        continue

    status_ct = pod.get('status', {}).get('containerStatuses', [])
    if sum(1 for c in status_ct if c.get('ready')) >= len(spec_ct):
        continue

    # Find the most recent condition transition, fall back to creationTimestamp
    latest = None
    for c in pod.get('status', {}).get('conditions', []):
        try:
            t = parse_ts(c['lastTransitionTime'])
            if latest is None or t > latest:
                latest = t
        except:
            pass
    if latest is None:
        try:
            latest = parse_ts(pod['metadata']['creationTimestamp'])
        except:
            continue

    if (now - latest) >= $STUCK_THRESHOLD:
        print('{} {}'.format(pod['metadata']['namespace'], pod['metadata']['name']))
") || true

if [ -z "$_stuck" ]; then
	aba_success "No stuck pods found — cluster looks healthy (or pods are still starting up)."
	exit 0
fi

_count=$(echo "$_stuck" | wc -l)
aba_warn "Found $_count stuck pod(s):"
echo "$_stuck" | while read _ns _pod; do
	_status=$($OC get pod "$_pod" -n "$_ns" -o jsonpath='{.status.phase}/{.status.reason}' 2>/dev/null) || true
	printf "  %s/%s  (%s)\n" "$_ns" "$_pod" "${_status:-unknown}" >&2
done

ask -n "Delete these pods to trigger a reschedule" || exit 0

echo "$_stuck" | while read _ns _pod; do
	case "$_pod" in
		etcd-*|kube-apiserver-*)
			echo "  SKIP (critical): $_ns/$_pod" >&2
			continue
			;;
	esac
	echo "  Deleting: $_ns/$_pod" >&2
	$OC delete pod "$_pod" -n "$_ns" || true
done

aba_success "Done. Pods will be rescheduled by their controllers."
