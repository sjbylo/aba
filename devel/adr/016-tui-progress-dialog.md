# ADR-016: TUI Progress Dialog (FIFO + PTY + mixedgauge)

## Status
Accepted

## Context

The TUI's `confirm_and_execute()` offers three execution modes:

1. **Terminal interactive** — full PTY, user sees everything
2. **Terminal non-interactive** — same, but prompts auto-answered (`-y`)
3. **TUI progressbox** — output scrolls in a dialog box

None of these show structured progress. Long operations (mirror save, sync,
load) run for 10-60+ minutes with scrolling log output. The user cannot see
which step is running, which steps remain, or how far along the workflow is.

### Rejected alternatives

- **Parsing stdout**: Fragile, couples display to log format, breaks when
  scripts change wording.
- **State files**: File truncation race condition (`echo > file` does
  `open(O_TRUNC)` then `write()` — concurrent readers see empty file at
  2.1% rate in testing). Atomic writes (`tmp+mv`) add complexity.
- **Background reader process**: Adds process coordination, signal handling,
  and cleanup complexity for no benefit over single-process design.
- **Polling / log scraping**: Same fragility as stdout parsing.

## Decision

### Architecture: FIFO + PTY + single-process event loop

Scripts emit structured events to a FIFO. The TUI reads the FIFO in a
single-process event loop and drives `dialog --mixedgauge` for a
multi-step progress display.

```
┌─────────────┐     FIFO      ┌──────────────────┐
│ ABA command  │──────────────▶│  TUI event loop   │
│ (in PTY)     │  aba_progress │  drain → draw     │
│              │               │  auto-complete    │
│  stdout/err  │──────────────▶│  prompt handling  │
│              │   pty-run.py  │                   │
└─────────────┘    output.log  └──────┬───────────┘
                                      │
                                      ▼
                               dialog --mixedgauge
```

### Components

1. **`aba_progress()`** (`scripts/include_all.sh`): 5-line function.
   Writes to `$ABA_PROGRESS_FIFO` if set, otherwise returns 0 immediately.
   Zero overhead in CLI mode.

2. **`pty-run.py`** (`tui/v2/pty-run.py`): Runs the ABA command in a real
   pseudo-terminal via `pty.fork()`. Captures output to a log file.
   Supports `--input-fifo` for forwarding keyboard input (interactive
   prompts).

3. **`tui-progress.sh`** (`tui/v2/tui-progress.sh`): Progress dialog engine.
   Single entry point: `_exec_with_progress "command" "Title"`.
   All state lives in bash associative arrays — no temp files, no races.

### Event protocol

Events are `|`-delimited lines written to the FIFO:

| Event | Format | Meaning |
|-------|--------|---------|
| PLAN | `PLAN\|id\|Display text` | Declare a step (sets order) |
| START | `START\|id` | Step is starting |
| DONE | `DONE\|id` | Step completed successfully |
| FAIL | `FAIL\|id` | Step failed |
| ERROR | `ERROR\|id\|message` | Error details for display |
| DETAIL | `DETAIL\|message` | Additional context |
| NEXT | `NEXT\|message` | Suggested next step |
| ABORT | `ABORT\|message` | User/script aborted |
| PROMPT | `PROMPT\|message` | Script waiting for input |
| PROMPT_DONE | `PROMPT_DONE` | Input received, resuming |

PLAN events arrive first (emitted by PHONY Makefile targets or script
preambles). The TUI waits up to 5 seconds for PLANs before drawing.
If none arrive (command doesn't use progress), falls back to progressbox.

### PHONY `_plan` targets in Makefiles

Makefile workflows emit PLANs via a PHONY prerequisite:

```makefile
_plan-save:
	@scripts/plan.sh save

save: _plan-save .init .rpmsext status-preflight data/imageset-config.yaml
	scripts/reg-save.sh
```

`_plan` targets are safe: they only write to the FIFO (no filesystem side
effects) and are a no-op when `ABA_PROGRESS_FIFO` is unset.

### Display guarantees

- **Frontier masking**: `_tp_draw()` finds the **last** step with a non-N/A
  status (the "frontier") and masks everything beyond it as N/A.  This
  replaces the earlier `_past_pending` mask and supports background tasks:
  a background step (In Progress at position 2) alongside sequential work
  (In Progress at position 6) displays correctly — only steps beyond the
  last real activity are masked.

- **Queued start (status 77)**: When START arrives before predecessors are
  visually complete, the step is queued (internal status 77) rather than
  shown as "In Progress". Auto-complete fills predecessors first, then
  transitions 77→7 (In Progress). Display maps 77→7.

- **Auto-complete with Skipped/Succeeded distinction**: 200ms between frames.
  Walks the `_tp_order` array top-to-bottom, finds the first pending step
  before an active/done step, and checks `_tp_real_done[]`:
  - If the step received real FIFO events (START/DONE) → Succeeded (0)
  - If the step never ran → Skipped (6)
  This gives correct labels immediately during execution, not just at the end.

- **Skipped sweep**: After the command finishes, `_tp_sweep_skipped()` marks
  any remaining steps that have no `_tp_real_done[]` entry as Skipped (6).
  Safety net for edge cases not caught by auto-complete.

- **Dynamic height**: Dialog height is `len(steps) + 8` (min 18).  Needed
  when sync PLANs arrive after install PLANs — the dialog grows mid-workflow.

- **Skipped in progress %**: Status 6 (Skipped) counts toward progress
  percentage alongside 0 (Succeeded), 3 (Completed), and 5 (Done).

### PLAN dedup and late PLANs

- **Dedup key is `_tp_text[]`**, not `_tp_status[]`.  If `_tp_text[$id]` is
  already set, the PLAN is silently ignored (duplicate).
- **Late PLANs**: A PLAN can arrive AFTER its START/DONE events (e.g. when
  Make runs a script before its `_plan` target fires).  The engine adds the
  step to `_tp_order` and sets `_tp_text`, but keeps the existing status.
  This avoids losing steps that executed before being formally declared.

### Crash detection

When the command exits with non-zero exit code and no step emitted FAIL,
the engine marks the last active step (status 7 or 77) as Failed and
generates a generic error message pointing to the output log.  This runs
in the main shell (not inside `$(_tp_finish_outcome)` subshell) so array
changes are visible.

### Background tasks (`run_once`)

Background tasks (started via `run_once`, waited for later) appear as
separate steps in the progress dialog:

```
Download CLI tools     [In Progress]  ← bg task, started early
Pre-flight checks      [Succeeded]
Save images            [In Progress]  ← sequential work
Wait for CLI tools     [   N/A   ]    ← not started yet
Pack transfer config   [   N/A   ]    ← masked (beyond frontier)
```

The frontier masking handles this naturally: the bg step stays visible
while later sequential steps progress.  When the wait step runs, it
shows In Progress until the bg download completes.

Scripts emit `START|id` when the bg task kicks off and `DONE|id` when
the wait succeeds.  The wait step has its own separate id (e.g.
`sv_cli_wait` vs `sv_tools`).

### FIFO mechanics

- FD opened read-write (`exec 7<>"$fifo"`) to avoid blocking on open.
- Non-blocking drain: `while read -t 0.01 -r -u 7 _line`.
- Done detection: `kill -0 $pid` (not EOF — read-write FD never gets EOF).
- After process exit, one final drain with `read -t 0.2` to catch trailing events.

### Outcome dialogs

| Outcome | Dialog |
|---------|--------|
| Success | `✓ Complete` msgbox |
| Error | `✗ Error` with View Output button (loops back to error) |
| Abort | `Aborted` msgbox with reason |
| Stopped | `Stopped` msgbox (incomplete steps) |

Error dialog uses `while dialog --yesno` loop — View Output returns to the
error dialog, only OK exits to the caller.

### Graceful fallback

If no PLAN events arrive within 5 seconds, `_exec_with_progress()` returns 2.
The caller can then fall back to `_exec_in_tui()` (progressbox). This means
workflows without progress events work unchanged.

## Implementation phases

### Phase 0 — Foundation (non-disruptive) ✅
- `aba_progress()` in `include_all.sh`
- `pty-run.py` in `tui/v2/`
- `tui-progress.sh` in `tui/v2/` (sourced by `abatui2.sh`)
- No existing functions modified, no workflows changed

### Phase 1 — day2.sh ✅
- PLAN/START/DONE events in `scripts/day2.sh` and `scripts/day2-config-*.sh`
- TUI menu entries call `_exec_with_progress()`

### Phase 2 — Mirror workflows ✅
- START/DONE events in `reg-save.sh`, `reg-load.sh`, `reg-sync.sh`,
  `reg-install.sh`, `reg-install-docker.sh`, `reg-install-quay.sh`,
  `reg-uninstall*.sh`, `install-rpms.sh`, `make-bundle.sh`,
  `download-catalogs-wait.sh`
- Background `run_once` tasks (CLI downloads) shown as visible progress
  steps in `reg-save.sh` and `make-bundle.sh`
- TUI callers wired in `tui-mirror.sh`, `tui-disco.sh`, `tui-lib.sh`

### Phase 3 — Cluster workflows ✅
- START/DONE events in `cluster-graceful-shutdown.sh`, `cluster-startup.sh`,
  `cluster-upgrade.sh`
- TUI callers wired in `tui-cluster.sh`

### Phase 4 — Engine hardening ✅
- `_tp_real_done[]` tracking: real-time Skipped vs Succeeded labels
- `_tp_sweep_skipped()`: final-pass safety net
- PLAN dedup and late PLAN handling
- Crash detection: non-zero exit without FAIL → marks last active step
- Frontier masking: supports background tasks alongside sequential work
- Dynamic dialog height
- Demo in `devel/tui-progress-demo/` covers all scenarios

### Phase 5 — PHONY `_plan-*` Makefile targets ✅
- `_plan-install`, `_plan-sync`, `_plan-save`, `_plan-load`, `_plan-uninstall`
  PHONY targets in `mirror/Makefile`
- `scripts/progress-plan.sh` — single plan emitter with cases per workflow (mirror, bundle, day2, cluster-*)
- PLANs removed from all mirror scripts (START/DONE/FAIL remain)
- `_plan-install` checks `.available` — emits nothing when cached
- Prereq ordering ensures install PLANs arrive before sync PLANs

### Phase 6 — Remaining work
- Rich error dialogs with structured guidance
- Output scrollback from progress view

## Consequences

- Users see structured multi-step progress for long operations.
- CLI mode is completely unaffected (`aba_progress` is a no-op).
- Scripts gain one function call per phase boundary — minimal intrusion.
- Makefiles gain one PHONY prerequisite per workflow — no side effects.
- TUI progress is decoupled from script output format — display survives
  any log wording changes.
- `dialog --mixedgauge` status codes (0=Succeeded, 1=Failed, 6=Skipped,
  7=In Progress, 9=N/A) are well-supported on RHEL 8/9.
- Background tasks (`run_once` downloads) are visible in the progress
  dialog alongside sequential work — no masking conflicts.
- Unexpected script crashes are detected and surfaced cleanly — the user
  sees "Failed" and an error dialog rather than a hung progress display.
- Demo in `devel/tui-progress-demo/` serves as reference and test harness.
