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
#   --update-build     Stamp ABA_BUILD timestamp into scripts/aba.sh.
#                      Without this flag, the build stamp is NOT modified
#                      (safe for standalone validation runs).
#   --skip-version     Legacy alias: opposite sense -- skips stamp (no-op
#                      now that stamp is opt-in, kept for compatibility).
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
UPDATE_BUILD=false
RELEASE_BRANCH=false
for arg in "$@"; do
    case "$arg" in
        --update-build)   UPDATE_BUILD=true ;;
        --skip-version)   ;;  # Legacy no-op (stamp is now opt-in)
        --release-branch) RELEASE_BRANCH=true ;;
    esac
done

# =============================================================================
# Step 1: Update ABA_BUILD timestamp
# =============================================================================
# ABA_BUILD is a YYYYMMDDHHMMSS timestamp embedded in scripts/aba.sh.
# It lets users (and support) see exactly when the installed binary was built.
# Only updated with --update-build (called by release.sh or explicit commit flow).
if $UPDATE_BUILD; then
    echo -e "${YELLOW}[1/5] Updating ABA_BUILD timestamp...${NC}"
    new_build=$(date +%Y%m%d%H%M%S)
    sed -i "s/^ABA_BUILD=.*/ABA_BUILD=$new_build/g" scripts/aba.sh
    echo -e "${GREEN}      ✓ ABA_BUILD = $new_build${NC}\n"
else
    echo -e "${YELLOW}[1/5] Skipping BUILD timestamp (use --update-build to stamp)${NC}\n"
fi

# Guard: ABA_VERSION must be semver (e.g. 1.0.0, 2.1.3-rc1) -- catches merge corruption
_aba_ver=$(grep '^ABA_VERSION=' scripts/aba.sh | head -1 | cut -d= -f2)
if ! echo "$_aba_ver" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+'; then
    echo -e "${RED}      ✗ ABA_VERSION is not semver: '$_aba_ver'${NC}"
    echo -e "${RED}        This usually means a merge overwrote the version.${NC}"
    echo -e "${RED}        Fix: set ABA_VERSION=X.Y.Z in scripts/aba.sh${NC}\n"
    exit 1
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

# =============================================================================
# Step 6: Lint aba_warning / aba_abort usage
# =============================================================================
# Detects consecutive aba_warning or aba_abort calls that should be combined
# into a single call with follow-up lines as extra arguments.
# Correct:   aba_warning "Main message" "Follow-up line"
# Wrong:     aba_warning "Line 1"
#            aba_warning "Line 2"   <-- should be a follow-up arg, not a new call
#
# Exceptions: lines with -p flag (different prefix) or continuation lines (\)
# are not flagged.
echo -e "${YELLOW}[6/6] Checking aba_warning/aba_abort usage patterns...${NC}"
_lint_failed=0

for script in scripts/*.sh; do
    [ -f "$script" ] || continue
    prev_line=0
    prev_fn=""
    while IFS=: read -r linenum content; do
        # Strip leading whitespace from content
        content="${content#"${content%%[![:space:]]*}"}"
        # Get function name (aba_warning or aba_abort)
        fn="${content%% *}"
        # Skip lines with -p flag (different prefix = intentionally separate)
        if [[ "$content" == *" -p "* ]]; then
            prev_line=0; prev_fn=""; continue
        fi
        # Skip continuation lines (previous source line ends with \)
        if [[ "$content" == *'\' ]]; then
            prev_line=0; prev_fn=""; continue
        fi
        # Check for consecutive same-function calls (within 2 source lines)
        if [ "$prev_fn" = "$fn" ] && [ $((linenum - prev_line)) -le 2 ]; then
            echo -e "  ${RED}$script:$linenum: consecutive '$fn' calls (combine with follow-up args)${NC}"
            _lint_failed=1
        fi
        prev_line=$linenum
        prev_fn="$fn"
    done < <(grep -n '^\s*aba_warning\b\|^\s*aba_abort\b' "$script" 2>/dev/null)
done

if [ $_lint_failed -eq 1 ]; then
    echo -e "${RED}      ✗ Found consecutive aba_warning/aba_abort calls that should be combined${NC}"
    echo -e "${RED}        Use: aba_warning \"Main message\" \"Follow-up line\" (multi-arg form)${NC}\n"
    exit 1
fi

echo -e "${GREEN}      ✓ aba_warning/aba_abort usage OK${NC}\n"

# =============================================================================
# Step 7: Verify README.md permalink anchors (only if README.md changed)
# =============================================================================
# README.md contains <a id="..."> permalink anchors referenced by external
# articles (Red Hat Developers blog, bundle README_FIRST.md, etc.).
# The HTML comment block at the top of README.md lists every inbound link
# as #anchor-name.  This step extracts those anchors and verifies each one
# still has a matching <a id="anchor-name"> in the file body.
# Only runs when README.md has staged or unstaged changes.
_readme_changed=""
git diff --name-only -- README.md 2>/dev/null | grep -q '^README.md$' && _readme_changed=1
git diff --cached --name-only -- README.md 2>/dev/null | grep -q '^README.md$' && _readme_changed=1

if [ "$_readme_changed" ]; then
    echo -e "${YELLOW}[7/7] Verifying README.md permalink anchors...${NC}"
    _anchor_missing=0
    while IFS= read -r _anchor; do
        [ -z "$_anchor" ] && continue
        if ! grep -q "<a id=\"$_anchor\">" README.md; then
            echo -e "  ${RED}✗ Missing permalink anchor: <a id=\"$_anchor\">${NC}"
            _anchor_missing=1
        fi
    done < <(sed -n '1,/^-->/p' README.md | grep -oE '#[a-z0-9][-a-z0-9]*' | sed 's/^#//' | sort -u)

    if [ $_anchor_missing -eq 1 ]; then
        echo -e "${RED}      ✗ README.md permalink anchors are broken!${NC}"
        echo -e "${RED}        External articles link to these anchors — do NOT remove them.${NC}"
        echo -e "${RED}        See the HTML comment block at the top of README.md for details.${NC}\n"
        exit 1
    fi
    echo -e "${GREEN}      ✓ All README.md permalink anchors verified${NC}\n"
else
    echo -e "${YELLOW}[7/7] Skipping README.md permalink check (file not changed)${NC}\n"
fi

echo -e "${GREEN}=== All Pre-Commit Checks Passed! ===${NC}"
