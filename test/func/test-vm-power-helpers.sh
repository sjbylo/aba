#!/bin/bash
# Unit tests for VM power management helpers:
#   _select_vm_hosts(), vmw_running_vms(), kvm_running_vms()
# No real VMs or hypervisors required — uses mock commands.

cd "$(dirname "$0")/../.."
REPO_ROOT="$PWD"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass=0
fail=0
FAILURES=""

test_pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; pass=$(( pass + 1 )); }
test_fail() { echo -e "${RED}✗ FAIL${NC}: $1"; fail=$(( fail + 1 )); FAILURES=1; }

_mock_dir=$(mktemp -d)
trap 'rm -rf "$_mock_dir"' EXIT

# Source include_all in a way that skips the ERR trap (pass a dummy arg)
source scripts/include_all.sh dummy_arg 2>/dev/null

echo
echo "=== Testing: VM Power Management Helpers ==="
echo

# ─────────────────────────────────────────────────────────────────────────────
# _select_vm_hosts()
# ─────────────────────────────────────────────────────────────────────────────
echo "--- _select_vm_hosts() ---"

# Test 1: defaults to all VMs (workers + masters)
(
	CP_NAMES="master0 master1 master2"
	WORKER_NAMES="worker0 worker1"
	workers="" ; masters=""
	_select_vm_hosts
	[ "$hosts" = "worker0 worker1 master0 master1 master2" ]
) && test_pass "_select_vm_hosts: defaults to all VMs" \
  || test_fail "_select_vm_hosts: defaults to all VMs"

# Test 2: workers=1 selects only workers
(
	CP_NAMES="master0 master1 master2"
	WORKER_NAMES="worker0 worker1"
	workers=1 ; masters=""
	_select_vm_hosts
	[ "$hosts" = "worker0 worker1" ]
) && test_pass "_select_vm_hosts: workers=1 selects only workers" \
  || test_fail "_select_vm_hosts: workers=1 selects only workers"

# Test 3: masters=1 selects only masters
(
	CP_NAMES="master0 master1 master2"
	WORKER_NAMES="worker0 worker1"
	workers="" ; masters=1
	_select_vm_hosts
	[ "$hosts" = "master0 master1 master2" ]
) && test_pass "_select_vm_hosts: masters=1 selects only masters" \
  || test_fail "_select_vm_hosts: masters=1 selects only masters"

# Test 4: SNO (no workers) — falls back to CP_NAMES
(
	CP_NAMES="sno1"
	WORKER_NAMES=""
	workers="" ; masters=""
	_select_vm_hosts
	[ "$hosts" = "sno1" ]
) && test_pass "_select_vm_hosts: SNO fallback to CP_NAMES" \
  || test_fail "_select_vm_hosts: SNO fallback to CP_NAMES"

# Test 5: both workers= and masters= set — workers takes priority (elif)
(
	CP_NAMES="master0 master1 master2"
	WORKER_NAMES="worker0 worker1"
	workers=1 ; masters=1
	_select_vm_hosts
	[ "$hosts" = "worker0 worker1" ]
) && test_pass "_select_vm_hosts: both set, workers takes priority" \
  || test_fail "_select_vm_hosts: both set, workers takes priority"

# ─────────────────────────────────────────────────────────────────────────────
# vmw_running_vms() with mock govc
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "--- vmw_running_vms() (mocked govc) ---"

# Create a mock govc that returns controlled JSON
cat > "$_mock_dir/govc" <<'MOCK'
#!/bin/bash
# Mock govc: vm name is the last arg; return poweredOn/poweredOff based on name
vm_name="${@: -1}"
case "$vm_name" in
	*-master0|*-worker0)
		cat <<-JSON
		{"virtualMachines":[{"runtime":{"powerState":"poweredOn"}}]}
		JSON
		;;
	*-master1|*-worker1)
		cat <<-JSON
		{"virtualMachines":[{"runtime":{"powerState":"poweredOff"}}]}
		JSON
		;;
	*)
		cat <<-JSON
		{"virtualMachines":[{"runtime":{"powerState":"poweredOff"}}]}
		JSON
		;;
esac
MOCK
chmod +x "$_mock_dir/govc"

# Test 6: mixed power states — only poweredOn returned
(
	export PATH="$_mock_dir:$PATH"
	CLUSTER_NAME="test1"
	CP_REPLICAS=3 ; WORKER_REPLICAS=2
	num_masters=3 ; num_workers=2
	result=$(vmw_running_vms master0 master1 worker0 worker1)
	expected="master0
worker0"
	[ "$result" = "$expected" ]
) && test_pass "vmw_running_vms: returns only poweredOn VMs" \
  || test_fail "vmw_running_vms: returns only poweredOn VMs"

# Test 7: all powered off — empty output
(
	export PATH="$_mock_dir:$PATH"
	CLUSTER_NAME="test1"
	CP_REPLICAS=3 ; WORKER_REPLICAS=2
	num_masters=3 ; num_workers=2
	result=$(vmw_running_vms master1 worker1)
	[ -z "$result" ]
) && test_pass "vmw_running_vms: empty when all off" \
  || test_fail "vmw_running_vms: empty when all off"

# Test 8: all powered on — all returned
(
	export PATH="$_mock_dir:$PATH"
	CLUSTER_NAME="test1"
	CP_REPLICAS=3 ; WORKER_REPLICAS=2
	num_masters=3 ; num_workers=2
	result=$(vmw_running_vms master0 worker0)
	expected="master0
worker0"
	[ "$result" = "$expected" ]
) && test_pass "vmw_running_vms: all returned when all on" \
  || test_fail "vmw_running_vms: all returned when all on"

# Test 9: govc fails — VM not returned
cat > "$_mock_dir/govc-fail" <<'MOCK'
#!/bin/bash
exit 1
MOCK
chmod +x "$_mock_dir/govc-fail"

(
	# Temporarily rename mock
	mv "$_mock_dir/govc" "$_mock_dir/govc.bak"
	cp "$_mock_dir/govc-fail" "$_mock_dir/govc"
	export PATH="$_mock_dir:$PATH"
	CLUSTER_NAME="test1"
	CP_REPLICAS=3 ; WORKER_REPLICAS=2
	num_masters=3 ; num_workers=2
	result=$(vmw_running_vms master0 worker0)
	mv "$_mock_dir/govc.bak" "$_mock_dir/govc"
	[ -z "$result" ]
) && test_pass "vmw_running_vms: govc failure returns empty" \
  || test_fail "vmw_running_vms: govc failure returns empty"

# ─────────────────────────────────────────────────────────────────────────────
# kvm_running_vms() with mock virsh
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "--- kvm_running_vms() (mocked virsh) ---"

cat > "$_mock_dir/virsh" <<'MOCK'
#!/bin/bash
# Mock virsh domstate: vm name is the last arg
vm_name="${@: -1}"
case "$vm_name" in
	*-master0|*-worker0) echo "running" ;;
	*-master1|*-worker1) echo "shut off" ;;
	*) echo "shut off" ;;
esac
MOCK
chmod +x "$_mock_dir/virsh"

# Test 10: mixed states — only running returned
(
	export PATH="$_mock_dir:$PATH"
	CLUSTER_NAME="test1"
	LIBVIRT_URI="qemu:///system"
	CP_REPLICAS=3 ; WORKER_REPLICAS=2
	num_masters=3 ; num_workers=2
	result=$(kvm_running_vms master0 master1 worker0 worker1)
	expected="master0
worker0"
	[ "$result" = "$expected" ]
) && test_pass "kvm_running_vms: returns only running VMs" \
  || test_fail "kvm_running_vms: returns only running VMs"

# Test 11: all shut off — empty output
(
	export PATH="$_mock_dir:$PATH"
	CLUSTER_NAME="test1"
	LIBVIRT_URI="qemu:///system"
	CP_REPLICAS=3 ; WORKER_REPLICAS=2
	num_masters=3 ; num_workers=2
	result=$(kvm_running_vms master1 worker1)
	[ -z "$result" ]
) && test_pass "kvm_running_vms: empty when all shut off" \
  || test_fail "kvm_running_vms: empty when all shut off"

# Test 12: all running — all returned
(
	export PATH="$_mock_dir:$PATH"
	CLUSTER_NAME="test1"
	LIBVIRT_URI="qemu:///system"
	CP_REPLICAS=3 ; WORKER_REPLICAS=2
	num_masters=3 ; num_workers=2
	result=$(kvm_running_vms master0 worker0)
	expected="master0
worker0"
	[ "$result" = "$expected" ]
) && test_pass "kvm_running_vms: all returned when all running" \
  || test_fail "kvm_running_vms: all returned when all running"

# Test 13: SNO — single VM naming (no cluster prefix doubling)
(
	export PATH="$_mock_dir:$PATH"
	CLUSTER_NAME="sno1"
	LIBVIRT_URI="qemu:///system"
	CP_REPLICAS=1 ; WORKER_REPLICAS=0
	num_masters=1 ; num_workers=0
	# For SNO, vm_name returns just the host (no prefix), so mock needs to handle "sno1"
	# Our mock returns "shut off" for unknown names, so create a specific mock
	cat > "$_mock_dir/virsh" <<-'SNO_MOCK'
	#!/bin/bash
	vm_name="${@: -1}"
	case "$vm_name" in
		sno1) echo "running" ;;
		*) echo "shut off" ;;
	esac
	SNO_MOCK
	chmod +x "$_mock_dir/virsh"
	result=$(kvm_running_vms sno1)
	[ "$result" = "sno1" ]
) && test_pass "kvm_running_vms: SNO single VM" \
  || test_fail "kvm_running_vms: SNO single VM"

# Test 14: virsh failure — VM not returned
(
	cat > "$_mock_dir/virsh" <<-'FAIL_MOCK'
	#!/bin/bash
	exit 1
	FAIL_MOCK
	chmod +x "$_mock_dir/virsh"
	export PATH="$_mock_dir:$PATH"
	CLUSTER_NAME="test1"
	LIBVIRT_URI="qemu:///system"
	CP_REPLICAS=3 ; WORKER_REPLICAS=2
	num_masters=3 ; num_workers=2
	result=$(kvm_running_vms master0 worker0)
	[ -z "$result" ]
) && test_pass "kvm_running_vms: virsh failure returns empty" \
  || test_fail "kvm_running_vms: virsh failure returns empty"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "=== Results: $pass passed, $fail failed ==="
[ -z "$FAILURES" ] && echo -e "${GREEN}All tests passed!${NC}" || echo -e "${RED}Some tests failed!${NC}"
exit ${FAILURES:+1}
exit 0
