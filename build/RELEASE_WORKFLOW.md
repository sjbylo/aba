# Release Workflow

Complete guide for managing releases, branches, tags, and GitHub releases.

## Branch Strategy

```
main branch:    Stable releases only (v0.9.0, v1.0.0, etc.)
dev branch:     Active development (default working branch)
```

### Workflow:

1. **Development**: Work on `dev` branch
2. **Release**: Run `build/release.sh` on `dev`, then merge to `main`
3. **Hotfix**: Branch from `main`, fix, merge back to both `main` and `dev`

## Release Process

### 0. Pre-flight: Populate CHANGELOG

**Before running the release script**, ensure the `[Unreleased]` section of `CHANGELOG.md` has content. The script checks this early and exits if empty.

> **Tip:** Add entries to `[Unreleased]` as you work — don't try to remember everything at release time.

### 1. Preview with Dry Run (recommended)

```bash
# See what the release would do, without making any changes
build/release.sh --dry-run 0.10.0 "New features and improvements"
```

The dry run shows:
- Files that would be modified
- CHANGELOG content that would be released

### 2. Run the Release Script

```bash
# Ensure you're on dev and up-to-date
git checkout dev
git pull

# Run the release script
build/release.sh 0.10.0 "New features and improvements"
```

The script automatically:
1. Runs pre-commit checks (RPM sync, syntax check, branch check, git pull)
2. Updates VERSION file
3. Embeds version in scripts/aba.sh
4. Updates version references in README.md
5. Updates CHANGELOG.md
6. Commits changes
7. Creates git tag v0.10.0
8. Verifies the tagged commit has correct version data

### 2b. Partial Release (--ref)

To release only up to a specific commit (not all of dev), use `--ref`:

```bash
# Preview first
build/release.sh --dry-run --ref 87cdf93 0.10.0 "Stability and bug fixes"

# Run the release
build/release.sh --ref 87cdf93 0.10.0 "Stability and bug fixes"
```

The script creates a temporary branch from the specified commit, applies the version
bump there, tags it, and returns to dev. This is useful when dev has newer commits
that are not yet ready for release.

### 3. Push and Merge to Main

After the script completes, push and merge to main:

```bash
# Default mode: push dev and tag, merge dev to main
git push origin dev
git push origin v0.10.0
git checkout main && git merge --no-ff dev && git push origin main && git checkout dev

# --ref mode: push tag, merge tag to main, sync dev
git push origin v0.10.0
git checkout main && git merge --no-ff v0.10.0 && git push origin main && git checkout dev
git merge main
git branch -d _release-v0.10.0
```

### 4. Create GitHub Release

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
   - Set as pre-release (for beta/RC versions)
   - Set as latest release (for stable releases)
6. Click **Publish release**

### 5. Post-release Verification

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

## Quick Reference

```bash
# Full release flow (copy-paste ready)
git checkout dev
build/release.sh --dry-run 0.10.0 "New features"          # preview
build/release.sh 0.10.0 "New features"                     # release
git push origin dev v0.10.0                                 # push
git checkout main && git merge --no-ff dev && git push origin main && git checkout dev  # merge to main
build/create-github-release.sh v0.10.0                      # GitHub release

# Partial release flow (--ref, copy-paste ready)
git checkout dev
build/release.sh --dry-run --ref abc1234 0.10.0 "Fixes"   # preview
build/release.sh --ref abc1234 0.10.0 "Fixes"             # release
git push origin v0.10.0                                     # push tag
git checkout main && git merge --no-ff v0.10.0 && git push origin main && git checkout dev
git merge main && git branch -d _release-v0.10.0           # sync dev, cleanup
build/create-github-release.sh v0.10.0                      # GitHub release
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

# 3. Merge to main and tag
git checkout main
git merge --no-ff hotfix-0.9.3
git tag -a v0.9.3 -m "Hotfix v0.9.3"
git push origin main v0.9.3

# 4. Merge to dev (to keep in sync)
git checkout dev
git merge --no-ff main
git push origin dev

# 5. Delete hotfix branch
git branch -d hotfix-0.9.3

# 6. Create GitHub release
build/create-github-release.sh v0.9.3
```

## Common Pitfalls

1. **Empty CHANGELOG [Unreleased]**: The script exits early if `[Unreleased]` is empty. Populate it as you work, not at release time.

2. **Wrong `ABA_VERSION` sed pattern**: The `sed` command in `release.sh` uses `s/^ABA_VERSION=.*/...` to match both quoted and unquoted formats. If `aba.sh` changes how `ABA_VERSION` is defined, update the sed pattern too.

3. **Accidental tag on wrong commit**: If a tag is pushed to the wrong commit, delete it locally and remotely before recreating it. Never force-move published tags — delete and recreate.

4. **Install script shows "up-to-date" incorrectly**: The `install` script uses `diff` to compare file contents (not timestamps). If you're testing dev builds, run `./install` again after switching to a release tag to force the update.

5. **Forgetting to merge to main**: After running the release script on `dev`, always merge `dev` into `main` so the released code is on both branches.

## Best Practices

1. **Always test before release**: Run functional tests on the exact commit you're releasing
2. **Keep CHANGELOG.md updated**: Add items to `[Unreleased]` as you work
3. **Use `--dry-run` first**: Preview the release before committing to it
4. **Never force-push tags**: Once published, delete and recreate instead
5. **Use semantic versioning**: Major.Minor.Patch
6. **Write clear release notes**: User-focused, not commit-focused
7. **Verify after tagging**: The script does this automatically, but also test the download

## Checking Release Status

```bash
# View all releases
gh release list

# View specific release
gh release view v0.10.0

# Download release assets
gh release download v0.10.0
```
