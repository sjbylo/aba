# Plan: Tidy Up ABA Output

## Goal

Minimal but useful output: show what ABA is doing, only show warnings and errors by default. Align with industry CLI conventions (terraform, helm, kubectl).

## Current State

- ~591 raw `echo` calls in `scripts/` vs ~405 `aba_info` calls -- heavy inconsistency
- `aba_info` gated by `INFO_ABA` (default on, `--quiet` disables)
- `aba_info_ok` always prints even in quiet mode -- inconsistent
- `aba_debug` gated by `DEBUG_ABA` (`--debug/-D`)
- `aba_warning` sleeps 1s after each warning -- unusual, slows scripts
- No `aba_error` function for non-fatal errors (only `aba_abort` which exits)
- `-v` means `--version`, not `--verbose` -- breaks CLI conventions
- Many scripts use raw `echo`, `echo_red`, `echo_yellow` bypassing the level system

## Related Backlog Items (already documented in ai/BACKLOG.md)

- **Replace dot-waiting loops with `aba_wait_show`** (lines 61-73)
- **Fix `aba_wait_show` timer freeze** (lines 186-207)
- **Clean up `aba startup` output redundancy** (lines 209-239)

## Proposed Changes

### Phase 1: Framework fixes (low risk)

1. **Add `aba_error` function** -- non-fatal error output (always prints, does NOT exit):
   ```bash
   aba_error() { echo_red "[ABA] Error: $@" >&2; }
   ```
   Location: `scripts/include_all.sh`

2. **Remove `sleep 1` from `aba_warning`** -- or make it opt-in via a flag (`-s`).
   Location: `scripts/include_all.sh`

3. **Gate `aba_info_ok` by `INFO_ABA`** (or rename to `aba_success` for clarity).
   Location: `scripts/include_all.sh`

4. **Add `--verbose` / `-V` flag** that enables more detail than default but less than debug.
   Location: `scripts/aba.sh`

### Phase 2: Migration (incremental, per-script)

5. **Audit and migrate raw `echo` to `aba_*` functions** -- start with the highest-traffic scripts:
   - `scripts/aba.sh` (~102 echo calls)
   - `scripts/cluster-config.sh` (~45)
   - `scripts/include_all.sh` (~152, many are helper definitions)
   
   Classification guide:
   - Progress/status messages -> `aba_info`
   - Success confirmations -> `aba_info_ok`
   - Non-fatal errors -> `aba_error`
   - Fatal errors -> `aba_abort`
   - Detailed tracing -> `aba_debug`

6. **Migrate dot-waiting loops to `aba_wait_show`** (from BACKLOG.md):
   - `scripts/day2-config-osus.sh` lines 112, 124, 276

### Phase 3: Specific output cleanups

7. **Clean up `aba startup` output** (from BACKLOG.md lines 209-239):
   - Show VM names only (strip vCenter paths)
   - Show node status once before and once after uncordon
   - Target: concise startup sequence

8. **Clean up `aba shutdown` output** -- same approach as startup

9. **Fix `aba_wait_show` timer freeze** (from BACKLOG.md lines 186-207):
   - Background the polled command, update timer every second

## Principles

- **Default output**: what ABA is doing + warnings + errors
- **`--quiet`**: warnings + errors only
- **`--verbose` / `-V`**: detailed progress (everything `aba_info` shows + more)
- **`--debug` / `-D`**: trace-level (timestamps, function names, variable dumps)
- **stderr**: all diagnostics (warnings, errors, debug)
- **stdout**: primary results only (e.g. cluster status, version info)
