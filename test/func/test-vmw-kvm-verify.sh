#!/bin/bash
# Unit tests for _vmw_verify_objects() and _kvm_verify_objects()
# Uses mock commands to simulate govc/virsh/ssh responses.

cd "$(dirname "$0")/../.."
REPO_ROOT="$PWD"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass=0
fail=0
FAILURES=""

test_pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; pass=$(( pass + 1 )); }
test_fail() { echo -e "${RED}✗ FAIL${NC}: $1 -- $2"; fail=$(( fail + 1 )); FAILURES=1; }

_mock_dir=$(mktemp -d)
_test_out=$(mktemp)
trap 'rm -rf "$_mock_dir" "$_test_out"' EXIT

# Source include_all for aba_debug, aba_warning, etc.
source scripts/include_all.sh dummy_arg 2>/dev/null

# Override aba_abort so it doesn't exit the test runner
aba_abort() { echo "ABORT: $*" >&2; exit 1; }

echo
echo "=== Testing: VMware/KVM object verification ==="
echo

# ─────────────────────────────────────────────────────────────────────────────
# VMware: _vmw_verify_objects
# ─────────────────────────────────────────────────────────────────────────────
echo "--- _vmw_verify_objects() ---"

# Extract the function from install-vmware.conf.sh
eval "$(sed -n '/^_vmw_verify_objects()/,/^}/p' scripts/install-vmware.conf.sh)"

# --- Mock govc: all objects exist ---
cat > "$_mock_dir/govc" <<'MOCK'
#!/bin/bash
cmd="$1"
case "$cmd" in
	datastore.info|datacenter.info|folder.info|pool.info)
		exit 0 ;;
	find)
		echo "/Datacenter/network/found" ;;
	*)
		exit 0 ;;
esac
MOCK
chmod +x "$_mock_dir/govc"

# Test 1: all objects valid — silent (no warnings), exit 0
(
	export PATH="$_mock_dir:$PATH"
	GOVC_DATASTORE="Datastore4"
	ISO_DATASTORE=""
	GOVC_NETWORK="Lab Network"
	GOVC_DATACENTER="Datacenter"
	GOVC_CLUSTER="Cluster"
	VC_FOLDER="/Datacenter/vm"
	GOVC_RESOURCE_POOL=""
	_vmw_verify_objects
) > "$_test_out" 2>&1
_rc=$?
if [ $_rc -eq 0 ] && ! grep -qi "warning" "$_test_out"; then
	test_pass "VMware: all valid — no warnings, exit 0"
else
	test_fail "VMware: all valid — no warnings, exit 0" "rc=$_rc, output: $(cat "$_test_out")"
fi

# Test 2: all objects valid — debug output present
(
	export PATH="$_mock_dir:$PATH"
	export DEBUG_ABA=1
	GOVC_DATASTORE="Datastore4"
	ISO_DATASTORE=""
	GOVC_NETWORK="Lab Network"
	GOVC_DATACENTER="Datacenter"
	GOVC_CLUSTER="Cluster"
	VC_FOLDER="/Datacenter/vm"
	GOVC_RESOURCE_POOL=""
	_vmw_verify_objects
) > "$_test_out" 2>&1
_rc=$?
if [ $_rc -eq 0 ] && grep -q "Verified.*Datastore" "$_test_out" && grep -q "Verified.*Network" "$_test_out"; then
	test_pass "VMware: all valid — debug shows 'Verified' lines"
else
	test_fail "VMware: all valid — debug shows 'Verified' lines" "rc=$_rc, output: $(cat "$_test_out")"
fi

# --- Mock govc: datastore fails ---
cat > "$_mock_dir/govc" <<'MOCK'
#!/bin/bash
cmd="$1"
case "$cmd" in
	datastore.info)
		# Fail for first arg (the datastore name)
		exit 1 ;;
	datacenter.info|folder.info|pool.info)
		exit 0 ;;
	find)
		echo "/found" ;;
	*)
		exit 0 ;;
esac
MOCK
chmod +x "$_mock_dir/govc"

# Test 3: datastore not found — warning + abort
(
	export PATH="$_mock_dir:$PATH"
	GOVC_DATASTORE="BadDatastore"
	ISO_DATASTORE=""
	GOVC_NETWORK="Lab Network"
	GOVC_DATACENTER="Datacenter"
	GOVC_CLUSTER="Cluster"
	VC_FOLDER=""
	GOVC_RESOURCE_POOL=""
	_vmw_verify_objects
) > "$_test_out" 2>&1
_rc=$?
if [ $_rc -ne 0 ] && grep -q "BadDatastore.*not found" "$_test_out" && grep -q "ABORT" "$_test_out"; then
	test_pass "VMware: bad datastore — warning + abort"
else
	test_fail "VMware: bad datastore — warning + abort" "rc=$_rc, output: $(cat "$_test_out")"
fi

# --- Mock govc: network fails ---
cat > "$_mock_dir/govc" <<'MOCK'
#!/bin/bash
cmd="$1"
case "$cmd" in
	datastore.info|datacenter.info|folder.info|pool.info)
		exit 0 ;;
	host.portgroup.info)
		exit 1 ;;
	find)
		# Return empty = not found
		echo "" ;;
	*)
		exit 0 ;;
esac
MOCK
chmod +x "$_mock_dir/govc"

# Test 4: network not found — warning + abort
(
	export PATH="$_mock_dir:$PATH"
	GOVC_DATASTORE="GoodDS"
	ISO_DATASTORE=""
	GOVC_NETWORK="BadNetwork"
	GOVC_DATACENTER="Datacenter"
	GOVC_CLUSTER=""
	VC_FOLDER=""
	GOVC_RESOURCE_POOL=""
	_vmw_verify_objects
) > "$_test_out" 2>&1
_rc=$?
if [ $_rc -ne 0 ] && grep -q "BadNetwork.*not found" "$_test_out"; then
	test_pass "VMware: bad network — warning + abort"
else
	test_fail "VMware: bad network — warning + abort" "rc=$_rc, output: $(cat "$_test_out")"
fi

# --- Mock govc: multiple failures ---
cat > "$_mock_dir/govc" <<'MOCK'
#!/bin/bash
cmd="$1"
case "$cmd" in
	datastore.info) exit 1 ;;
	datacenter.info) exit 1 ;;
	host.portgroup.info) exit 1 ;;
	folder.info|pool.info) exit 0 ;;
	find) echo "" ;;
	*) exit 0 ;;
esac
MOCK
chmod +x "$_mock_dir/govc"

# Test 5: multiple failures — all reported (not just first)
(
	export PATH="$_mock_dir:$PATH"
	GOVC_DATASTORE="BadDS"
	ISO_DATASTORE=""
	GOVC_NETWORK="BadNet"
	GOVC_DATACENTER="BadDC"
	GOVC_CLUSTER="BadCluster"
	VC_FOLDER=""
	GOVC_RESOURCE_POOL=""
	VC=1
	_vmw_verify_objects
) > "$_test_out" 2>&1
_rc=$?
_warn_count=$(grep -ci "warning" "$_test_out" || true)
if [ $_rc -ne 0 ] && [ "$_warn_count" -ge 3 ]; then
	test_pass "VMware: multiple failures — all $_warn_count reported"
else
	test_fail "VMware: multiple failures — expected >=3 warnings" "rc=$_rc, warnings=$_warn_count, output: $(cat "$_test_out")"
fi

# --- Mock govc: folder missing (informational, not error) ---
cat > "$_mock_dir/govc" <<'MOCK'
#!/bin/bash
cmd="$1"
case "$cmd" in
	datastore.info|datacenter.info|pool.info) exit 0 ;;
	folder.info) exit 1 ;;
	find) echo "/found" ;;
	*) exit 0 ;;
esac
MOCK
chmod +x "$_mock_dir/govc"

# Test 6: folder missing — no abort, just debug
(
	export PATH="$_mock_dir:$PATH"
	GOVC_DATASTORE="GoodDS"
	ISO_DATASTORE=""
	GOVC_NETWORK="GoodNet"
	GOVC_DATACENTER="GoodDC"
	GOVC_CLUSTER="GoodCluster"
	VC_FOLDER="/Datacenter/vm"
	GOVC_RESOURCE_POOL=""
	_vmw_verify_objects
) > "$_test_out" 2>&1
_rc=$?
if [ $_rc -eq 0 ] && ! grep -q "ABORT" "$_test_out"; then
	test_pass "VMware: folder missing — no abort (informational)"
else
	test_fail "VMware: folder missing — no abort (informational)" "rc=$_rc, output: $(cat "$_test_out")"
fi

# Test 7: no optional objects set — nothing to check, exit 0
(
	export PATH="$_mock_dir:$PATH"
	GOVC_DATASTORE=""
	ISO_DATASTORE=""
	GOVC_NETWORK=""
	GOVC_DATACENTER=""
	GOVC_CLUSTER=""
	VC_FOLDER=""
	GOVC_RESOURCE_POOL=""
	_vmw_verify_objects
) > "$_test_out" 2>&1
_rc=$?
if [ $_rc -eq 0 ]; then
	test_pass "VMware: no objects configured — exit 0"
else
	test_fail "VMware: no objects configured — exit 0" "rc=$_rc, output: $(cat "$_test_out")"
fi

# ─────────────────────────────────────────────────────────────────────────────
# KVM: _kvm_verify_objects
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "--- _kvm_verify_objects() ---"

# Extract the function from install-kvm.conf.sh
eval "$(sed -n '/^_kvm_verify_objects()/,/^}/p' scripts/install-kvm.conf.sh)"

# --- Mock ssh: all objects exist ---
cat > "$_mock_dir/ssh" <<'MOCK'
#!/bin/bash
# Last arg is the remote command
exit 0
MOCK
chmod +x "$_mock_dir/ssh"

# Test 8: all KVM objects valid — no warnings, exit 0
(
	export PATH="$_mock_dir:$PATH"
	KVM_HOST="kvmhost1"
	KVM_STORAGE_POOL="/var/lib/libvirt/images"
	KVM_NETWORK="br0"
	_kvm_verify_objects
) > "$_test_out" 2>&1
_rc=$?
if [ $_rc -eq 0 ] && ! grep -qi "warning" "$_test_out"; then
	test_pass "KVM: all valid — no warnings, exit 0"
else
	test_fail "KVM: all valid — no warnings, exit 0" "rc=$_rc, output: $(cat "$_test_out")"
fi

# Test 9: all KVM objects valid — debug shows Verified
(
	export PATH="$_mock_dir:$PATH"
	export DEBUG_ABA=1
	KVM_HOST="kvmhost1"
	KVM_STORAGE_POOL="/var/lib/libvirt/images"
	KVM_NETWORK="br0"
	_kvm_verify_objects
) > "$_test_out" 2>&1
_rc=$?
if [ $_rc -eq 0 ] && grep -q "Verified.*Storage pool" "$_test_out" && grep -q "Verified.*Network bridge" "$_test_out"; then
	test_pass "KVM: all valid — debug shows 'Verified' lines"
else
	test_fail "KVM: all valid — debug shows 'Verified' lines" "rc=$_rc, output: $(cat "$_test_out")"
fi

# --- Mock ssh: storage pool path fails, network path succeeds ---
cat > "$_mock_dir/ssh" <<'MOCK'
#!/bin/bash
# The remote command is the last arg; pool check uses test -d on the pool path,
# network check uses test -d on /sys/class/net/...
remote_cmd="${@: -1}"
case "$remote_cmd" in
	*"/sys/class/net/"*) exit 0 ;;
	*) exit 1 ;;
esac
MOCK
chmod +x "$_mock_dir/ssh"

# Test 10: storage pool not found — warning + abort
(
	export PATH="$_mock_dir:$PATH"
	KVM_HOST="kvmhost1"
	KVM_STORAGE_POOL="/bad/path"
	KVM_NETWORK="br0"
	_kvm_verify_objects
) > "$_test_out" 2>&1
_rc=$?
if [ $_rc -ne 0 ] && grep -q "/bad/path.*not found" "$_test_out" && grep -q "ABORT" "$_test_out"; then
	test_pass "KVM: bad storage pool — warning + abort"
else
	test_fail "KVM: bad storage pool — warning + abort" "rc=$_rc, output: $(cat "$_test_out")"
fi

# --- Mock ssh: all fail ---
cat > "$_mock_dir/ssh" <<'MOCK'
#!/bin/bash
exit 1
MOCK
chmod +x "$_mock_dir/ssh"

# Test 11: both fail — both reported
(
	export PATH="$_mock_dir:$PATH"
	KVM_HOST="kvmhost1"
	KVM_STORAGE_POOL="/bad/pool"
	KVM_NETWORK="badbridge"
	_kvm_verify_objects
) > "$_test_out" 2>&1
_rc=$?
_warn_count=$(grep -ci "warning" "$_test_out" || true)
if [ $_rc -ne 0 ] && [ "$_warn_count" -eq 2 ]; then
	test_pass "KVM: both fail — both warnings reported"
else
	test_fail "KVM: both fail — both warnings reported" "rc=$_rc, warnings=$_warn_count, output: $(cat "$_test_out")"
fi

# Test 12: no KVM objects configured — exit 0
(
	export PATH="$_mock_dir:$PATH"
	KVM_HOST="kvmhost1"
	KVM_STORAGE_POOL=""
	KVM_NETWORK=""
	_kvm_verify_objects
) > "$_test_out" 2>&1
_rc=$?
if [ $_rc -eq 0 ]; then
	test_pass "KVM: no objects configured — exit 0"
else
	test_fail "KVM: no objects configured — exit 0" "rc=$_rc, output: $(cat "$_test_out")"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "=== Results: $pass passed, $fail failed ==="
[ -z "$FAILURES" ] && echo -e "${GREEN}All tests passed!${NC}" || echo -e "${RED}Some tests failed!${NC}"
exit ${FAILURES:+1}
exit 0
