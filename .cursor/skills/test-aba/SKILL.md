---
name: test-aba
description: >-
  Test ABA CLI and TUI functionality. Use when the user says "test aba",
  "run tests", "test the status command", "write a regression test",
  "test on disco/bastion/conno", or asks about testing ABA features.
---

# Test ABA

Systematic testing of ABA CLI commands, TUI, and scripts.
Covers functional tests, CLI verification, TUI smoke testing, and regression tests.

## Code change permissions

| Code area | Permission | Notes |
|---|---|---|
| `test/func/*`, `test/e2e/*` | **Freely modifiable** | Create, edit, delete tests without asking |
| `scripts/`, `tui/`, `templates/`, `Makefile*` | **Ask user first** | Only fix if bug is obvious AND under 5 lines. Otherwise report the bug |
| `build/pre-commit-checks.sh` | **Ask user first** | Lint/check changes need approval |
| `ai/*` | **Freely modifiable** | Notes, plans, bullets |

When a test reveals a bug in ABA core:
1. **Always** write the regression test first (in `test/func/`)
2. **Report** the bug with reproduction steps
3. **Only fix** ABA core code if the user says so, or if it's trivially obvious (typo, wrong variable name, off-by-one) AND under 5 lines

When a test itself is broken or flaky:
- Fix the test freely — no permission needed
- Document why it was flaky in a code comment

## Test hosts

| Host | Mode | Use for |
|------|------|---------|
| bastion (localhost) | CONNO (connected) | CLI, TUI, mirror, cluster status |
| disco.example.com | DISCO (disconnected) | Offline paths, bundle, load, status perf |
| conno.example.com | CONNO (connected) | Functional tests, remote script validation |

SSH: `ssh -F ~/.aba/ssh.conf <host> "..."`

## tmux requirement

**All commands and TUI sessions MUST run inside tmux on the target host.**
Never run `aba`, `abatui`, or test commands directly in the Cursor shell.

### Setup

Create tmux sessions **on each remote host** (not locally with SSH inside):

```bash
# On conno
ssh -F ~/.aba/ssh.conf conno.example.com \
  "tmux new-session -d -s hack -x 160 -y 45 'cd ~/aba && exec bash'"

# On disco
ssh -F ~/.aba/ssh.conf disco.example.com \
  "tmux new-session -d -s hack -x 160 -y 45 'cd ~/tmp/aba && exec bash'"

# On bastion (local)
tmux new-session -d -s hack-bastion -x 160 -y 45 'cd ~/aba && exec bash'
```

### Running commands

Send commands and read output via SSH + tmux:

```bash
# Send a command to conno's tmux
ssh -F ~/.aba/ssh.conf conno.example.com \
  "tmux send-keys -t hack 'aba status' Enter"

# Wait, then capture output
sleep 3
ssh -F ~/.aba/ssh.conf conno.example.com \
  "tmux capture-pane -t hack -p"
```

### Why

This keeps long-running commands, TUI dialogs, and interactive prompts in a
stable terminal **on the host where they run**. It survives agent restarts,
avoids blocking the Cursor shell, and gives the TUI a real terminal with
correct dimensions.

Any fixed or changed code can be deployed to remote hosts before testing:
```bash
scp -F ~/.aba/ssh.conf scripts/repo-status.sh scripts/cluster-status.sh disco.example.com:aba/scripts/
scp -F ~/.aba/ssh.conf tui/v2/*.sh disco.example.com:aba/tui/v2/
```

## Phase 1: Run existing functional tests (baseline)

Always start here. Establish what passes before changing anything.

```bash
# Unit tests only (fast, <60s)
test/func/run-all-tests.sh --unit

# All tests (unit + integration)
test/func/run-all-tests.sh --all
```

Record results. Pre-existing failures are NOT bugs you introduced — note them and move on.

## Phase 2: CLI testing on bastion and disco

Test commands on relevant hosts. Verify exit code, output content, and no unexpected errors.

### Status commands (bastion)

```bash
aba status                            # milestone + next steps
aba status --all                      # verbose + cluster health
aba status --shell                    # k=v output, all keys present
aba -d mirror status                  # mirror summary
aba -d mirror status --shell          # mirror k=v
aba -d <cluster> status               # pick a real installed cluster
```

### Status commands (disco, via SSH)

```bash
ssh disco "cd ~/aba && aba status"                    # <3s
ssh disco "cd ~/aba && aba status --shell"
ssh disco "cd ~/aba && aba -d mirror status"
ssh disco "cd ~/aba && time bash scripts/repo-status.sh"   # verify <3s
```

### Help text verification

```bash
aba --help | grep -q "status"        || echo "FAIL: status missing from main help"
aba mirror --help | grep -q "status" || echo "FAIL: status missing from mirror help"
aba cluster --help | grep -q "status" || echo "FAIL: status missing from cluster help"
```

### Edge cases

```bash
cd /tmp && aba status                 # from wrong directory — should not crash
```

## Phase 3: TUI smoke test via tmux

Launch TUI in tmux, navigate with keystrokes, capture pane output.

### Bastion (CONNO mode)

```bash
tmux kill-session -t tui-test 2>/dev/null
tmux new-session -d -s tui-test "cd ~/aba && abatui"
sleep 5

# Verify splash screen
tmux capture-pane -t tui-test -p > /tmp/tui-splash.txt
grep -q "ABA TUI v2" /tmp/tui-splash.txt || echo "FAIL: no TUI header"
grep -q "$(hostname -s)" /tmp/tui-splash.txt || echo "FAIL: hostname not in header"

# Navigate past splash
tmux send-keys -t tui-test Enter
sleep 3
tmux capture-pane -t tui-test -p > /tmp/tui-menu.txt
# Verify main menu appeared (look for menu items)

# Exit
tmux send-keys -t tui-test Escape
sleep 1
tmux send-keys -t tui-test Tab Enter   # confirm exit
sleep 1
tmux kill-session -t tui-test 2>/dev/null
```

### Disco (DISCO mode)

Deploy code first, then test via SSH + tmux. Verify:
- Black background: `ssh disco "cat /tmp/dialogrc-v2.* 2>/dev/null | grep screen_color"`
  Expected: `screen_color = (WHITE,BLACK,ON)`
- "Fully Disconnected" in header
- Short hostname in header

## Phase 4: Write regression tests

When a bug is found, write a test in `test/func/`.

### Test file conventions

- File: `test/func/test-<descriptive-name>.sh`
- Starts with `#!/bin/bash`
- `cd "$(dirname "$0")/../.."` to set CWD to repo root
- Print test name at start
- Exit 0 on pass, non-zero on fail
- No side effects (don't modify repo state, use temp dirs)
- Must work without network for unit tests

### Template

```bash
#!/bin/bash
# Test: <one-line description>
# Regression test for: <commit or bug description>

cd "$(dirname "$0")/../.."
source scripts/include_all.sh 2>/dev/null

echo "Test: <description>"

failed=0

# --- Test case ---
if <condition>; then
	echo "✓ PASS: <what was verified>"
else
	echo "✗ FAIL: <what went wrong>"
	failed=1
fi

exit $failed
```

### Register the test

Add to `test/func/run-all-tests.sh`:
- Fast, no-network → `unit_tests` array
- Slow or network-dependent → `integration_tests` array

### Regression test ideas

| Bug pattern | Test approach |
|---|---|
| Sub-script failure not propagated | Script calls failing sub-script, verify parent exits non-zero |
| Wrong namespace in wait loop | Grep test scripts for hardcoded namespace vs `$NS` |
| Status slow on disco | Time the command, assert <3s |
| Missing key in --shell output | Parse output, verify all documented keys present |
| Help text missing command | Grep help files for expected strings |
| `$ABA_ROOT` leak | Existing test: `test-aba-root-only-in-aba-sh.sh` |

## Phase 5: Performance and pre-commit

```bash
# Status performance on disco (should be <3s)
ssh disco "cd ~/aba && time bash scripts/repo-status.sh" 2>&1

# Pre-commit checks (should pass clean)
build/pre-commit-checks.sh --skip-version
```

## Reporting

After testing, summarize in this format:

```
## Test Results

**Baseline**: X/Y unit passed, A/B integration passed
**CLI**: status variants verified on bastion + disco
**TUI**: splash OK, header OK, menu OK
**Regressions written**: N new tests
**Bugs found**: (list with severity)
**Bugs fixed**: (list, only if permitted and trivial)
```

## Phase 6: Stray process detection

After exiting `aba`, `abatui`, or any TUI/CLI test, check for orphaned processes
that should have been cleaned up. Dialog processes, SSH wrappers, and background
scripts can leak when the parent crashes, the agent session dies, or cleanup
traps don't fire.

### What to check

Run on **each host** (bastion, conno, disco) after the TUI and CLI have been
fully exited:

```bash
# On bastion (local)
ps -eo pid,ppid,lstart,stat,args | \
  grep -E 'dialog|abatui|script.*dlg|progress-plan\.sh|tui-progress|aba_progress' | \
  grep -v grep

# Stray SSH sessions to remote hosts (dialog/script wrappers over SSH)
ps -eo pid,ppid,lstart,stat,args | \
  grep -E 'ssh.*(conno|disco).*dialog|ssh.*(conno|disco).*script.*dlg' | \
  grep -v grep

# On conno
ssh -F ~/.aba/ssh.conf conno.example.com \
  "ps -eo pid,ppid,lstart,stat,args | \
   grep -E 'dialog|abatui|script.*dlg|progress-plan\.sh|tui-progress' | \
   grep -v grep"

# On disco
ssh -F ~/.aba/ssh.conf disco.example.com \
  "ps -eo pid,ppid,lstart,stat,args | \
   grep -E 'dialog|abatui|script.*dlg|progress-plan\.sh|tui-progress' | \
   grep -v grep"
```

### Known stray patterns

| Pattern | Cause | Severity |
|---|---|---|
| `dialog` with ppid=1 | TUI crashed or was killed without cleanup | Medium — wastes resources, holds terminal |
| `script -qc "dialog ..."` with ppid=1 | TUI's output-capture wrapper orphaned | Medium — same as above |
| `ssh ... dialog ... < /dev/null` | Agent tested TUI dialog remotely, parent died | Low — agent testing artifact |
| `bash scripts/progress-plan.sh` with ppid=1 | Background progress task leaked | Low — usually harmless |
| `ssh ... conno ... script -qc` orphaned | Remote TUI operation lost its parent | Medium — leaks on remote host too |

### What to do with strays

1. **Identify the origin**: check `lstart` (when it was spawned) and the full
   command args to determine if it's from the TUI, CLI, agent testing, or e2e.
2. **Check if ABA-caused**: stray `dialog` or `script -qc "dialog ..."` processes
   are TUI bugs — the TUI should clean up children on exit. File as a bug.
3. **Safe to kill**: any orphaned `dialog` or `script -qc` process can be killed
   safely. Use `kill <pid>` (on the correct host).
4. **Don't kill**: `run.sh` daemon/dispatch processes, tmux sessions (`hack`,
   `aba-reuse`, `quay-ng-build`, etc.), or anything the user is actively using.

### Automated check script

```bash
#!/bin/bash
# Quick stray-process scan for aba/TUI leftovers
# Run after exiting TUI / finishing tests

echo "=== Bastion strays ==="
ps -eo pid,ppid,lstart,stat,args | \
  grep -E '\bdialog\b|abatui|script.*dlg_capture|progress-plan\.sh' | \
  grep -v grep || echo "(none)"

echo ""
echo "=== Stray SSH→dialog sessions ==="
ps -eo pid,ppid,lstart,stat,args | \
  grep -E 'ssh.*example\.com.*dialog|ssh.*example\.com.*script.*dlg' | \
  grep -v grep || echo "(none)"

for host in conno.example.com disco.example.com; do
  echo ""
  echo "=== $host strays ==="
  ssh -F ~/.aba/ssh.conf "$host" \
    "ps -eo pid,ppid,lstart,stat,args | \
     grep -E '\bdialog\b|abatui|script.*dlg_capture|progress-plan\.sh' | \
     grep -v grep" 2>/dev/null || echo "(none or unreachable)"
done
```

### When strays indicate a real bug

File a bug if you find:
- `dialog` orphaned (ppid=1) on any host **after a normal TUI exit** (not a crash/kill)
- Background scripts from ABA core (not agent testing) that survive past their
  parent's exit
- Processes growing in count across TUI restarts (leak per session)

The TUI's `_tui_exit_cleanup()` currently only removes the PID file — it does
NOT kill child processes. This is a known gap.

## When to use this skill

- **Before a release**: all 6 phases
- **After fixing a bug**: phase 4 (write test) → phase 1 (run suite)
- **After CLI output changes**: phase 2
- **After TUI changes**: phase 3 + phase 6
- **Periodically**: phase 1 to maintain baseline
- **After any TUI/CLI session**: phase 6 (stray check)
