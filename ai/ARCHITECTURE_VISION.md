# ABA Architecture Vision

## Current State (As of 2026-01-18)

### Build System
- **Makefiles everywhere**: `cli/`, `mirror/`, `cluster-dir/`, and root-level orchestration
- **`aba.sh` wraps make**: Most commands go through `BUILD_COMMAND` → make target → script
- **Heavy make dependency**: Even simple script calls use make targets

### Error Handling
- **Scripts use `exit 1`**: Most scripts call `aba_abort` or `exit 1` on errors
- **Works with make**: Make stops on error, providing implicit error handling
- **Breaks with TUI**: When TUI sources `include_all.sh`, any `exit 1` kills the entire TUI
- **No consistent pattern**: Mix of functions and top-level script code, both using exit

### Script Organization
- **`scripts/include_all.sh`**: Massive utility library (~1800 lines) with functions, colors, validation, etc.
- **Individual scripts**: Often mix top-level code and functions
- **Source vs Execute**: Not always clear which scripts should be sourced vs executed

## Problems

### 1. Make Overuse
- Make adds overhead for simple script orchestration
- Not all workflows have file dependencies (make's strength)
- Makes debugging harder (extra layer of indirection)
- Forces serialization where parallelism might be better

### 2. Exit vs Return Confusion
- Functions in sourced files can't safely use `exit`
- No clear rule for when to exit vs return
- TUI crashes are hard to debug (no stack trace, just disappears)
- Testing is difficult (functions that exit can't be easily tested)

### 3. Architecture Inconsistency
- Same code path works differently depending on caller (make vs TUI vs direct)
- Error handling strategy varies by script
- Difficult to reason about failure modes

## Future Architecture Vision

### Make Usage: Only Where It Adds Value

**Keep make for:**
- **`cli/Makefile`**: Building, downloading, extracting binaries
  - Dependencies: `oc-mirror` needs extraction before use
  - Parallel downloads: `make -j` for multiple CLIs
  - File targets: Only rebuild/download if missing
  
- **`mirror/Makefile`**: Mirror registry workflows
  - Dependencies: Registry must exist before sync
  - File targets: imagesets, bundle creation
  - Complex multi-step workflows with checkpoints
  
- **`cluster-dir/Makefile`**: Cluster configuration generation
  - Dependencies: Templates → rendered configs
  - File targets: install-config.yaml, etc.
  - Rebuilds only when sources change

**Remove make for:**
- Simple script orchestration (`aba tui`, `aba bundle`, etc.)
- TUI workflows (already bypasses make)
- Script-to-script calls where there are no file dependencies
- Anything that's just "run this command"

### Error Handling: Functions Return, Scripts Exit

**Clear rule:**
- **Functions** (anything in `function_name() { }`) → **Always `return 1`** on error
- **Top-level script code** (not in a function) → **Can use `aba_abort` / `exit 1`**

**Benefits:**
- Functions are reusable from anywhere (CLI, TUI, tests)
- Callers decide how critical an error is
- TUI can handle errors gracefully with dialogs
- Testing becomes straightforward

**Pattern:**
```bash
# FUNCTION - returns error codes
download_catalog() {
    if [[ -z "$1" ]]; then
        echo "[ABA] Error: catalog name required" >&2
        return 1
    fi
    # ... do work ...
    return 0
}

# TOP-LEVEL SCRIPT CODE - can abort
if ! download_catalog "$catalog"; then
    aba_abort "Critical: Failed to download catalog"  # Exit script
fi
```

### Script Organization

**`scripts/include_all.sh`**:
- Pure function library
- No top-level execution code
- All functions return error codes
- Safe to source from anywhere (CLI, TUI, tests)

**Individual scripts**:
- Minimal top-level code (argument parsing, main flow)
- Call functions from `include_all.sh`
- Use `aba_abort` for critical errors in main flow
- Can `exit 0` at end of successful execution

**`aba.sh`**:
- Direct script calls for simple operations
- Make calls only for `cli/`, `mirror/`, `cluster-dir/`
- Proper error checking with `if ! script; then aba_abort; fi`
- Cleaner, more direct execution paths

### TUI Integration

**Current problem:**
```bash
source scripts/include_all.sh  # Any exit 1 kills TUI!
```

**Future solution:**
```bash
source scripts/include_all.sh  # Safe - no exits, only returns

# TUI can handle all errors gracefully
if ! wait_for_all_catalogs "$ver"; then
    show_error_dialog "Catalog download failed"
    return  # Back to menu
fi
```

## Migration Path

### Phase 1: Tactical Fixes (Current)
- ✅ Fix critical TUI-called functions (`wait_for_all_catalogs`, `download_all_catalogs`)
- ✅ Change `exit 1` → `return 1` for functions TUI uses directly
- ✅ Document the problem and vision (this file)
- Keep everything else as-is to avoid breaking existing workflows

### Phase 2: Function Library Cleanup
- Audit all functions in `include_all.sh`
- Ensure no function uses `exit` or `aba_abort`
- Add error messages with `echo "..." >&2`
- Return appropriate error codes (0=success, 1=error)
- Test each function independently

### Phase 3: Script Refactoring
- Update individual scripts to call functions and check return codes
- Move more logic into functions (easier to test/reuse)
- Reduce top-level script code to just main flow
- Keep `aba_abort` only in main script flow, not in functions

### Phase 4: Reduce Make Usage
- Identify make targets that don't need make
- Update `aba.sh` to call scripts directly where appropriate
- Keep make only for `cli/`, `mirror/`, `cluster-dir/`
- Simplify execution paths

### Phase 5: Testing & Validation
- Create tests for all refactored functions
- Test TUI extensively (no unexpected exits)
- Test CLI workflows (proper error handling)
- Ensure all error paths are covered

## Benefits of New Architecture

1. **TUI Stability**: No more mysterious exits, all errors handled gracefully
2. **Testability**: Functions with return codes are easy to test
3. **Reusability**: Functions can be called from anywhere safely
4. **Clarity**: Clear distinction between "library code" and "executable scripts"
5. **Performance**: Direct execution faster than make wrapper
6. **Debugging**: Clearer error messages, easier to trace failures
7. **Maintainability**: Simpler code paths, easier to understand and modify

## Examples

### Before (Current):
```bash
# include_all.sh
wait_for_all_catalogs() {
    if ! run_once -w ...; then
        aba_abort "Failed"  # KILLS TUI!
    fi
}

# aba.sh
make -C mirror download-catalogs  # Via make
```

### After (Vision):
```bash
# include_all.sh
wait_for_all_catalogs() {
    if ! run_once -w ...; then
        echo "[ABA] Error: Failed" >&2
        return 1  # Safe return
    fi
    return 0
}

# aba.sh (for non-file-dependent operations)
if ! ./scripts/download-catalogs.sh; then
    aba_abort "Failed to download catalogs"
fi

# aba.sh (for file-dependent operations - still use make)
make -C mirror imageset  # Keep make where it adds value
```

## Notes

- This is a **long-term vision**, not immediate refactoring
- Changes should be **incremental and tested**
- **Backward compatibility** is important during transition
- Focus on **high-value changes first** (TUI stability, frequently-used functions)
- Document decisions as we go

## Related Documents

- `RULES_OF_ENGAGEMENT.md` - Development workflow and coding standards
- `TUI_BUTTON_STANDARDS.md` - TUI-specific guidelines
- `RUN_ONCE_RELIABILITY.md` - Background task management

