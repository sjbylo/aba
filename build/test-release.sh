#!/bin/bash
# =============================================================================
# Test the release scripts end-to-end against a disposable clone.
# =============================================================================
# Creates a sandboxed copy of the repo with a local bare "origin" so the full
# pipeline (including push, merge-to-main, sync-dev) runs for real — without
# touching your actual repo or GitHub remote.
#
# A mock 'gh' CLI is injected so the GitHub release step executes without
# requiring real authentication.
#
# All arguments are forwarded to build/release.sh.
#
# Usage:
#   build/test-release.sh 0.9.99 "Test release"
#   build/test-release.sh --ref HEAD~3 0.9.99 "Partial release test"
#   build/test-release.sh --hotfix 0.9.99 "Hotfix test"
#   build/test-release.sh --dry-run 0.9.99 "Dry-run test"
#   build/test-release.sh --keep 0.9.99 "Keep sandbox for inspection"
#
# Options (test-specific, stripped before forwarding to release.sh):
#   --keep    Don't delete the sandbox on exit; prints path for inspection.
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

cd "$(dirname "$0")/.." || exit 1
REAL_REPO="$(pwd)"

# --- Parse test-specific flags, collect the rest for release.sh --------------
KEEP=false
RELEASE_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --keep) KEEP=true ;;
        *)      RELEASE_ARGS+=("$arg") ;;
    esac
done

if [ ${#RELEASE_ARGS[@]} -eq 0 ]; then
    echo -e "${RED}Usage: $0 [--keep] <release.sh args...>${NC}"
    echo -e "${YELLOW}Example: $0 0.9.99 \"Test release\"${NC}"
    echo -e "${YELLOW}Example: $0 --hotfix 0.9.99 \"Hotfix test\"${NC}"
    echo -e "${YELLOW}Example: $0 --keep --ref HEAD~3 0.9.99 \"Inspect sandbox\"${NC}"
    exit 1
fi

# --- Create sandbox ----------------------------------------------------------
SANDBOX=$(mktemp -d "/tmp/aba-release-test.XXXXXX")
if ! $KEEP; then
    trap 'rm -rf "$SANDBOX"' EXIT
fi

echo -e "${CYAN}=== Release Script Test ===${NC}"
echo -e "${YELLOW}Sandbox: $SANDBOX${NC}\n"

# --- Clone repo with a local bare "origin" -----------------------------------
echo -e "${YELLOW}[1/3] Setting up test environment...${NC}"
git clone --bare "$REAL_REPO" "$SANDBOX/origin.git" --quiet
git clone "$SANDBOX/origin.git" "$SANDBOX/aba" --quiet
cd "$SANDBOX/aba"

# Ensure both branches exist locally
git checkout dev  --quiet 2>/dev/null || git checkout -b dev origin/dev --quiet
git checkout main --quiet 2>/dev/null || git checkout -b main origin/main --quiet

# --hotfix needs to start on main; everything else on dev
STARTING_BRANCH=dev
for arg in "${RELEASE_ARGS[@]}"; do
    [ "$arg" = "--hotfix" ] && STARTING_BRANCH=main && break
done
git checkout "$STARTING_BRANCH" --quiet

# --- Ensure CHANGELOG [Unreleased] has content (may be empty after a release) -
if ! sed -n '/^## \[Unreleased\]/,/^---$/p' CHANGELOG.md | sed '1d;$d' | grep -q '[^[:space:]]'; then
    sed -i '/^## \[Unreleased\]/a \\n### Test\n\n- Dummy entry for release script testing' CHANGELOG.md
    git add CHANGELOG.md
    git commit -m "test: add dummy CHANGELOG entry" --quiet
fi

# --- Inject mock 'gh' CLI ---------------------------------------------------
mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/gh" << 'MOCK_GH'
#!/bin/bash
case "$1" in
    auth)    echo "✓ Logged in to github.com account testuser (mock)"; exit 0 ;;
    release) echo "[MOCK] gh $*"; exit 0 ;;
    *)       echo "[MOCK] gh $*"; exit 0 ;;
esac
MOCK_GH
chmod +x "$SANDBOX/bin/gh"
export PATH="$SANDBOX/bin:$PATH"

echo -e "${GREEN}       ✓ Sandbox ready (branch: $STARTING_BRANCH)${NC}\n"

# --- Run release.sh ----------------------------------------------------------
echo -e "${YELLOW}[2/3] Running: build/release.sh ${RELEASE_ARGS[*]}${NC}\n"

rc=0
build/release.sh "${RELEASE_ARGS[@]}" || rc=$?

# --- Post-test verification --------------------------------------------------
echo
echo -e "${YELLOW}[3/3] Post-test verification${NC}\n"

echo -e "${CYAN}Branches:${NC}"
git branch -vv
echo

echo -e "${CYAN}Tags:${NC}"
git tag -n
echo

echo -e "${CYAN}Recent history (all branches):${NC}"
git log --oneline --all --graph -12
echo

# If a version tag was created, verify its contents
TAG=$(git tag --sort=-creatordate | head -1)
if [ -n "$TAG" ]; then
    echo -e "${CYAN}Verifying tag $TAG:${NC}"
    VER_FILE=$(git show "$TAG:VERSION" 2>/dev/null | tr -d '[:space:]')
    ABA_VER=$(git show "$TAG:scripts/aba.sh" 2>/dev/null | grep "^ABA_VERSION=" | cut -d= -f2)
    echo "  VERSION file:      $VER_FILE"
    echo "  ABA_VERSION:       $ABA_VER"
    echo "  CHANGELOG section: $(git show "$TAG:CHANGELOG.md" 2>/dev/null | grep "^## \[" | head -2)"
    echo
fi

if [ $rc -eq 0 ]; then
    echo -e "${GREEN}=== Test PASSED (exit code $rc) ===${NC}"
else
    echo -e "${RED}=== Test FAILED (exit code $rc) ===${NC}"
fi

if $KEEP; then
    echo -e "\n${YELLOW}Sandbox preserved at: $SANDBOX${NC}"
    echo -e "${YELLOW}  Working clone: $SANDBOX/aba${NC}"
    echo -e "${YELLOW}  Bare origin:   $SANDBOX/origin.git${NC}"
    echo -e "${YELLOW}  Clean up with: rm -rf $SANDBOX${NC}"
fi

exit $rc
