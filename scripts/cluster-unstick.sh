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

aba_info "Finding stuck pods (not ready for >$((STUCK_THRESHOLD/60)) min or in error state)..."

# Get pods in error state (CrashLoopBackOff, Error, ImagePullBackOff, ErrImagePull, CreateContainerError)
_error_pods=$($OC get po -A --no-headers 2>/dev/null | \
	awk '$4 ~ /(CrashLoopBackOff|Error|ImagePullBackOff|ErrImagePull|CreateContainerError|InvalidImageName)/ {print $1, $2}') || true

# Get pods not fully ready, excluding Completed and error pods (handled above).
# Only include pods whose last state transition was >5 min ago.
_not_ready_pods=$($OC get po -A -o json 2>/dev/null | python3 -c "
import json, sys, time

data = json.load(sys.stdin)
now = time.time()
threshold = $STUCK_THRESHOLD

for pod in data.get('items', []):
    ns = pod['metadata']['namespace']
    name = pod['metadata']['name']
    phase = pod.get('status', {}).get('phase', '')

    # Skip completed pods
    if phase == 'Succeeded':
        continue

    # Check if pod is fully ready
    containers = pod.get('status', {}).get('containerStatuses', [])
    spec_containers = pod.get('spec', {}).get('containers', [])
    if not spec_containers:
        continue

    ready_count = sum(1 for c in containers if c.get('ready', False))
    total_count = len(spec_containers)

    if ready_count >= total_count:
        continue

    # Pod is not ready — check how long it's been in this state
    conditions = pod.get('status', {}).get('conditions', [])
    # Find the most recent transition time
    latest_transition = None
    for cond in conditions:
        t = cond.get('lastTransitionTime', '')
        if t:
            # Parse ISO 8601 timestamp
            try:
                from datetime import datetime, timezone
                dt = datetime.fromisoformat(t.replace('Z', '+00:00'))
                epoch = dt.timestamp()
                if latest_transition is None or epoch > latest_transition:
                    latest_transition = epoch
            except:
                pass

    if latest_transition is None:
        # No transition time available — use pod creation time
        ct = pod['metadata'].get('creationTimestamp', '')
        if ct:
            try:
                from datetime import datetime, timezone
                dt = datetime.fromisoformat(ct.replace('Z', '+00:00'))
                latest_transition = dt.timestamp()
            except:
                continue
        else:
            continue

    age_seconds = now - latest_transition
    if age_seconds >= threshold:
        print(f'{ns} {name}')
") || true

# Combine and deduplicate
_stuck=$(echo -e "${_error_pods}\n${_not_ready_pods}" | sort -u | grep -v '^$') || true

if [ -z "$_stuck" ]; then
	aba_info_ok "No stuck pods found — cluster looks healthy (or pods are still starting up)."
	exit 0
fi

_count=$(echo "$_stuck" | wc -l)
aba_warning "Found $_count stuck pod(s):"
echo "$_stuck" | while read _ns _pod; do
	_status=$($OC get pod "$_pod" -n "$_ns" -o jsonpath='{.status.phase}/{.status.containerStatuses[0].state}' 2>/dev/null | cut -d'{' -f1) || true
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

aba_info_ok "Done. Pods will be rescheduled by their controllers."
