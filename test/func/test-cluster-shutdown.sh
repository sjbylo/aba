#!/bin/bash
# Graceful shutdown: drain output stays in the log, the drain limit stays 60s,
# an already-off VM is not halted again, and a run without --wait only triggers.

set -euo pipefail

cd "$(dirname "$0")/../.."
export ABA_ROOT="$(pwd)"
REPO="$ABA_ROOT"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; echo "$2" | sed 's/^/    | /'; }

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

BIN="$ROOT/bin"
mkdir -p "$BIN"

cat > "$BIN/curl" << 'EOF'
#!/bin/bash
# The cluster reachability probe is local. Everything else is a real download.
if [[ "$*" == *"127.0.0.1:6443"* ]]; then
	exit 0
fi
exec /usr/bin/curl "$@"
EOF

cat > "$BIN/oc" << 'EOF'
#!/bin/bash
echo "$*" >> "$OC_LOG"
args="$*"
if [[ "$args" == *"whoami"* && "$args" != *"show-server"* ]]; then
	echo kubeadmin
	exit 0
fi
if [[ "$args" == *"show-server"* ]]; then
	echo "https://127.0.0.1:6443"
	exit 0
fi
if [[ "$args" == *"adm drain"* ]]; then
	echo "DRAIN-DETAIL $args"
	exit 0
fi
if [[ "$args" == *"adm cordon"* || "$args" == *"adm release"* ]]; then
	[ "$args" == *"release"* ] && echo "example.com/tools:test"
	exit 0
fi
if [[ "$args" == *"debug"* ]]; then
	echo "OC-DEBUG $args"
	exit 0
fi
if [[ "$args" == *"get node "* && "$args" == *"Ready"* ]]; then
	node=$(echo "$args" | sed -n 's/.*get node \([^ ]*\).*/\1/p')
	case " ${NOT_READY:-} " in
		*" $node "*) echo False ;;
		*) echo True ;;
	esac
	exit 0
fi
# TOPO is sno, compact, or standard. IP_SHUFFLE lists name=ip out of node order
# so a positional zip of "oc get nodes" with the IP list pairs the wrong host.
_topo=${TOPO:-standard}
_cp="master1 master2 master3"
_all="master1 master2 master3 worker1"
[ "$_topo" = "sno" ] && _cp="master1" && _all="master1"
[ "$_topo" = "compact" ] && _all="master1 master2 master3"
if [[ "$args" == *"get nodes"* && "$args" == *"worker,!"* ]]; then
	[ "$_topo" = "standard" ] && echo "worker1"
	exit 0
fi
if [[ "$args" == *"get nodes"* && "$args" == *"control-plane"* ]]; then
	echo "$_cp"
	exit 0
fi
if [[ "$args" == *"get nodes"* && "$args" == *"node-role.kubernetes.io/master"* ]]; then
	echo "$_cp"
	exit 0
fi
if [[ "$args" == *"get nodes"* && "$args" == *"node-role.kubernetes.io/worker"* ]]; then
	case "$_topo" in
		sno) echo "master1" ;;
		compact) echo "master1 master2 master3" ;;
		*) echo "worker1 master1 master2 master3" ;;
	esac
	exit 0
fi
if [[ "$args" == *"InternalIP"* && "$args" == *"metadata.name"* ]]; then
	if [ "${IP_SHUFFLE:-}" = "1" ]; then
		printf '%s\n' "worker1=10.0.0.203" "master3=10.0.0.202" "master1=10.0.0.200" "master2=10.0.0.201"
	elif [ "$_topo" = "sno" ]; then
		printf '%s\n' "master1=10.0.0.200"
	elif [ "$_topo" = "compact" ]; then
		# Not the same order as the node list. Positional pairing would attach .202 to master1.
		printf '%s\n' "master3=10.0.0.202" "master1=10.0.0.200" "master2=10.0.0.201"
	else
		printf '%s\n' "master1=10.0.0.200" "master2=10.0.0.201" "master3=10.0.0.202" "worker1=10.0.0.203"
	fi
	exit 0
fi
if [[ "$args" == *"InternalIP"* ]]; then
	if [ "${IP_SHUFFLE:-}" = "1" ]; then
		echo "10.0.0.203 10.0.0.202 10.0.0.200 10.0.0.201"
	elif [ "$_topo" = "sno" ]; then
		echo "10.0.0.200"
	elif [ "$_topo" = "compact" ]; then
		echo "10.0.0.202 10.0.0.200 10.0.0.201"
	else
		echo "10.0.0.200 10.0.0.201 10.0.0.202 10.0.0.203"
	fi
	exit 0
fi
if [[ "$args" == *"get nodes"* && "$args" == *"metadata.name"* ]]; then
	echo "$_all"
	exit 0
fi
if [[ "$args" == *"get nodes"* ]]; then
	case "$_topo" in
		sno) printf 'NAME      STATUS\nmaster1   Ready\n' ;;
		compact) printf 'NAME      STATUS\nmaster1   Ready\nmaster2   Ready\nmaster3   Ready\n' ;;
		*) printf 'NAME      STATUS\nmaster1   Ready\nmaster2   Ready\nmaster3   Ready\nworker1   Ready\n' ;;
	esac
	exit 0
fi
exit 0
EOF

cat > "$BIN/ssh" << 'EOF'
#!/bin/bash
echo "$*" >> "$SSH_LOG"
args="$*"
if [[ "$args" == *"shutdown -h 1"* || "$args" == *"shutdown -h now"* ]]; then
	host=$(echo "$args" | grep -oE 'core@[0-9.]+' | head -1)
	case " ${SSH_FAIL:-} " in
		*" $host "*) exit 1 ;;
	esac
	exit 0
fi
if [[ "$args" == *"ip -4"* ]]; then
	# master3, 10.0.0.202, holds the API VIP in this fixture.
	[[ "$args" == *"10.0.0.202"* ]] && exit 0
	exit 1
fi
exit 1
EOF

cat > "$BIN/govc" << 'EOF'
#!/bin/bash
if [ "$1" = "about" ]; then
	echo "API type: VirtualCenter"
	exit 0
fi
name="${!#}"
ps=poweredOn
case " ${GOVC_OFF:-} " in
	*" $name "*) ps=poweredOff ;;
esac
printf '%s\n' "{\"virtualMachines\":[{\"runtime\":{\"powerState\":\"$ps\"}}]}"
EOF

cat > "$BIN/aba" << 'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$BIN/curl" "$BIN/oc" "$BIN/ssh" "$BIN/govc" "$BIN/aba"

KEY="$ROOT/id_rsa"
touch "$KEY"

new_cluster() {
	local dir="$1" topo="${2:-standard}" masters workers
	case "$topo" in
		sno) masters=1; workers=0 ;;
		compact) masters=3; workers=0 ;;
		standard) masters=3; workers=1 ;;
		*) echo "unknown topo: $topo" >&2; return 1 ;;
	esac
	mkdir -p "$dir/iso-agent-based/auth"
	ln -sfn "$REPO/scripts" "$dir/scripts"
	cat > "$dir/iso-agent-based/auth/kubeconfig" << 'EOF'
apiVersion: v1
kind: Config
clusters:
- cluster:
    server: https://127.0.0.1:6443
  name: sd
contexts:
- context:
    cluster: sd
    user: admin
  name: sd
current-context: sd
users:
- name: admin
  user:
    token: test
EOF
	cat > "$dir/cluster.conf" << EOF
cluster_name=sdtest
base_domain=example.com
machine_network=10.0.0.0/20
starting_ip=10.0.0.200
num_masters=$masters
num_workers=$workers
master_prefix=master
worker_prefix=worker
next_hop_address=10.0.0.1
api_vip=10.0.0.10
ingress_vip=10.0.0.11
ssh_key_file=$KEY
EOF
	cat > "$dir/vmware.conf" << 'EOF'
GOVC_URL=https://vcenter.example.com
GOVC_USERNAME=user
GOVC_PASSWORD=test
GOVC_INSECURE=1
GOVC_DATACENTER=Datacenter
EOF
}

run_sd() {
	local dir="$1"
	shift
	local oc_log="$ROOT/oc.log" ssh_log="$ROOT/ssh.log"
	: > "$oc_log"
	: > "$ssh_log"
	(
		cd "$dir"
		export PATH="$BIN:$PATH"
		export ASK_OVERRIDE=1 ABA_DO_NOT_UPDATE=1 INFO_ABA=1
		export OC_LOG="$oc_log" SSH_LOG="$ssh_log"
		export NOT_READY="${NOT_READY:-}" SSH_FAIL="${SSH_FAIL:-}" GOVC_OFF="${GOVC_OFF:-}"
		export TOPO="${TOPO:-}" IP_SHUFFLE="${IP_SHUFFLE:-}"
		export ABA_SHUTDOWN_WAIT_SEC="${ABA_SHUTDOWN_WAIT_SEC:-}"
		export ABA_SHUTDOWN_HALT_NOW_AFTER="${ABA_SHUTDOWN_HALT_NOW_AFTER:-}"
		bash scripts/cluster-graceful-shutdown.sh "$@"
	)
}

echo "=== cluster graceful shutdown ==="

# Drain details stay in the log. The screen gets one line per node.
# The API-VIP holder (master3) is halted last. master1 is already off.
dir="$ROOT/c1"
new_cluster "$dir"
export GOVC_OFF="sdtest-master1" NOT_READY="" SSH_FAIL=""
set +e
out=$(run_sd "$dir" 2>&1)
rc=$?
set -e
unset GOVC_OFF NOT_READY SSH_FAIL
{
	[ "$rc" -eq 0 ] \
		&& ! printf '%s\n' "$out" | grep -q "DRAIN-DETAIL" \
		&& grep -q "DRAIN-DETAIL" "$dir/.shutdown.log" \
		&& grep -q -- "--timeout=60s" "$ROOT/oc.log" \
		&& printf '%s\n' "$out" | grep -q "Draining worker1" \
		&& printf '%s\n' "$out" | grep -q "Draining master1" \
		&& printf '%s\n' "$out" | grep -q "already powered off" \
		&& ! grep -q "core@10.0.0.200 sudo shutdown -h 1" "$ROOT/ssh.log" \
		&& printf '%s\n' "$out" | grep -q "Triggered shutdown of the cluster nodes" \
		&& ! printf '%s\n' "$out" | grep -q "Cluster shutdown completed successfully" \
		&& awk '
			BEGIN { n = 0 }
			/shutdown -h 1/ {
				if ($0 ~ /10\.0\.0\.203/) i[n]="w"
				else if ($0 ~ /10\.0\.0\.201/) i[n]="m2"
				else if ($0 ~ /10\.0\.0\.202/) i[n]="m3"
				else i[n]="other"
				n++
			}
			END { exit !(n==3 && i[0]=="w" && i[1]=="m2" && i[2]=="m3") }
		' "$ROOT/ssh.log"
} && ok "no --wait: drain stays in the log, already-off is skipped, VIP node is last" \
	|| bad "no --wait: drain stays in the log, already-off is skipped, VIP node is last" "$out"

# A node that cannot be halted fails the command. No success line.
# NotReady means oc debug is not tried.
dir="$ROOT/c2"
new_cluster "$dir"
export SSH_FAIL="core@10.0.0.201" NOT_READY="master2" GOVC_OFF=""
set +e
out=$(run_sd "$dir" 2>&1)
rc=$?
set -e
unset SSH_FAIL NOT_READY GOVC_OFF
{
	[ "$rc" -ne 0 ] \
		&& printf '%s\n' "$out" | grep -q "Could not trigger shutdown of: master2" \
		&& ! printf '%s\n' "$out" | grep -q "Triggered shutdown of the cluster nodes" \
		&& ! printf '%s\n' "$out" | grep -q "completed successfully" \
		&& ! grep -q "OC-DEBUG" "$dir/.shutdown.log"
} && ok "failed halt exits non-zero and does not oc-debug a NotReady node" \
	|| bad "failed halt exits non-zero and does not oc-debug a NotReady node" "$out"

# SSH failed, node still Ready: oc debug runs under timeout and can accept the halt.
dir="$ROOT/c4"
new_cluster "$dir"
export SSH_FAIL="core@10.0.0.200 core@10.0.0.201 core@10.0.0.202 core@10.0.0.203"
export NOT_READY="" GOVC_OFF=""
set +e
out=$(run_sd "$dir" 2>&1)
rc=$?
set -e
unset SSH_FAIL NOT_READY GOVC_OFF
{
	[ "$rc" -eq 0 ] \
		&& printf '%s\n' "$out" | grep -q "shutdown via oc debug" \
		&& grep -q "OC-DEBUG" "$dir/.shutdown.log" \
		&& grep -q -- "--kill-after=10s" "$REPO/scripts/cluster-graceful-shutdown.sh" \
		&& printf '%s\n' "$out" | grep -q "Triggered shutdown of the cluster nodes"
} && ok "Ready node falls back to oc debug when SSH fails" \
	|| bad "Ready node falls back to oc debug when SSH fails" "$out"

# --wait confirms power-off and does not also print the trigger sentence.
dir="$ROOT/c3"
new_cluster "$dir"
export GOVC_OFF="sdtest-master1 sdtest-master2 sdtest-master3 sdtest-worker1"
export NOT_READY="" SSH_FAIL=""
set +e
out=$(run_sd "$dir" wait=1 2>&1)
rc=$?
set -e
unset GOVC_OFF NOT_READY SSH_FAIL
{
	[ "$rc" -eq 0 ] \
		&& printf '%s\n' "$out" | grep -q "All nodes powered off." \
		&& ! printf '%s\n' "$out" | grep -q "Triggered shutdown of the cluster nodes" \
		&& ! printf '%s\n' "$out" | grep -q "completed successfully"
} && ok "--wait: success is only that every node is powered off" \
	|| bad "--wait: success is only that every node is powered off" "$out"

# Node names and InternalIPs are not in the same order. Each SSH target is
# that node's own IP. A positional zip would send master1 to 10.0.0.203.
dir="$ROOT/c-shuffle"
new_cluster "$dir" standard
export IP_SHUFFLE=1 TOPO=standard NOT_READY="" SSH_FAIL="" GOVC_OFF=""
set +e
out=$(run_sd "$dir" 2>&1)
rc=$?
set -e
unset IP_SHUFFLE TOPO NOT_READY SSH_FAIL GOVC_OFF
{
	[ "$rc" -eq 0 ] \
		&& printf '%s\n' "$out" | grep -q "worker1 (10.0.0.203): shutdown via SSH" \
		&& printf '%s\n' "$out" | grep -q "master1 (10.0.0.200): shutdown via SSH" \
		&& printf '%s\n' "$out" | grep -q "master2 (10.0.0.201): shutdown via SSH" \
		&& printf '%s\n' "$out" | grep -q "master3 (10.0.0.202): shutdown via SSH" \
		&& ! printf '%s\n' "$out" | grep -q "master1 (10.0.0.203)" \
		&& awk '
			BEGIN { n = 0 }
			/shutdown -h 1/ {
				if ($0 ~ /10\.0\.0\.203/) i[n]="w"
				else if ($0 ~ /10\.0\.0\.202/) i[n]="m3"
				else i[n]="other"
				n++
			}
			END { exit !(n==4 && i[0]=="w" && i[3]=="m3") }
		' "$ROOT/ssh.log"
} && ok "standard: node IP is paired by name when the API order differs" \
	|| bad "standard: node IP is paired by name when the API order differs" "$out"

# SNO: one master, no workers. No cordon/drain. The one node is halted.
dir="$ROOT/c-sno"
new_cluster "$dir" sno
export TOPO=sno NOT_READY="" SSH_FAIL="" GOVC_OFF=""
set +e
out=$(run_sd "$dir" 2>&1)
rc=$?
set -e
unset TOPO NOT_READY SSH_FAIL GOVC_OFF
{
	[ "$rc" -eq 0 ] \
		&& ! printf '%s\n' "$out" | grep -q "Draining" \
		&& ! grep -q "DRAIN-DETAIL" "$dir/.shutdown.log" \
		&& printf '%s\n' "$out" | grep -q "master1 (10.0.0.200): shutdown via SSH" \
		&& printf '%s\n' "$out" | grep -q "Triggered shutdown of the cluster nodes" \
		&& ! printf '%s\n' "$out" | grep -q "master2"
} && ok "sno: no drain, the single node is halted" \
	|| bad "sno: no drain, the single node is halted" "$out"

# Compact: every master has the worker role. No dedicated worker. VIP last.
# The IP list is not in node order, so master1 must still be 10.0.0.200.
dir="$ROOT/c-compact"
new_cluster "$dir" compact
export TOPO=compact NOT_READY="" SSH_FAIL="" GOVC_OFF=""
set +e
out=$(run_sd "$dir" 2>&1)
rc=$?
set -e
unset TOPO NOT_READY SSH_FAIL GOVC_OFF
{
	[ "$rc" -eq 0 ] \
		&& printf '%s\n' "$out" | grep -q "Draining master1" \
		&& printf '%s\n' "$out" | grep -q "Draining master2" \
		&& printf '%s\n' "$out" | grep -q "Draining master3" \
		&& ! printf '%s\n' "$out" | grep -q "Draining worker" \
		&& printf '%s\n' "$out" | grep -q "master1 (10.0.0.200): shutdown via SSH" \
		&& printf '%s\n' "$out" | grep -q "master2 (10.0.0.201): shutdown via SSH" \
		&& printf '%s\n' "$out" | grep -q "master3 (10.0.0.202): shutdown via SSH" \
		&& ! printf '%s\n' "$out" | grep -q "master1 (10.0.0.202)" \
		&& awk '
			BEGIN { n = 0 }
			/shutdown -h 1/ {
				if ($0 ~ /10\.0\.0\.202/) i[n]="m3"
				else i[n]="other"
				n++
			}
			END { exit !(n==3 && i[2]=="m3") }
		' "$ROOT/ssh.log"
} && ok "compact: drain every master, halt the API node last, IPs stay paired" \
	|| bad "compact: drain every master, halt the API node last, IPs stay paired" "$out"

# --wait: shutdown -h now is sent once, then the wait times out and names aba kill.
dir="$ROOT/c-wait-fail"
new_cluster "$dir" standard
export ABA_SHUTDOWN_WAIT_SEC=25 ABA_SHUTDOWN_HALT_NOW_AFTER=0
export NOT_READY="" SSH_FAIL="" GOVC_OFF=""
set +e
out=$(run_sd "$dir" wait=1 2>&1)
rc=$?
set -e
unset ABA_SHUTDOWN_WAIT_SEC ABA_SHUTDOWN_HALT_NOW_AFTER NOT_READY SSH_FAIL GOVC_OFF
_nows=$(grep -c 'shutdown -h now' "$ROOT/ssh.log" || true)
{
	[ "$rc" -ne 0 ] \
		&& printf '%s\n' "$out" | grep -q "aba kill" \
		&& ! printf '%s\n' "$out" | grep -q "All nodes powered off." \
		&& ! printf '%s\n' "$out" | grep -q "Triggered shutdown of the cluster nodes" \
		&& [ "$_nows" -eq 4 ]
} && ok "--wait: one immediate halt, then timeout names aba kill" \
	|| bad "--wait: one immediate halt, then timeout names aba kill (nows=$_nows rc=$rc)" "$out"

# Ctrl-C during --wait is an abort, not a successful power-off.
dir="$ROOT/c-int"
new_cluster "$dir" sno
export TOPO=sno ABA_SHUTDOWN_WAIT_SEC=60 ABA_SHUTDOWN_HALT_NOW_AFTER=999
export NOT_READY="" SSH_FAIL="" GOVC_OFF=""
set +e
out=$(
	cd "$dir"
	export PATH="$BIN:$PATH"
	export ASK_OVERRIDE=1 ABA_DO_NOT_UPDATE=1 INFO_ABA=1
	export OC_LOG="$ROOT/oc.log" SSH_LOG="$ROOT/ssh.log"
	export NOT_READY SSH_FAIL GOVC_OFF TOPO
	export ABA_SHUTDOWN_WAIT_SEC ABA_SHUTDOWN_HALT_NOW_AFTER
	: > "$OC_LOG"
	: > "$SSH_LOG"
	timeout --preserve-status --signal=INT 12 bash scripts/cluster-graceful-shutdown.sh wait=1 2>&1
)
rc=$?
set -e
unset TOPO ABA_SHUTDOWN_WAIT_SEC ABA_SHUTDOWN_HALT_NOW_AFTER NOT_READY SSH_FAIL GOVC_OFF
{
	[ "$rc" -eq 130 ] \
		&& printf '%s\n' "$out" | grep -q "Aborted" \
		&& ! printf '%s\n' "$out" | grep -q "All nodes powered off." \
		&& ! printf '%s\n' "$out" | grep -q "Triggered shutdown of the cluster nodes"
} && ok "--wait: Ctrl-C aborts and does not report success" \
	|| bad "--wait: Ctrl-C aborts and does not report success (rc=$rc)" "$out"

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
