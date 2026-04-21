#!/bin/bash
# MTU state audit for all lab components
# Usage: bash ai/check-mtu-state.sh          # report current state
#        bash ai/check-mtu-state.sh 9000      # verify all at MTU 9000

SSH="ssh -F $HOME/.aba/ssh.conf"
HOSTS="esxi1.lan esxi2.lan esxi3.lan esxi4.lan"
NAS_IP="10.0.1.8"
EXPECTED_MTU="${1:-0}"

RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[0;33m'
RST='\033[0m'

errors=0

report() {
	local component="$1" current="$2" expected="$3"
	if [ "$EXPECTED_MTU" -gt 0 ] 2>/dev/null; then
		if [ "$current" = "$expected" ]; then
			printf "${GRN}[OK]${RST}  %-45s MTU=%s\n" "$component" "$current"
		else
			printf "${RED}[FAIL]${RST} %-45s MTU=%s (expected %s)\n" "$component" "$current" "$expected"
			errors=$(( errors + 1 ))
		fi
	else
		printf "%-50s MTU=%s\n" "$component" "$current"
	fi
}

echo "========================================"
echo "  MTU State Audit - $(date +%Y-%m-%d\ %H:%M)"
[ "$EXPECTED_MTU" -gt 0 ] && echo "  Expected MTU: $EXPECTED_MTU"
echo "========================================"
echo ""

# --- ESXi Hosts ---
echo "--- ESXi Hosts ---"
for h in $HOSTS; do
	short="${h%.lan}"

	# vSwitch MTU
	while IFS='|' read -r vs mtu; do
		vs=$(echo "$vs" | xargs)
		mtu=$(echo "$mtu" | xargs)
		report "$short / $vs" "$mtu" "$EXPECTED_MTU"
	done < <($SSH root@$h "esxcli network vswitch standard list" 2>/dev/null | \
		awk '/^[^ ]/{vs=$1} /MTU:/{print vs"|"$2}')

	# VMkernel MTU -- name appears on its own line, fields indented below
	while IFS='|' read -r vmk mtu; do
		vmk=$(echo "$vmk" | xargs)
		mtu=$(echo "$mtu" | xargs)
		report "$short / $vmk (VMkernel)" "$mtu" "$EXPECTED_MTU"
	done < <($SSH root@$h "esxcli network ip interface list" 2>/dev/null | \
		awk '/^[^ ]/{vmk=$1} /^   MTU:/{print vmk"|"$2}')

	# Physical NIC MTU -- MAC is followed by MTU in fixed-width columns
	while IFS='|' read -r nic mtu; do
		nic=$(echo "$nic" | xargs)
		mtu=$(echo "$mtu" | xargs)
		report "$short / $nic (physical NIC)" "$mtu" "$EXPECTED_MTU"
	done < <($SSH root@$h "esxcli network nic list" 2>/dev/null | \
		awk 'NR>2 && NF>0 { for(i=1;i<=NF;i++) if($i ~ /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/) {print $1"|"$(i+1); break} }')

	echo ""
done

# --- NAS ---
echo "--- NAS ($NAS_IP) ---"
if ping -c1 -W1 "$NAS_IP" >/dev/null 2>&1; then
	printf "  NAS is ${GRN}reachable${RST} (ping OK)\n"
else
	printf "  NAS is ${RED}unreachable${RST} (ping failed)\n"
fi
echo "  (SSH disabled -- check MTU manually via DSM Web UI)"
echo "  DSM > Control Panel > Network > Network Interface > Edit"
echo ""

# --- Jumbo Frame Ping Test ---
echo "--- Jumbo Frame Ping Test (vmkping -s 8972 -d) ---"
if [ "$EXPECTED_MTU" = "9000" ]; then
	for h in $HOSTS; do
		short="${h%.lan}"

		# Test ESXi → NAS
		result=$($SSH root@$h "vmkping -s 8972 -d -c 1 $NAS_IP 2>&1" | tail -1)
		if echo "$result" | grep -q "1 packets received"; then
			printf "${GRN}[OK]${RST}  %-45s → NAS jumbo ping OK\n" "$short"
		else
			printf "${RED}[FAIL]${RST} %-45s → NAS jumbo ping FAILED\n" "$short"
			errors=$(( errors + 1 ))
		fi

		# Test ESXi → other ESXi hosts (vMotion path)
		for h2 in $HOSTS; do
			[ "$h" = "$h2" ] && continue
			short2="${h2%.lan}"
			h2_ip=$($SSH root@$h2 "esxcli network ip interface ipv4 get -i vmk0 2>/dev/null" | awk 'NR==2{print $2}')
			if [ -n "$h2_ip" ]; then
				result=$($SSH root@$h "vmkping -s 8972 -d -c 1 $h2_ip 2>&1" | tail -1)
				if echo "$result" | grep -q "1 packets received"; then
					printf "${GRN}[OK]${RST}  %-45s → %s jumbo ping OK\n" "$short" "$short2"
				else
					printf "${RED}[FAIL]${RST} %-45s → %s jumbo ping FAILED\n" "$short" "$short2"
					errors=$(( errors + 1 ))
				fi
			fi
		done
	done
else
	echo "(Skipped -- pass '9000' as argument to enable: bash $0 9000)"
fi

echo ""
echo "========================================"
if [ "$EXPECTED_MTU" -gt 0 ] && [ "$errors" -gt 0 ]; then
	printf "${RED}$errors component(s) not at MTU $EXPECTED_MTU${RST}\n"
	exit 1
elif [ "$EXPECTED_MTU" -gt 0 ]; then
	printf "${GRN}All components at MTU $EXPECTED_MTU${RST}\n"
fi
echo ""
