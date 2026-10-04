---
name: test-aba
description: >-
  Test ABA CLI and TUI functionality. Use when the user says "test aba",
  "run tests", "test the status command", "write a regression test",
  "test on disco/bastion/conno", or asks about testing ABA features.
---

# Test ABA

Systematic testing of ABA CLI commands, TUI, and scripts.

## Test hosts

| Host | Mode | Use for |
|------|------|---------|
| bastion (localhost) | CONNO (connected) | CLI, TUI, mirror, cluster status |
| disco.example.com | DISCO (disconnected) | Offline paths, bundle, load, status perf |
| conno.example.com | CONNO (connected) | Functional tests, remote script validation |

SSH: `ssh -F ~/.aba/ssh.conf <host> "..."`

## Phase 1: Run existing tests (baseline)

Always start here. Establish what passes before changing anything.

```bash
# Unit tests only (fast, <60s)
test/func/run-all-tests.sh --unit

# All tests (unit + integration)
test/func/run-all-tests.sh --all
```

Record results. Do NOT fix pre-existing failures without user permission.
Pre-existing failures are NOT bugs you introduced — note them and move on.

## Phase 2: Targeted CLI testing

Test specific commands on relevant hosts. Verify:
- Exit code (0 for success, non-zero for expected failures)
- Output contains expected keys/strings
- No unexpected warnings or errors on stderr

### Status commands

```bash
# Bastion
aba status                          # milestone + next steps
aba status --all                    # verbose + cluster health
aba status --shell                  # k=v output, verify all keys present
aba -d mirror status
aba -d mirror status --shell
aba -d <cluster> status             # pick a real installed cluster

# Disco (via SSH)
ssh disco "cd ~/aba && aba status"                # should complete in <3s
ssh disco "cd ~/aba && aba status --shell"
```

### Help text

```bash
aba --help | grep -q "status"       || echo "FAIL: status missing from help"
aba mirror --help | grep -q "status" || echo "FAIL: status missing from mirror help"
aba cluster --help | grep -q "status" || echo "FAIL: status missing from cluster help"
```

### Edge cases

```bash
# Run status from wrong directory
cd /tmp && aba status               # should handle gracefully
# Status with no aba.conf
# Status with missing pull secret
```

## Phase 3: TUI smoke test via tmux

Launch TUI in tmux, send keystrokes, capture pane output.

```bash
# On bastion
tmux new-session -d -s tui-test "cd ~/aba && abatui"
sleep 4
tmux capture-pane -t tui-test -p    # verify splash screen

# Check header has hostname
tmux capture-pane -t tui-test -p | grep -q "$(hostname -s)" \
    || echo "FAIL: hostname not in header"

# Navigate past splash
tmux send-keys -t tui-test Enter
sleep 3
tmux capture-pane -t tui-test -p    # verify main menu

# Exit cleanly
tmux send-keys -t tui-test Escape
sleep 1
tmux send-keys -t tui-test Enter    # confirm exit
tmux kill-session -t tui-test 2>/dev/null
```

For DISCO TUI testing, deploy code first:
```bash
scp -F ~/.aba/ssh.conf tui/v2/*.sh disco.example.com:aba/tui/v2/
```

Then repeat via SSH + tmux on disco. Verify:
- Black background (check dialogrc: `grep screen_color /tmp/dialogrc-v2.*`)
- "Fully Disconnected" in header
- Hostname in header

## Phase 4: Write regression tests

When a bug is found and fixed, write a test in `test/func/`.

### Test file conventions

- File: `test/func/test-<descriptive-name>.sh`
- Starts with `#!/bin/bash`
- `cd "$(dirname "$0")/../.."` to set CWD to repo root
- Print test name at start
- Exit 0 on pass, non-zero on fail
- No side effects (don't modify repo state, use temp dirs)
- Must work without network (for unit tests) or document if network needed

### Template

```bash
#!/bin/bash
# Test: <one-line description>
# Regression test for: <link to bug or commit>

cd "$(dirname "$0")/../.."
source scripts/include_all.sh 2>/dev/null

echo "Test: <description>"

failed=0

# --- Test case 1 ---
if <condition>; then
    echo "✓ PASS: <what was verified>"
else
    echo "✗ FAIL: <what went wrong>"
    failed=1
fi

# --- Test case 2 ---
# ...

exit $failed
```

### Register the test

Add the test to `test/func/run-all-tests.sh`:
- Fast, no-network tests → `unit_tests` array
- Slow or network-dependent → `integration_tests` array

### Regression test ideas for common bug patterns

| Bug pattern | Test approach |
|---|---|
| Sub-script failure not propagated | Create a script that calls a failing sub-script, verify parent exits non-zero |
| Wrong namespace in wait loop | Grep test scripts for hardcoded namespace vs `$NS` variable |
| Status command slow on disco | Time the command, assert <3s (integration test on disco) |
| Missing key in --shell output | Parse output, verify all documented keys are present |
| Config edge case | Create temp dir with broken config, run command, verify error message |
| Help text missing new command | Grep help files for expected strings |

## Phase 5: Performance checks

```bash
# Status performance on disco (should be <3s)
ssh disco "cd ~/aba && time bash scripts/repo-status.sh" 2>&1

# Pre-commit checks (should pass)
build/pre-commit-checks.sh --skip-version
```

## Reporting

After testing, summarize:

```
## Test Results

**Baseline**: X/Y unit tests passed, A/B integration tests passed
**CLI tests**: all status variants verified on bastion + disco
**TUI**: splash OK, header OK, navigation OK
**Regressions written**: N new tests added
**Issues found**: (list any)
```

## When to use this skill

- Before a release (comprehensive: phases 1-5)
- After fixing a bug (phase 4: write regression test, phase 1: run suite)
- After changing CLI output (phase 2: verify output)
- After TUI changes (phase 3: smoke test)
- Periodically (phase 1: maintain baseline)
