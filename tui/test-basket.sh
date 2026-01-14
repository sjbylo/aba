#!/bin/bash
# Quick test script to verify basket functionality

cd "$(dirname "$0")/.."

source scripts/include_all.sh

# Initialize global arrays
declare -gA OP_BASKET
declare -gA OP_SET_ADDED
declare -gA OP_REMOVED

OP_BASKET=()
OP_SET_ADDED=()
OP_REMOVED=()

echo "=== Testing Basket Functionality ==="
echo

# Test 1: Add operators directly
echo "Test 1: Adding operators directly to basket"
OP_BASKET["test-op-1"]=1
OP_BASKET["test-op-2"]=1
echo "  Basket count: ${#OP_BASKET[@]}"
echo "  Basket contents: ${!OP_BASKET[*]}"
echo "  Expected: 2 operators (test-op-1, test-op-2)"
echo

# Test 2: Add from operator set
echo "Test 2: Adding from operator set (mesh3)"
if [[ -f templates/operator-set-mesh3 ]]; then
    while IFS= read -r op; do
        [[ "$op" =~ ^# ]] && continue
        op=${op%%#*}
        op=${op//$'\n'/}
        op=${op##[[:space:]]}
        op=${op%%[[:space:]]}
        [[ -z "$op" ]] && continue
        OP_BASKET["$op"]=1
        echo "  Added: $op"
    done < templates/operator-set-mesh3
    echo "  Basket count after mesh3: ${#OP_BASKET[@]}"
    echo "  Basket contents: ${!OP_BASKET[*]}"
else
    echo "  ERROR: templates/operator-set-mesh3 not found"
fi
echo

# Test 3: Check if array persists
echo "Test 3: Checking array persistence"
function test_function() {
    echo "  Inside function - basket count: ${#OP_BASKET[@]}"
    echo "  Inside function - basket contents: ${!OP_BASKET[*]}"
    OP_BASKET["new-op-from-function"]=1
}
test_function
echo "  After function - basket count: ${#OP_BASKET[@]}"
echo "  After function - basket contents: ${!OP_BASKET[*]}"
echo

echo "=== Test Complete ==="
echo "If basket count is 0 or operators are missing, there's a bug."

