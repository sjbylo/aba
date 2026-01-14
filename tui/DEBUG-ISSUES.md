# TUI Debug Issues

## Current Problems

### 1. Help Button Exits with Code 2
**Status**: Still broken despite fixes
**Possible Cause**: Shell script is exiting when it shouldn't

### 2. All Operators Added Instead of Selected One
**Status**: Still broken
**Possible Cause**: Dialog parsing is wrong

## Test Results

### test-basket.sh - WORKS ✅
```
Basket count: 6
Basket contents: kiali-ossm test-op-1 test-op-2 new-op-from-function cincinnati-operator servicemeshoperator3
```
This proves: Global arrays work, add_set_to_basket() works

### test-dialog-parse.sh - Issues
- Mac bash 3.x doesn't support `declare -A` (associative arrays)
- BUT the TUI runs on RHEL which has bash 4+
- So this test is misleading

## Root Cause Analysis

### Issue 1: Dialog Parsing
The problem is likely in how dialog's output is parsed.

Dialog returns: `"op1" "op2" "op3"`

Current parsing:
```bash
while read -r op; do
    op=${op//\"/}  # Remove quotes
    ...
done < <(echo "$newsel" | tr ' ' '\n')
```

This splits on EVERY space, including spaces WITHIN operator names!

Example:
- Dialog returns: `"advanced-cluster-management"`
- After `tr ' ' '\n'`: 
  ```
  "advanced-cluster-management"
  ```
- After removing quotes: `advanced-cluster-management` ✅

BUT if dialog returns multiple:
- Dialog returns: `"op1" "op2"`  
- After `tr ' ' '\n'`:
  ```
  "op1"
  "op2"
  ```
- Looks correct... 🤔

### Issue 2: The REAL Problem

Looking at the search code:
```bash
# Add all selected operators
for op in "${!SEL[@]}"; do
    OP_BASKET["$op"]=1
done

# Then loop through ALL matches and remove unselected
while IFS= read -r op; do
    ...
    if [[ -n "${OP_BASKET[$op]:-}" && -z "${SEL[$op]:-}" ]]; then
        # Remove
    fi
done <<<"$matches"
```

Wait... we're ONLY looping through selected operators to add.
Then looping through matches to remove.

But the search itself returns TOO MANY matches!

### Issue 3: The Search Query

When you search for "mtv", what does the search return?

```bash
matches=$(grep -hRi --no-filename -i -- "$query" "$ABA_ROOT"/mirror/.index/* 2>/dev/null | sort -u)
```

This grep searches for "mtv" in the CONTENT of index files, not just operator names!

So if an index file has:
```
advanced-cluster-management
  description: includes MTV features
```

It will match "advanced-cluster-management" because "mtv" appears in the description!

## Solution

Need to see actual log output from RHEL to understand what's happening:

```bash
grep "User selected in dialog" /tmp/aba-tui-*.log
grep "matches for:" /tmp/aba-tui-*.log  
grep "After search update" /tmp/aba-tui-*.log
```

## Quick Fix to Try

Change the search to only match operator NAMES, not descriptions:

```bash
# Current (matches everything):
matches=$(grep -hRi --no-filename -i -- "$query" "$ABA_ROOT"/mirror/.index/* 2>/dev/null | sort -u)

# Better (one operator per line):
matches=$(grep -hRi --no-filename -i -- "$query" "$ABA_ROOT"/mirror/.index/* 2>/dev/null | \
    grep -v ":" | \  # Remove description lines
    sort -u)
```

