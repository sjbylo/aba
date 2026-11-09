#!/bin/bash
# Test: standalone AgentConfig summary
# The shape follows the local example scripts. This checks the product script.

cd "$(dirname "$0")/../.." || exit 1

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }

echo "=== AgentConfig summary ==="

if ! command -v jq >/dev/null 2>&1 || ! python3 -c 'import yaml' >/dev/null 2>&1; then
	echo "SKIPPED: jq and Python yaml are required"
	exit 0
fi

_tmp=$(mktemp -d)
trap 'rm -rf "$_tmp"' EXIT

# Every needle must appear. One failure prints the summary once.
_expect() {
	local title="$1" file="$2" flags="$3"
	shift 3
	local out rc=0 bad="" needle
	if [ -n "$flags" ]; then
		out=$(scripts/agent-config-summary.sh $flags "$file" 2>&1) || rc=$?
	else
		out=$(scripts/agent-config-summary.sh "$file" 2>&1) || rc=$?
	fi
	if [ "$rc" -ne 0 ]; then
		_fail "$title (rc=$rc)"
		printf '%s\n' "$out"
		return
	fi
	for needle in "$@"; do
		if ! printf '%s\n' "$out" | grep -F -qx -- "$needle"; then
			bad="${bad} missing [${needle}]"
		fi
	done
	if [ -z "$bad" ]; then
		_pass "$title"
	else
		_fail "$title:${bad}"
		printf '%s\n' "$out"
	fi
}

cat > "$_tmp/sno.yaml" <<'EOF'
metadata:
  name: ocp
rendezvousIP: 10.0.1.100
additionalNTPSources:
  - 10.0.1.8
hosts:
  - hostname: ocp
    role: master
    interfaces:
      - name: eno1
        macAddress: "00:50:56:07:d9:01"
    networkConfig:
      interfaces:
        - name: eno1
          type: ethernet
          ipv4:
            address:
              - ip: 10.0.1.100
                prefix-length: 20
      dns-resolver:
        config:
          server:
            - 10.0.1.8
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: 10.0.0.1
            next-hop-interface: eno1
EOF

_out=$(scripts/agent-config-summary.sh "$_tmp/sno.yaml" 2>&1) && _rc=0 || _rc=$?
_want='ocp | 1 masters (ocp) | RV: 10.0.1.100 | GW: 10.0.0.1 | DNS/NTP: 10.0.1.8
IP:  10.0.1.x/20: M1=.100
MAC: eno1 00:50:56:07:d9:xx M1=01
NET: eno1 | Bond: - | DHCP: - | VIP: -'
if [ "$_rc" -eq 0 ] && [ "$_out" = "$_want" ]; then
	_pass "SNO compact summary"
else
	_fail "SNO compact summary (rc=$_rc)"
	printf '%s\n' "$_out"
fi

cat > "$_tmp/three.yaml" <<'EOF'
metadata:
  name: ocp
rendezvousIP: 10.0.1.100
additionalNTPSources:
  - 10.0.1.8
hosts:
  - hostname: master1
    role: master
    interfaces:
      - name: eno1
        macAddress: "00:50:56:07:d9:01"
    networkConfig:
      interfaces:
        - name: eno1
          type: ethernet
          ipv4:
            address:
              - ip: 10.0.1.100
                prefix-length: 20
      dns-resolver:
        config:
          server:
            - 10.0.1.8
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: 10.0.0.1
  - hostname: master2
    role: master
    interfaces:
      - name: eno1
        macAddress: "00:50:56:07:d9:02"
    networkConfig:
      interfaces:
        - name: eno1
          type: ethernet
          ipv4:
            address:
              - ip: 10.0.1.101
                prefix-length: 20
      dns-resolver:
        config:
          server:
            - 10.0.1.8
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: 10.0.0.1
  - hostname: master3
    role: master
    interfaces:
      - name: eno1
        macAddress: "00:50:56:07:d9:03"
    networkConfig:
      interfaces:
        - name: eno1
          type: ethernet
          ipv4:
            address:
              - ip: 10.0.1.102
                prefix-length: 20
      dns-resolver:
        config:
          server:
            - 10.0.1.8
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: 10.0.0.1
EOF

_out=$(scripts/agent-config-summary.sh "$_tmp/three.yaml")
if printf '%s\n' "$_out" | grep -qx 'ocp | 3 masters (master1-3) | RV: 10.0.1.100 | GW: 10.0.0.1 | DNS/NTP: 10.0.1.8' \
	&& printf '%s\n' "$_out" | grep -qx 'IP:  10.0.1.x/20: M1-3 .100-102' \
	&& printf '%s\n' "$_out" | grep -qx 'MAC: eno1 00:50:56:07:d9:xx M1-3 1-3'; then
	_pass "three masters compress names, IPs, and MACs"
else
	_fail "three-master compression"
	printf '%s\n' "$_out"
fi

_out=$(scripts/agent-config-summary.sh "$_tmp/missing.yaml" 2>&1) && _rc=0 || _rc=$?
if [ "$_rc" -ne 0 ] && printf '%s\n' "$_out" | grep -q 'not found'; then
	_pass "missing file is an error"
else
	_fail "missing file should fail (rc=$_rc)"
fi

# Masters and workers share one subnet, so both ranges compress.
cat > "$_tmp/mw.yaml" <<'EOF'
metadata:
  name: edge
rendezvousIP: 10.0.1.100
additionalNTPSources:
  - 10.0.1.8
hosts:
  - hostname: master1
    role: master
    interfaces:
      - name: eno1
        macAddress: "00:50:56:07:d9:01"
    networkConfig:
      interfaces:
        - name: eno1
          type: ethernet
          ipv4:
            address:
              - ip: 10.0.1.100
                prefix-length: 20
      dns-resolver:
        config:
          server:
            - 10.0.1.8
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: 10.0.0.1
  - hostname: master2
    role: master
    interfaces:
      - name: eno1
        macAddress: "00:50:56:07:d9:02"
    networkConfig:
      interfaces:
        - name: eno1
          type: ethernet
          ipv4:
            address:
              - ip: 10.0.1.101
                prefix-length: 20
      dns-resolver:
        config:
          server:
            - 10.0.1.8
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: 10.0.0.1
  - hostname: master3
    role: master
    interfaces:
      - name: eno1
        macAddress: "00:50:56:07:d9:03"
    networkConfig:
      interfaces:
        - name: eno1
          type: ethernet
          ipv4:
            address:
              - ip: 10.0.1.102
                prefix-length: 20
      dns-resolver:
        config:
          server:
            - 10.0.1.8
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: 10.0.0.1
  - hostname: worker1
    role: worker
    interfaces:
      - name: eno1
        macAddress: "00:50:56:07:d9:04"
    networkConfig:
      interfaces:
        - name: eno1
          type: ethernet
          ipv4:
            address:
              - ip: 10.0.1.103
                prefix-length: 20
      dns-resolver:
        config:
          server:
            - 10.0.1.8
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: 10.0.0.1
  - hostname: worker2
    role: worker
    interfaces:
      - name: eno1
        macAddress: "00:50:56:07:d9:05"
    networkConfig:
      interfaces:
        - name: eno1
          type: ethernet
          ipv4:
            address:
              - ip: 10.0.1.104
                prefix-length: 20
      dns-resolver:
        config:
          server:
            - 10.0.1.8
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: 10.0.0.1
EOF
_expect "masters and workers compress separately" "$_tmp/mw.yaml" "" \
	'edge | 3 masters (master1-3), 2 workers (worker1-2) | RV: 10.0.1.100 | GW: 10.0.0.1 | DNS/NTP: 10.0.1.8' \
	'IP:  10.0.1.x/20: M1-3 .100-102; W1-2 .103-104' \
	'MAC: eno1 00:50:56:07:d9:xx M1-3 1-3; W1-2 4-5' \
	'NET: eno1 | Bond: - | DHCP: - | VIP: -'

# master1 then master3 is not a run. Aliases are still M1, M2.
cat > "$_tmp/gap.yaml" <<'EOF'
metadata:
  name: gap
rendezvousIP: 10.2.0.10
hosts:
  - hostname: master1
    role: master
    interfaces:
      - name: eno1
        macAddress: "aa:bb:cc:dd:ee:01"
    networkConfig:
      interfaces:
        - name: eno1
          type: ethernet
          ipv4:
            address:
              - ip: 10.2.0.10
                prefix-length: 20
      dns-resolver:
        config:
          server:
            - 10.0.1.8
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: 10.0.0.1
  - hostname: master3
    role: master
    interfaces:
      - name: eno1
        macAddress: "aa:bb:cc:dd:ee:03"
    networkConfig:
      interfaces:
        - name: eno1
          type: ethernet
          ipv4:
            address:
              - ip: 10.2.0.12
                prefix-length: 20
      dns-resolver:
        config:
          server:
            - 10.0.1.8
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: 10.0.0.1
EOF
_expect "gapped names and MACs stay listed" "$_tmp/gap.yaml" "" \
	'gap | 2 masters (master1, master3) | RV: 10.2.0.10 | GW: 10.0.0.1 | DNS: 10.0.1.8 | NTP: -' \
	'IP:  10.2.0.x/20: M1=.10; M2=.12' \
	'MAC: eno1 aa:bb:cc:dd:ee:xx M1=01; M2=03'

cat > "$_tmp/dns.yaml" <<'EOF'
metadata:
  name: dns
rendezvousIP: 10.0.1.10
additionalNTPSources:
  - 10.9.9.1
  - 10.9.9.2
hosts:
  - hostname: master1
    role: master
    interfaces:
      - name: eno1
        macAddress: "00:11:22:33:44:01"
    networkConfig:
      interfaces:
        - name: eno1
          type: ethernet
          ipv4:
            address:
              - ip: 10.0.1.10
                prefix-length: 24
      dns-resolver:
        config:
          server:
            - 10.1.1.1
            - 10.1.1.2
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: 10.0.0.1
EOF
_expect "DNS and NTP stay apart when they differ" "$_tmp/dns.yaml" "" \
	'dns | 1 masters (master1) | RV: 10.0.1.10 | GW: 10.0.0.1 | DNS: M1=10.1.1.1; M1=10.1.1.2 | NTP: 10.9.9.1, 10.9.9.2'

cat > "$_tmp/gw.yaml" <<'EOF'
metadata:
  name: gw
rendezvousIP: 10.0.1.10
hosts:
  - hostname: master1
    role: master
    interfaces:
      - name: ens1
        macAddress: "00:11:22:33:44:11"
    networkConfig:
      interfaces:
        - name: ens1
          type: ethernet
          ipv4:
            address:
              - ip: 10.0.1.10
                prefix-length: 24
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: 10.0.0.1
  - hostname: worker1
    role: worker
    interfaces:
      - name: ens1
        macAddress: "00:11:22:33:44:12"
    networkConfig:
      interfaces:
        - name: ens1
          type: ethernet
          ipv4:
            address:
              - ip: 10.8.0.20
                prefix-length: 24
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: 10.8.0.1
EOF
_expect "mixed gateways and subnets stay per node" "$_tmp/gw.yaml" "" \
	'gw | 1 masters (master1), 1 workers (worker1) | RV: 10.0.1.10 | GW: M1=10.0.0.1; W1=10.8.0.1 | DNS/NTP: -' \
	'IP:  10.0.1.x/24: M1=.10 | 10.8.0.x/24: W1=.20' \
	'MAC: ens1 00:11:22:33:44:xx M1=11; W1=12'

cat > "$_tmp/bond.yaml" <<'EOF'
metadata:
  name: bond
rendezvousIP: 10.1.0.10
additionalNTPSources:
  - 10.1.0.8
apiVIPs:
  - 10.1.0.2
ingressVIPs:
  - 10.1.0.3
cpuArchitecture: x86_64
hosts:
  - hostname: master1
    role: master
    interfaces:
      - name: eno1
        macAddress: "xx:xx:xx:xx:xx:xx"
      - name: eno2
        macAddress: "00:50:56:BE:00:02"
    rootDeviceHints:
      deviceName: /dev/sda
    networkConfig:
      interfaces:
        - name: bond0.100
          type: vlan
          vlan:
            base-iface: bond0
            id: 100
          ipv4:
            enabled: true
            dhcp: true
            address:
              - ip: 10.1.0.10
                prefix-length: 24
        - name: bond0
          type: bond
          link-aggregation:
            mode: active-backup
            port:
              - eno1
              - eno2
      dns-resolver:
        config:
          server:
            - 10.1.0.8
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: 10.0.0.1
            next-hop-interface: bond0.100
  - hostname: worker1
    role: worker
    interfaces:
      - name: eno1
        macAddress: "00:50:56:BE:00:11"
      - name: eno2
        macAddress: "00:50:56:BE:00:12"
    networkConfig:
      interfaces:
        - name: bond0.100
          type: vlan
          ipv4:
            address:
              - ip: 10.1.0.11
                prefix-length: 24
        - name: bond0
          type: bond
          link-aggregation:
            mode: 802.3ad
            port:
              - eno1
              - eno2
      dns-resolver:
        config:
          server:
            - 10.1.0.8
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: 10.0.0.1
EOF
_expect "bond, VLAN, DHCP, VIPs, and a placeholder MAC" "$_tmp/bond.yaml" "" \
	'bond | 1 masters (master1), 1 workers (worker1) | RV: 10.1.0.10 | GW: 10.0.0.1 | DNS/NTP: 10.1.0.8' \
	'IP:  10.1.0.x/24: M1=.10; W1=.11' \
	'MAC: eno2 00:50:56:be:00:xx M1=02; W1=12 | eno1 00:50:56:be:00:xx W1=11 | M1:eno1=xx:xx:xx:xx:xx:xx' \
	'NET: bond0.100, bond0 | Bond: bond0(active-backup):eno1,eno2, bond0(802.3ad):eno1,eno2 | DHCP: M1:bond0.100:v4 | VIP: api=["10.1.0.2"], ingress=["10.1.0.3"]'
_expect "short summary adds CPU and the disk hint" "$_tmp/bond.yaml" -s \
	'CPU: x86_64 | Disks: M1={"deviceName":"/dev/sda"}' \
	'NIC: bond0.100, bond0 | Bond: bond0(active-backup):eno1,eno2, bond0(802.3ad):eno1,eno2 | DHCP: M1:bond0.100:v4 | VIP: api=["10.1.0.2"], ingress=["10.1.0.3"]'
_expect "verbose summary is per node" "$_tmp/bond.yaml" -v \
	'master1 [master] (M1)' \
	'  MAC:         eno1=xx:xx:xx:xx:xx:xx, eno2=00:50:56:BE:00:02' \
	'  DHCP:        bond0.100:v4' \
	'  Bonds:       bond0(active-backup):eno1,eno2' \
	'  Root disk:   {"deviceName":"/dev/sda"}' \
	'worker1 [worker] (W1)' \
	'  Bonds:       bond0(802.3ad):eno1,eno2' \
	'  Gateway:     10.0.0.1'

cat > "$_tmp/v6.yaml" <<'EOF'
metadata:
  name: v6
rendezvousIP: fd00::10
hosts:
  - hostname: master1
    role: master
    interfaces:
      - name: eth0
        macAddress: "52:54:00:aa:bb:01"
    networkConfig:
      interfaces:
        - name: eth0
          type: ethernet
          ipv6:
            enabled: true
            dhcp: false
            address:
              - ip: fd00::10
                prefix-length: 64
      routes:
        config:
          - destination: "::/0"
            next-hop-address: fd00::1
EOF
_expect "IPv6 address and gateway" "$_tmp/v6.yaml" "" \
	'v6 | 1 masters (master1) | RV: fd00::10 | GW: fd00::1 | DNS/NTP: -' \
	'IP:  M1=fd00::10/64' \
	'MAC: eth0 52:54:00:aa:bb:xx M1=01'

cat > "$_tmp/bare.yaml" <<'EOF'
metadata:
  name: bare
hosts:
  - hostname: node-a
    role: master
    networkConfig:
      interfaces:
        - name: eth0
          type: ethernet
          ipv4:
            address:
              - ip: 192.168.1.5
                prefix-length: 24
EOF
_expect "missing rendezvous, NTP, and MAC" "$_tmp/bare.yaml" "" \
	'bare | 1 masters (node-a) | RV: - | GW: - | DNS/NTP: -' \
	'IP:  192.168.1.x/24: M1=.5' \
	'MAC: -' \
	'NET: eth0 | Bond: - | DHCP: - | VIP: -'

cat > "$_tmp/up.yaml" <<'EOF'
metadata:
  name: up
rendezvousIP: 10.0.0.5
hosts:
  - hostname: master1
    role: master
    interfaces:
      - name: eno1
        macAddress: "AA:BB:CC:DD:EE:0A"
    networkConfig:
      interfaces:
        - name: eno1
          type: ethernet
          ipv4:
            address:
              - ip: 10.0.0.5
                prefix-length: 8
EOF
_expect "uppercase MAC is folded and /8 is kept" "$_tmp/up.yaml" "" \
	'up | 1 masters (master1) | RV: 10.0.0.5 | GW: - | DNS/NTP: -' \
	'IP:  10.0.0.x/8: M1=.5' \
	'MAC: eno1 aa:bb:cc:dd:ee:xx M1=0a'

cat > "$_tmp/dual.yaml" <<'EOF'
metadata:
  name: dual
rendezvousIP: 10.4.0.1
hosts:
  - hostname: master1
    role: master
    interfaces:
      - name: eno1
        macAddress: "00:11:22:33:44:01"
      - name: eno2
        macAddress: "00:99:88:77:66:01"
    networkConfig:
      interfaces:
        - name: eno1
          type: ethernet
          ipv4:
            address:
              - ip: 10.4.0.1
                prefix-length: 24
        - name: eno2
          type: ethernet
EOF
_expect "two NICs keep both MAC prefixes" "$_tmp/dual.yaml" "" \
	'dual | 1 masters (master1) | RV: 10.4.0.1 | GW: - | DNS/NTP: -' \
	'IP:  10.4.0.x/24: M1=.1' \
	'MAC: eno1 00:11:22:33:44:xx M1=01 | eno2 00:99:88:77:66:xx M1=01' \
	'NET: eno1, eno2 | Bond: - | DHCP: - | VIP: -'

# No path: the default file is ./agent-config.yaml.
cp "$_tmp/sno.yaml" "$_tmp/agent-config.yaml"
(
	cd "$_tmp" || exit 1
	"$OLDPWD/scripts/agent-config-summary.sh"
) > "$_tmp/default.out"
if grep -qx 'ocp | 1 masters (ocp) | RV: 10.0.1.100 | GW: 10.0.0.1 | DNS/NTP: 10.0.1.8' "$_tmp/default.out"; then
	_pass "default file is ./agent-config.yaml"
else
	_fail "default file should be ./agent-config.yaml"
	cat "$_tmp/default.out"
fi

_out=$(scripts/agent-config-summary.sh -h 2>&1) && _rc=0 || _rc=$?
if [ "$_rc" -eq 0 ] && printf '%s\n' "$_out" | grep -q 'Compact summary'; then
	_pass "help exits 0"
else
	_fail "help should exit 0 (rc=$_rc)"
fi

_out=$(scripts/agent-config-summary.sh --nope "$_tmp/sno.yaml" 2>&1) && _rc=0 || _rc=$?
if [ "$_rc" -ne 0 ] && printf '%s\n' "$_out" | grep -q 'Unknown option'; then
	_pass "unknown option is an error"
else
	_fail "unknown option should fail (rc=$_rc)"
fi

echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
