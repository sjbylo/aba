#!/bin/bash
# Release script for aba
# Usage: build/release.sh <version> "<release description>" [<commit-ref>]
#
# Examples:
#   build/release.sh 0.9.2 "Bug fixes and improvements"            # release from HEAD on dev
#   build/release.sh 0.9.2 "Bug fixes and improvements" 76c9bfc    # release from specific commit
#
# Without <commit-ref>:
#   Works on the current dev branch (existing behavior).
#   Updates VERSION, aba.sh, README.md, CHANGELOG.md, commits, and tags on dev.
#
# With <commit-ref>:
#   Merges <commit-ref> into main, applies version-bump commit there, and tags.
#   Then prints instructions to push main and merge the version bump back into dev.
#
# This script:
# 1. Validates version format
# 2. Updates VERSION file
# 3. Embeds version in scripts/aba.sh
# 4. Updates version references in README.md
# 5. Updates CHANGELOG.md
# 6. Runs pre-commit checks
# 7. Commits changes
# 8. Creates git tag
# 9. Shows commands to push
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

# Validate arguments
if [ -z "$1" ] || [ -z "$2" ]; then
    echo -e "${RED}Usage: $0 <version> \"<release description>\" [<commit-ref>]${NC}"
    echo -e "${YELLOW}Example: $0 0.9.2 \"Bug fixes and improvements\"${NC}"
    echo -e "${YELLOW}Example: $0 0.9.2 \"Bug fixes and improvements\" 76c9bfc${NC}"
    exit 1
fi

NEW_VERSION="$1"
RELEASE_DESC="$2"
RELEASE_REF="${3:-}"  # Optional: specific commit/ref to release

# Validate version format (semver: MAJOR.MINOR.PATCH)
if ! echo "$NEW_VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo -e "${RED}Error: Invalid version format '$NEW_VERSION'${NC}"
    echo -e "${YELLOW}Expected format: MAJOR.MINOR.PATCH (e.g., 0.9.2)${NC}"
    exit 1
fi

echo -e "${CYAN}=== Aba Release Process ===${NC}\n"
echo -e "${YELLOW}New version: $NEW_VERSION${NC}"
echo -e "${YELLOW}Description: $RELEASE_DESC${NC}"

# Check for uncommitted changes
if ! git diff-index --quiet HEAD --; then
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

# --- Determine release mode ---
if [ -n "$RELEASE_REF" ]; then
    # --- Ref mode: merge specific commit into main, version-bump there ---
    echo -e "${YELLOW}Release ref: $RELEASE_REF${NC}\n"

    # Validate the ref exists
    if ! git rev-parse --verify "$RELEASE_REF" >/dev/null 2>&1; then
        echo -e "${RED}Error: Ref '$RELEASE_REF' does not exist${NC}"
        exit 1
    fi

    RESOLVED_REF=$(git rev-parse --short "$RELEASE_REF")
    echo -e "${YELLOW}Resolved ref: $RESOLVED_REF ($(git log -1 --format='%s' "$RELEASE_REF"))${NC}\n"

    # Remember where we started so we can return
    STARTING_BRANCH=$(git branch --show-current)
    if [ -z "$STARTING_BRANCH" ]; then
        echo -e "${RED}Error: Not on a branch (detached HEAD). Checkout a branch first.${NC}"
        exit 1
    fi

    # Switch to main and merge the ref
    echo -e "${YELLOW}[1/10] Switching to main and merging $RESOLVED_REF...${NC}"
    git checkout main
    git merge --no-ff "$RELEASE_REF" -m "Merge $RESOLVED_REF for release v$NEW_VERSION"
    echo -e "${GREEN}       ✓ Merged $RESOLVED_REF into main${NC}\n"

    RELEASE_BRANCH="main"
    STEP_OFFSET=1  # Extra step for the merge
else
    # --- HEAD mode: release from current dev branch ---
    echo -e ""

    CURRENT_BRANCH=$(git branch --show-current)
    if [ "$CURRENT_BRANCH" != "dev" ]; then
        echo -e "${RED}Error: Must be on 'dev' branch (currently on '$CURRENT_BRANCH')${NC}"
        echo -e "${YELLOW}Hint: Use a commit ref as 3rd argument to release from a specific commit.${NC}"
        exit 1
    fi

    STARTING_BRANCH="dev"
    RELEASE_BRANCH="dev"
    STEP_OFFSET=0
fi

# --- Common release steps (run on whichever branch we're on) ---

STEP=$((2 + STEP_OFFSET))
TOTAL=$((9 + STEP_OFFSET))

echo -e "${YELLOW}[$STEP/$TOTAL] Updating VERSION file...${NC}"
echo "$NEW_VERSION" > VERSION
echo -e "${GREEN}       ✓ VERSION updated to $NEW_VERSION${NC}\n"

STEP=$((STEP + 1))
echo -e "${YELLOW}[$STEP/$TOTAL] Embedding version in scripts/aba.sh...${NC}"
# Handle both quoted (ABA_VERSION="...") and unquoted (ABA_VERSION=...) formats
sed -i "s/^ABA_VERSION=.*/ABA_VERSION=$NEW_VERSION/" scripts/aba.sh
echo -e "${GREEN}       ✓ scripts/aba.sh now contains ABA_VERSION=$NEW_VERSION${NC}\n"

STEP=$((STEP + 1))
echo -e "${YELLOW}[$STEP/$TOTAL] Updating version references in README.md...${NC}"
sed -i "s|/tags/v[0-9]*\.[0-9]*\.[0-9]*\.tar\.gz|/tags/v$NEW_VERSION.tar.gz|g" README.md
sed -i "s|tar xzf v[0-9]*\.[0-9]*\.[0-9]*\.tar\.gz|tar xzf v$NEW_VERSION.tar.gz|g" README.md
sed -i "s|cd aba-[0-9]*\.[0-9]*\.[0-9]*|cd aba-$NEW_VERSION|g" README.md
sed -i "s|--branch v[0-9]*\.[0-9]*\.[0-9]*|--branch v$NEW_VERSION|g" README.md
echo -e "${GREEN}       ✓ README.md version references updated to $NEW_VERSION${NC}\n"

STEP=$((STEP + 1))
echo -e "${YELLOW}[$STEP/$TOTAL] Updating CHANGELOG.md...${NC}"
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

STEP=$((STEP + 1))
echo -e "${YELLOW}[$STEP/$TOTAL] Running pre-commit checks...${NC}"
build/pre-commit-checks.sh --skip-version
echo

STEP=$((STEP + 1))
echo -e "${YELLOW}[$STEP/$TOTAL] Staging changes...${NC}"
git add VERSION CHANGELOG.md README.md scripts/aba.sh
echo -e "${GREEN}       ✓ Staged: VERSION, CHANGELOG.md, README.md, scripts/aba.sh${NC}\n"

STEP=$((STEP + 1))
echo -e "${YELLOW}[$STEP/$TOTAL] Creating commit...${NC}"
git commit -m "release: Bump version to $NEW_VERSION

$RELEASE_DESC

Release notes:
- See CHANGELOG.md for full details"
echo -e "${GREEN}       ✓ Commit created${NC}\n"

STEP=$((STEP + 1))
echo -e "${YELLOW}[$STEP/$TOTAL] Creating git tag v$NEW_VERSION...${NC}"
git tag -a "v$NEW_VERSION" -m "Release v$NEW_VERSION: $RELEASE_DESC"
echo -e "${GREEN}       ✓ Tag created: v$NEW_VERSION${NC}\n"

STEP=$((STEP + 1))
echo -e "${YELLOW}[$STEP/$TOTAL] Verifying version embedding...${NC}"
if grep -q "^ABA_VERSION=$NEW_VERSION" scripts/aba.sh; then
    echo -e "${GREEN}       ✓ Version correctly embedded in aba.sh${NC}\n"
else
    echo -e "${RED}       ✗ Version NOT embedded in aba.sh!${NC}\n"
    exit 1
fi

echo -e "${GREEN}=== Release v$NEW_VERSION Ready! ===${NC}\n"

# --- Print next steps depending on mode ---

echo -e "${CYAN}Next steps:${NC}"
echo -e "${YELLOW}1. Review the changes:${NC}"
echo -e "   git show HEAD"
echo -e "   git show v$NEW_VERSION"
echo

if [ -n "$RELEASE_REF" ]; then
    # Ref mode: we're on main, need to push main + tag, then merge back to dev
    echo -e "${YELLOW}2. Push main and tag:${NC}"
    echo -e "   git push origin main"
    echo -e "   git push origin v$NEW_VERSION"
    echo
    echo -e "${YELLOW}3. Merge version bump back into dev:${NC}"
    echo -e "   git checkout $STARTING_BRANCH"
    echo -e "   git merge main"
    echo -e "   git push origin $STARTING_BRANCH"
    echo
else
    # HEAD mode: we're on dev
    echo -e "${YELLOW}2. Push to origin:${NC}"
    echo -e "   git push origin dev"
    echo -e "   git push origin v$NEW_VERSION"
    echo
    echo -e "${YELLOW}3. Merge to main:${NC}"
    echo -e "   git checkout main"
    echo -e "   git merge --no-ff dev -m \"Merge release v$NEW_VERSION\""
    echo -e "   git push origin main"
    echo -e "   git checkout dev"
    echo
fi

echo -e "${YELLOW}4. Create GitHub release (optional):${NC}"
echo
echo -e "   ${CYAN}Recommended: Web Interface (no tools needed)${NC}"
echo -e "   https://github.com/sjbylo/aba/releases/new?tag=v$NEW_VERSION"
echo -e "   - Select tag v$NEW_VERSION"
echo -e "   - Copy release notes from CHANGELOG.md"
echo -e "   - Click 'Publish release'"
echo
echo -e "   ${CYAN}Alternative: Automated script (requires 'gh' CLI)${NC}"
echo -e "   build/create-github-release.sh v$NEW_VERSION"
echo
echo -e "${CYAN}See build/RELEASE_WORKFLOW.md for complete instructions.${NC}"
