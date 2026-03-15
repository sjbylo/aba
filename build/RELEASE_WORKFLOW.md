# Release Workflow

Complete guide for managing releases, branches, tags, and GitHub releases.

## Branch Strategy

```
main branch:    Stable releases only (v0.9.0, v1.0.0, etc.)
dev branch:     Active development (default working branch)
```

### Workflow:

1. **Development**: Work on `dev` branch
2. **Release**: Run `build/release.sh` on `dev` — it handles everything end-to-end
3. **Hotfix**: Commit fix on `main`, run `build/release.sh --hotfix` — it tags, pushes, and syncs dev

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

The script automatically handles the **entire release lifecycle**:

**Build (steps 1-9, non-interactive):**
1. Checks prerequisites (gh CLI, branch, clean tree, CHANGELOG)
2. Runs pre-commit checks (RPM sync, syntax check, git pull)
3. Updates VERSION, scripts/aba.sh, README.md, CHANGELOG.md
4. Commits changes and creates annotated git tag
5. Verifies the tagged commit has correct version data

**Publish (steps 10-14, each with `[Y/n]` confirmation):**
6. Pushes tag to origin
7. Checks out main (creates from remote if needed), merges, pushes
8. Syncs dev with main (--ref mode only)
9. Pushes dev to origin
10. Creates GitHub release via `gh` CLI

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

### 3. That's It!

The script handles pushing, merging to main, syncing dev, and creating the GitHub
release — all with confirmation prompts. No manual steps are needed.

If you skipped any confirmation prompts during the run, the script prints the
manual command for that step so you can run it later.

**Alternative: Create GitHub release via web interface** (if you skipped step 14)

1. Go to: https://github.com/sjbylo/aba/releases/new?tag=v0.10.0
2. **Release title**: `Aba v0.10.0`
3. **Description**: Copy the v0.10.0 section from CHANGELOG.md
4. Click **Publish release**

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
# Full release (one command does everything, with confirmations)
git checkout dev
build/release.sh --dry-run 0.10.0 "New features"          # preview
build/release.sh 0.10.0 "New features"                     # release + publish

# Partial release from a specific commit
git checkout dev
build/release.sh --dry-run --ref abc1234 0.10.0 "Fixes"   # preview
build/release.sh --ref abc1234 0.10.0 "Fixes"             # release + publish

# Hotfix release (urgent patch on main)
git checkout main
# ... make and commit your fix ...
build/release.sh --dry-run --hotfix 0.9.3 "Critical fix"  # preview
build/release.sh --hotfix 0.9.3 "Critical fix"            # release + publish
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
# 1. Switch to main and apply the fix
git checkout main
git pull
vim scripts/some-script.sh
git add scripts/some-script.sh
git commit -m "fix: Critical bug in catalog download"

# 2. Preview the hotfix release
build/release.sh --dry-run --hotfix 0.9.3 "Critical fix for catalog download"

# 3. Run the hotfix release (handles everything)
build/release.sh --hotfix 0.9.3 "Critical fix for catalog download"
```

The `--hotfix` flag tells the script it's running on `main` (not `dev`). It:
- Applies the version bump and CHANGELOG update on main
- Tags the release
- Pushes main and the tag
- Merges main back into dev (keeping dev in sync)
- Pushes dev
- Creates the GitHub release

All publish steps have `[Y/n]` confirmation prompts, same as a normal release.

## Common Pitfalls

1. **Empty CHANGELOG [Unreleased]**: The script exits early if `[Unreleased]` is empty. Populate it as you work, not at release time.

2. **`gh` CLI not installed**: The script checks for `gh` at startup and shows install commands. Install once: `sudo dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo && sudo dnf install gh -y && gh auth login`

3. **Wrong `ABA_VERSION` sed pattern**: The `sed` command in `release.sh` uses `s/^ABA_VERSION=.*/...` to match both quoted and unquoted formats. If `aba.sh` changes how `ABA_VERSION` is defined, update the sed pattern too.

4. **Accidental tag on wrong commit**: If a tag is pushed to the wrong commit, delete it locally and remotely before recreating it. Never force-move published tags — delete and recreate.

5. **Install script shows "up-to-date" incorrectly**: The `install` script uses `diff` to compare file contents (not timestamps). If you're testing dev builds, run `./install` again after switching to a release tag to force the update.

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
