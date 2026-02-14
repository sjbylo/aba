# Important Design Decisions

This file documents key architectural and design decisions made during development.
**Purpose:** Prevent reverting decisions or forgetting context in long sessions.

---

## Catalog Downloads (Jan 2026)

### Decision: Use Only 3 Catalogs
**Date:** Jan 18-19, 2026  
**Decision:** Download and use only **3 operator catalogs**:
- `redhat-operator`
- `certified-operator`  
- `community-operator`

**Explicitly EXCLUDED:**
- ~~`redhat-marketplace`~~ - REMOVED, do NOT add back!

**Rationale:**
- Marketplace catalog is redundant
- Reduces download time and storage
- All necessary operators are in the other 3 catalogs

**Implementation:**
- `download_all_catalogs()` in `include_all.sh` - 3 catalogs only
- `wait_for_all_catalogs()` in `include_all.sh` - waits for 3 catalogs
- `add-operators-to-imageset.sh` - checks only 3 catalog files

---

## Run Once Mechanism

### Decision: No Automatic Cleanup on Ctrl-C
**Date:** Jan 19, 2026  
**Decision:** Background `run_once` tasks continue running even if main script is interrupted.

**Rationale:**
- Consistency: Ctrl-C should behave like normal exit
- Efficiency: Don't kill downloads in progress
- Explicit control: User runs `aba reset` to clean up

**Removed:**
- `aba_runtime_cleanup()` function
- `aba_runtime_install_traps()` function
- Trap handlers for INT/TERM signals

---

## Output Formatting

### Decision: Selective [ABA] Prefix
**Date:** Jan 19, 2026  
**Decision:** Use `[ABA]` prefix only for operational messages, not documentation.

**Use [ABA] for:**
- User prompts (channel, version selection)
- Status updates ("Pull secret found", "Validating...")
- Success/error indicators ("✓ Authentication successful")
- Warnings and errors

**Do NOT use [ABA] for:**
- ASCII art banner
- Section headers ("Fully Disconnected (air-gapped)")
- Multi-line instructional text
- Command examples (`aba bundle...`)

**Rationale:**
- Matches industry conventions (git, docker, kubectl)
- More readable
- Distinguishes aba orchestration from wrapped tool output

---

## Connectivity Checks

### Decision: 10-Minute TTL Cache
**Date:** Jan 19, 2026  
**Decision:** Cache internet connectivity checks for 10 minutes.

**Implementation:**
- `cli:check:api.openshift.com` - 10 min TTL
- `cli:check:mirror.openshift.com` - 10 min TTL
- `cli:check:registry.redhat.io` - 10 min TTL

**Behavior:**
- Only show "Checking..." message when actually checking (not cached)
- Silent on cache hit

**Rationale:**
- Avoid excessive checks
- Still detect network changes within reasonable timeframe

---

## Error Handling Patterns

### Decision: Use `if` for Expected Failures
**Date:** Jan 19, 2026  
**Decision:** Use `if command; then ... else ...` pattern for commands that might fail.

**Do NOT use:**
```bash
trap - ERR
set +e
command
set -e
trap 'show_error' ERR
```

**DO use:**
```bash
if command 2>&1 >/dev/null; then
    # success
else
    # handle failure
fi
```

Or for showing errors but not propagating:
```bash
command || true
```

**Rationale:**
- Idiomatic bash
- Works with `set -e` and ERR traps naturally
- Cleaner, more maintainable

---

## Script Architecture

### Decision: $ABA_ROOT Only in aba.sh and TUI
**Date:** Jan 19, 2026  
**Decision:** The `$ABA_ROOT` variable must **ONLY** be used in:
- `scripts/aba.sh`
- `tui/abatui.sh`

**All other scripts MUST:**
1. Change to aba root at start: `cd "$(dirname "$0")/.." || exit 1`
2. Use relative paths: `scripts/...`, `mirror/...`, `templates/...`
3. Never reference `$ABA_ROOT`

**Rationale:**
- `aba.sh` sets `$ABA_ROOT` and changes to it before calling other scripts/functions
- Scripts may be called via `make` from subdirectories (e.g., `make -C mirror save`)
- When called via `make`, `$ABA_ROOT` is NOT set in the environment
- Using `cd` + relative paths works for both invocation methods

**Test Enforcement:**
- `test/func/test-aba-root-only-in-aba-sh.sh` - Automated check
- Runs as part of unit test suite
- **Will FAIL if $ABA_ROOT is added to any other script**

**Examples:**
```bash
# CORRECT (other scripts)
cd "$(dirname "$0")/.." || exit 1
source scripts/include_all.sh
mkdir -p mirror/.index

# INCORRECT (will break via make)
source "$ABA_ROOT/scripts/include_all.sh"
mkdir -p "$ABA_ROOT/mirror/.index"
```

---

## Makefile Design Principles

### Decision: Explicit Dependencies in Makefiles
**Date:** Jan 20, 2026  
**Decision:** All dependencies must be **explicit in Makefiles**, not hidden inside scripts.

**Rationale:**
- Makes dependency chain clear to anyone reading the Makefile
- Easier to understand build order without reading script internals
- Prevents unexpected behavior when targets run in parallel
- Standard Makefile best practice

**Example:**
```makefile
# CORRECT: Explicit dependency
save/imageset-config-save.yaml: ../aba.conf catalogs-download catalogs-wait
	$(SCRIPTS)/reg-create-imageset-config-save.sh

# INCORRECT: Hidden wait inside script
save/imageset-config-save.yaml: ../aba.conf catalogs-download
	$(SCRIPTS)/reg-create-imageset-config-save.sh  # Calls wait_for_all_catalogs() internally - NOT VISIBLE!
```

**Note:**
- Scripts MAY still include defensive waits internally (good practice)
- But Makefile MUST declare all true dependencies explicitly

---

## run_once vs Make File Dependencies

### Design Constraint: run_once State is Independent of Output Files
**Date:** Feb 2026  
**Status:** Known limitation, mitigated

**The Tension:**

Make's dependency model is file-based and self-healing: if a target file is
deleted, Make re-runs the rule to recreate it. The `run_once` mechanism is
state-based (`~/.aba/runner/<task-id>/`): once a task is marked "done", the
wrapper short-circuits and never invokes Make at all.

When `run_once` wraps a Make target, it **overrides Make's dependency tracking**.
If the output file is deleted manually (`rm mirror-registry`), Make would rebuild
it, but `run_once` says "already done" and silently skips.

**Scope of the Problem:**

Plain `make` is NOT affected. `make mirror-registry` after `rm mirror-registry`
works perfectly -- Make sees the missing file and re-runs the rule.

The issue only arises through `run_once`-wrapped code paths:
- Bundle mode (`scripts/aba.sh`): `run_once -i "$TASK_QUAY_REG" -- make -sC mirror mirror-registry`
- `ensure_quay_registry()`: `run_once -w -i "$TASK_QUAY_REG" -- make -sC mirror mirror-registry`

**Current Mitigation:**

Every `rm` in `make clean` / `make reset` is paired with a `run_once -r` call
to reset the corresponding task state. This ensures the official cleanup paths
work correctly.

**Remaining Risk:**

If a user deletes files manually with `rm` (bypassing `make clean`), `run_once`
state becomes stale and subsequent operations silently skip. This is acceptable
because:
1. Users should use `make clean` / `make reset` / `aba clean` -- never raw `rm`
2. Plain `make` (without `run_once`) is unaffected
3. `aba reset -f` does a global `run_once -G` cleanup as a last resort

**Possible Future Fix:**

Add an optional `-o <output_file>` flag to `run_once`. If the output file is
missing, treat the task as not-done even if state says "done". This would make
`run_once` self-healing like Make. Low priority since current mitigation works.

---

## Why run_once Cannot Be Replaced by make -j

### Question: Can `make -j` (parallel make) fully replace `run_once`?
**Date:** Feb 2026  
**Answer:** No. `make -j` covers ~30-40% of what `run_once` does. They solve different problems.

### What make -j CAN replace

**Simple file-producing tasks** (downloads, extractions) within a single Make
invocation. If all targets are in the Makefile with proper dependencies,
`make -j4` downloads tarballs in parallel and extracts them. Make's file-based
tracking handles "already done" for free. Example:

```makefile
oc.tar.gz:
	curl -OL $(mirror_url)/oc.tar.gz
~/bin/oc: oc.tar.gz
	tar xzf oc.tar.gz -C ~/bin
```

Plain `make -j` would parallelize this correctly.

### What make -j CANNOT replace

**1. Cross-process coordination (start early, wait later)**

This is the main reason `run_once` exists. The core pattern in `aba.sh`:

```bash
# scripts/aba.sh line ~872: Start extraction NOW (background, non-blocking)
run_once -i "$TASK_QUAY_REG" -- make -sC mirror mirror-registry

# ... hundreds of lines of other work happen ...

# scripts/include_all.sh (ensure_quay_registry): Wait when actually needed
run_once -w -m "Installing mirror-registry" -i "$TASK_QUAY_REG" -- ...
```

These are separate processes. `make -j` runs targets within a single `make`
invocation -- it cannot coordinate "start in script A, wait in script B."
Replacing this would require restructuring the entire orchestration into a
single Makefile (massive rewrite).

**2. Non-file-producing tasks**

```bash
# Version fetches (cached values, not files)
run_once -i ocp:stable:latest_version -- bash -lc 'fetch_latest_version stable'

# Connectivity checks with TTL
run_once -i cli:check:api.openshift.com -t 600 -- curl -sL https://api.openshift.com/
```

Make's model is "does the target file exist?" -- no file here, so Make
cannot cache these results.

**3. TTL-based caching**

`run_once -t 600` expires results after 10 minutes. Make has no TTL concept --
it only checks file modification times.

**4. Wait timeouts and user-facing messages**

```bash
run_once -w -W 300 -m "Waiting for redhat-operator catalog" -i "catalog:4.19:redhat-operator"
```

Custom wait messages (`-m`), timeouts (`-W`), and quiet mode (`-q`) are UX
features that Make does not provide.

**5. Error capture across invocations**

`run_once -e -i <task>` retrieves stderr from a previous run. Make either
rebuilds or doesn't -- it does not cache error information.

### Summary

| Capability                        | make -j | run_once |
|-----------------------------------|---------|----------|
| Parallel file-producing tasks     | Yes     | Yes      |
| File-based "already done" check   | Yes     | No (state-based) |
| Cross-process start/wait          | No      | Yes      |
| TTL-based caching                 | No      | Yes      |
| Non-file result caching           | No      | Yes      |
| Custom wait messages/timeouts     | No      | Yes      |
| Error capture across invocations  | No      | Yes      |

### Conclusion

`make -j` is great for what Make does (file dependencies within a single build).
`run_once` solves a different problem (cross-process task coordination with
caching). They are complementary, not interchangeable. The current architecture
is script-centric (bash scripts orchestrate the flow, Make handles individual
build steps, `run_once` bridges the gap with cross-process coordination).

---

## Notes for AI Assistants

- **Read this file at the start of each session**
- **Consult before making changes to areas covered here**
- **Update this file when new major decisions are made**
- **If uncertain, ask the user before reverting a decision**
