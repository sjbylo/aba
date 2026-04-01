# E2E Error Suppression Audit — Findings & Rules

Date: 2026-03-30

## Problem

The E2E test framework was riddled with `|| true` and `2>/dev/null` that
silently hid real failures.  Orphan VMs, stale registries, and broken cleanup
went undetected for weeks because the framework swallowed errors instead of
exposing them.

## Root cause

These scripts do **not** use `set -e`.  Without `set -e`, `|| true` has
**zero functional effect** — it does not prevent script termination (nothing
would terminate anyway).  Every `|| true` was pure "I don't care if this
fails" signalling, which is always wrong in a test framework.

## What was removed

| Pattern | Count | Why it was wrong |
|---|---|---|
| `|| true` on `aba delete` / `aba uninstall` | 21 | Silently left orphan VMs and mirrors running |
| `|| true` on SSH cleanup commands | ~15 | If SSH to disN fails, suite starts with dirty state |
| `|| true` on framework counters `(( count++ ))` | 7 | Unnecessary — no `set -e` |
| `|| true` on `govc` destroy | 2 restored | `vm.power -off` on an already-off VM returns error — acceptable |
| `|| true` on `podman rm -f` in suites | 1 | Papering over incomplete cleanup — replaced with assertion |
| `|| true` on `suite_end`, `sudo chown`, etc. | ~10 | If these fail, something is wrong |
| `2>/dev/null` on `cat`/`grep` with existing `[ -f ]` guard | ~15 | Guard confirms file exists; `2>/dev/null` hides real read errors |
| `2>/dev/null` on `loginctl`, SSH `echo`, `grep` on conf files | ~8 | Hid SSH failures and config problems |

## What was kept (and why)

| Pattern | Why it's acceptable |
|---|---|
| `kill -0 $pid 2>/dev/null` | Process probe; "no such process" on stderr is noise |
| `tmux kill-session ... 2>/dev/null` | Session may not exist; stderr message is noise |
| `tmux has-session ... 2>/dev/null` | Checking existence; stderr is noise |
| `tmux set-option ... 2>/dev/null` | UI config; graceful failure is fine |
| `[ "$x" -gt 0 ] 2>/dev/null` | Arithmetic guard; non-numeric produces bash warning |
| `cat /tmp/e2e-last-suites 2>/dev/null` (remote) | File doesn't exist until runner creates it; polled via SSH |
| `git rev-parse ... 2>/dev/null \|\| echo dev` | May not be in a git repo |
| `govc vm.power -off ... \|\| true` (destroy only) | VM may already be powered off |
| `dnf remove -y ... \|\| true` | Some packages may not be installed |

## Bugs found during the audit

### 1. `_verify_no_orphan_vms()` was dead code

`govc` was deleted by `_cleanup_non_mirror_local()` before the orphan check
ran.  The check printed "WARNING: govc not found" and **returned 0** (success).
Every suite on VMware ran without orphan detection.

**Fix:** Install `govc` into `$_FRAMEWORK_BIN` (never cleaned by suites).
If govc is missing on a VMware pool, **FATAL error** — not a warning.

### 2. SSH-eats-stdin in cleanup loops

`ssh` inside `while read ... done < file` consumed the entire input stream.
Only the first entry in `.cleanup` files was processed; the rest were silently
skipped.  This left orphan VMs after every crashed suite.

**Fix:** `< /dev/null` on every `ssh` call inside `while read` loops.

### 3. `_cleanup_dis_aba()` return code unchecked

The function's callers ignored its exit code.  If SSH to disN was broken, all
cleanup commands silently failed and the suite started with stale state.

**Fix:** Callers now check the return code and stop on failure.

### 4. `_verify_no_mirror_data_dirs()` reported "all clean" when SSH was broken

If SSH to disN failed, every `test -d` inside the function failed, so
`_leftovers` stayed empty.  The function returned 0 ("no leftover dirs!")
when it couldn't actually check anything.

**Fix:** SSH connectivity pre-check before the loop.

### 5. Unguarded `aba delete && rm -rf` in suite cleanup sections

Several suites deleted a cluster earlier in the test, then tried to delete it
again in the end-of-suite cleanup without checking if the directory still
existed.  This caused retries and interactive prompts.

**Fix:** `if [ -d $X ]; then aba --dir $X delete && rm -rf $X; fi`

### 6. `A && B || true` bash trap

`grep ... && sed ... || true` does NOT mean "if grep succeeds, run sed, else
ignore."  If `sed` fails (file missing, permissions), `|| true` catches that
too.  This hid config file write failures.

**Fix:** Rewrite as `if grep ...; then sed ...; fi`

## Rules going forward

1. **NEVER use `|| true` in test framework or suite code.**
   These scripts have no `set -e`.  `|| true` does nothing except say
   "I don't care if this fails" — which is always wrong in tests.

2. **NEVER use `podman rm`, `rm -rf`, or `govc destroy` to clean up test
   resources in suites.**  Use `aba delete` / `aba uninstall`.  If you need
   to sweep, there's a bug in the cleanup path — find and fix it.

3. **NEVER use `2>/dev/null` on a command whose file/resource is already
   confirmed to exist** (e.g. after `[ -f "$file" ]`).  The `2>/dev/null`
   would hide permission errors, disk-full errors, etc.

4. **Acceptable `2>/dev/null`:** `kill -0`, `tmux` commands, arithmetic
   guards, remote state-file polling where the file genuinely may not exist.

5. **When a cleanup step might find nothing to clean**, use a guard
   (`if [ -d $X ]; then ...`), not `|| true`.  The guard documents intent;
   `|| true` hides everything.

6. **If orphan VMs are detected, STOP and investigate.**  Never sweep them
   away silently.  The root cause is always a cleanup bug that will recur.
