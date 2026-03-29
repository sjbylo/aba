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
    echo -e "${YELLOW}Install with:${NC}"
    echo -e "  sudo dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo"
    echo -e "  sudo dnf install gh -y"
    echo -e "  gh auth login"
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

# Release bullets file provides the user-facing GitHub release body.
# Format: one-liner summary on line 1, then ### sections with bullets.
RELEASE_BULLETS_FILE="ai/RELEASE_BULLETS_${VERSION}.md"
if [ ! -f "$RELEASE_BULLETS_FILE" ]; then
    echo -e "${RED}Error: Release bullets file not found: $RELEASE_BULLETS_FILE${NC}"
    echo -e "${YELLOW}Create the file with user-facing release highlights before running this script.${NC}"
    echo -e "${YELLOW}Format: one-liner summary on line 1, then ### sections with bullet points.${NC}"
    echo -e "${YELLOW}See ai/RELEASE_BULLETS_0.9.7.md for an example.${NC}"
    exit 1
fi
if [ ! -s "$RELEASE_BULLETS_FILE" ]; then
    echo -e "${RED}Error: Release bullets file is empty: $RELEASE_BULLETS_FILE${NC}"
    exit 1
fi

RELEASE_NOTES=$(cat "$RELEASE_BULLETS_FILE")
echo -e "${GREEN}✓ Loaded release notes from $RELEASE_BULLETS_FILE${NC}\n"

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

if [ "$DRAFT_FLAG" ]; then
    gh release create "$TAG" \
        --title "Aba $TAG" \
        --notes-file "$RELEASE_BULLETS_FILE" \
        --draft
    echo -e "${GREEN}✓ Draft release created: $TAG${NC}"
    echo -e "${CYAN}Review and publish at: https://github.com/sjbylo/aba/releases${NC}"
else
    gh release create "$TAG" \
        --title "Aba $TAG" \
        --notes-file "$RELEASE_BULLETS_FILE" \
        --latest
    echo -e "${GREEN}✓ Release published: $TAG${NC}"
    echo -e "${CYAN}View at: https://github.com/sjbylo/aba/releases/tag/$TAG${NC}"
fi

echo
echo -e "${GREEN}=== GitHub Release Created! ===${NC}"
