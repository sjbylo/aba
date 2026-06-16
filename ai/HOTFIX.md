# Hotfix Workflow

Apply targeted bug fixes to a released version without pulling in dev features.

## When to use

- User-facing bug found in the current release
- Fix must ship without waiting for the next feature release
- Keep changes minimal to reduce merge risk

## Steps

```bash
# 1. Create fix branch from main
git checkout main
git checkout -b fix/<version>     # e.g. fix/0.9.7

# 2. Make fixes (keep minimal -- bug fixes only, no new features or tests)
#    Edit files, verify syntax:
build/pre-commit-checks.sh --skip-version

# 3. Commit
git add <files>
git commit -m "Fix: <short description>"

# 4. Merge to main
git checkout main
git merge fix/<version> -m "Merge fix/<version>: <description>"

# 5. Re-tag the release (update in place, no new version number)
git tag -f v<version>

# 6. Merge to dev
git checkout dev
git merge fix/<version> -m "Merge fix/<version>: <description>"
#    Resolve conflicts if any (likely in files changed on both branches)

# 7. Push everything
git push origin main
git push origin dev
git push origin v<version> --force

# 8. Clean up
git branch -d fix/<version>
```

## Notes

- The fix branch is based on `main`, not `dev` -- this ensures only the fix goes into the release.
- Force-updating the tag avoids consuming a version number. The GitHub release auto-updates.
- Pre-commit checks will warn "not on dev branch" -- that's expected on the fix branch.
- New tests for the fix go on `dev` after the merge, not on the fix branch.
- If the fix touches files that `dev` also changed, expect minor merge conflicts at step 6.
