# Release Workflow

Complete guide for managing releases, branches, tags, and GitHub releases.

## Branch Strategy

```
main branch:    Stable releases only (v0.9.0, v1.0.0, etc.)
dev branch:     Active development (default working branch)
```

### Workflow:

1. **Development**: Work on `dev` branch
2. **Release**: Run `build/release.sh` (from `dev` HEAD or a specific tested commit)
3. **Hotfix**: Branch from `main`, fix, merge back to both `main` and `dev`

## Release Process

The release script supports two modes:

| Mode | Command | When to use |
|------|---------|-------------|
| **HEAD mode** | `build/release.sh 0.10.0 "Description"` | Releasing everything on `dev` |
| **Ref mode** | `build/release.sh 0.10.0 "Description" <commit>` | Releasing a specific tested commit |

### Choosing a Mode

- **HEAD mode** (default): Use when `dev` HEAD has been fully tested and is ready for release.
- **Ref mode**: Use when `dev` has moved ahead of the last tested commit and you want to release from a known-good point. The script merges the specified commit into `main`, applies the version bump there, and tags on `main`.

### 0. Pre-flight: Populate CHANGELOG

**Before running the release script**, ensure the `[Unreleased]` section of `CHANGELOG.md` has content. The script checks this early and exits if empty.

> **Tip:** Add entries to `[Unreleased]` as you work — don't try to remember everything at release time.

### 1. Preview with Dry Run (recommended)

```bash
# See what the release would do, without making any changes
build/release.sh --dry-run 0.10.0 "New features and improvements"

# With a specific commit
build/release.sh --dry-run 0.10.0 "New features" abc1234
```

The dry run shows:
- Release mode (HEAD vs ref)
- Files that would be modified
- CHANGELOG content that would be released

### 2a. Release from HEAD on `dev`

```bash
# Ensure you're on dev and up-to-date
git checkout dev
git pull

# Run the release script
build/release.sh 0.10.0 "New features and improvements"

# The script automatically:
# - Validates inputs and checks CHANGELOG
# - Updates VERSION file
# - Embeds version in scripts/aba.sh
# - Updates version references in README.md
# - Updates CHANGELOG.md
# - Runs pre-commit checks
# - Commits changes
# - Creates git tag v0.10.0
# - Verifies the tagged commit has correct version data
```

After the script completes:

```bash
# Push dev branch and tag
git push origin dev
git push origin v0.10.0

# Merge to main
git checkout main
git pull
git merge --no-ff dev -m "Merge release v0.10.0 to main"
git push origin main

# Return to dev
git checkout dev
```

### 2b. Release from a Specific Commit (ref mode)

Use this when `dev` has untested commits beyond the point you want to release.

```bash
# Can be run from any branch (typically dev)
build/release.sh 0.10.0 "New features and improvements" abc1234

# The script automatically:
# - Switches to main
# - Merges abc1234 into main (no-ff)
# - Applies version bump on main
# - Tags v0.10.0 on main
# - Verifies the tagged commit
# - Prints next steps
```

After the script completes (you are now on `main`):

```bash
# Push main and tag
git push origin main
git push origin v0.10.0

# Merge version bump back into dev
git checkout dev
git merge main
git push origin dev
```

### 3. Create GitHub Release

```bash
# Automated (recommended — requires 'gh' CLI)
build/create-github-release.sh v0.10.0

# Or create a draft for review
build/create-github-release.sh v0.10.0 --draft
```

**Alternative: Web Interface** (no tools required)

1. Go to: https://github.com/sjbylo/aba/releases/new
2. **Choose tag**: Select `v0.10.0` from dropdown (tag must already be pushed)
3. **Release title**: `Aba v0.10.0`
4. **Description**: Copy the v0.10.0 section from CHANGELOG.md
5. **Options**:
   - ☐ Set as pre-release (for beta/RC versions)
   - ☑ Set as latest release (for stable releases)
6. Click **Publish release**

### 4. Post-release Verification

The release script performs automated verification of the tag, but you can also verify manually:

```bash
# Check that the tag has the correct VERSION
git show v0.10.0:VERSION

# Check that aba.sh has the correct ABA_VERSION
git show v0.10.0:scripts/aba.sh | grep ABA_VERSION

# Download and test the tarball
curl -sL https://github.com/sjbylo/aba/archive/refs/tags/v0.10.0.tar.gz | tar xz
cd aba-0.10.0
./install
aba --aba-version
```

## Managing Tags

### List Tags
```bash
# List all tags
git tag

# List tags with messages
git tag -n

# Show tag details
git show v0.10.0
```

### Delete Tag (if mistake)
```bash
# Delete local tag
git tag -d v0.10.0

# Delete remote tag
git push origin --delete v0.10.0
```

### Move Tag (if needed — NOT RECOMMENDED for published releases)
```bash
# Delete old tag
git tag -d v0.10.0
git push origin --delete v0.10.0

# Create new tag at current commit
git tag -a v0.10.0 -m "Release v0.10.0: Fixed version"
git push origin v0.10.0
```

## Release Cadence

**Aba uses periodic releases (~monthly)**

### Version Numbering:

- **MAJOR** (1.0.0): Breaking changes, major refactors
- **MINOR** (0.9.0 → 0.10.0): New features, backward compatible
- **PATCH** (0.9.0 → 0.9.1): Bug fixes only

### Example Timeline:

```
0.9.0  - January 2026   - Initial versioned release
0.9.1  - February 2026  - Bug fixes
0.9.2  - February 2026  - Bug fixes and install improvements
0.10.0 - March 2026     - New features (operators, enhanced TUI)
1.0.0  - Q2 2026        - Stable 1.0 release
```

## Hotfix Workflow (urgent fixes to released versions)

```bash
# 1. Branch from main (the released version)
git checkout main
git pull
git checkout -b hotfix-0.9.3

# 2. Make the fix
vim scripts/some-script.sh
git add scripts/some-script.sh
git commit -m "fix: Critical bug in catalog download"

# 3. Release the hotfix
build/release.sh 0.9.3 "Critical bug fix for catalog downloads"

# 4. Push and create release
git push origin hotfix-0.9.3
git push origin v0.9.3

# 5. Merge to main
git checkout main
git merge --no-ff hotfix-0.9.3
git push origin main

# 6. Merge to dev (to keep in sync)
git checkout dev
git merge --no-ff hotfix-0.9.3
git push origin dev

# 7. Delete hotfix branch
git branch -d hotfix-0.9.3
git push origin --delete hotfix-0.9.3

# 8. Create GitHub release for v0.9.3
build/create-github-release.sh v0.9.3
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
build/release.sh 0.9.4 "Rollback to pre-0.9.3 state"
```

## GitHub Release Assets (Optional)

You can attach files to GitHub releases:

```bash
# Create a release tarball
git archive --format=tar.gz --prefix=aba-0.10.0/ v0.10.0 > aba-0.10.0.tar.gz

# Upload via gh CLI
gh release upload v0.10.0 aba-0.10.0.tar.gz
```

## Checking Release Status

```bash
# View all releases
gh release list

# View specific release
gh release view v0.10.0

# Download release assets
gh release download v0.10.0
```

## Common Pitfalls and Lessons Learned

1. **Releasing from the wrong commit**: If `dev` has untested commits beyond your tested point, use **ref mode** (`build/release.sh <ver> "<desc>" <commit>`) to release from the exact tested commit. Always double-check with `--dry-run` first.

2. **Empty CHANGELOG [Unreleased]**: The script exits early if `[Unreleased]` is empty. Populate it as you work, not at release time.

3. **Wrong `ABA_VERSION` sed pattern**: The `sed` command in `release.sh` uses `s/^ABA_VERSION=.*/...` to match both quoted and unquoted formats. If `aba.sh` changes how `ABA_VERSION` is defined, update the sed pattern too.

4. **Accidental tag on wrong commit**: If a tag is pushed to the wrong commit, delete it locally and remotely before recreating it. Never force-move published tags — delete and recreate.

5. **GitHub "Latest" badge**: The "Latest" badge on GitHub releases goes to the most recently *published* release, not the highest version number. If you publish an older release after a newer one, manually set the correct latest via the GitHub UI or use `gh release edit v0.10.0 --latest`.

6. **Install script shows "up-to-date" incorrectly**: The `install` script uses `diff` to compare file contents (not timestamps). If you're testing dev builds, run `./install` again after switching to a release tag to force the update.

7. **Forgetting to merge `main` back into `dev`**: After a ref-mode release, always merge `main` back into `dev` so the version-bump commit exists on both branches.

## Best Practices

1. ✅ **Always test before release**: Run functional tests on the exact commit you're releasing
2. ✅ **Keep CHANGELOG.md updated**: Add items to `[Unreleased]` as you work
3. ✅ **Use `--dry-run` first**: Preview the release before committing to it
4. ✅ **Never force-push tags**: Once published, delete and recreate instead
5. ✅ **Use semantic versioning**: Major.Minor.Patch
6. ✅ **Write clear release notes**: User-focused, not commit-focused
7. ✅ **Verify after tagging**: The script does this automatically, but also test the download
8. ✅ **Merge `main` back to `dev`**: Especially after ref-mode releases

## Quick Reference

### HEAD Release (simple)
```bash
git checkout dev
build/release.sh --dry-run 0.10.0 "New features"   # preview
build/release.sh 0.10.0 "New features"               # release
git push origin dev v0.10.0
git checkout main && git merge --no-ff dev -m "Merge release v0.10.0" && git push origin main
git checkout dev
build/create-github-release.sh v0.10.0
```

### Ref Release (specific commit)
```bash
build/release.sh --dry-run 0.10.0 "New features" abc1234   # preview
build/release.sh 0.10.0 "New features" abc1234               # release (auto-switches to main)
git push origin main v0.10.0
git checkout dev && git merge main && git push origin dev
build/create-github-release.sh v0.10.0
```
