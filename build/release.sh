#!/bin/bash
# Release script for aba
# Usage: build/release.sh <version> "<release description>"
#
# Example: build/release.sh 0.9.1 "Bug fixes and improvements"
#
# This script:
# 1. Validates version format
# 2. Updates VERSION file
# 3. Updates CHANGELOG.md
# 4. Runs pre-commit checks
# 5. Commits changes
# 6. Creates git tag
# 7. Shows commands to push
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
    echo -e "${RED}Usage: $0 <version> \"<release description>\"${NC}"
    echo -e "${YELLOW}Example: $0 0.9.1 \"Bug fixes and improvements\"${NC}"
    exit 1
fi

NEW_VERSION="$1"
RELEASE_DESC="$2"

# Validate version format (semver: MAJOR.MINOR.PATCH)
if ! echo "$NEW_VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo -e "${RED}Error: Invalid version format '$NEW_VERSION'${NC}"
    echo -e "${YELLOW}Expected format: MAJOR.MINOR.PATCH (e.g., 0.9.1)${NC}"
    exit 1
fi

echo -e "${CYAN}=== Aba Release Process ===${NC}\n"
echo -e "${YELLOW}New version: $NEW_VERSION${NC}"
echo -e "${YELLOW}Description: $RELEASE_DESC${NC}\n"

# Check if on dev branch
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" != "dev" ]; then
    echo -e "${RED}Error: Must be on 'dev' branch (currently on '$CURRENT_BRANCH')${NC}"
    exit 1
fi

# Check for uncommitted changes
if ! git diff-index --quiet HEAD --; then
    echo -e "${RED}Error: You have uncommitted changes. Commit or stash them first.${NC}"
    git status --short
    exit 1
fi

echo -e "${YELLOW}[1/8] Updating VERSION file...${NC}"
echo "$NEW_VERSION" > VERSION
echo -e "${GREEN}      ✓ VERSION updated to $NEW_VERSION${NC}\n"

echo -e "${YELLOW}[2/8] Embedding version in scripts/aba.sh...${NC}"
sed -i "s/^ABA_VERSION=\".*\"/ABA_VERSION=\"$NEW_VERSION\"/" scripts/aba.sh
echo -e "${GREEN}      ✓ scripts/aba.sh now contains ABA_VERSION=\"$NEW_VERSION\"${NC}\n"

echo -e "${YELLOW}[3/8] Updating CHANGELOG.md...${NC}"
# Extract current [Unreleased] section
UNRELEASED_CONTENT=$(sed -n '/^## \[Unreleased\]/,/^---$/p' CHANGELOG.md | sed '1d;$d')

if [ -z "$UNRELEASED_CONTENT" ]; then
    echo -e "${RED}      ✗ No unreleased changes found in CHANGELOG.md${NC}"
    exit 1
fi

# Get today's date
TODAY=$(date +%Y-%m-%d)

# Create new release section
NEW_RELEASE_SECTION="## [$NEW_VERSION] - $TODAY

$RELEASE_DESC

$UNRELEASED_CONTENT"

# Update CHANGELOG.md: Clear [Unreleased], add new release
sed -i "/^## \[Unreleased\]/,/^---$/c\\
## [Unreleased]\\
\\
### Added\\
\\
### Changed\\
\\
### Fixed\\
\\
### Documentation\\
\\
---\\
\\
$NEW_RELEASE_SECTION\\
\\
---" CHANGELOG.md

# Update version links at bottom
sed -i "s|\[Unreleased\]:.*|[Unreleased]: https://github.com/sjbylo/aba/compare/v$NEW_VERSION...HEAD|" CHANGELOG.md
sed -i "/^\[Unreleased\]:/a [$NEW_VERSION]: https://github.com/sjbylo/aba/releases/tag/v$NEW_VERSION" CHANGELOG.md

echo -e "${GREEN}      ✓ CHANGELOG.md updated${NC}\n"

echo -e "${YELLOW}[4/8] Running pre-commit checks...${NC}"
build/pre-commit-checks.sh
echo

echo -e "${YELLOW}[5/8] Staging changes...${NC}"
git add VERSION CHANGELOG.md scripts/aba.sh
echo -e "${GREEN}      ✓ Staged: VERSION, CHANGELOG.md, scripts/aba.sh${NC}\n"

echo -e "${YELLOW}[6/8] Creating commit...${NC}"
git commit -m "release: Bump version to $NEW_VERSION

$RELEASE_DESC

Release notes:
- See CHANGELOG.md for full details"
echo -e "${GREEN}      ✓ Commit created${NC}\n"

echo -e "${YELLOW}[7/8] Creating git tag v$NEW_VERSION...${NC}"
git tag -a "v$NEW_VERSION" -m "Release v$NEW_VERSION: $RELEASE_DESC"
echo -e "${GREEN}      ✓ Tag created: v$NEW_VERSION${NC}\n"

echo -e "${YELLOW}[8/8] Verifying version embedding...${NC}"
if grep -q "^ABA_VERSION=\"$NEW_VERSION\"" scripts/aba.sh; then
    echo -e "${GREEN}      ✓ Version correctly embedded in aba.sh${NC}\n"
else
    echo -e "${RED}      ✗ Version NOT embedded in aba.sh!${NC}\n"
    exit 1
fi

echo -e "${GREEN}=== Release v$NEW_VERSION Ready! ===${NC}\n"

echo -e "${CYAN}Next steps:${NC}"
echo -e "${YELLOW}1. Review the changes:${NC}"
echo -e "   git show HEAD"
echo -e "   git show v$NEW_VERSION"
echo
echo -e "${YELLOW}2. Push to origin:${NC}"
echo -e "   git push origin dev"
echo -e "   git push origin v$NEW_VERSION"
echo
echo -e "${YELLOW}3. (Optional) Merge to main:${NC}"
echo -e "   git checkout main"
echo -e "   git merge --no-ff dev -m \"Merge release v$NEW_VERSION\""
echo -e "   git push origin main"
echo
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
