# gotest — autonomous E2E monitoring loop

When the user says **"gotest"** (or "run the tests"), enter an autonomous monitoring loop and do not stop until they return.

## What to do

- **Monitor and investigate** in a loop:
  - Run E2E tests (`test/e2e/run.sh`), monitor status and logs
  - Do not wait more that 10 mins between checking the status, otherwise you may miss a failed suite!
  - When a suite fails, investigate the root cause: read logs, trace the error, identify the fix
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
- **Use `~/bin/notify.sh`** to send Telegram notifications while the user is AFK.
  Only use it during gotest (not when the user is present in the chat).

## How to find this again

- File: **`ai/GOTEST.md`** (this file)
- Search: `gotest` or `GOTEST` in the repo, or open `ai/GOTEST.md`

## Reference

- E2E coordinator: `test/e2e/run.sh` (see `ai/HANDOFF_CONTEXT.md` → "How to Run Tests")
- Rules summary: `.cursor/rules/rules-of-engagement.mdc` (section "gotest")
