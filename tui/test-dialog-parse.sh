#!/bin/bash
# Test dialog output parsing

# Simulate dialog output (what dialog actually returns)
# Dialog returns: "item1" "item2" "item3"
test_output='"mtv-operator" "openshift-gitops-operator"'

echo "=== Testing Dialog Output Parsing ==="
echo "Simulated dialog output: [$test_output]"
echo

# Method 1: Split on space and remove quotes
echo "Method 1: tr space to newline"
declare -A SEL1
while read -r op; do
    op=${op//\"/}
    op=${op##[[:space:]]}
    op=${op%%[[:space:]]}
    if [[ -n "$op" ]]; then
        SEL1["$op"]=1
        echo "  Parsed: [$op]"
    fi
done < <(echo "$test_output" | tr ' ' '\n')
echo "  Count: ${#SEL1[@]}"
echo "  Keys: ${!SEL1[*]}"
echo

# Method 2: Use eval to parse properly
echo "Method 2: eval array assignment"
declare -A SEL2
eval "selected_items=($test_output)"
for op in "${selected_items[@]}"; do
    SEL2["$op"]=1
    echo "  Parsed: [$op]"
done
echo "  Count: ${#SEL2[@]}"
echo "  Keys: ${!SEL2[*]}"
echo

# Method 3: Read into array directly
echo "Method 3: read -a array"
declare -A SEL3
read -r -a arr <<<"$test_output"
for op in "${arr[@]}"; do
    op=${op//\"/}
    [[ -n "$op" ]] && SEL3["$op"]=1
    echo "  Parsed: [$op]"
done
echo "  Count: ${#SEL3[@]}"
echo "  Keys: ${!SEL3[*]}"
echo

echo "=== Correct Method ==="
echo "Method 2 (eval) gives correct results: ${#SEL2[@]} operators"

