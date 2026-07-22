#!/bin/bash
# Functional test: VIP collision detection in verify-config.sh
#
# Tests that ABA correctly detects and rejects invalid VIP configurations
# for multi-node clusters (standard/compact), including:
#   - api_vip == ingress_vip
#   - VIP inside node IP range
#   - Subnet-wrapping edge cases
#   - SNO bypass (VIP checks should not apply)
#   - Valid configurations (should pass VIP checks)
#
# Prerequisites: aba installed, aba.conf configured with a valid domain.
# Does NOT require a mirror, DNS, or vCenter — uses verify_conf=conf.

set -euo pipefail

ABA_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ABA_ROOT"
source scripts/include_all.sh

_pass=0
_fail=0
_total=0
_test_dirs=()

_cleanup() {
	for d in "${_test_dirs[@]}"; do
		[ -d "$d" ] && rm -rf "$d"
	done
}
trap _cleanup EXIT

# Save and restore verify_conf setting
# Extract just the value, stripping trailing tabs/spaces and comments
_orig_verify_conf=$(grep '^verify_conf=' aba.conf 2>/dev/null | head -1 \
	| sed 's/^verify_conf=//; s/[[:space:]].*//; s/#.*//')

_restore_verify_conf() {
	if [ -n "${_orig_verify_conf:-}" ]; then
		replace-value-conf -n verify_conf -v "$_orig_verify_conf" -f aba.conf
	else
		replace-value-conf -n verify_conf -v "all" -f aba.conf
	fi
}
trap '_restore_verify_conf; _cleanup' EXIT

# Skip DNS checks — we only want to test VIP validation logic
replace-value-conf -n verify_conf -v conf -f aba.conf

# Helper: create a cluster dir with proper ABA structure, inject VIP config,
# then run verify-config.sh.  Checks the output for expected error messages.
_test_vip() {
	local test_name="$1"
	local starting_ip="$2"
	local api_vip="$3"
	local ingress_vip="$4"
	local num_masters="${5:-3}"
	local num_workers="${6:-2}"
	local expect_fail="${7:-1}"  # 1=expect abort, 0=expect pass
	local expect_msg="${8:-}"

	_total=$(( _total + 1 ))

	local cname="viptest$_total"
	local cdir="$ABA_ROOT/$cname"

	# Clean up any previous run
	[ -d "$cdir" ] && rm -rf "$cdir"
	_test_dirs+=("$cdir")

	# Create a proper cluster dir via make init (sets up symlinks)
	mkdir -p "$cdir"
	cd "$cdir"
	ln -fs ../templates/Makefile.cluster Makefile
	make -s init 2>/dev/null || true

	# Write cluster.conf with the test values
	source <(normalize-aba-conf)
	cat > cluster.conf <<-EOF
	cluster_name=$cname
	base_domain=${domain:-example.com}
	api_vip=$api_vip
	ingress_vip=$ingress_vip
	starting_ip=$starting_ip
	num_masters=$num_masters
	num_workers=$num_workers
	machine_network=${machine_network:-10.0.0.0}
	prefix_length=${prefix_length:-20}
	next_hop_address=${next_hop_address:-10.0.0.1}
	dns_servers=${dns_servers:-10.0.1.8}
	hostPrefix=23
	mac_prefix=00:50:56:2x:xx:
	master_prefix=master
	worker_prefix=worker
	ssh_key_file=~/.ssh/id_rsa
	mirror_name=mirror
	ports=ens160
	master_cpu_count=10
	master_mem=20
	worker_cpu_count=5
	worker_mem=10
	data_disk=500
	EOF

	# Ensure mirror.conf exists (verify-config sources it)
	[ -f mirror.conf ] || touch mirror.conf

	local output="" rc=0
	output=$(scripts/verify-config.sh 2>&1) || rc=$?

	cd "$ABA_ROOT"

	if [ "$expect_fail" = "1" ]; then
		if [ "$rc" -ne 0 ]; then
			if [ -n "$expect_msg" ] && ! echo "$output" | grep -qF "$expect_msg"; then
				echo "FAIL: $test_name — aborted but wrong message"
				echo "  Expected: $expect_msg"
				echo "  Got: $(echo "$output" | tail -5)"
				_fail=$(( _fail + 1 ))
			else
				echo "PASS: $test_name"
				_pass=$(( _pass + 1 ))
			fi
		else
			echo "FAIL: $test_name — expected abort but verify-config passed!"
			_fail=$(( _fail + 1 ))
		fi
	else
		if [ "$rc" -eq 0 ]; then
			echo "PASS: $test_name"
			_pass=$(( _pass + 1 ))
		else
			# Check if it failed on VIP collision (our code) vs DNS/other (acceptable)
			if echo "$output" | grep -qE 'must be different|falls within the node IP range'; then
				echo "FAIL: $test_name — VIP check wrongly rejected valid config!"
				echo "  Output: $(echo "$output" | tail -5)"
				_fail=$(( _fail + 1 ))
			else
				# Failed on DNS/mirror/other — VIP checks passed, which is what we test
				echo "PASS: $test_name (VIP checks OK; failed later — expected)"
				_pass=$(( _pass + 1 ))
			fi
		fi
	fi
}

echo "=== VIP Collision Detection Tests ==="
echo ""

# -----------------------------------------------------------------------
# Tests that SHOULD fail (bad VIP configs)
# -----------------------------------------------------------------------

_test_vip "api_vip == ingress_vip" \
	10.0.2.100  10.0.2.90  10.0.2.90  3 2  1  "must be different"

_test_vip "api_vip == starting_ip (first node)" \
	10.0.2.100  10.0.2.100  10.0.2.91  3 2  1  "falls within the node IP range"

_test_vip "api_vip inside node range (middle)" \
	10.0.2.100  10.0.2.102  10.0.2.91  3 2  1  "falls within the node IP range"

_test_vip "api_vip == last node IP (3m+2w=5, last=.104)" \
	10.0.2.100  10.0.2.104  10.0.2.91  3 2  1  "falls within the node IP range"

_test_vip "ingress_vip inside node range" \
	10.0.2.100  10.0.2.90  10.0.2.101  3 2  1  "falls within the node IP range"

_test_vip "both VIPs inside node range" \
	10.0.2.100  10.0.2.101  10.0.2.102  3 2  1  "falls within the node IP range"

# Edge case: IP range wraps across /24 boundary
# starting_ip=10.0.0.253, 5 nodes → range 10.0.0.253 to 10.0.1.1
_test_vip "VIP in wrapped range (253+5, VIP=10.0.1.1)" \
	10.0.0.253  10.0.1.1  10.0.0.240  3 2  1  "falls within the node IP range"

# Compact cluster (3 masters, 0 workers)
_test_vip "compact: api_vip == ingress_vip" \
	10.0.2.100  10.0.2.90  10.0.2.90  3 0  1  "must be different"

_test_vip "compact: api_vip in node range (3m, last=.102)" \
	10.0.2.100  10.0.2.101  10.0.2.91  3 0  1  "falls within the node IP range"

# -----------------------------------------------------------------------
# Tests that SHOULD pass (valid VIP configs)
# -----------------------------------------------------------------------

_test_vip "VIPs before node range" \
	10.0.2.100  10.0.2.90  10.0.2.91  3 2  0

_test_vip "VIPs after node range (3m+2w=5, first free=.105)" \
	10.0.2.100  10.0.2.110  10.0.2.111  3 2  0

_test_vip "VIPs just outside range (one below, one above)" \
	10.0.2.100  10.0.2.99  10.0.2.105  3 2  0

_test_vip "SNO: api_vip == ingress_vip is fine" \
	10.0.2.100  10.0.2.100  10.0.2.100  1 0  0

_test_vip "SNO: VIP == starting_ip is fine" \
	10.0.2.100  10.0.2.100  10.0.2.100  1 0  0

# Wrap edge case: valid VIP outside wrapped range
# starting_ip=10.0.0.253, 5 nodes → range ends at 10.0.1.1, VIP=10.0.1.3 is safe
_test_vip "VIP outside wrapped range (253+5, VIP=10.0.1.3)" \
	10.0.0.253  10.0.1.3  10.0.0.240  3 2  0

# -----------------------------------------------------------------------
# Auto-allocation tests
# -----------------------------------------------------------------------
# These test verify-config.sh's VIP auto-allocation when:
#   - VIPs are empty in cluster.conf
#   - ABA manages DNS (dnsmasq marker exists) or not
#   - starting_ip is at various positions in the subnet

echo ""
echo "=== VIP Auto-Allocation Tests ==="
echo ""

# Helper: run verify-config with empty VIPs, optionally with ABA dnsmasq marker.
# Checks whether VIPs were auto-allocated and written to cluster.conf.
_test_auto_alloc() {
	local test_name="$1"
	local starting_ip="$2"
	local num_masters="${3:-3}"
	local num_workers="${4:-2}"
	local machine_net="${5:-10.0.0.0}"
	local prefix_len="${6:-20}"
	local aba_dns="${7:-1}"          # 1=simulate ABA-managed DNS, 0=external
	local expect_fail="${8:-0}"      # 1=expect abort, 0=expect auto-alloc
	local expect_api="${9:-}"        # expected api_vip (empty = just check non-empty)
	local expect_ing="${10:-}"       # expected ingress_vip

	_total=$(( _total + 1 ))

	local cname="autotest$_total"
	local cdir="$ABA_ROOT/$cname"

	[ -d "$cdir" ] && rm -rf "$cdir"
	_test_dirs+=("$cdir")

	mkdir -p "$cdir"
	cd "$cdir"
	ln -fs ../templates/Makefile.cluster Makefile
	make -s init 2>/dev/null || true

	source <(normalize-aba-conf)
	cat > cluster.conf <<-EOF
	cluster_name=$cname
	base_domain=${domain:-example.com}
	api_vip=
	ingress_vip=
	starting_ip=$starting_ip
	num_masters=$num_masters
	num_workers=$num_workers
	machine_network=$machine_net
	prefix_length=$prefix_len
	next_hop_address=${next_hop_address:-10.0.0.1}
	dns_servers=${dns_servers:-10.0.1.8}
	hostPrefix=23
	mac_prefix=00:50:56:2x:xx:
	master_prefix=master
	worker_prefix=worker
	ssh_key_file=~/.ssh/id_rsa
	mirror_name=mirror
	ports=ens160
	master_cpu_count=10
	master_mem=20
	worker_cpu_count=5
	worker_mem=10
	data_disk=500
	EOF

	[ -f mirror.conf ] || touch mirror.conf

	# Simulate ABA-managed DNS marker if requested
	if [ "$aba_dns" = "1" ]; then
		sudo mkdir -p /etc/dnsmasq.d
		sudo touch /etc/dnsmasq.d/aba-upstream.conf
	else
		sudo rm -f /etc/dnsmasq.d/aba-upstream.conf
	fi

	local output="" rc=0
	output=$(scripts/verify-config.sh 2>&1) || rc=$?

	cd "$ABA_ROOT"

	if [ "$expect_fail" = "1" ]; then
		if [ "$rc" -ne 0 ]; then
			echo "PASS: $test_name (correctly aborted)"
			_pass=$(( _pass + 1 ))
		else
			echo "FAIL: $test_name — expected abort but passed!"
			_fail=$(( _fail + 1 ))
		fi
	else
		if [ "$rc" -ne 0 ]; then
			# Check if it failed on auto-allocation vs other
			if echo "$output" | grep -qE 'Cannot auto-allocate|Missing DNS record'; then
				echo "FAIL: $test_name — auto-allocation failed: $(echo "$output" | grep -E 'Cannot|Missing' | head -1)"
				_fail=$(( _fail + 1 ))
			else
				echo "PASS: $test_name (auto-alloc OK; failed later — expected)"
				_pass=$(( _pass + 1 ))
			fi
		else
			echo "PASS: $test_name"
			_pass=$(( _pass + 1 ))
		fi

		# Verify the allocated VIPs if expected values given
		if [ -n "$expect_api" ] && [ -f "$cdir/cluster.conf" ]; then
			local got_api got_ing
			got_api=$(grep '^api_vip=' "$cdir/cluster.conf" | head -1 | sed 's/api_vip=//; s/[[:space:]].*//')
			got_ing=$(grep '^ingress_vip=' "$cdir/cluster.conf" | head -1 | sed 's/ingress_vip=//; s/[[:space:]].*//')
			if [ "$got_api" != "$expect_api" ] || [ "$got_ing" != "$expect_ing" ]; then
				echo "  FAIL: expected api=$expect_api ing=$expect_ing, got api=$got_api ing=$got_ing"
				_fail=$(( _fail + 1 ))
				_pass=$(( _pass - 1 ))
			fi
		fi
	fi
}

# --- Auto-alloc "before" (normal case) ---
# starting_ip=10.0.2.100, 5 nodes → api=10.0.2.98, ing=10.0.2.99
_test_auto_alloc "auto-alloc: before starting_ip (normal)" \
	10.0.2.100  3 2  10.0.0.0 20  1  0  10.0.2.98  10.0.2.99

# --- Auto-alloc "before" near bottom but still in subnet ---
# starting_ip=10.0.0.5, 5 nodes → api=10.0.0.3, ing=10.0.0.4 (still in 10.0.0.0/20)
_test_auto_alloc "auto-alloc: before, near bottom of subnet" \
	10.0.0.5  3 2  10.0.0.0 20  1  0  10.0.0.3  10.0.0.4

# --- Auto-alloc "after" fallback (starting_ip at very bottom) ---
# starting_ip=10.0.0.1, 5 nodes → before=9.255.255.255 (out of subnet!)
# fallback: after last node +10 = 10.0.0.1+5+10=10.0.0.16, ing=10.0.0.17
_test_auto_alloc "auto-alloc: fallback to after (starting_ip near bottom)" \
	10.0.0.1  3 2  10.0.0.0 20  1  0  10.0.0.16  10.0.0.17

# --- Auto-alloc "after" fallback (starting_ip=x.x.x.2) ---
# starting_ip=10.0.0.2 → before: api=10.0.0.0 (network addr, <= net_int) → fallback
# after: 10.0.0.2+5+10=10.0.0.17, ing=10.0.0.18
_test_auto_alloc "auto-alloc: fallback to after (starting_ip=.2)" \
	10.0.0.2  3 2  10.0.0.0 20  1  0  10.0.0.17  10.0.0.18

# --- No ABA-managed DNS → should abort ---
_test_auto_alloc "auto-alloc: abort when external DNS (no dnsmasq marker)" \
	10.0.2.100  3 2  10.0.0.0 20  0  1

# --- SNO with empty VIPs should NOT auto-allocate (SNO doesn't need VIPs) ---
# Use _test_vip for this since SNO skips VIP checks entirely
# (already covered by existing tests above)

# Restore dnsmasq marker if it existed before (bastion normally has it)
sudo touch /etc/dnsmasq.d/aba-upstream.conf 2>/dev/null || true

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
echo ""
echo "=== Results: $_pass passed, $_fail failed (of $_total) ==="
echo ""

[ "$_fail" -gt 0 ] && exit 1
exit 0
