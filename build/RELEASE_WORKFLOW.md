# Release Workflow

Complete guide for managing releases, branches, tags, and GitHub releases.

## Branch Strategy

```
main branch:    Stable releases only (v0.9.0, v1.0.0, etc.)
dev branch:     Active development (default working branch)
```

### Workflow:

1. **Development**: Work on `dev` branch
2. **Release**: Create tag on `dev`, then merge to `main`
3. **Hotfix**: Branch from `main`, fix, merge back to both `main` and `dev`

## Release Process

### 1. Prepare Release (on `dev` branch)

```bash
# Ensure you're on dev and up-to-date
git checkout dev
git pull

# Ensure all changes are committed
git status

# Run the release script
build/release.sh 0.9.0 "Initial public release with versioning system"

# This script automatically:
# - Updates VERSION file
# - Embeds version in scripts/aba.sh
# - Updates CHANGELOG.md
# - Runs pre-commit checks
# - Commits changes
# - Creates git tag v0.9.0
```

### 2. Push to GitHub

```bash
# Push dev branch with new commits
git push origin dev

# Push the new tag
git push origin v0.9.0
```

### 3. Merge to `main` (for stable releases)

```bash
# Switch to main
git checkout main
git pull

# Merge from dev (no fast-forward to preserve history)
git merge --no-ff dev -m "Merge release v0.9.0 to main"

# Push main
git push origin main
```

### 4. Create GitHub Release (Optional)

**GitHub releases are optional!** Git tags alone are sufficient for version management. However, GitHub releases provide a nice UI for users to download specific versions and read release notes.

**Primary Method: Web Interface (No tools required)**

1. Go to: https://github.com/sjbylo/aba/releases/new
2. **Choose tag**: Select `v0.9.0` from dropdown (tag must already be pushed)
3. **Release title**: `Aba v0.9.0`
4. **Description**: Copy the v0.9.0 section from CHANGELOG.md
5. **Options**:
   - ☐ Set as pre-release (for beta/RC versions)
   - ☑ Set as latest release (for stable releases)
6. Click **Publish release**

**Done!** No command-line tools needed.

---

**Alternative: Automated Script (requires GitHub CLI)**

If you have `gh` installed and want to automate:

```bash
# Install gh (optional)
sudo dnf install gh

# Authenticate (first time only)
gh auth login

# Create release automatically
build/create-github-release.sh v0.9.0

# Or create a draft for review
build/create-github-release.sh v0.9.0 --draft
```

**Note:** The automated script (`build/create-github-release.sh`) is provided for convenience but is entirely optional. The web interface is simpler and doesn't require any tools.

## Managing Tags

### List Tags
```bash
# List all tags
git tag

# List tags with messages
git tag -n

# Show tag details
git show v0.9.0
```

### Delete Tag (if mistake)
```bash
# Delete local tag
git tag -d v0.9.0

# Delete remote tag
git push origin --delete v0.9.0
```

### Move Tag (if needed - NOT RECOMMENDED for published releases)
```bash
# Delete old tag
git tag -d v0.9.0
git push origin --delete v0.9.0

# Create new tag at current commit
git tag -a v0.9.0 -m "Release v0.9.0: Fixed version"
git push origin v0.9.0
```

## Release Cadence

**Aba uses periodic releases (~monthly)**

### Version Numbering:

- **MAJOR** (1.0.0): Breaking changes, major refactors
- **MINOR** (0.9.0 → 0.10.0): New features, backward compatible
- **PATCH** (0.9.0 → 0.9.1): Bug fixes only

### Example Timeline:

```
0.9.0 - January 2026  - Initial versioned release
0.9.1 - February 2026 - Bug fixes
0.10.0 - March 2026   - New features (operators, enhanced TUI)
1.0.0 - Q2 2026       - Stable 1.0 release
```

## Hotfix Workflow (urgent fixes to released versions)

```bash
# 1. Branch from main (the released version)
git checkout main
git pull
git checkout -b hotfix-0.9.1

# 2. Make the fix
vim scripts/some-script.sh
git add scripts/some-script.sh
git commit -m "fix: Critical bug in catalog download"

# 3. Release the hotfix
build/release.sh 0.9.1 "Critical bug fix for catalog downloads"

# 4. Push and create release
git push origin hotfix-0.9.1
git push origin v0.9.1

# 5. Merge to main
git checkout main
git merge --no-ff hotfix-0.9.1
git push origin main

# 6. Merge to dev (to keep in sync)
git checkout dev
git merge --no-ff hotfix-0.9.1
git push origin dev

# 7. Delete hotfix branch
git branch -d hotfix-0.9.1
git push origin --delete hotfix-0.9.1

# 8. Create GitHub release for v0.9.1
```

## Branch Cleanup

### List Branches
```bash
# Local branches
git branch

# Remote branches
git branch -r

# All branches with last commit
git branch -a -v
```

### Delete Merged Branches
```bash
# Delete local branch
git branch -d feature-branch-name

# Delete remote branch
git push origin --delete feature-branch-name
```

## Rollback Scenarios

### Rollback a Commit (before push)
```bash
# Undo last commit, keep changes
git reset --soft HEAD~1

# Undo last commit, discard changes
git reset --hard HEAD~1
```

### Rollback a Release (after push)
```bash
# Create a new release that reverts changes
git revert HEAD
build/release.sh 0.9.2 "Rollback to pre-0.9.1 state"
```

## GitHub Release Assets (Optional)

You can attach files to GitHub releases:

```bash
# Create a release tarball
git archive --format=tar.gz --prefix=aba-0.9.0/ v0.9.0 > aba-0.9.0.tar.gz

# Upload via gh CLI
gh release upload v0.9.0 aba-0.9.0.tar.gz
```

## Checking Release Status

```bash
# View all releases
gh release list

# View specific release
gh release view v0.9.0

# Download release assets
gh release download v0.9.0
```

## Best Practices

1. ✅ **Always test before release**: Run functional tests
2. ✅ **Keep CHANGELOG.md updated**: Add items to [Unreleased] as you work
3. ✅ **Tag from dev first**: Create tag on dev, then merge to main
4. ✅ **Never force-push tags**: Once published, tags are immutable
5. ✅ **Use semantic versioning**: Major.Minor.Patch
6. ✅ **Write clear release notes**: User-focused, not commit-focused
7. ✅ **Test the release**: Download from GitHub and verify

## Quick Reference

```bash
# Prepare and release
git checkout dev
build/release.sh 0.10.0 "New features and improvements"
git push origin dev v0.10.0

# Merge to main
git checkout main
git merge --no-ff dev -m "Merge release v0.10.0"
git push origin main

# Create GitHub release
gh release create v0.10.0 --title "Aba v0.10.0" --latest

# Return to dev
git checkout dev
```
