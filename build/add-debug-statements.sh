#!/bin/bash
# Helper tool to identify where aba_debug statements might be missing
# Usage: build/add-debug-statements.sh [--report|--suggest]

set -e

cd "$(dirname "$0")/.." || exit 1

mode="${1:---report}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}=== ABA Debug Statement Analysis ===${NC}\n"

# Analyze a script file
analyze_script() {
    local file="$1"
    local functions=$(grep -n "^[a-zA-Z_][a-zA-Z0-9_]*\(\)" "$file" 2>/dev/null | cut -d: -f1,2 || true)
    local debug_lines=$(grep -n "aba_debug" "$file" 2>/dev/null | cut -d: -f1 || true)
    
    if [ -z "$functions" ]; then
        return
    fi
    
    local func_count=$(echo "$functions" | wc -l)
    local debug_count=$(echo "$debug_lines" | wc -l)
    
    echo "  $file"
    echo "    Functions: $func_count"
    echo "    aba_debug calls: $debug_count"
    
    # Check each function
    while IFS=: read -r line_num func_name; do
        func_name=$(echo "$func_name" | sed 's/().*//')
        
        # Check if function has aba_debug within next 10 lines
        local has_debug=$(sed -n "${line_num},$((line_num + 10))p" "$file" | grep -q "aba_debug" && echo "yes" || echo "no")
        
        if [ "$has_debug" = "no" ]; then
            echo -e "    ${YELLOW}⚠${NC}  Line $line_num: Function '$func_name' lacks entry debug"
        fi
    done <<< "$functions"
    
    echo
}

if [ "$mode" = "--report" ]; then
    echo -e "${YELLOW}Analyzing scripts for debug coverage...${NC}\n"
    
    for script in scripts/*.sh; do
        [ -f "$script" ] || continue
        [ "$(basename "$script")" = "include_all.sh" ] && continue  # Skip the library
        analyze_script "$script"
    done
    
    echo -e "${CYAN}Summary:${NC}"
    total_funcs=$(grep -r "^[a-zA-Z_][a-zA-Z0-9_]*\(\)" scripts/*.sh 2>/dev/null | grep -v include_all.sh | wc -l)
    total_debugs=$(grep -r "aba_debug" scripts/*.sh 2>/dev/null | wc -l)
    echo "  Total functions: $total_funcs"
    echo "  Total aba_debug calls: $total_debugs"
    echo "  Average debugs per function: $((total_debugs / (total_funcs + 1)))"
    
elif [ "$mode" = "--suggest" ]; then
    echo -e "${YELLOW}Suggesting debug statement patterns...${NC}\n"
    
    cat <<'EOF'
## Recommended Debug Statement Patterns:

### 1. Function Entry (always add)
```bash
my_function() {
    aba_debug "Entering my_function()"  # Or with params: "my_function($1, $2)"
    
    # ... function body ...
}
```

### 2. Before Critical Operations
```bash
aba_debug "Calling make with: $BUILD_COMMAND"
make $BUILD_COMMAND

aba_debug "Downloading from: $url"
curl -O "$url"

aba_debug "Removing directory: $dir"
rm -rf "$dir"
```

### 3. Key Variable Assignments
```bash
ocp_version=$(get_ocp_version)
aba_debug "ocp_version=$ocp_version"

domain=$(get_domain)
aba_debug "domain=$domain"
```

### 4. Conditional Branches
```bash
if [ "$interactive_mode" ]; then
    aba_debug "Running in interactive mode"
    # ...
else
    aba_debug "Running in non-interactive mode"
    # ...
fi
```

### 5. Loop Iterations (for complex loops)
```bash
for catalog in $catalogs; do
    aba_debug "Processing catalog: $catalog"
    # ...
done
```

### 6. Before/After run_once Calls
```bash
aba_debug "Starting background task: cli:download:$item"
run_once -i "cli:download:$item" -- make -sC cli $item
aba_debug "Background task started successfully"
```

### 7. Error Paths
```bash
if ! check_connectivity; then
    aba_debug "Connectivity check failed"
    aba_abort "Cannot reach required sites"
fi
```

### 8. Return Points
```bash
my_function() {
    # ... work ...
    aba_debug "my_function returning: $result"
    return 0
}
```

## Quick Add Pattern:

```bash
# For function entries, use sed:
sed -i '/^function_name() {/a\    aba_debug "Entering function_name()"' script.sh

# Or manually review and add systematically
```

## Priority Areas to Add Debug Statements:

1. **scripts/aba.sh** - Main entry point, argument parsing
2. **scripts/download-*.sh** - Download operations
3. **scripts/reg-*.sh** - Registry operations
4. **scripts/make-bundle.sh** - Bundle creation
5. **All functions in include_all.sh** - Core utilities

## Testing Debug Output:

```bash
# Enable debug mode
export DEBUG_ABA=1
aba bundle ...

# Or
aba --debug bundle ...
```
EOF

else
    echo -e "${RED}Unknown mode: $mode${NC}"
    echo "Usage: $0 [--report|--suggest]"
    exit 1
fi
