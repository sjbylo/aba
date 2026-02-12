# ABA Technical Backlog

This file tracks architectural improvements and technical debt that should be addressed in future releases.

---

## High Priority

### 1. Systematic Script Directory Management Cleanup

**Status:** Backlog  
**Priority:** High  
**Estimated Effort:** Large (16+ scripts to review/update)  
**Created:** 2026-01-23

**Problem:**
Currently, scripts have inconsistent directory management practices:
- 16+ scripts do `cd "$(dirname "$0")/.."` to change to ABA_ROOT or mirror/
- Some scripts trust Makefile's CWD (correct per architecture)
- Some scripts force their own execution context (violates architecture)
- This inconsistency led to the need for CWD restoration in `run_once` self-healing

**Current Workaround:**
`run_once` saves and restores CWD during self-healing validation to handle mixed architecture.

**Architecture Principle (from RULES_OF_ENGAGEMENT.md):**
> **Key Principle**: Scripts don't "know" their execution context from where they're stored. The **Makefile** that calls them sets their working directory (CWD).

**Scripts That Need Review:**
```bash
# Scripts that cd to mirror/:
- scripts/reg-load.sh
- scripts/reg-save.sh
- scripts/reg-sync.sh
- scripts/download-catalogs-wait.sh
- scripts/download-catalogs-start.sh
- scripts/reg-create-imageset-config-sync.sh
- scripts/reg-create-imageset-config-save.sh
- scripts/check-version-mismatch.sh

# Scripts that cd to ABA_ROOT:
- scripts/ensure-cli.sh
- scripts/run-once.sh
- scripts/make-bundle.sh
- scripts/install-rpms.sh
- scripts/download-and-wait-catalogs.sh
- scripts/cli-install-all.sh
- scripts/cli-download-all.sh
- scripts/cleanup-runner.sh
- scripts/download-catalog-index.sh
```

**Recommended Approach:**

1. **Audit Phase** (1-2 hours)
   - For each script, determine if `cd` is necessary or violates architecture
   - Check if script can trust Makefile's CWD + symlinks
   - Document dependencies and callers

2. **Decision Criteria**
   - **Remove `cd`** if:
     - Script is called from Makefile (Makefile sets CWD)
     - Symlinks provide access to needed resources
     - Script doesn't need specific execution context
   - **Keep `cd`** if:
     - Script is called directly by users (e.g., `aba.sh`)
     - Script is a top-level entry point
     - No Makefile to set execution context

3. **Implementation** (4-6 hours)
   - Update scripts systematically
   - Test each change individually
   - Update callers if needed
   - Run full test suite after each group

4. **Validation**
   - All E2E tests pass
   - Mirror operations work (sync, save, load)
   - Bundle creation works
   - TUI works correctly

**Benefits:**
- ✅ Cleaner, more maintainable code
- ✅ Consistent with architecture principles
- ✅ Potentially remove CWD restoration from `run_once`
- ✅ Easier to debug (predictable execution context)
- ✅ Better preparation for `/opt/aba` migration

**Risks:**
- Breaking existing workflows if not careful
- Complex testing matrix (16+ scripts × multiple use cases)
- May uncover other hidden assumptions

**Dependencies:**
- None (can be done incrementally)

**Notes:**
- Current CWD restoration in `run_once` should **remain** until this cleanup is complete
- Can be done incrementally, one script or group at a time
- Consider documenting which scripts MUST cd (entry points) in RULES_OF_ENGAGEMENT.md

---

## Medium Priority

*(Add future items here)*

---

## Low Priority

*(Add future items here)*

---

## Completed

*(Move completed items here with completion date)*
