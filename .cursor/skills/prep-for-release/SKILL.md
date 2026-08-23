---
name: prep-for-release
description: >-
  Prepare ABA for a new release. Use when the user says "prep for release",
  "prepare release", "get ready for release", or asks about release preparation.
---

# Prep for Release

Prepare the ABA repository for running `build/release.sh`.

## Prerequisites

`build/release.sh` requires these to exist BEFORE it runs:

1. **CHANGELOG.md** — entries under `## [Unreleased]`
2. **`ai/RELEASE_BULLETS_<version>.md`** — user-facing highlights
3. **Clean working tree** — no uncommitted changes
4. **External contributors credited** — in CHANGELOG `[Unreleased]` section

## Steps

ALL commands MUST run inside a tmux session named `release-prep` on bastion.
This ensures long-running commands (catalog refresh, tests) survive disconnects.

```bash
tmux new-session -d -s release-prep 2>/dev/null || true
```

Send ALL subsequent commands via `tmux send-keys -t release-prep '...' Enter`.
NEVER run release prep commands directly — always through tmux.

### 1. Refresh catalog indexes

```bash
tools/refresh-catalog-indexes.sh -y
```

This pulls fresh operator catalog data from registry.redhat.io and updates
`catalogs/`. Must be done on a host with podman and container auth for
registry.redhat.io. After it completes, review the changes and commit
when the user approves. Do NOT use `--commit` (auto-commits without permission).

### 2. Functional tests — DO NOT run

Functional tests are run separately by the developer, not as part of
release prep. Do not run `test/func/run-all-tests.sh` here.

### 3. Run smoke test (if significant changes)

Follow `ai/SMOKE_TEST_RUNBOOK.md` on conno.example.com. Required for
feature releases; can skip for docs-only or trivial fixes.

### 4. Check for external contributors

```bash
git shortlog -sne $(git describe --tags --abbrev=0)..HEAD | grep -v sjbylo
```

Every external contributor must be credited in CHANGELOG under `[Unreleased]`
with `(@handle)` and in a `### Community` section.

### 5. Write CHANGELOG entries

Add entries under `## [Unreleased]` in `CHANGELOG.md`. Group by:
- `### Added` — new features
- `### Changed` — changes to existing features
- `### Fixed` — bug fixes
- `### Removed` — removed features

### 6. Write release bullets

Create `ai/RELEASE_BULLETS_<version>.md` with user-facing highlights.
Rules (from workspace rules):
- User-facing and brief only
- Significant items only (not exhaustive)
- State the fact, not documentation
- One-liner per item

### 7. Ensure clean working tree

```bash
git status
```

Commit or stash everything. `release.sh` refuses to run with uncommitted changes.

### 8. Dry-run release.sh

```bash
build/release.sh --dry-run <version> "<description>"
```

Verify the output looks correct before the real run.

## After prep is complete

Tell the user: "Ready. Run: `build/release.sh <version> \"<description>\"`"

## What release.sh handles (do NOT do manually)

- VERSION file bump
- ABA_VERSION in aba.sh
- README version refs
- CHANGELOG reformatting ([Unreleased] → [X.Y.Z])
- Git commit, tag, merge to main, push, GitHub release
- Pre-commit checks (syntax, RPM sync)
- Merge conflict detection
