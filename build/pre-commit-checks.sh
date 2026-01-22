#!/bin/bash
# Pre-commit checks for aba repository
# Usage: build/pre-commit-checks.sh [--skip-version]
#
# This script:
# 1. Updates ABA_BUILD timestamp in scripts/aba.sh (unless --skip-version)
# 2. Syncs RPM list in install script with templates/rpms-external.txt
# 3. Checks syntax of all shell scripts
# 4. Verifies we're on dev branch
# 5. Pulls latest changes
#
# Exit codes:
#   0 = All checks passed
#   1 = Check failed

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Find ABA_ROOT
cd "$(dirname "$0")/.." || exit 1
ABA_ROOT="$(pwd)"

echo -e "${YELLOW}=== Pre-Commit Checks ===${NC}\n"

# Parse options
SKIP_VERSION=false
if [[ "$1" == "--skip-version" ]]; then
    SKIP_VERSION=true
    echo -e "${YELLOW}(Skipping VERSION update)${NC}\n"
fi

# 1. Update ABA_BUILD timestamp
if [[ "$SKIP_VERSION" == false ]]; then
    echo -e "${YELLOW}[1/5] Updating ABA_BUILD timestamp...${NC}"
    new_build=$(date +%Y%m%d%H%M%S)
    sed -i "s/^ABA_BUILD=.*/ABA_BUILD=$new_build/g" scripts/aba.sh
    echo -e "${GREEN}      ✓ ABA_BUILD = $new_build${NC}\n"
else
    echo -e "${YELLOW}[1/5] Skipping BUILD timestamp update${NC}\n"
fi

# 2. Sync install script RPM list with templates/rpms-external.txt
echo -e "${YELLOW}[2/5] Syncing RPM list in install script...${NC}"
if [ -f templates/rpms-external.txt ]; then
    rpm_list=$(cat templates/rpms-external.txt)
    # Update line 17: required_pkgs+=(...)
    sed -i "s|^required_pkgs+=([^)]*).*|required_pkgs+=($rpm_list)  # Synced from templates/rpms-external.txt|" install
    echo -e "${GREEN}      ✓ Synced: $rpm_list${NC}\n"
else
    echo -e "${RED}      ✗ templates/rpms-external.txt not found${NC}\n"
    exit 1
fi

# 3. Check syntax of all shell scripts
echo -e "${YELLOW}[3/5] Checking shell script syntax...${NC}"
failed=0
checked=0

for dir in scripts mirror templates bundles test/func; do
    [ -d "$dir" ] || continue
    for script in "$dir"/*.sh; do
        [ -f "$script" ] || continue
        checked=$((checked + 1))
        if ! bash -n "$script" 2>/dev/null; then
            echo -e "${RED}      ✗ Syntax error: $script${NC}"
            bash -n "$script"  # Show the actual error
            failed=1
        fi
    done
done

if [ $failed -eq 1 ]; then
    echo -e "${RED}      ✗ Script syntax check FAILED${NC}\n"
    exit 1
fi

echo -e "${GREEN}      ✓ All $checked shell scripts have valid syntax${NC}\n"

# 4. Verify we're on dev branch
echo -e "${YELLOW}[4/5] Verifying git branch...${NC}"
current_branch=$(git branch --show-current)
if [[ "$current_branch" != "dev" ]]; then
    echo -e "${RED}      ✗ Not on dev branch (current: $current_branch)${NC}\n"
    exit 1
fi
echo -e "${GREEN}      ✓ On dev branch${NC}\n"

# 5. Pull latest changes
echo -e "${YELLOW}[5/5] Pulling latest changes...${NC}"
if git pull --rebase 2>&1 | grep -q "Already up to date"; then
    echo -e "${GREEN}      ✓ Already up to date${NC}\n"
else
    echo -e "${GREEN}      ✓ Pulled latest changes${NC}\n"
fi

echo -e "${GREEN}=== All Pre-Commit Checks Passed! ===${NC}"
