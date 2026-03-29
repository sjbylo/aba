# gotest — autonomous E2E monitoring loop

When the user says **"gotest"** (or "run the tests"), enter an autonomous monitoring loop and do not stop until they return.

## What to do

- **Monitor and investigate** in a loop:
  - Run E2E tests (`test/e2e/run.sh`), monitor status and logs
  - Do not wait more that 10 mins between checking the status, otherwise you may miss a failed suite!
  - When a suite fails, enter 'p' to pause (if needed), investigate the root cause: read logs, trace the error, identify the fix
  - **Add proposed fixes to a plan** — do NOT edit any code directly
- **Always ensure the dispatcher is running** — check at every monitoring cycle.
  If not running, start it: `run.sh run --all --force` (queues all suites, dispatches to idle pools).
  Never rely solely on manual SSH launches; the dispatcher handles queuing and pool allocation.
- **Do NOT stop to ask questions** — the user is away
- **Do NOT change ANY code** — no ABA core, no test code, no scripts. Read-only.
  The only files you may write to are `ai/SESSION_STATE.md` and plan files.
- **Keep ALL pools busy** — queue additional suites on idle pools, even if already tested
- **Don't wait for pools to free up** — if a pool just finished (pass or fail), force-dispatch
  the suite you need onto it immediately: `run.sh run --suite <name> --pool N --force`
- **Report a summary** when the user returns, including:
  - Which suites passed / failed
  - Root cause analysis for each failure
  - Proposed fixes (in a plan, ready for user approval)
- Do not add band-aids to any code, always find the root cause first!
- **Be persistent** — if the shell or tools fail transiently (empty output, aborted commands,
  connectivity loss), retry immediately. Do NOT stop the monitoring loop or wait for the user.
  Transient failures (e.g. laptop restart, IDE reconnect) are expected; the dispatcher keeps
  running independently. Retry with exponential backoff and resume polling as soon as the shell
  recovers.
- **Use `~/bin/notify.sh`** to send Telegram notifications at least every 10 mins
  Only use it during gotest (not when the user is present in the chat).

## Root cause investigation rules

When a suite fails, you MUST:

1. **Never skip or dismiss a failure** — every failure has a root cause. "Transient",
   "infrastructure issue", or "timing problem" are NOT root causes. Dig deeper.

2. **Trace the FULL error chain** — read the actual error output, not just the summary.
   SSH into the failing host if needed. Read installer logs, podman logs, systemd journal.
   Don't stop at "it failed" — find out WHY it failed.

3. **Distinguish symptom from cause** — "PermissionError on quay_sqlite.db" is a symptom.
   "reg-install-quay.sh doesn't check eval exit code" is the cause. Always reach the cause.

4. **If the fix is in ABA code, say so** — never work around an ABA bug in test code.
   If a test fails because ABA has a bug, the fix belongs in ABA, not in the suite.

5. **If you can't determine the root cause from logs alone**, say exactly what information
   is missing and what commands to run on next occurrence. Don't hand-wave.

6. **Never propose a fix that masks the real problem** — no `|| true`, no `sudo rm -rf`,
   no "add a retry". If cleanup fails, find out why cleanup fails. If install fails,
   find out why install fails.

7. **Log your investigation steps** — for each failure, document:
   - The exact error message and where it came from
   - What you checked (files, logs, host state)
   - What you concluded and why
   - What remains unknown (if anything)

## How to find this again

- File: **`ai/GOTEST.md`** (this file)
- Search: `gotest` or `GOTEST` in the repo, or open `ai/GOTEST.md`

## Reference

- E2E coordinator: `test/e2e/run.sh` (see `ai/HANDOFF_CONTEXT.md` → "How to Run Tests")
- Rules summary: `.cursor/rules/rules-of-engagement.mdc` (section "gotest")
