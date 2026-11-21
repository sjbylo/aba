#!/bin/bash
# The access card. Recorded clusterstate/state.sh wins over cluster.conf counts.
# Password, kubeconfig, and /etc/hosts lines are always shown. aba info does
# not list itself. The install caller adds the success line.

set -eo pipefail

cd "$(dirname "$0")/../.."
source scripts/include_all.sh 2>/dev/null

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf '  PASS  %s\n' "$*"; }
_fail() { fail=$(( fail + 1 )); printf '  FAIL  %s\n' "$*"; }

has_line() {
	printf '%s\n' "$1" | grep -F -qx -- "$2"
}

_tmp=$(mktemp -d)
_home=$(mktemp -d)
mkdir -p "$_tmp/clusterstate" "$_tmp/iso-agent-based/auth"
printf 'apiVersion: v1\n' > "$_tmp/iso-agent-based/auth/kubeconfig"
printf '%s' 'card-secret' > "$_tmp/iso-agent-based/auth/kubeadmin-password"
cat > "$_tmp/clusterstate/state.sh" <<'EOF'
cluster_name=virt
base_domain=example.com
cluster_type=compact
platform=vmw
starting_ip=10.0.0.200
cp_names=""
worker_names=""
EOF

out=$(
	cd "$_tmp" || exit 1
	HOME=$_home ABA_TARGET_DIR= ABA_TRACE_FILE= \
		INFO_ABA=1 ocp_version=5.0.1 \
		cluster_name=wrong base_domain=wrong.example \
		num_masters=1 num_workers=0 platform=bm \
		api_vip=10.0.0.198 ingress_vip=10.0.0.199 starting_ip=10.9.9.9 \
		show_cluster_card
)

if has_line "$out" "[ABA] virt.example.com    5.0.1    VMware    compact, 3 masters" \
	&& has_line "$out" "[ABA] Console     https://console-openshift-console.apps.virt.example.com" \
	&& has_line "$out" "[ABA] User        kubeadmin" \
	&& has_line "$out" "[ABA] Password    card-secret" \
	&& has_line "$out" "[ABA] API         https://api.virt.example.com:6443" \
	&& has_line "$out" "[ABA] Kubeconfig  $_tmp/iso-agent-based/auth/kubeconfig" \
	&& has_line "$out" "[ABA] Optionally, set these values in /etc/hosts to access the cluster." \
	&& has_line "$out" "10.0.0.198 api.virt.example.com" \
	&& has_line "$out" "10.0.0.199 console-openshift-console.apps.virt.example.com" \
	&& has_line "$out" "10.0.0.199 oauth-openshift.apps.virt.example.com" \
	&& has_line "$out" "[ABA] Terminal    aba terminal" \
	&& has_line "$out" "[ABA] Shell       . <(aba shell)" \
	&& has_line "$out" "[ABA] Login       . <(aba login)" \
	&& has_line "$out" "[ABA] Later       aba day2, aba day2-osus, aba day2-ntp" \
	&& has_line "$out" "[ABA] Help        README.md, Day-2 Operations" \
	&& ! printf '%s\n' "$out" | grep -q 'sno' \
	&& ! printf '%s\n' "$out" | grep -q '10.0.0.200' \
	&& ! printf '%s\n' "$out" | grep -q 'aba info' \
	&& ! printf '%s\n' "$out" | grep -q 'installed successfully'; then
	_pass "state type wins and the card shows every access line"
else
	_fail "state type wins and the card shows every access line: $out"
fi

cat > "$_tmp/clusterstate/state.sh" <<'EOF'
cluster_name=hub
base_domain=example.com
cluster_type=sno
platform=vmw
starting_ip=10.0.0.100
EOF

out=$(
	cd "$_tmp" || exit 1
	HOME=$_home ABA_TARGET_DIR= \
		INFO_ABA=1 ocp_version=5.0.1 \
		cluster_name=hub base_domain=example.com \
		num_masters=3 num_workers=0 platform=bm \
		api_vip= ingress_vip= starting_ip=10.9.9.9 \
		show_cluster_card
)

if has_line "$out" "[ABA] hub.example.com    5.0.1    VMware    sno, 1 master" \
	&& has_line "$out" "10.0.0.100 api.hub.example.com" \
	&& has_line "$out" "10.0.0.100 console-openshift-console.apps.hub.example.com" \
	&& has_line "$out" "10.0.0.100 oauth-openshift.apps.hub.example.com" \
	&& ! printf '%s\n' "$out" | grep -q '10.9.9.9' \
	&& ! printf '%s\n' "$out" | grep -q '3 masters'; then
	_pass "SNO state uses the recorded node address"
else
	_fail "SNO state uses the recorded node address: $out"
fi

out=$(
	cd "$_tmp" || exit 1
	HOME=$_home ABA_TARGET_DIR= installed_from= \
		INFO_ABA=1 ocp_version=5.0.1 \
		cluster_name=hub base_domain=example.com \
		num_masters=1 num_workers=0 \
		api_vip= ingress_vip= starting_ip=10.0.0.100 \
		show_cluster_summary
)
if printf '%s\n' "$out" | grep -F -qx '[ABA] Cluster installed successfully!' \
	&& printf '%s\n' "$out" | grep -F -q 'sno, 1 master'; then
	_pass "install adds the success line above the same card"
else
	_fail "install adds the success line above the same card: $out"
fi

rm -rf "$_tmp" "$_home"

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
