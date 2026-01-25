#!/bin/bash
# Create GitHub release from tag (OPTIONAL AUTOMATION)
#
# This script is entirely optional! You can create releases via the web interface:
# https://github.com/sjbylo/aba/releases/new
#
# Usage: build/create-github-release.sh <tag> [--draft]
#
# Example: build/create-github-release.sh v0.9.0
#          build/create-github-release.sh v0.9.1 --draft
#
# Requirements:
# - GitHub CLI (gh) installed and authenticated: sudo dnf install gh
# - Tag must already exist in git and be pushed to origin

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

# Check if gh is installed
if ! command -v gh &> /dev/null; then
    echo -e "${RED}Error: GitHub CLI (gh) is not installed${NC}"
    echo -e "${YELLOW}Install from: https://cli.github.com/${NC}"
    echo -e "${YELLOW}Or install via: sudo dnf install gh${NC}"
    exit 1
fi

# Check if authenticated
if ! gh auth status &> /dev/null; then
    echo -e "${RED}Error: Not authenticated with GitHub${NC}"
    echo -e "${YELLOW}Run: gh auth login${NC}"
    exit 1
fi

# Validate arguments
if [ -z "$1" ]; then
    echo -e "${RED}Usage: $0 <tag> [--draft]${NC}"
    echo -e "${YELLOW}Example: $0 v0.9.0${NC}"
    exit 1
fi

TAG="$1"
DRAFT_FLAG=""

if [ "$2" = "--draft" ]; then
    DRAFT_FLAG="--draft"
fi

# Validate tag format
if ! echo "$TAG" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo -e "${RED}Error: Invalid tag format '$TAG'${NC}"
    echo -e "${YELLOW}Expected format: v0.9.0${NC}"
    exit 1
fi

# Check if tag exists
if ! git rev-parse "$TAG" &> /dev/null; then
    echo -e "${RED}Error: Tag '$TAG' does not exist${NC}"
    echo -e "${YELLOW}Create tag first: git tag -a $TAG -m \"Release $TAG\"${NC}"
    exit 1
fi

# Extract version number (remove 'v' prefix)
VERSION="${TAG#v}"

echo -e "${CYAN}=== Creating GitHub Release ===${NC}\n"
echo -e "${YELLOW}Tag: $TAG${NC}"
echo -e "${YELLOW}Version: $VERSION${NC}"
if [ "$DRAFT_FLAG" ]; then
    echo -e "${YELLOW}Mode: Draft (for review)${NC}"
else
    echo -e "${YELLOW}Mode: Published (live release)${NC}"
fi
echo

# Check if CHANGELOG.md exists and has this version
if [ ! -f CHANGELOG.md ]; then
    echo -e "${RED}Error: CHANGELOG.md not found${NC}"
    exit 1
fi

# Extract release notes from CHANGELOG.md
echo -e "${YELLOW}Extracting release notes from CHANGELOG.md...${NC}"

# Find the section for this version
RELEASE_NOTES=$(sed -n "/^## \[$VERSION\]/,/^---$/p" CHANGELOG.md | sed '1d;$d' | sed '/^$/d')

if [ -z "$RELEASE_NOTES" ]; then
    echo -e "${RED}Error: No release notes found for version $VERSION in CHANGELOG.md${NC}"
    echo -e "${YELLOW}Expected section: ## [$VERSION]${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Found release notes for $VERSION${NC}\n"

# Show preview
echo -e "${CYAN}Release Notes Preview:${NC}"
echo "---"
echo "$RELEASE_NOTES"
echo "---"
echo

# Confirm
if [ ! "$DRAFT_FLAG" ]; then
    echo -e "${YELLOW}This will create a PUBLISHED release. Continue? [y/N]:${NC} "
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Cancelled${NC}"
        exit 0
    fi
fi

# Create release
echo -e "${YELLOW}Creating GitHub release...${NC}"

# Save release notes to temp file
TEMP_NOTES=$(mktemp)
echo "$RELEASE_NOTES" > "$TEMP_NOTES"

# Create the release
if [ "$DRAFT_FLAG" ]; then
    gh release create "$TAG" \
        --title "Aba $TAG" \
        --notes-file "$TEMP_NOTES" \
        --draft
    echo -e "${GREEN}✓ Draft release created: $TAG${NC}"
    echo -e "${CYAN}Review and publish at: https://github.com/sjbylo/aba/releases${NC}"
else
    gh release create "$TAG" \
        --title "Aba $TAG" \
        --notes-file "$TEMP_NOTES" \
        --latest
    echo -e "${GREEN}✓ Release published: $TAG${NC}"
    echo -e "${CYAN}View at: https://github.com/sjbylo/aba/releases/tag/$TAG${NC}"
fi

# Cleanup
rm -f "$TEMP_NOTES"

echo
echo -e "${GREEN}=== GitHub Release Created! ===${NC}"
