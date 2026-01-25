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
- `tui/abatui_experimental.sh`

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

## Notes for AI Assistants

- **Read this file at the start of each session**
- **Consult before making changes to areas covered here**
- **Update this file when new major decisions are made**
- **If uncertain, ask the user before reverting a decision**
