#!/bin/bash
# =============================================================================
# Pre-commit checks for aba repository
# =============================================================================
# Runs a series of sanity checks before a release commit is created.
# Called by build/release.sh (step 1) but can also be run standalone.
#
# What it does:
#   1. Stamps a build timestamp (ABA_BUILD) into scripts/aba.sh
#   2. Syncs RPM package lists from templates/ into the install script so
#      the install script always installs the right set of packages
#   3. Syntax-checks every .sh file in key directories
#   4. Verifies we're on the dev branch
#   5. Pulls latest changes from the remote
#
# Options:
#   --skip-version     Skip the ABA_BUILD timestamp update (useful for
#                      re-running checks without changing the build stamp)
#   --release-branch   Skip the branch check (step 4) and git pull (step 5).
#                      Used by release.sh --ref when running on a temporary
#                      release branch that isn't dev and has no remote.
#
# Exit codes:
#   0 = All checks passed
#   1 = A check failed
# =============================================================================

set -e

# --- Terminal colours --------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Navigate to repository root (one level up from build/)
cd "$(dirname "$0")/.." || exit 1
ABA_ROOT="$(pwd)"

echo -e "${YELLOW}=== Pre-Commit Checks ===${NC}\n"

# --- Parse options -----------------------------------------------------------
SKIP_VERSION=false
RELEASE_BRANCH=false
for arg in "$@"; do
    case "$arg" in
        --skip-version)   SKIP_VERSION=true ;;
        --release-branch) RELEASE_BRANCH=true ;;
    esac
done
if $SKIP_VERSION; then
    echo -e "${YELLOW}(Skipping VERSION update)${NC}\n"
fi

# =============================================================================
# Step 1: Update ABA_BUILD timestamp
# =============================================================================
# ABA_BUILD is a YYYYMMDDHHMMSS timestamp embedded in scripts/aba.sh.
# It lets users (and support) see exactly when the installed binary was built.
if [[ "$SKIP_VERSION" == false ]]; then
    echo -e "${YELLOW}[1/5] Updating ABA_BUILD timestamp...${NC}"
    new_build=$(date +%Y%m%d%H%M%S)
    sed -i "s/^ABA_BUILD=.*/ABA_BUILD=$new_build/g" scripts/aba.sh
    echo -e "${GREEN}      ✓ ABA_BUILD = $new_build${NC}\n"
else
    echo -e "${YELLOW}[1/5] Skipping BUILD timestamp update${NC}\n"
fi

# =============================================================================
# Step 2a: Sync external RPM list
# =============================================================================
# templates/rpms-external.txt lists the RPM packages needed on an
# internet-connected host.  This step copies that list into the install
# script so the two stay in sync automatically.  The sed matches a specific
# line shape:  required_pkgs+=(...)  # Synced from templates/rpms-external.txt
echo -e "${YELLOW}[2a/6] Syncing external RPM list in install script...${NC}"
if [ -f templates/rpms-external.txt ]; then
    rpm_list=$(cat templates/rpms-external.txt)
    sed -i "s|^required_pkgs+=([^)]*)  # Synced from templates/rpms-external.txt|required_pkgs+=($rpm_list)  # Synced from templates/rpms-external.txt|" install
    echo -e "${GREEN}       ✓ Synced external RPMs: $rpm_list${NC}\n"
else
    echo -e "${RED}       ✗ templates/rpms-external.txt not found${NC}\n"
    exit 1
fi

# =============================================================================
# Step 2b: Sync internal RPM list
# =============================================================================
# templates/rpms-internal.txt lists additional RPMs needed on an air-gapped
# (disconnected) host that receives a bundle.  Same sed technique as 2a but
# for the internal line.
echo -e "${YELLOW}[2b/6] Syncing internal RPM list for bundle installations...${NC}"
if [ -f templates/rpms-internal.txt ]; then
    rpm_internal_list=$(cat templates/rpms-internal.txt)
    sed -i "s|^required_pkgs+=([^)]*)  # Synced from templates/rpms-internal.txt|required_pkgs+=($rpm_internal_list)  # Synced from templates/rpms-internal.txt|" install
    echo -e "${GREEN}       ✓ Synced internal RPMs: $rpm_internal_list${NC}\n"
else
    echo -e "${RED}       ✗ templates/rpms-internal.txt not found${NC}\n"
    exit 1
fi

# =============================================================================
# Step 3: Syntax-check all shell scripts
# =============================================================================
# Runs `bash -n` (parse-only, no execution) on every .sh file in the key
# source directories.  Catches typos, unmatched quotes, etc. before they
# reach users.
echo -e "${YELLOW}[3/6] Checking shell script syntax...${NC}"
failed=0
checked=0

for dir in scripts mirror templates bundles test/func; do
    [ -d "$dir" ] || continue
    for script in "$dir"/*.sh; do
        [ -f "$script" ] || continue
        checked=$((checked + 1))
        if ! bash -n "$script" 2>/dev/null; then
            echo -e "${RED}      ✗ Syntax error: $script${NC}"
            bash -n "$script"  # Re-run without suppression to show the error
            failed=1
        fi
    done
done

if [ $failed -eq 1 ]; then
    echo -e "${RED}      ✗ Script syntax check FAILED${NC}\n"
    exit 1
fi

echo -e "${GREEN}      ✓ All $checked shell scripts have valid syntax${NC}\n"

# =============================================================================
# Step 4: Verify we're on the dev branch
# =============================================================================
# Skipped with --release-branch (used when release.sh --ref creates a
# temporary branch that isn't dev).
if $RELEASE_BRANCH; then
    echo -e "${YELLOW}[4/6] Skipping branch check (--release-branch)${NC}\n"
else
    echo -e "${YELLOW}[4/6] Verifying git branch...${NC}"
    current_branch=$(git branch --show-current)
    if [[ "$current_branch" != "dev" ]]; then
        echo -e "${RED}      ✗ Not on dev branch (current: $current_branch)${NC}\n"
        exit 1
    fi
    echo -e "${GREEN}      ✓ On dev branch${NC}\n"
fi

# =============================================================================
# Step 5: Pull latest changes
# =============================================================================
# Ensures we're building on top of the latest remote state.  Uses --rebase
# to keep commit history linear.
# Skipped with --release-branch (temp branch has no remote tracking branch).
if $RELEASE_BRANCH; then
    echo -e "${YELLOW}[5/6] Skipping git pull (--release-branch)${NC}\n"
else
    echo -e "${YELLOW}[5/6] Pulling latest changes...${NC}"
    if git pull --rebase 2>&1 | grep -q "Already up to date"; then
        echo -e "${GREEN}      ✓ Already up to date${NC}\n"
    else
        echo -e "${GREEN}      ✓ Pulled latest changes${NC}\n"
    fi
fi

echo -e "${GREEN}=== All Pre-Commit Checks Passed! ===${NC}"
