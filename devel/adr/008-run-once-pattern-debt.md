# ADR-008: run_once pattern — known technical debt

## Status
Accepted (documented 2026-06-06)

## Context
ADR-002 established the rule: **run_once calls MUST live outside Makefiles**.
The `cli/Makefile` refactoring (2026-06-06) fully implemented this for the CLI
download/install pipeline.  A subsequent code review found additional call sites
that still use the old patterns.  This ADR documents them and provides a fix
plan.

## Safety assessment — no race conditions in current code

**The code as-is will NOT cause race conditions or data corruption.**  Here is
why each violation is safe:

### Category 1: `run_once -w` (wait) inside Makefile recipes

The race condition fixed in `cli/Makefile` was caused by `run_once` **starting
background downloads** inside Make recipes.  Make's file-target evaluation saw
the partially-written tarball, considered the prerequisite satisfied, and
extracted a corrupt file.

The remaining Makefile violations all use **wait mode** (`-w`), which is
synchronous — the recipe blocks until the task completes, then proceeds.  No
background process races with Make's file-target evaluation.  These are
functionally equivalent to calling a blocking script inside a recipe.

### Category 2: `-w` combined with `-- command` (old start+wait pattern)

The canonical pattern is: start (with command), then wait (without command).
The old pattern passes the command on `-w` as a fallback: "start if not started,
then wait."  This works correctly — `run_once` saves the command to `cmd.sh` on
first invocation, and subsequent calls are idempotent.

### Category 3: Command string mismatches (guard REMOVED — see below)

TUI and `aba` CLI **share task IDs by design** — a user can stop the TUI, run
`aba`, and completed tasks (downloads, installs, version fetches) carry over.
This means both entry points register the same task IDs with equivalent
commands.  However, multiple callers used **semantically equivalent but
string-different** commands (relative vs absolute path, tab vs space, `-d`
vs `--dir`, `-s -C` vs `-sC`).

A command consistency guard was added to catch accidental task ID reuse, but
it compared literal strings and **caused a FATAL error in E2E production**
(`mirror:reg:download` — `make -s -C mirror` vs `make --no-print-directory`).
The guard was removed because:

1. Commands can be equivalent without being string-identical
2. Runtime string comparison causes false positives on legitimate usage
3. TUI ↔ `aba` task sharing is intentional and requires equivalent (not identical) commands
4. Descriptive task ID naming already prevents accidental collisions
5. The guard fired as FATAL in production (E2E cluster-ops suite)

The fix is to centralize commands as variables (preventing drift) rather than
enforcing string equality at runtime.

### Why fix the remaining debt?

1. **TUI ↔ aba interchangeability** — shared task IDs are by design.
   Centralizing commands ensures both entry points always produce the same
   `cmd.sh`, so switching between TUI and `aba` works seamlessly.
2. **Consistency** — the SPEC (rule 3) and ADR-002 say "outside Makefiles."
   Having exceptions undermines the rule.
3. **Grep-ability** — `grep -r run.once */Makefile*` should return zero hits.
4. **Future safety** — if someone copies one of these patterns to a download
   recipe (where it IS dangerous), the precedent is confusing.

---

## Findings

### Finding 1: `run-once.sh -w` inside Makefile recipes (ADR-002 boundary violation)

| File | Line | Target | Call |
|------|------|--------|------|
| `Makefile` | 42 | `vmw:` | `run-once.sh -w -m "Waiting for govc CLI tool" -i cli:install:govc -- make -sC cli govc` |
| `templates/Makefile.cluster` | 89 | `vmware.conf:` | Same govc wait |
| `templates/Makefile.mirror` | 160 | `save:` | `run-once.sh -w -m "Waiting for registry binary download" -i "mirror:reg:download" -- $(MAKE) download-registries` |
| `templates/Makefile.mirror` | 192 | `mirror-registry:` | Same registry download wait |
| `templates/Makefile.mirror` | 357, 365-366 | `clean:` / `reset:` | `run-once.sh -r -i "mirror:reg:install"` (state cleanup only) |

**Risk: NONE** — all are `-w` (synchronous wait) or `-r` (state reset).

### Finding 2: `-w` combined with `-- command` (old pattern)

| File | Line(s) | Task ID | Notes |
|------|---------|---------|-------|
| `scripts/include_all.sh` | 3545 | `$TASK_QUAY_REG` (`mirror:reg:install`) | `ensure_quay_registry()` — should split to start-then-wait |
| `scripts/cli-install-all.sh` | 61 | `cli:install:$item` | `--wait` mode passes `-q -w` + `-- make -sC cli $item` |
| `tui/v2/tui-mirror.sh` | 659, 728 | `aba:isconf:generate` | `-q -w` + `-- bash -lc "..."` |
| `tui/abatui.sh` | 2486, 2547, 2594, 2720, 2889, 2980 | `tui:isconf:generate` | 6 instances of `-q -w` + `-- bash -lc "..."` |

**Risk: NONE** — each task ID has exactly one command; guard never fires.

### Finding 3: Command string mismatches across callers (guard removed, centralizing)

TUI and `aba` share task IDs intentionally — so a user can switch between
them and completed tasks carry over.  Multiple callers registered the same
task ID with **semantically equivalent but string-different** commands.
The command consistency guard (since removed) compared literal strings, so
these mismatches caused a FATAL error in E2E production.

**Fix applied**: guard removed; commands centralized as variables in
`include_all.sh` so all callers use the same string.  Partially done —
remaining callers tracked below.

#### 3a. `$TASK_OC_MIRROR` (`cli:install:oc-mirror`)

| Caller | Command saved to `cmd.sh` |
|--------|---------------------------|
| `aba.sh:1421` | `make -sC cli oc-mirror` |
| `abatui.sh:3739` | `make -sC /home/steve/aba/cli oc-mirror` |
| `include_all.sh:3251` (via `CMD_INST_OC_MIRROR`) | `make -sC cli oc-mirror` |

**Mismatch**: relative `cli` vs absolute `$ABA_ROOT/cli`.

#### 3b. `$TASK_QUAY_REG_DOWNLOAD` (`mirror:reg:download`)

| Caller | Command saved to `cmd.sh` |
|--------|---------------------------|
| `aba.sh:1650` | `make -s -C mirror download-registries` |
| `abatui.sh:1953` | `make -s -C /home/steve/aba/mirror download-registries` |
| `tui-direct.sh:140` | `make -sC /home/steve/aba/mirror download-registries` |
| `tui-mirror.sh:1170` (wait+cmd) | `make -sC /home/steve/aba/mirror download-registries` |
| `Makefile.mirror:160` (wait+cmd) | `make --no-print-directory download-registries` |

**Mismatches**: relative vs absolute path; `-s -C` (space) vs `-sC` (no space);
`Makefile.mirror` uses `$(MAKE)` with `--no-print-directory` and no `-C` (runs
from within the mirror directory).

#### 3c. `ocp:<channel>:latest_version` (and `_previous`, `_older` variants)

| Caller | Command saved to `cmd.sh` |
|--------|---------------------------|
| `aba.sh:1412` | `bash -lc 'source ./scripts/include_all.sh; fetch_latest_version⇥stable'` **(TAB between function and arg)** |
| `abatui.sh:3725` | `bash -lc 'source ./scripts/include_all.sh; fetch_latest_version stable'` (space) |
| `include_all.sh:3492` | `bash -lc "source '/home/steve/aba/scripts/include_all.sh' && fetch_latest_version stable"` |
| `abatui.sh:895` | `bash -lc "source ./scripts/include_all.sh; fetch_latest_version stable"` |
| `tui-direct.sh:296` | `bash -lc "source ./scripts/include_all.sh; fetch_latest_version stable"` |

**Mismatches**: tab vs space; `./scripts` vs `$ABA_ROOT/scripts`; `;` vs `&&`;
single vs double quotes (though shell expansion happens before `run_once` sees
the args, so quotes don't differ in `cmd.sh` — but path and separator do).

#### 3d. `aba:isconf:generate`

| Caller | Command saved to `cmd.sh` |
|--------|---------------------------|
| `include_all.sh:3502` | `bash -lc "cd '/home/steve/aba' && aba -d mirror isconf"` |
| `tui-mirror.sh:585` (start) | `bash -lc "cd '/home/steve/aba' && aba isconf --dir mirror"` |
| `tui-mirror.sh:659` (wait+cmd) | `bash -lc "cd '/home/steve/aba' && aba isconf --dir mirror"` |

**Mismatches**: `aba -d mirror isconf` vs `aba isconf --dir mirror` (different
flag form `-d` vs `--dir`, different argument order).

### Finding 4: Non-centralized task IDs

| File | Task ID | Should be |
|------|---------|-----------|
| `templates/Makefile.mirror` | Hardcoded `"mirror:reg:download"` | `$(TASK_QUAY_REG_DOWNLOAD)` (not accessible from Make) |
| `templates/Makefile.mirror` | Hardcoded `"mirror:reg:install"` | `$(TASK_QUAY_REG)` |
| `tui/abatui.sh` | Hardcoded `"tui:isconf:generate"` | Should use a centralized variable |
| `tui/v2/tui-mirror.sh` | Hardcoded `"aba:isconf:generate"` | Should use a centralized variable |

**Risk: NONE** — IDs are stable strings, just not DRY.

---

## Fix plan

### Phase A: Mirror Makefile refactoring (medium effort, medium risk)

Move `run_once -w` calls out of `templates/Makefile.mirror` into wrapper
scripts, following the `cli/` pattern.

1. Create `scripts/mirror-download-registries.sh` (or extend existing scripts):
   - Wraps `make -sC mirror download-registries` with `run_once` start-then-wait
   - Replaces the `run-once.sh -w` call inside the `save:` and `mirror-registry:` recipes
2. Update `templates/Makefile.mirror`:
   - `save:` recipe calls `$(SCRIPTS)/mirror-download-registries.sh --wait`
   - `mirror-registry:` recipe calls the same script
   - `clean:` / `reset:` recipes call the script with `--reset` (or keep
     inline `run-once.sh -r` since reset is not a race risk — lowest priority)
3. Add `TASK_QUAY_REG_DOWNLOAD` and `TASK_QUAY_REG` to the centralized block
   in `include_all.sh` (already done — just ensure the new script uses them)

**Testing**: Existing E2E suites covering `make save`, `make mirror-registry`,
`make clean`, `make reset` in the mirror directory.

### Phase B: Govc wait in root/cluster Makefiles (small effort, low risk)

1. Replace `run-once.sh -w ... -i cli:install:govc -- make -sC cli govc` in:
   - `Makefile:42` (`vmw:` target)
   - `templates/Makefile.cluster:89` (`vmware.conf:` target)
   with a call to `ensure_govc` (which already exists and follows the correct
   pattern), wrapped in a small shell helper if needed since `ensure_govc`
   requires `include_all.sh` to be sourced.

**Testing**: E2E suites that create VMware clusters.

### Phase C: `ensure_quay_registry()` pattern fix (small effort, low risk)

1. Split `ensure_quay_registry()` in `include_all.sh` from:
   ```bash
   run_once -w -m "..." -i "$TASK_QUAY_REG" -- make -sC mirror mirror-registry
   ```
   to:
   ```bash
   run_once -i "$TASK_QUAY_REG" -- make -sC mirror mirror-registry
   run_once -w -m "..." -i "$TASK_QUAY_REG"
   ```

**Testing**: Mirror E2E suites.

### Phase D: `cli-install-all.sh --wait` pattern fix (small effort, low risk)

1. In `--wait` mode, split the loop to first do an idempotent start (without
   `-w`), then wait (with `-w`, without command).  Same pattern already used
   in `cli-download-all.sh --wait`.

**Testing**: `test-cli-download-pipeline.sh`, `test-download-before-install-race.sh`.

### Phase E: TUI isconf pattern fix (medium effort, low risk)

1. In both `tui/abatui.sh` and `tui/v2/tui-mirror.sh`, change the wait
   calls from:
   ```bash
   run_once -q -w -i "tui:isconf:generate" -- bash -lc "..."
   ```
   to:
   ```bash
   run_once -i "tui:isconf:generate" -- bash -lc "..."  # idempotent start
   run_once -q -w -i "tui:isconf:generate"              # wait only
   ```
2. Centralize the task ID and command as variables.

**Testing**: TUI functional tests, manual TUI walkthrough.

### Phase F: Centralize remaining task IDs (small effort, no risk)

1. Add `TASK_TUI_ISCONF`, `TASK_ABA_ISCONF`, `TASK_MIRROR_REG_DOWNLOAD`,
   `TASK_MIRROR_REG_INSTALL` etc. to `include_all.sh` centralized block.
2. Replace hardcoded strings with variable references.

**Testing**: All existing tests (variable rename is mechanical).

### Phase G: Centralize commands to prevent drift (medium effort, DONE/IN PROGRESS)

The command consistency guard was removed (it caused false-positive FATALs in
E2E).  Instead, centralize commands as arrays in `include_all.sh` and have
every caller reference the centralized variable.  This prevents drift without
brittle runtime string comparison.

**3a fix — `$TASK_OC_MIRROR`:**
- Add `CMD_INST_OC_MIRROR=(make -sC cli oc-mirror)` (already exists).
- Change `abatui.sh:3739` from `make -sC "$ABA_ROOT/cli" oc-mirror` to
  `"${CMD_INST_OC_MIRROR[@]}"`.

**3b fix — `$TASK_QUAY_REG_DOWNLOAD`:**
- Add `CMD_DL_QUAY_REG=(make -sC mirror download-registries)` to `include_all.sh`.
- Change all callers (`aba.sh:1650`, `abatui.sh:1953`, `tui-direct.sh:140`,
  `tui-mirror.sh:1170`) to use `"${CMD_DL_QUAY_REG[@]}"`.
- For `Makefile.mirror:160,192`: these are wait-with-command calls inside Make
  that should be fixed by Phase A (move to script).  Until then, they run from
  within the mirror directory so the command differs by design — but the `-w`
  call should drop the `-- command` entirely (Phase A).

**3c fix — `ocp:<channel>:latest_version`:**
- Create a helper function `_ocp_version_cmd()` in `include_all.sh` that
  returns the command array for a given channel+function.
- Fix the TAB in `aba.sh:1412-1417` to a space.
- Normalize all callers to use the same source path and separator.

**3d fix — `aba:isconf:generate`:**
- Create `CMD_ABA_ISCONF=(bash -lc "cd '${ABA_ROOT:-.}' && aba isconf --dir mirror")`
  in `include_all.sh`.
- Change `include_all.sh:3502` from `aba -d mirror isconf` to
  `aba isconf --dir mirror` (matching the TUI callers).
- Change all `tui-mirror.sh` callers to use `"${CMD_ABA_ISCONF[@]}"`.

**Testing**: All existing func tests + manual TUI walkthrough.  The guard
itself can be tested by temporarily making two callers overlap.

---

## Priority order

| Phase | Effort | Risk if skipped | Recommendation |
|-------|--------|-----------------|----------------|
| G (centralize cmds) | Medium | Drift risk only (guard removed) | Partially done; finish with remaining phases |
| C (ensure_quay) | Small | None | Quick win, bundle with G |
| D (cli-install-all) | Small | None | Quick win, bundle with G |
| F (centralize IDs) | Small | None | Mechanical, bundle with G |
| A (mirror Makefile) | Medium | None (wait mode, no race) | Do when touching mirror code next |
| B (govc Makefile) | Small | None | Do when touching vmw code next |
| E (TUI isconf) | Medium | None | Do with next TUI refactoring |

## Decision
Guard removed (caused E2E FATAL).  Commands partially centralized (mirror reg,
oc-mirror, isconf, version fetches).  Remaining phases are pattern consistency
fixes — fix opportunistically when touching the affected subsystems.
