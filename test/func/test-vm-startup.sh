#!/bin/bash
# vmw startup powers the VMs on and uncordons every node.
# SNO, compact, and standard differ only in which nodes the API returns.
# Offline: fake aba, curl, and oc. No hypervisor and no cluster.

set -euo pipefail

cd "$(dirname "$0")/../.." || exit 1
ROOT=$PWD

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf '  PASS  %s\n' "$*"; }
_fail() { fail=$(( fail + 1 )); printf '  FAIL  %s\n' "$*"; }

WORK=$(mktemp -d /tmp/aba-vm-startup.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
REPO=$WORK/repo
CL=$REPO/vm1
mkdir -p "$WORK/bin" "$CL/iso-agent-based/auth"
cp -a "$ROOT/scripts" "$REPO/scripts"
printf '#!/bin/bash\nexit 0\n' > "$REPO/scripts/cli-install-all.sh"
chmod +x "$REPO/scripts/cli-install-all.sh"
ln -s "$REPO/scripts" "$CL/scripts"

cat > "$WORK/bin/aba" << EOF
#!/bin/bash
echo "\$*" >> "$WORK/aba.log"
exit 0
EOF
cat > "$WORK/bin/curl" << 'EOF'
#!/bin/bash
echo "Red Hat OpenShift"
exit 0
EOF
cat > "$WORK/bin/oc" << EOF
#!/bin/bash
echo "\$*" >> "$WORK/oc.log"
args="\$*"
if [[ "\$args" == *"show-console"* ]]; then
	echo "https://console.apps.example.com/"
	exit 0
fi
if [[ "\$args" == *"whoami"* ]]; then
	exit 0
fi
if [[ "\$args" == *"get csr"* || "\$args" == *"adm uncordon"* || "\$args" == *"get pods"* ]]; then
	exit 0
fi
if [[ "\$args" == *"get co"* ]]; then
	echo "authentication 4.0.0 True False False"
	exit 0
fi
if [[ "\$args" == *"kube-apiserver-to-kubelet-signer"* ]]; then
	echo "2027-01-01T00:00:00Z"
	exit 0
fi
if [[ "\$args" == *"get nodes"* && "\$args" == *"Ready"* ]]; then
	for _n in \$NODES; do echo True; done
	exit 0
fi
# First read is still cordoned. After every node was uncordoned, the re-read is clean.
if [[ "\$args" == *"node.kubernetes.io/unschedulable"* ]]; then
	_done=1
	for _n in \$NODES; do
		grep -q "adm uncordon \$_n" "$WORK/oc.log" || _done=
	done
	for _n in \$NODES; do
		if [ "\$_done" ]; then
			printf '%s||\n' "\$_n"
		else
			printf '%s|true|yes\n' "\$_n"
		fi
	done
	exit 0
fi
if [[ "\$args" == *"get nodes"* && "\$args" == *"metadata.name"* ]]; then
	echo "\$NODES"
	exit 0
fi
if [[ "\$args" == *"get nodes"* ]]; then
	for _n in \$NODES; do echo "\$_n Ready"; done
	exit 0
fi
exit 0
EOF
chmod +x "$WORK/bin/aba" "$WORK/bin/curl" "$WORK/bin/oc"

printf 'ask=false\nverify_conf=off\nplatform=vmw\n' > "$CL/aba.conf"
cat > "$CL/cluster.conf" << 'EOF'
cluster_name=vm1
base_domain=example.com
machine_network=10.0.0.0/20
starting_ip=10.0.0.200
num_masters=3
num_workers=0
master_prefix=master
worker_prefix=worker
next_hop_address=10.0.0.1
api_vip=10.0.0.10
ingress_vip=10.0.0.11
EOF
printf 'platform=vmw\n' > "$CL/state.sh"
printf 'clusters:\n- cluster:\n    server: https://api.vm1.example.com:6443\n' > "$CL/iso-agent-based/auth/kubeconfig"

# _startup <nodes>: sets out, rc. NODES is the API node list for this topology.
_startup() {
	rm -f "$WORK/aba.log" "$WORK/oc.log"
	export NODES="$1" INFO_ABA=1 PATH="$WORK/bin:$PATH"
	out=$(cd "$CL" && timeout 90 bash scripts/cluster-startup.sh 2>&1) && rc=0 || rc=$?
}

echo
echo "=== vmw startup uncordon (test-vm-startup.sh) ==="
echo

_check() {
	local label="$1" nodes="$2" n
	_startup "$nodes"
	ok=1
	echo "$out" | grep -q "All nodes are ready" || ok=
	echo "$out" | grep -q "Cluster startup completed successfully" || ok=
	grep -q '^start$' "$WORK/aba.log" || ok=
	for n in $nodes; do
		grep -q "adm uncordon $n" "$WORK/oc.log" || ok=
	done
	[ "$rc" -eq 0 ] || ok=
	if [ "$ok" ]; then
		_pass "$label"
	else
		_fail "$label: rc=$rc aba=$(cat "$WORK/aba.log" 2>/dev/null) out: $(echo "$out" | tail -12)"
	fi
}

_check "sno: aba start, then uncordon the one node" "master1"
_check "compact: aba start, then uncordon every master" "master1 master2 master3"
_check "standard: aba start, then uncordon masters and workers" "master1 master2 master3 worker1 worker2"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
