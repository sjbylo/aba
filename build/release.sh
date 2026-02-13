#!/bin/bash
# Release script for aba
# Usage: build/release.sh [--dry-run] <version> "<release description>"
#
# Examples:
#   build/release.sh 0.9.4 "Bug fixes and improvements"
#   build/release.sh --dry-run 0.9.4 "New features"
#
# Options:
#   --dry-run   Show what would happen without making any changes.
#
# This script runs on the dev branch and:
# 1. Validates inputs and pre-conditions (CHANGELOG, clean tree, tag, branch)
# 2. Runs pre-commit checks (RPM sync, syntax, git pull)
# 3. Updates VERSION file
# 4. Embeds version in scripts/aba.sh
# 5. Updates version references in README.md
# 6. Updates CHANGELOG.md
# 7. Commits changes
# 8. Creates git tag
# 9. Verifies the tagged commit has correct version data
# 10. Shows commands to push and merge to main
#
# After running this script, merge dev to main:
#   git push origin dev && git push origin v<VERSION>
#   git checkout main && git merge --no-ff dev && git push origin main && git checkout dev
#
# Exit codes:
#   0 = Success
#   1 = Error

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Find ABA_ROOT
cd "$(dirname "$0")/.." || exit 1
ABA_ROOT="$(pwd)"

# --- Parse arguments ---
# Extract --dry-run flag from anywhere in the argument list
DRY_RUN=false
ARGS=()
for arg in "$@"; do
    if [ "$arg" = "--dry-run" ]; then
        DRY_RUN=true
    else
        ARGS+=("$arg")
    fi
done

# Reassign positional args (without --dry-run)
set -- "${ARGS[@]}"

# Validate arguments
if [ -z "$1" ] || [ -z "$2" ]; then
    echo -e "${RED}Usage: $0 [--dry-run] <version> \"<release description>\"${NC}"
    echo -e "${YELLOW}Example: $0 0.9.4 \"Bug fixes and improvements\"${NC}"
    echo -e "${YELLOW}Example: $0 --dry-run 0.9.4 \"New features\"${NC}"
    exit 1
fi

NEW_VERSION="$1"
RELEASE_DESC="$2"

# Validate version format (semver: MAJOR.MINOR.PATCH)
if ! echo "$NEW_VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo -e "${RED}Error: Invalid version format '$NEW_VERSION'${NC}"
    echo -e "${YELLOW}Expected format: MAJOR.MINOR.PATCH (e.g., 0.9.4)${NC}"
    exit 1
fi

# --- Header ---
if $DRY_RUN; then
    echo -e "${CYAN}=== Aba Release Process (DRY RUN — no changes will be made) ===${NC}\n"
else
    echo -e "${CYAN}=== Aba Release Process ===${NC}\n"
fi
echo -e "${YELLOW}New version: $NEW_VERSION${NC}"
echo -e "${YELLOW}Description: $RELEASE_DESC${NC}"

# --- Pre-flight checks (read-only, safe for dry-run) ---

# Must be on dev branch
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" != "dev" ]; then
    echo -e "${RED}Error: Must be on 'dev' branch (currently on '$CURRENT_BRANCH')${NC}"
    exit 1
fi

# Check if tag already exists (prevents mid-script failure after changes are committed)
if git rev-parse "v$NEW_VERSION" >/dev/null 2>&1; then
    echo -e "${RED}Error: Tag v$NEW_VERSION already exists${NC}"
    echo -e "${YELLOW}Delete it first with: git tag -d v$NEW_VERSION && git push origin --delete v$NEW_VERSION${NC}"
    exit 1
fi

# Check for uncommitted changes (skip in dry-run mode since no changes will be made)
if ! $DRY_RUN && ! git diff-index --quiet HEAD --; then
    echo -e "${RED}Error: You have uncommitted changes. Commit or stash them first.${NC}"
    git status --short
    exit 1
fi

# Check CHANGELOG has unreleased content BEFORE making any changes (safe early exit)
UNRELEASED_CONTENT=$(sed -n '/^## \[Unreleased\]/,/^---$/p' CHANGELOG.md | sed '1d;$d')
if [ -z "$UNRELEASED_CONTENT" ]; then
    echo -e "${RED}Error: No unreleased changes found in CHANGELOG.md${NC}"
    echo -e "${YELLOW}Add entries under '## [Unreleased]' in CHANGELOG.md first.${NC}"
    exit 1
fi
echo -e "${GREEN}CHANGELOG [Unreleased] section has content${NC}\n"

# --- Dry-run: show summary and exit ---
if $DRY_RUN; then
    echo -e "${CYAN}--- Dry Run Summary ---${NC}\n"

    echo -e "${YELLOW}  - Pre-commit checks (RPM sync, syntax, pull)${NC}"
    echo -e "${YELLOW}  - Version-bump commit on dev${NC}"
    echo -e "${YELLOW}  - Tag v$NEW_VERSION on dev${NC}"

    echo
    echo -e "${YELLOW}Files that would be modified:${NC}"
    echo -e "  VERSION              -> $NEW_VERSION"
    echo -e "  scripts/aba.sh       -> ABA_VERSION=$NEW_VERSION"
    echo -e "  README.md            -> version refs updated to v$NEW_VERSION"
    echo -e "  CHANGELOG.md         -> [Unreleased] moved to [$NEW_VERSION]"

    echo
    echo -e "${YELLOW}CHANGELOG [Unreleased] content to be released:${NC}"
    echo "$UNRELEASED_CONTENT" | head -20
    TOTAL_LINES=$(echo "$UNRELEASED_CONTENT" | wc -l)
    if [ "$TOTAL_LINES" -gt 20 ]; then
        echo -e "  ${YELLOW}... ($((TOTAL_LINES - 20)) more lines)${NC}"
    fi

    echo
    echo -e "${GREEN}=== Dry run complete. No changes were made. ===${NC}"
    exit 0
fi

# =====================================================================
# Beyond this point, changes are made. Dry-run has already exited above.
# =====================================================================

TOTAL=9

# --- Step 1: Pre-commit checks (runs BEFORE any file changes, so git pull is safe) ---
echo -e "${YELLOW}[1/$TOTAL] Running pre-commit checks...${NC}"
build/pre-commit-checks.sh
echo

# --- Step 2-5: Version bump ---
echo -e "${YELLOW}[2/$TOTAL] Updating VERSION file...${NC}"
echo "$NEW_VERSION" > VERSION
echo -e "${GREEN}       ✓ VERSION updated to $NEW_VERSION${NC}\n"

echo -e "${YELLOW}[3/$TOTAL] Embedding version in scripts/aba.sh...${NC}"
# Handle both quoted (ABA_VERSION="...") and unquoted (ABA_VERSION=...) formats
sed -i "s/^ABA_VERSION=.*/ABA_VERSION=$NEW_VERSION/" scripts/aba.sh
echo -e "${GREEN}       ✓ scripts/aba.sh now contains ABA_VERSION=$NEW_VERSION${NC}\n"

echo -e "${YELLOW}[4/$TOTAL] Updating version references in README.md...${NC}"
sed -i "s|/tags/v[0-9]*\.[0-9]*\.[0-9]*\.tar\.gz|/tags/v$NEW_VERSION.tar.gz|g" README.md
sed -i "s|tar xzf v[0-9]*\.[0-9]*\.[0-9]*\.tar\.gz|tar xzf v$NEW_VERSION.tar.gz|g" README.md
sed -i "s|cd aba-[0-9]*\.[0-9]*\.[0-9]*|cd aba-$NEW_VERSION|g" README.md
sed -i "s|--branch v[0-9]*\.[0-9]*\.[0-9]*|--branch v$NEW_VERSION|g" README.md
echo -e "${GREEN}       ✓ README.md version references updated to $NEW_VERSION${NC}\n"

echo -e "${YELLOW}[5/$TOTAL] Updating CHANGELOG.md...${NC}"
# UNRELEASED_CONTENT was already validated at the top of the script

# Get today's date
TODAY=$(date +%Y-%m-%d)

# Create new release section
NEW_RELEASE_SECTION="## [$NEW_VERSION] - $TODAY

$RELEASE_DESC

$UNRELEASED_CONTENT"

# Update CHANGELOG.md: Clear [Unreleased], add new release
{
    echo "## [Unreleased]"
    echo ""
    echo "---"
    echo ""
    echo "$NEW_RELEASE_SECTION"
    echo ""
    echo "---"
    sed -n '/^---$/,$p' CHANGELOG.md | tail -n +2
} > CHANGELOG.md.tmp && mv CHANGELOG.md.tmp CHANGELOG.md

# Update version links at bottom
sed -i "s|\[Unreleased\]:.*|[Unreleased]: https://github.com/sjbylo/aba/compare/v$NEW_VERSION...HEAD|" CHANGELOG.md
sed -i "/^\[Unreleased\]:/a [$NEW_VERSION]: https://github.com/sjbylo/aba/releases/tag/v$NEW_VERSION" CHANGELOG.md

echo -e "${GREEN}       ✓ CHANGELOG.md updated${NC}\n"

# --- Step 6-7: Commit and tag ---
echo -e "${YELLOW}[6/$TOTAL] Staging and committing...${NC}"
git add VERSION CHANGELOG.md README.md scripts/aba.sh
git commit -m "release: Bump version to $NEW_VERSION

$RELEASE_DESC

Release notes:
- See CHANGELOG.md for full details"
echo -e "${GREEN}       ✓ Commit created${NC}\n"

echo -e "${YELLOW}[7/$TOTAL] Creating git tag v$NEW_VERSION...${NC}"
git tag -a "v$NEW_VERSION" -m "Release v$NEW_VERSION: $RELEASE_DESC"
echo -e "${GREEN}       ✓ Tag created: v$NEW_VERSION${NC}\n"

# --- Step 8: Post-release verification ---
# Verify the tagged commit has the correct version data.
# This catches issues like sed patterns not matching or wrong files being committed.
echo -e "${YELLOW}[8/$TOTAL] Verifying tagged release v$NEW_VERSION...${NC}"
VERIFY_OK=true

# Check VERSION file at the tag
TAG_VERSION=$(git show "v$NEW_VERSION:VERSION" 2>/dev/null | tr -d '[:space:]')
if [ "$TAG_VERSION" = "$NEW_VERSION" ]; then
    echo -e "${GREEN}       ✓ VERSION file: $TAG_VERSION${NC}"
else
    echo -e "${RED}       ✗ VERSION file: expected '$NEW_VERSION', got '$TAG_VERSION'${NC}"
    VERIFY_OK=false
fi

# Check ABA_VERSION in aba.sh at the tag
TAG_ABA_VER=$(git show "v$NEW_VERSION:scripts/aba.sh" 2>/dev/null | grep "^ABA_VERSION=" | cut -d= -f2)
if [ "$TAG_ABA_VER" = "$NEW_VERSION" ]; then
    echo -e "${GREEN}       ✓ ABA_VERSION in aba.sh: $TAG_ABA_VER${NC}"
else
    echo -e "${RED}       ✗ ABA_VERSION in aba.sh: expected '$NEW_VERSION', got '$TAG_ABA_VER'${NC}"
    VERIFY_OK=false
fi

# Check CHANGELOG has the version section
if git show "v$NEW_VERSION:CHANGELOG.md" 2>/dev/null | grep -q "^## \[$NEW_VERSION\]"; then
    echo -e "${GREEN}       ✓ CHANGELOG.md has [$NEW_VERSION] section${NC}"
else
    echo -e "${RED}       ✗ CHANGELOG.md missing [$NEW_VERSION] section${NC}"
    VERIFY_OK=false
fi

# Check README has the version in download URLs
if git show "v$NEW_VERSION:README.md" 2>/dev/null | grep -q "v$NEW_VERSION"; then
    echo -e "${GREEN}       ✓ README.md references v$NEW_VERSION${NC}"
else
    echo -e "${RED}       ✗ README.md does not reference v$NEW_VERSION${NC}"
    VERIFY_OK=false
fi

if $VERIFY_OK; then
    echo -e "${GREEN}       ✓ All verification checks passed${NC}\n"
else
    echo -e "${RED}       ✗ Verification FAILED — review the tag before pushing!${NC}\n"
fi

# --- Step 9: Show next steps ---
echo -e "${GREEN}=== Release v$NEW_VERSION Ready! ===${NC}\n"

echo -e "${CYAN}[9/$TOTAL] Next steps:${NC}"
echo -e "${YELLOW}1. Review the changes:${NC}"
echo -e "   git show HEAD"
echo -e "   git show v$NEW_VERSION"
echo

echo -e "${YELLOW}2. Push dev and tag:${NC}"
echo -e "   git push origin dev"
echo -e "   git push origin v$NEW_VERSION"
echo

echo -e "${YELLOW}3. Merge to main:${NC}"
echo -e "   git checkout main && git merge --no-ff dev && git push origin main && git checkout dev"
echo

echo -e "${YELLOW}4. Create GitHub release:${NC}"
echo
echo -e "   ${CYAN}Automated (recommended, requires 'gh' CLI):${NC}"
echo -e "   build/create-github-release.sh v$NEW_VERSION"
echo
echo -e "   ${CYAN}Alternative: Web Interface${NC}"
echo -e "   https://github.com/sjbylo/aba/releases/new?tag=v$NEW_VERSION"
echo
echo -e "${CYAN}See build/RELEASE_WORKFLOW.md for complete instructions.${NC}"
