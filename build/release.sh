#!/bin/bash
# =============================================================================
# Release script for aba
# =============================================================================
# Automates the full release lifecycle: validation, version bump, tagging, and
# post-release verification.
#
# Three modes:
#   DEFAULT   — releases from the current tip of dev.
#   --ref     — releases from a specific (older) commit on dev, useful when
#               dev has moved ahead but you only want to ship up to a point.
#   --hotfix  — releases from the main branch.  The hotfix commit should
#               already be on main.  Script applies version bump, tags,
#               pushes main, then merges back into dev.
#
# Usage:
#   build/release.sh [--dry-run] [--ref <commit>|--hotfix] <version> "<release description>"
#
# Examples:
#   build/release.sh 0.9.4 "Bug fixes and improvements"
#   build/release.sh --dry-run 0.9.4 "New features"
#   build/release.sh --ref 87cdf93 0.9.4 "Partial release up to specific commit"
#   build/release.sh --hotfix 0.9.5 "Critical fix for X"
#
# Options:
#   --dry-run        Show what would happen without making any changes.
#   --ref <commit>   Release from a specific commit instead of dev HEAD.
#                    Creates a temporary branch, applies version bump there,
#                    tags it, then returns to dev.
#   --hotfix         Release from main.  Must be run on the main branch.
#                    Mutually exclusive with --ref.
#
# High-level flow:
#   1. Pre-flight: validate inputs, check gh CLI, CHANGELOG, clean tree, tag
#   2. Run pre-commit checks (RPM sync, syntax, git pull)
#   3-5. Update VERSION, scripts/aba.sh, README.md
#   6. Update CHANGELOG.md (move [Unreleased] -> [X.Y.Z])
#   7. Commit changes
#   8. Create annotated git tag
#   9. Verify the tagged commit has correct version data
#  10-14. Push tag, merge to main, sync dev, push dev, create GitHub release
#
# Steps 10-14 are automated with confirmation prompts before each action.
#
# Exit codes:
#   0 = Success
#   1 = Error
# =============================================================================

set -e

# --- Terminal colours (used throughout for status messages) ------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'       # No Colour — resets terminal back to default

# Prompt for confirmation before destructive steps.  Default is Yes (Enter).
confirm() {
    local msg="$1"
    echo -en "${YELLOW}$msg [Y/n]: ${NC}"
    read -r reply
    [[ -z "$reply" || "$reply" =~ ^[Yy]$ ]]
}

# Navigate to repository root (one level up from build/)
cd "$(dirname "$0")/.." || exit 1
ABA_ROOT="$(pwd)"

# =============================================================================
# Parse CLI arguments
# =============================================================================
# Flags go into named variables; everything else is collected into ARGS[]
# so we can treat them as positional args (<version> and <description>).
DRY_RUN=false
REF_COMMIT=""
HOTFIX=false
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=true ;;
        --hotfix)  HOTFIX=true ;;
        --ref)
            shift
            if [ -z "$1" ]; then
                echo -e "${RED}Error: --ref requires a commit argument${NC}"
                exit 1
            fi
            REF_COMMIT="$1"
            ;;
        *) ARGS+=("$1") ;;   # Non-flag args: version + description
    esac
    shift
done

if $HOTFIX && [ -n "$REF_COMMIT" ]; then
    echo -e "${RED}Error: --hotfix and --ref cannot be used together${NC}"
    exit 1
fi

# Re-assign so $1=version, $2=description
set -- "${ARGS[@]}"

# --- Validate positional arguments ------------------------------------------
if [ -z "$1" ] || [ -z "$2" ]; then
    echo -e "${RED}Usage: $0 [--dry-run] [--ref <commit>|--hotfix] <version> \"<release description>\"${NC}"
    echo -e "${YELLOW}Example: $0 0.9.4 \"Bug fixes and improvements\"${NC}"
    echo -e "${YELLOW}Example: $0 --dry-run 0.9.4 \"New features\"${NC}"
    echo -e "${YELLOW}Example: $0 --ref 87cdf93 0.9.4 \"Partial release\"${NC}"
    echo -e "${YELLOW}Example: $0 --hotfix 0.9.5 \"Critical fix for X\"  (run from main)${NC}"
    exit 1
fi

NEW_VERSION="$1"
RELEASE_DESC="$2"

# Enforce semantic versioning (MAJOR.MINOR.PATCH)
if ! echo "$NEW_VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo -e "${RED}Error: Invalid version format '$NEW_VERSION'${NC}"
    echo -e "${YELLOW}Expected format: MAJOR.MINOR.PATCH (e.g., 0.9.4)${NC}"
    exit 1
fi

# --- Print header -----------------------------------------------------------
HEADER_SUFFIX=""
$DRY_RUN && HEADER_SUFFIX=" (DRY RUN — no changes will be made)"
[ -n "$REF_COMMIT" ] && HEADER_SUFFIX="$HEADER_SUFFIX (--ref $REF_COMMIT)"
$HOTFIX && HEADER_SUFFIX="$HEADER_SUFFIX (--hotfix from main)"

echo -e "${CYAN}=== Aba Release Process${HEADER_SUFFIX} ===${NC}\n"
echo -e "${YELLOW}New version: $NEW_VERSION${NC}"
echo -e "${YELLOW}Description: $RELEASE_DESC${NC}"
[ -n "$REF_COMMIT" ] && echo -e "${YELLOW}Target ref:  $REF_COMMIT${NC}"

# =============================================================================
# Pre-flight checks (read-only — safe to run even in dry-run mode)
# =============================================================================

# GitHub CLI is required for creating the GitHub release at the end.
# Check early so the user doesn't discover this after 10 minutes of work.
if ! command -v gh &>/dev/null; then
    echo -e "${RED}Error: GitHub CLI (gh) is required but not installed${NC}"
    echo -e "${YELLOW}Install with:${NC}"
    echo -e "  sudo dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo"
    echo -e "  sudo dnf install gh -y"
    echo -e "  gh auth login"
    exit 1
fi
if ! gh auth status &>/dev/null 2>&1; then
    echo -e "${RED}Error: GitHub CLI (gh) is not authenticated${NC}"
    echo -e "${YELLOW}Run: gh auth login${NC}"
    exit 1
fi
echo -e "${GREEN}GitHub CLI (gh) installed and authenticated${NC}\n"

CURRENT_BRANCH=$(git branch --show-current)
if $HOTFIX; then
    if [ "$CURRENT_BRANCH" != "main" ]; then
        echo -e "${RED}Error: --hotfix must be run from 'main' branch (currently on '$CURRENT_BRANCH')${NC}"
        exit 1
    fi
else
    if [ "$CURRENT_BRANCH" != "dev" ]; then
        echo -e "${RED}Error: Must be on 'dev' branch (currently on '$CURRENT_BRANCH')${NC}"
        exit 1
    fi
fi

# When --ref is given, make sure the commit exists and is reachable from dev.
# This prevents accidentally tagging a commit on a different branch.
if [ -n "$REF_COMMIT" ]; then
    if ! git rev-parse --verify "$REF_COMMIT" >/dev/null 2>&1; then
        echo -e "${RED}Error: Ref '$REF_COMMIT' does not exist${NC}"
        exit 1
    fi
    REF_FULL=$(git rev-parse "$REF_COMMIT")
    if ! git merge-base --is-ancestor "$REF_FULL" HEAD; then
        echo -e "${RED}Error: Ref '$REF_COMMIT' ($REF_FULL) is not an ancestor of current dev HEAD${NC}"
        exit 1
    fi
    echo -e "${GREEN}Ref $REF_COMMIT is a valid ancestor of dev${NC}\n"
fi

# Catch duplicate tags early (before we commit anything), so the script
# doesn't leave a half-finished release if the tag creation fails later.
if git rev-parse "v$NEW_VERSION" >/dev/null 2>&1; then
    echo -e "${RED}Error: Tag v$NEW_VERSION already exists${NC}"
    echo -e "${YELLOW}Delete it first with: git tag -d v$NEW_VERSION && git push origin --delete v$NEW_VERSION${NC}"
    exit 1
fi

# Refuse to run with uncommitted changes (skip in dry-run since nothing is written)
# Refresh the index first to avoid false positives from stale stat cache.
git update-index --refresh >/dev/null 2>&1 || true
if ! $DRY_RUN && ! git diff-index --quiet HEAD --; then
    echo -e "${RED}Error: You have uncommitted changes. Commit or stash them first.${NC}"
    git status --short
    exit 1
fi

# CHANGELOG must have content under [Unreleased]; that content becomes the
# release notes for the new version.  Extract everything between the
# "## [Unreleased]" header and the next "---" separator.
UNRELEASED_CONTENT=$(sed -n '/^## \[Unreleased\]/,/^---$/p' CHANGELOG.md | sed '1d;$d')
if [ -z "$UNRELEASED_CONTENT" ]; then
    echo -e "${RED}Error: No unreleased changes found in CHANGELOG.md${NC}"
    echo -e "${YELLOW}Add entries under '## [Unreleased]' in CHANGELOG.md first.${NC}"
    exit 1
fi
echo -e "${GREEN}CHANGELOG [Unreleased] section has content${NC}\n"

# Release bullets file is used as the GitHub release body (user-facing summary).
# Format: plain-text one-liner on line 1, then ### sections with bullet points.
RELEASE_BULLETS_FILE="ai/RELEASE_BULLETS_${NEW_VERSION}.md"
if [ ! -f "$RELEASE_BULLETS_FILE" ]; then
    echo -e "${RED}Error: Release bullets file not found: $RELEASE_BULLETS_FILE${NC}"
    echo -e "${YELLOW}Create the file with user-facing release highlights.${NC}"
    echo -e "${YELLOW}Format: one-liner summary on line 1, then ### sections.${NC}"
    echo -e "${YELLOW}See ai/RELEASE_BULLETS_0.9.7.md for an example.${NC}"
    exit 1
fi
if [ ! -s "$RELEASE_BULLETS_FILE" ]; then
    echo -e "${RED}Error: Release bullets file is empty: $RELEASE_BULLETS_FILE${NC}"
    exit 1
fi
echo -e "${GREEN}Release bullets file found: $RELEASE_BULLETS_FILE${NC}\n"

# =============================================================================
# Dry-run: show a summary then exit — nothing is written to disk or git.
# =============================================================================
if $DRY_RUN; then
    echo -e "${CYAN}--- Dry Run Summary ---${NC}\n"

    echo -e "${YELLOW}Steps 1-9 (build):${NC}"
    if $HOTFIX; then
        echo -e "   1. Pre-commit checks (hotfix on main; skip branch/pull checks)"
    elif [ -n "$REF_COMMIT" ]; then
        echo -e "   1. Pre-commit checks (RPM sync, syntax; skip pull)"
        echo -e "      Create temp branch _release-v$NEW_VERSION from $REF_COMMIT"
    else
        echo -e "   1. Pre-commit checks (RPM sync, syntax)"
    fi
    echo -e "   2-5. Update VERSION, aba.sh, README.md"
    echo -e "   6. Update CHANGELOG.md ([Unreleased] -> [$NEW_VERSION])"
    echo -e "   7. Commit version bump"
    echo -e "   8. Tag v$NEW_VERSION"
    echo -e "   9. Verify tagged commit"

    echo
    echo -e "${YELLOW}Steps 10-14 (publish, each with confirmation):${NC}"
    echo -e "  10. Push tag v$NEW_VERSION to origin"
    if $HOTFIX; then
        echo -e "  11. Push main (hotfix already committed on main)"
        echo -e "  12. Checkout dev, merge main into dev (sync hotfix)"
    elif [ -n "$REF_COMMIT" ]; then
        echo -e "  11. Checkout main, merge tag, push"
        echo -e "  12. Merge main back into dev (sync version bump)"
    else
        echo -e "  11. Checkout main, merge dev, push"
        echo -e "  12. (skipped — default mode, dev already has version bump)"
    fi
    echo -e "  13. Push dev to origin"
    echo -e "  14. Create GitHub release via gh CLI"

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

# =============================================================================
# Real release — beyond this point every step mutates the working tree or git.
# Dry-run has already exited above.
# =============================================================================

TOTAL=14                                      # Total steps (for [N/$TOTAL] labels)
RELEASE_BRANCH_NAME="_release-v$NEW_VERSION"  # Temp branch name used with --ref

# -----------------------------------------------------------------------------
# Step 1: Pre-commit checks
# -----------------------------------------------------------------------------
# In --ref mode we:
#   a) Save dev's CHANGELOG and pre-commit script to a temp dir (they may be
#      newer than the target commit and are needed on the temp branch).
#   b) Create a temporary branch from the target commit.
#   c) Copy those saved files onto the temp branch.
#   d) Run pre-commit checks with --release-branch (skips branch and pull checks).
#
# In default mode we simply run pre-commit checks on dev as-is.
if [ -n "$REF_COMMIT" ]; then
    echo -e "${YELLOW}[1/$TOTAL] Creating temp branch from $REF_COMMIT and running pre-commit checks...${NC}"
    _tmp="/tmp/_aba_release_$$"
    mkdir -p "$_tmp"
    cp CHANGELOG.md "$_tmp/"
    cp build/pre-commit-checks.sh "$_tmp/"
    git checkout -b "$RELEASE_BRANCH_NAME" "$REF_COMMIT"
    cp "$_tmp/CHANGELOG.md" CHANGELOG.md
    cp "$_tmp/pre-commit-checks.sh" build/pre-commit-checks.sh
    rm -rf "$_tmp"
    build/pre-commit-checks.sh --release-branch
elif $HOTFIX; then
    echo -e "${YELLOW}[1/$TOTAL] Running pre-commit checks (hotfix on main)...${NC}"
    build/pre-commit-checks.sh --release-branch
else
    echo -e "${YELLOW}[1/$TOTAL] Running pre-commit checks...${NC}"
    build/pre-commit-checks.sh
fi
echo

# -----------------------------------------------------------------------------
# Step 2: Update VERSION file
# -----------------------------------------------------------------------------
# VERSION is a single-line file read by various scripts to know the current
# release; it's the canonical source of truth for the version number.
echo -e "${YELLOW}[2/$TOTAL] Updating VERSION file...${NC}"
echo "$NEW_VERSION" > VERSION
echo -e "${GREEN}       ✓ VERSION updated to $NEW_VERSION${NC}\n"

# -----------------------------------------------------------------------------
# Step 3: Embed version in scripts/aba.sh
# -----------------------------------------------------------------------------
# scripts/aba.sh has an ABA_VERSION= line that gets printed on --version and
# used at runtime.  We patch it in-place with sed.
echo -e "${YELLOW}[3/$TOTAL] Embedding version in scripts/aba.sh...${NC}"
sed -i "s/^ABA_VERSION=.*/ABA_VERSION=$NEW_VERSION/" scripts/aba.sh
echo -e "${GREEN}       ✓ scripts/aba.sh now contains ABA_VERSION=$NEW_VERSION${NC}\n"

# -----------------------------------------------------------------------------
# Step 4: Update version references in README.md
# -----------------------------------------------------------------------------
# README has download URLs like /tags/vX.Y.Z.tar.gz, extraction commands like
# "tar xzf vX.Y.Z.tar.gz", "cd aba-X.Y.Z", and git clone --branch vX.Y.Z.
# Each sed replaces the old version pattern with the new one.
echo -e "${YELLOW}[4/$TOTAL] Updating version references in README.md...${NC}"
sed -i "s|/tags/v[0-9]*\.[0-9]*\.[0-9]*\.tar\.gz|/tags/v$NEW_VERSION.tar.gz|g" README.md
sed -i "s|tar xzf v[0-9]*\.[0-9]*\.[0-9]*\.tar\.gz|tar xzf v$NEW_VERSION.tar.gz|g" README.md
sed -i "s|cd aba-[0-9]*\.[0-9]*\.[0-9]*|cd aba-$NEW_VERSION|g" README.md
sed -i "s|--branch v[0-9]*\.[0-9]*\.[0-9]*|--branch v$NEW_VERSION|g" README.md
echo -e "${GREEN}       ✓ README.md version references updated to $NEW_VERSION${NC}\n"

# -----------------------------------------------------------------------------
# Step 5: Update CHANGELOG.md
# -----------------------------------------------------------------------------
# Transforms CHANGELOG from:
#   ## [Unreleased]
#   <content>
#   ---
#   ## [prev] ...
#
# Into:
#   ## [Unreleased]          <-- empty, ready for next cycle
#   ---
#   ## [NEW_VERSION] - DATE
#   <description>
#   <content>                <-- the old unreleased items
#   ---
#   ## [prev] ...
#
# Also updates the comparison/link URLs at the bottom of the file.
echo -e "${YELLOW}[5/$TOTAL] Updating CHANGELOG.md...${NC}"

TODAY=$(date +%Y-%m-%d)

NEW_RELEASE_SECTION="## [$NEW_VERSION] - $TODAY

$RELEASE_DESC

$UNRELEASED_CONTENT"

{
    echo "## [Unreleased]"
    echo ""
    echo "---"
    echo ""
    echo "$NEW_RELEASE_SECTION"
    echo ""
    echo "---"
    # Append everything after the first "---" in the original file
    # (i.e. all previous release sections).
    sed -n '/^---$/,$p' CHANGELOG.md | tail -n +2
} > CHANGELOG.md.tmp && mv CHANGELOG.md.tmp CHANGELOG.md

# Point [Unreleased] comparison link at HEAD vs the new tag
sed -i "s|\[Unreleased\]:.*|[Unreleased]: https://github.com/sjbylo/aba/compare/v$NEW_VERSION...HEAD|" CHANGELOG.md
# Add a release link for the new version right after the [Unreleased] link
sed -i "/^\[Unreleased\]:/a [$NEW_VERSION]: https://github.com/sjbylo/aba/releases/tag/v$NEW_VERSION" CHANGELOG.md

echo -e "${GREEN}       ✓ CHANGELOG.md updated${NC}\n"

# -----------------------------------------------------------------------------
# Step 6: Stage and commit all changed files
# -----------------------------------------------------------------------------
echo -e "${YELLOW}[6/$TOTAL] Staging and committing...${NC}"
git add VERSION CHANGELOG.md README.md scripts/aba.sh install build/pre-commit-checks.sh
git commit -m "release: Bump version to $NEW_VERSION

$RELEASE_DESC

Release notes:
- See CHANGELOG.md for full details"
echo -e "${GREEN}       ✓ Commit created${NC}\n"

# -----------------------------------------------------------------------------
# Step 7: Create an annotated git tag
# -----------------------------------------------------------------------------
# Annotated tags (vs lightweight) carry a tagger name/date and message, which
# is what GitHub shows on the Releases page.
echo -e "${YELLOW}[7/$TOTAL] Creating git tag v$NEW_VERSION...${NC}"
git tag -a "v$NEW_VERSION" -m "Release v$NEW_VERSION: $RELEASE_DESC"
echo -e "${GREEN}       ✓ Tag created: v$NEW_VERSION${NC}\n"

# -----------------------------------------------------------------------------
# Step 8: Post-release verification
# -----------------------------------------------------------------------------
# Read the tagged commit and double-check that every file we touched actually
# contains the new version string.  This catches sed patterns that silently
# didn't match, wrong files being staged, etc.
echo -e "${YELLOW}[8/$TOTAL] Verifying tagged release v$NEW_VERSION...${NC}"
VERIFY_OK=true

# VERSION file at the tag
TAG_VERSION=$(git show "v$NEW_VERSION:VERSION" 2>/dev/null | tr -d '[:space:]')
if [ "$TAG_VERSION" = "$NEW_VERSION" ]; then
    echo -e "${GREEN}       ✓ VERSION file: $TAG_VERSION${NC}"
else
    echo -e "${RED}       ✗ VERSION file: expected '$NEW_VERSION', got '$TAG_VERSION'${NC}"
    VERIFY_OK=false
fi

# ABA_VERSION variable inside scripts/aba.sh
TAG_ABA_VER=$(git show "v$NEW_VERSION:scripts/aba.sh" 2>/dev/null | grep "^ABA_VERSION=" | cut -d= -f2)
if [ "$TAG_ABA_VER" = "$NEW_VERSION" ]; then
    echo -e "${GREEN}       ✓ ABA_VERSION in aba.sh: $TAG_ABA_VER${NC}"
else
    echo -e "${RED}       ✗ ABA_VERSION in aba.sh: expected '$NEW_VERSION', got '$TAG_ABA_VER'${NC}"
    VERIFY_OK=false
fi

# CHANGELOG must have a "## [X.Y.Z]" header
if git show "v$NEW_VERSION:CHANGELOG.md" 2>/dev/null | grep -q "^## \[$NEW_VERSION\]"; then
    echo -e "${GREEN}       ✓ CHANGELOG.md has [$NEW_VERSION] section${NC}"
else
    echo -e "${RED}       ✗ CHANGELOG.md missing [$NEW_VERSION] section${NC}"
    VERIFY_OK=false
fi

# README must reference the new version (download URLs, etc.)
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

# -----------------------------------------------------------------------------
# Step 9: Return to dev (if --ref); stay on main (if --hotfix)
# -----------------------------------------------------------------------------
if [ -n "$REF_COMMIT" ]; then
    echo -e "${YELLOW}[9/$TOTAL] Returning to dev branch...${NC}"
    git checkout dev
    echo -e "${GREEN}       ✓ Back on dev branch${NC}\n"
elif $HOTFIX; then
    echo -e "${YELLOW}[9/$TOTAL] Staying on main (hotfix mode)${NC}\n"
else
    echo -e "${YELLOW}[9/$TOTAL] Already on dev (skipped)${NC}\n"
fi

# =============================================================================
# Automated publish — push, merge, sync, and create GitHub release.
# Each destructive step requires confirmation (default: Yes).
# =============================================================================

echo -e "${CYAN}=== Publishing Release v$NEW_VERSION ===${NC}\n"

# -----------------------------------------------------------------------------
# Step 10: Push tag to origin
# -----------------------------------------------------------------------------
echo -e "${YELLOW}[10/$TOTAL] Push tag v$NEW_VERSION to origin${NC}"
if confirm "Push tag v$NEW_VERSION?"; then
    git push origin "v$NEW_VERSION"
    echo -e "${GREEN}       ✓ Tag pushed${NC}\n"
else
    echo -e "${YELLOW}       ⊘ Skipped${NC}\n"
fi

# -----------------------------------------------------------------------------
# Step 11: Merge to main and push
# -----------------------------------------------------------------------------
if $HOTFIX; then
    echo -e "${YELLOW}[11/$TOTAL] Push main (hotfix already on main)${NC}"
    if confirm "Push main?"; then
        git push origin main
        echo -e "${GREEN}       ✓ main pushed${NC}\n"
    else
        echo -e "${YELLOW}       ⊘ Skipped (run manually: git push origin main)${NC}\n"
    fi
else
    echo -e "${YELLOW}[11/$TOTAL] Merge to main and push${NC}"
    if confirm "Checkout main, merge, and push?"; then
        git checkout main 2>/dev/null || git checkout -b main origin/main
        git pull --rebase origin main
        if [ -n "$REF_COMMIT" ]; then
            git merge --no-ff "v$NEW_VERSION" -m "Merge release v$NEW_VERSION into main"
        else
            git merge --no-ff dev -m "Merge dev into main for release v$NEW_VERSION"
        fi
        git push origin main
        git checkout dev
        echo -e "${GREEN}       ✓ main updated and pushed${NC}\n"
    else
        echo -e "${YELLOW}       ⊘ Skipped (run manually: git checkout main && git merge --no-ff v$NEW_VERSION && git push origin main && git checkout dev)${NC}\n"
    fi
fi

# -----------------------------------------------------------------------------
# Step 12: Sync dev with main (--ref and --hotfix modes)
# -----------------------------------------------------------------------------
if [ -n "$REF_COMMIT" ]; then
    echo -e "${YELLOW}[12/$TOTAL] Sync dev with main (merge version bump back into dev)${NC}"
    if confirm "Merge main into dev?"; then
        git merge main -m "Merge main back into dev after release v$NEW_VERSION"
        echo -e "${GREEN}       ✓ dev synced with main${NC}\n"
    else
        echo -e "${YELLOW}       ⊘ Skipped (run manually: git merge main)${NC}\n"
    fi
elif $HOTFIX; then
    echo -e "${YELLOW}[12/$TOTAL] Sync dev with main (merge hotfix into dev)${NC}"
    if confirm "Checkout dev and merge main into dev?"; then
        git checkout dev
        git merge main -m "Merge hotfix v$NEW_VERSION from main into dev"
        echo -e "${GREEN}       ✓ dev synced with hotfix${NC}\n"
    else
        echo -e "${YELLOW}       ⊘ Skipped (run manually: git checkout dev && git merge main)${NC}\n"
    fi
else
    echo -e "${YELLOW}[12/$TOTAL] Sync dev with main (not needed in default mode)${NC}\n"
fi

# -----------------------------------------------------------------------------
# Step 13: Push dev and cleanup
# -----------------------------------------------------------------------------
echo -e "${YELLOW}[13/$TOTAL] Push dev to origin${NC}"
if confirm "Push dev?"; then
    # Ensure we're on dev (hotfix mode may still be on main if step 12 was skipped)
    if [ "$(git branch --show-current)" != "dev" ]; then
        git checkout dev
    fi
    git push origin dev
    echo -e "${GREEN}       ✓ dev pushed${NC}\n"
else
    echo -e "${YELLOW}       ⊘ Skipped (run manually: git push origin dev)${NC}\n"
fi

if [ -n "$REF_COMMIT" ]; then
    git branch -d "$RELEASE_BRANCH_NAME" 2>/dev/null && \
        echo -e "${GREEN}       ✓ Deleted temp branch $RELEASE_BRANCH_NAME${NC}\n" || true
fi

# -----------------------------------------------------------------------------
# Step 14: Create GitHub release
# -----------------------------------------------------------------------------
echo -e "${YELLOW}[14/$TOTAL] Create GitHub release${NC}"
if confirm "Create GitHub release for v$NEW_VERSION?"; then
    build/create-github-release.sh "v$NEW_VERSION"
else
    echo -e "${YELLOW}       ⊘ Skipped${NC}"
    echo -e "${YELLOW}       Run manually: build/create-github-release.sh v$NEW_VERSION${NC}"
    echo -e "${YELLOW}       Or via web:   https://github.com/sjbylo/aba/releases/new?tag=v$NEW_VERSION${NC}\n"
fi

echo -e "${GREEN}=== Release v$NEW_VERSION Complete! ===${NC}"
