#!/bin/bash
# Test GOVC_RESOURCE_POOL placeholder resolution in normalize-vmware-conf.
# Verifies that $GOVC_DATACENTER and $GOVC_CLUSTER in the value are expanded
# to their actual values, producing the absolute path openshift-install needs.

set -e

cd "$(dirname "$0")/../.."

source scripts/include_all.sh

echo "=== Testing GOVC_RESOURCE_POOL Resolution ==="
echo ""

# --- Setup ---

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT INT TERM

# Mock govc so normalize-vmware-conf sees "vCenter" (not ESXi)
govc() {
	if [ "$1" = "about" ]; then
		echo "API type:  VirtualCenter"
		return 0
	fi
}
export -f govc

passed=0
failed=0

assert_pool() {
	local label="$1" expected="$2" actual="$3"
	if [ "$actual" = "$expected" ]; then
		echo "✓ PASS: $label"
		echo "        got: $actual"
		passed=$(( passed + 1 ))
	else
		echo "✗ FAIL: $label"
		echo "        expected: $expected"
		echo "        got:      $actual"
		failed=$(( failed + 1 ))
	fi
}

# Helper: write a vmware.conf, run normalize-vmware-conf, extract GOVC_RESOURCE_POOL.
# $1 = raw GOVC_RESOURCE_POOL value (use single quotes in caller to preserve literal $).
resolve_pool() {
	local pool_value="$1"
	# Write the static lines with a quoted heredoc (no expansion)
	cat > "$TEST_DIR/vmware.conf" <<-'EOF'
		GOVC_DATACENTER=MyDC
		GOVC_CLUSTER=MyCluster
	EOF
	# Append the resource pool line; printf preserves literal $ in pool_value
	printf "GOVC_RESOURCE_POOL='%s'\n" "$pool_value" >> "$TEST_DIR/vmware.conf"

	# normalize-vmware-conf reads vmware.conf from $PWD
	(cd "$TEST_DIR" && normalize-vmware-conf) | \
		grep '^export GOVC_RESOURCE_POOL=' | tail -1 | \
		sed "s/^export GOVC_RESOURCE_POOL=//; s/^'//; s/'$//"
}

##############################################################
echo "Test 1: Placeholder expansion (\$GOVC_DATACENTER/\$GOVC_CLUSTER)"
echo "----------------------------------------------"

result=$(resolve_pool '/$GOVC_DATACENTER/host/$GOVC_CLUSTER/Resources')
assert_pool "placeholders resolved" "/MyDC/host/MyCluster/Resources" "$result"
echo ""

##############################################################
echo "Test 2: Placeholder with sub-pool"
echo "----------------------------------------------"

result=$(resolve_pool '/$GOVC_DATACENTER/host/$GOVC_CLUSTER/Resources/DevPool')
assert_pool "placeholders + sub-pool" "/MyDC/host/MyCluster/Resources/DevPool" "$result"
echo ""

##############################################################
echo "Test 3: Absolute path (no placeholders -- no-op)"
echo "----------------------------------------------"

result=$(resolve_pool '/Datacenter/host/Cluster/Resources')
assert_pool "absolute path unchanged" "/Datacenter/host/Cluster/Resources" "$result"
echo ""

##############################################################
echo "Test 4: Only \$GOVC_DATACENTER placeholder"
echo "----------------------------------------------"

result=$(resolve_pool '/$GOVC_DATACENTER/host/StaticCluster/Resources')
assert_pool "only datacenter resolved" "/MyDC/host/StaticCluster/Resources" "$result"
echo ""

##############################################################
echo "Test 5: Only \$GOVC_CLUSTER placeholder"
echo "----------------------------------------------"

result=$(resolve_pool '/StaticDC/host/$GOVC_CLUSTER/Resources')
assert_pool "only cluster resolved" "/StaticDC/host/MyCluster/Resources" "$result"
echo ""

##############################################################
echo "Test 6: Unset GOVC_RESOURCE_POOL (commented out)"
echo "----------------------------------------------"

cat > "$TEST_DIR/vmware.conf" <<-'EOF'
	GOVC_DATACENTER=MyDC
	GOVC_CLUSTER=MyCluster
	#GOVC_RESOURCE_POOL='/$GOVC_DATACENTER/host/$GOVC_CLUSTER/Resources'
EOF

result=$( (cd "$TEST_DIR" && normalize-vmware-conf) | \
	grep '^export GOVC_RESOURCE_POOL=' | tail -1 || echo "")
if [ -z "$result" ]; then
	echo "✓ PASS: no GOVC_RESOURCE_POOL exported when commented out"
	passed=$(( passed + 1 ))
else
	echo "✗ FAIL: unexpected export when commented out: $result"
	failed=$(( failed + 1 ))
fi
echo ""

##############################################################
echo "=== Results: $passed passed, $failed failed ==="
echo ""

if [ "$failed" -eq 0 ]; then
	echo "✓ All GOVC_RESOURCE_POOL resolution tests passed!"
	exit 0
else
	echo "✗ Some tests failed!"
	exit 1
fi
