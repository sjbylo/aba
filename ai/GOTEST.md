# gotest — autonomous E2E test loop

When the user says **"gotest"** (or "run the tests"), enter an autonomous loop and do not stop until they return.

## What to do

- **Test, monitor, fix, deploy, re-test** in a loop:
  - Run E2E tests (`test/e2e/run.sh`), monitor status and logs
  - Do not wait more that 10 mins between checking the status, otherwise you may miss a failed suite! 
  - Fix only **test code or suites** under `~/aba/test` (and `ai/` for docs/notes)
  - Stop suites if needed, deploy changes (`run.sh deploy --force`), re-run tests
- **Always ensure the dispatcher is running** — check at every monitoring cycle.
  If not running, start it: `run.sh run --all --force` (queues all suites, dispatches to idle pools).
  Never rely solely on manual SSH launches; the dispatcher handles queuing and pool allocation.
- **Do NOT stop to ask questions** — the user is away
- **Do NOT change any ABA core files** — only `test/` and `ai/`
- **Keep ALL pools busy** — queue additional suites on idle pools, even if already tested
- **Report a summary** when the user returns
- If a fix would require core ABA changes, **note it and move on** (do not change core)
- Do not add band-aids to any code, always find the root cause first!

## How to find this again

- File: **`ai/GOTEST.md`** (this file)
- Search: `gotest` or `GOTEST` in the repo, or open `ai/GOTEST.md`

## Reference

- E2E coordinator: `test/e2e/run.sh` (see `ai/HANDOFF_CONTEXT.md` → "How to Run Tests")
- Rules summary: `.cursor/rules/rules-of-engagement.mdc` (section "gotest")
