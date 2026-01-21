# ABA Development Rules of Engagement

This document contains the key rules, workflow, and architectural principles for working on the ABA project with AI assistance.

## Workflow

**Development Environment**: Cursor Remote-SSH connected directly to `registry4`

```
Cursor (on registry4)
---------------------
1. Edit files directly on registry4
2. Test changes immediately
3. Commit to git (when user approves)
```

**Key Points:**
- ✅ **Edit**: Changes are made directly on registry4 via Remote-SSH
- ✅ **Test**: Test immediately in the same environment
- ✅ **Commit**: Git operations happen on registry4 (with user permission!)
- ✅ **No sync needed**: Working directly on target machine
- ✅ **Real-time**: Changes are immediately available for testing

## 🚨 GIT COMMIT RULES 🚨

**CRITICAL: NEVER commit or push without explicit user permission!**

### ❌ DON'T:
- Automatically commit after making changes
- Commit "to save progress"
- Commit when user says "ok" or "continue" (unless specifically about commits)
- Push to origin without being asked

### ✅ DO:
- Make changes and show them to user
- Run syntax checks: `bash -n scripts/*.sh`
- **WAIT** for user to explicitly say "commit" or "push"
- Ask "Should I commit these changes?" when work is complete

### Only commit when user says:
- "commit this"
- "commit and push"
- "ok, commit to dev branch"
- Any explicit instruction to commit/push

**If uncertain, ASK!**

### Pre-Commit Checklist (AI Assistant Workflow)

**Use the automated pre-commit script:**

```bash
# For code commits (updates VERSION):
build/pre-commit-checks.sh

# For docs-only commits (skip VERSION update):
build/pre-commit-checks.sh --skip-version
```

**The script automatically:**
1. ✅ Updates `ABA_VERSION` timestamp in `scripts/aba.sh` (unless `--skip-version`)
2. ✅ Checks syntax of all shell scripts (96+ files)
3. ✅ Verifies we're on `dev` branch
4. ✅ Pulls latest changes with `git pull --rebase`

**After running the script:**

5. **Stage and show** for approval:
   ```bash
   git add <files>
   git status --short
   # Show user: "Ready to commit: <msg>. Files: <list>. Proceed?"
   # WAIT for explicit "ok, commit" approval
   ```

6. **Commit and push** (only after approval):
   ```bash
   git commit -m "type: description"
   git push origin dev
   ```

**Important Notes:**
- Use `build/pre-commit-checks.sh` for code changes (updates BUILD timestamp)
- Use `build/pre-commit-checks.sh --skip-version` for docs-only commits
- Infrastructure/build scripts go in `build/`, not in application code directories

### Versioning System

**Aba uses Semantic Versioning (SemVer): `MAJOR.MINOR.PATCH`**

- **MAJOR**: Breaking changes (CLI changes, workflow changes)
- **MINOR**: New features (backward compatible)
- **PATCH**: Bug fixes

**Files:**
- `VERSION`: Contains current version (e.g., "0.9.0")
- `CHANGELOG.md`: Human-readable changes (distilled bullet points)
- `scripts/aba.sh`: Reads VERSION at runtime, contains ABA_BUILD timestamp

**Version Display:**
```bash
# Show version:
aba --aba-version
# Output: aba version 0.9.0 (build 20260120220637)
#         Git: dev @ 0da6892

# Banner shows version automatically:
aba
#   __   ____   __  
#  / _\ (  _ \ / _\     Aba v0.9.0 - Install & manage air-gapped OpenShift quickly!
# /    \ ) _ (/    \    Follow the instructions below or see the README.md file for more.
# \_/\_/(____/\_/\_/
```

**Release Workflow:**

For periodic releases (~monthly), use the automated release script:

```bash
# Create a new release (e.g., 0.9.1):
build/release.sh 0.9.1 "Bug fixes and improvements"

# This script automatically:
# 1. Validates version format
# 2. Updates VERSION file
# 3. Embeds version in scripts/aba.sh
# 4. Moves [Unreleased] CHANGELOG items to new release section
# 5. Runs pre-commit checks (syntax + build timestamp)
# 6. Commits changes
# 7. Creates git tag v0.9.1
# 8. Shows next steps

# Then push:
git push origin dev
git push origin v0.9.1

# Create GitHub release (optional, via web interface):
# Visit: https://github.com/sjbylo/aba/releases/new?tag=v0.9.1
# - Select tag v0.9.1
# - Copy release notes from CHANGELOG.md
# - Click "Publish release"

# (Optional) Automated alternative (requires 'gh' CLI):
# build/create-github-release.sh v0.9.1

# (Optional) Merge to main for stable releases:
git checkout main
git merge --no-ff dev -m "Merge release v0.9.1"
git push origin main
git checkout dev
```

**Full workflow documentation**: See `build/RELEASE_WORKFLOW.md` for:
- Branch management (dev/main/hotfix)
- Tag management
- GitHub release creation (web interface + optional automation)
- Rollback procedures
- Best practices

**Note:** GitHub releases are optional. Git tags alone are sufficient for versioning.

**CHANGELOG.md Guidelines:**
- AI assistant adds distilled bullet points to `[Unreleased]` section
- User reviews before release/merge
- `build/release.sh` moves items from `[Unreleased]` to new release automatically
- Keep entries concise and user-focused

**Version vs Build:**
- `ABA_VERSION`: Semantic version from VERSION file (manually updated for releases)
- `ABA_BUILD`: Timestamp updated automatically by `build/pre-commit-checks.sh` on every commit

## File Modification Permissions

### ✅ CAN MODIFY (without explicit permission):
- `aba/tui/*` - TUI experimental work
- `aba/test/func/*` - Functional/unit tests
- `aba/ai/*` - AI documentation and rules

### ⚠️ CAN MODIFY (with user permission):
- `scripts/include_all.sh` - Core utilities (ask first!)
- `scripts/aba.sh` - Main entry point (ask first!)

### ❌ CANNOT MODIFY (unless explicitly requested):
- All other scripts in `scripts/`
- Low-level functions (e.g., `_print_colored`, `aba_info`, `aba_debug`)
- Makefiles (without discussion)
- Any file not explicitly mentioned

**Principle**: When in doubt, ASK before modifying!

## Coding Style Rules

### Indentation
- ✅ **Use TABS** for indentation, not spaces
- ✅ **Empty lines**: NO characters (no spaces, no tabs)
- ❌ **Don't**: Mix tabs and spaces
- ❌ **Don't**: Put whitespace on empty lines

**Example**:
```bash
if [ "$x" ]; then
	echo "good"  # <-- tab indent

	echo "still good"  # <-- empty line above has NO characters
fi
```

### Output Redirection

**General Unix Convention**:
- **Stdout**: Normal program output (human-readable text OR structured data)
- **Stderr**: Error messages, warnings, diagnostics, progress info

**General Rule**: Scripts can output human-readable text to stdout normally (like `ls`, `grep`, most commands).

**Special Case - `aba bundle --out -`**: 

Only for the `aba bundle --out -` command which needs to ONLY output tar data, all message output to screen must be on stderr.

When this command is used to pipe tar data (e.g., `aba bundle --out - | ssh host tar xf -`), ALL non-tar output must go to stderr to keep stdout pure binary. This means any script in the execution path of `aba bundle --out -` must redirect informational messages with `>&2`.

**Why**: Piped commands need clean binary streams. Human messages on stdout would corrupt the tar archive.

**Example**:
```bash
# In scripts called during "aba bundle --out -"
aba_info "Downloading binary data." >&2  # Message to stderr
make -s tar out=-                        # Tar data to stdout (no messages!)
```

**Testing**:
```bash
# Stdout should be pure tar (no text messages)
aba bundle --out - 2>/dev/null | file -
# Should output: /dev/stdin: POSIX tar archive
```

### Comments
- Add comments for "new-fangled" bash features
- Explain indirect expansion, arithmetic operations, array operations
- Keep comments concise but clear

**Example**:
```bash
arg="${!i}"  # Indirect expansion: if i=1, get $1
i=$((i + 1))  # Arithmetic expansion: increment i
```

### Error Handling and User Messages

**Use `aba_abort` in scripts, NEVER in TUI code:**

```bash
# ✅ CORRECT - In scripts/aba.sh and scripts/*.sh
if ! some_command; then
    aba_abort "Operation failed" \
        "Additional context line 1" \
        "Additional context line 2"
fi

# ❌ WRONG - In tui/abatui_experimental.sh
if ! some_command; then
    aba_abort "This will break the TUI!"  # NEVER DO THIS!
fi

# ✅ CORRECT - In TUI, use dialog boxes
if ! some_command; then
    dialog --msgbox "Operation failed\n\nPlease check logs" 0 0
    return
fi
```

**Why:**
- `aba_abort` calls `exit 1` which terminates the entire process
- In TUI, `exit` kills the dialog interface immediately (bad UX)
- TUI should use dialog boxes for errors and return to menu

**Standard message functions:**
- `aba_info` - Normal informational messages (white text)
- `aba_info_ok` - Success messages (green text)
- `aba_warning` - Warning messages (red text, non-fatal)
- `aba_abort` - Fatal errors (red text, exits script) - **Scripts only!**
- `aba_debug` - Debug messages (magenta, only if DEBUG_ABA=1)

### TUI Dialog Colors and Sizing

**CRITICAL**: Always use `--colors` flag with `dialog` to enable color codes in TUI:

```bash
# ✅ CORRECT - Colors will render properly
dialog --colors --backtitle "$(ui_backtitle)" --msgbox "\Z1Error!\Zn

Message text here" 0 0

# ❌ WRONG - Color codes display as literal text
dialog --backtitle "$(ui_backtitle)" --msgbox "\Z1Error!\Zn

Message text here" 0 0
```

**Color Codes** (only work with `--colors` flag):
- `\Z1` - Red text (errors)
- `\Z2` - Green text (success)
- `\Zn` - Reset to normal color

**Dialog Sizing**:
- ✅ **Use `0 0`** for auto-sizing (recommended)
- ❌ **Avoid hardcoded sizes** like `12 60` - text may overflow on different terminals

### Bash Quirks and Pitfalls

#### The `$(<"file" 2>/dev/null)` Bug

**CRITICAL**: `$(<"file" 2>/dev/null)` returns **EMPTY** in bash (bug/limitation in version 5.1.8+)

```bash
# ✅ WORKS
pid=$(<"$pid_file")

# ❌ BROKEN - Returns empty!
pid=$(<"$pid_file" 2>/dev/null)

# ✅ FIX - Check file exists first
if [[ -f "$pid_file" ]]; then
    pid=$(<"$pid_file")
fi
```

#### Stderr Redirection Best Practice

**RULE**: Only use `2>/dev/null` IF there is an **explicit reason** to do so.

**DON'T** blindly suppress errors:
```bash
# ❌ BAD - Hides real errors
result=$(some_command 2>/dev/null)
rm -f "$file" 2>/dev/null
```

**DO** handle errors properly:
```bash
# ✅ GOOD - Check conditions first
if [[ -f "$file" ]]; then
    result=$(<"$file")
fi

# ✅ GOOD - Let errors show
rm -f "$file"  # -f flag already ignores "file not found"

# ✅ ACCEPTABLE - When you genuinely need to ignore expected errors
# (Document WHY with a comment!)
reg_code=$(curl --connect-timeout 5 "$url" 2>/dev/null || true)  # Registry may be down
```

**Why:**
- Suppressing errors makes debugging difficult
- Many errors indicate real problems
- Use conditionals (`if [[ -f ... ]]`) instead of hiding errors
- Commands like `rm -f` already ignore missing files

**When `2>/dev/null` IS appropriate:**
- Network calls that may timeout/fail gracefully
- Optional features that may not be available
- Explicitly documented "try and ignore if unavailable" scenarios

## Architectural Principles

### 1. Use `run_once()` for Task Management

**CRITICAL RULE**: Scripts must **NEVER** access `~/.aba/runner/` directory directly. Only `run_once()` should interact with runner state.

**DON'T** do this:
```bash
# Manual locking, PID files, custom wait logic
if [ -f .lock ]; then wait; fi
do_task &
echo $! > .pid

# Accessing runner/ directory directly - FORBIDDEN!
pid_file="$HOME/.aba/runner/${task_id}.pid"
if [[ -f "$pid_file" ]]; then
    pid=$(<"$pid_file")
    echo "Waiting for PID $pid..."
fi
```

**DO** this:
```bash
# Let run_once handle everything
run_once -i "task:id" -- do_task                           # Start task
run_once -w -i "task:id" -- do_task                        # Wait for completion
run_once -w -m "Waiting for task..." -i "task:id"          # Wait with message (shows PID automatically)
run_once -e -i "task:id"                                   # Get stderr from failed task
run_once -w -W 600 -i "task:id"                            # Wait with 600s timeout
run_once -t 3600 -i "task:id" -- do_task                   # Cache result for 1 hour (TTL)
```

**Common Pattern - Error Handling**:
```bash
if run_once -w -m "Waiting for download..." -i "task:id"; then
    aba_info_ok "Task completed successfully"
else
    # Fetch error details from failed task
    error_output=$(run_once -e -i "task:id" | head -20)
    aba_abort "Task failed" \
        "Error details:" \
        "$error_output"
fi
```

**Benefits**:
- Automatic locking
- Background execution
- Built-in wait functionality with optional messages
- TTL-based idempotency
- Error output capture
- PID display (automatic when using `-m`)
- Clean cleanup on interrupt
- **Encapsulation**: Only `run_once()` accesses runner/ internals

#### run_once Flags Reference

**Core Flags:**
- `-i "task:id"` - Task identifier (required)
- `-w` - Wait for task completion
- `-m "message"` - Custom waiting message (shows PID automatically)
- `-q` - Quiet wait (suppress waiting messages for short tasks)
- `-e` - Fetch stderr from failed task
- `-t seconds` - TTL (cache successful result)
- `-W seconds` - Wait timeout
- `-r` - Reset/retry task
- `-c` - Clean up task
- `-F` - Clean up all failed tasks

**When to Use -q (Quiet Wait):**
```bash
# ✓ Use -q for short tasks (< 2 seconds) to avoid clutter:
run_once -w -q -i "cli:check:api.openshift.com" -- curl -sL --head https://api.openshift.com/

# ✗ DON'T use -q for long tasks - users need feedback:
run_once -w -q -i "cli:install:oc-mirror" -- make -sC cli oc-mirror  # BAD - could take minutes!

# ✓ Use -m for long tasks:
run_once -w -m "Waiting for oc-mirror binary download" -i "cli:install:oc-mirror" -- make -sC cli oc-mirror
```

#### scripts/run-once.sh Wrapper

**Purpose**: Makes `run_once()` available to Makefiles and external contexts where sourcing `include_all.sh` isn't practical.

**Location**: `scripts/run-once.sh` (executable wrapper)

**Usage in Makefiles:**
```makefile
# In any Makefile:
install-tool:
	@$(SCRIPTS)/run-once.sh -w -m "Waiting for tool" -i tool:install:name -- make -sC cli name
```

**How it works:**
```bash
#!/bin/bash
# scripts/run-once.sh
cd "$(dirname "$0")/.." || exit 1
source scripts/include_all.sh
run_once "$@"  # Pass all arguments to run_once function
```

#### CLI and Mirror Tool Installation Pattern

**CRITICAL**: ALL CLI and mirror tool installations MUST use `run_once` to leverage background downloads.

**Two-Phase Architecture:**

**Phase 1: Download (tarballs)**
```bash
# Started early in aba.sh/TUI:
scripts/cli-download-all.sh        # Starts background downloads
run_once -i mirror:reg:download -- make -sC mirror download-registries
```

**Phase 2: Install (extract to ~/bin)**
```bash
# When tool is actually needed:
run_once -w -m "Waiting for oc-mirror binary" -i cli:install:oc-mirror -- make -sC cli oc-mirror
run_once -w -m "Waiting for govc CLI tool" -i cli:install:govc -- make -sC cli govc
```

**Task ID Naming Convention:**

CLI Tools (managed in `cli/`):
```bash
cli:download:openshift-install-linux-4.19.21.tar.gz  # Download phase (tarball)
cli:install:openshift-install                        # Install phase (extract to ~/bin)
cli:install:oc
cli:install:oc-mirror
cli:install:govc
cli:install:butane
```

Mirror Tools (managed in `mirror/`):
```bash
mirror:download:docker-reg-image.tgz      # Download phase
mirror:install:docker-reg                 # Install phase
mirror:download:mirror-registry-amd64.tar.gz
mirror:install:mirror-registry
```

**Standard Pattern in Code:**
```bash
# In scripts that need CLI tools:
run_once -w -m "Waiting for openshift-install binary" -i cli:install:openshift-install -- make -sC cli openshift-install

# In Makefiles (use wrapper):
$(SCRIPTS)/run-once.sh -w -m "Waiting for govc CLI tool" -i cli:install:govc -- make -sC cli govc

# For ALL tools at once:
scripts/cli-install-all.sh --wait
```

**Benefits:**
- ✅ Background downloads started early are USED (not wasted)
- ✅ Proper waiting messages with PID display
- ✅ Consistent error handling via `run_once -e`
- ✅ Caching prevents redundant downloads
- ✅ Clear namespace separation (`cli:` vs `mirror:`)

### 2. Avoid `$ABA_ROOT` in Scripts
**Current State**: `$ABA_ROOT` is used in 146 places (needs cleanup!)

**Principle**: Only `aba.sh` should use `$ABA_ROOT`

**Why**: 
- Scripts are called via Makefiles which set the execution context (CWD)
- Scripts know their starting directory
- Using relative paths is cleaner and prepares for `/opt/aba` architecture

**Example**:
```bash
# WRONG (in most scripts)
index_file="$ABA_ROOT/mirror/.index/catalog-index"
make -sC "$ABA_ROOT/mirror" save

# RIGHT
index_file="mirror/.index/catalog-index"  # Script runs from aba root
make -sC mirror save
```

**Exception**: `aba.sh` discovers `$ABA_ROOT` and changes to it

### 3. Trust Makefile Execution Context (and Symlinks!)

**Key Principle**: Scripts don't "know" their execution context from where they're stored. The **Makefile** that calls them sets their working directory (CWD).

**Critical: Symlink Architecture**

Subdirectories have symlinks to shared resources, created by `make init`:
```bash
# Symlinks in subdirectories:
cli/scripts -> ../scripts
mirror/scripts -> ../scripts
mirror/cli -> ../cli              # NEW: Simplifies path management
mirror/templates -> ../templates
mirror/aba.conf -> ../aba.conf
compact/scripts -> ../scripts
sno/scripts -> ../scripts
sno2/scripts -> ../scripts
standard/scripts -> ../scripts
```

**Key Pattern: Use Simple Paths, Let Symlinks Handle Context**

Instead of managing different paths for different execution contexts, **symlinks allow all scripts to use the same simple paths**:

```bash
# All scripts use "cli" - symlinks make it work from any context:
make -sC cli oc-mirror              # ✓ Works from aba/
make -sC cli oc-mirror              # ✓ Works from aba/mirror/ (via cli -> ../cli symlink)

# All scripts use "scripts/" - symlinks make it work:
source scripts/include_all.sh       # ✓ Works from aba/
source scripts/include_all.sh       # ✓ Works from aba/mirror/ (via scripts -> ../scripts)
```

**Benefits of Symlink Approach:**
- ✅ **Consistent code**: All scripts use same paths (`cli`, `mirror`, `scripts`)
- ✅ **No context awareness needed**: Scripts don't need to know where they run
- ✅ **Simpler maintenance**: No special cases for subdirectory execution
- ✅ **Automatic setup**: `make init` creates all necessary symlinks

**When Symlinks Are Created:**
```bash
# In subdirectory Makefiles (e.g., mirror/Makefile):
init: .init
.init: ../aba.conf
	ln -fs ../templates
	ln -fs ../scripts
	ln -fs ../aba.conf
	ln -fs ../cli           # Creates cli symlink in mirror/
	mkdir -p regcreds
	touch .init
```

**run_once Task Consistency:**

Since all scripts now use the same paths (via symlinks), `run_once` commands are identical:
```bash
# All scripts use "cli" - no path variations needed
run_once -w -i cli:install:oc-mirror -- make -sC cli oc-mirror
```

**Important**: The **calling Makefile** determines the execution context (CWD), and **symlinks** provide consistent access to shared resources regardless of where the script runs.

#### Symlink Path Resolution in Scripts

**Problem**: When scripts need to cd based on their own location, `dirname "$0"` returns the symlink path, not the real path!

```bash
# ❌ BROKEN - When called via mirror/scripts/ symlink
cd "$(dirname "$0")/.." || exit 1
# dirname returns "scripts" (symlink), so cd goes to wrong place!

# ✅ CORRECT - Resolve symlinks first
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
cd "$SCRIPT_DIR/.." || exit 1
# pwd -P resolves symlinks to real physical path
```

**When to use**:
- Scripts that need to cd to a specific directory based on their location
- Examples: `download-catalog-index-simple.sh`, `reg-sync.sh`, `reg-save.sh`

**When NOT needed**:
- Scripts that just source files (source works fine with symlinks)
- Scripts that don't change directory

#### INFO_ABA in Makefile-Called Scripts

**Problem**: Scripts called from Makefiles don't get `INFO_ABA` set (it's only set by `aba.sh`), so `aba_info()` messages don't display!

**Solution**: Conditionally set `INFO_ABA` if not already set:

```bash
#!/bin/bash

# Enable INFO messages by default when called directly from make
# (unless explicitly disabled by parent process via --quiet)
[ -z "${INFO_ABA+x}" ] && export INFO_ABA=1

source scripts/include_all.sh
```

**How it works**:
- `${INFO_ABA+x}` returns `x` if variable is set (even if empty)
- `-z` tests if result is empty (meaning variable is unset)
- Only sets `INFO_ABA=1` if completely unset
- Respects `INFO_ABA=` from `aba --quiet`

**Which scripts need this**:
- Scripts called directly from Makefiles: `reg-sync.sh`, `reg-save.sh`, `download-catalogs-start.sh`, etc.
- NOT needed in scripts only called via `aba.sh`

### 4. Separation of Concerns
```
aba.sh           → Entry point, discovers root, handles arguments
include_all.sh   → Utility functions (aba_info, run_once, etc.)
scripts/*.sh     → Task-specific scripts, called via Makefiles
Makefiles        → Define targets and execution context
```

## If Cursor Crashes

### What You'll Lose:
- Detailed conversation history from the session
- Context about current work
- Specific fixes and decisions made

### What's Preserved:
- All file changes (saved on registry4)
- Git diffs show what changed
- System may provide a session summary

### Recovery Steps:

1. **Remind AI of Key Rules** (paste this section):
   ```
   - Working via Cursor Remote-SSH on registry4
   - Only modify: aba/tui, aba/test/func, scripts/include_all.sh (with permission)
   - Use run_once() for task management
   - Scripts use relative paths (minimal $ABA_ROOT usage)
   - Tabs for indentation, empty lines with NO whitespace
   - Never commit without explicit user permission
   ```

2. **State What You Were Working On**:
   - "We were fixing stdout leakage in `aba bundle -o -`"
   - "We were cleaning up $ABA_ROOT usage"
   - "We were implementing feature X"

3. **Check What Changed**:
   ```bash
   cd /home/steve/aba
   git status
   git diff
   ```

## Common Patterns

### Testing Changes
```bash
# Edit files directly in Cursor (via Remote-SSH)
# Files are already on registry4, no sync needed!

# Test immediately
cd /home/steve/aba
./aba test-command

# Check for errors
bash -n scripts/somescript.sh

# Run relevant tests
test/func/test-something.sh

# User commits when satisfied (don't commit without permission!)
git add scripts/somescript.sh
git commit -m "Fix XYZ"
```

### Adding New Features
1. Discuss design first
2. Implement directly on registry4 (via Remote-SSH)
3. Test immediately (no sync delay!)
4. Iterate until working
5. User commits when ready (always ask first!)

### Debugging
- Use `-D` flag for debug output: `aba -D command`
- Check log files in `~/.aba/runner/` for background tasks
- Use `run_once` logs for task debugging
- Debug output goes to stderr by default

### Bundle Creation with `--light`

**Purpose**: The `--light` flag avoids temporary disk space duplication when creating bundles.

**What it does:**
- Excludes large image-set archives (`mirror/save/mirror_*.tar`) from the bundle
- Reduces bundle from ~25GB to ~5GB (repo only)
- User must transfer image archives separately

**What it does NOT do:**
- ❌ Does NOT reduce total transfer size (still need to copy both files)
- ❌ Does NOT use hard links (tar archives can't preserve external hard links)

**When to use:**
- ✅ Bundle output on **same filesystem** as `mirror/save/`
- ✅ Limited disk space (avoids 2x temporary usage)
- ✅ Need to split transfer across different media

**When NOT to use:**
- ❌ Bundle output on **different filesystem** (no benefit)
- ❌ Plenty of disk space available
- ❌ Want single all-in-one bundle file

**Detection in TUI:**
- TUI uses `stat -c %d` to check device numbers (more reliable than filesystem type)
- Only offers `--light` when bundle and mirror are on same device
- Warns about disk space if full bundle chosen on same device

**Example workflow:**
```bash
# Create light bundle (same filesystem)
aba bundle --light -o /home/user/bundle.tar

# Result: bundle.tar (5GB) + mirror/save/mirror_*.tar (20GB) on disk = 25GB
# Must copy BOTH files to air-gapped environment

# On internal bastion:
tar xvf bundle.tar
mv mirror_*.tar aba/mirror/save/
cd aba
./install
```

## Testing Strategy

### Two Types of Tests in `test/func/`

#### 1. **Unit Tests** (Fast, Static)

**Purpose**: Quick regression checks, run frequently

**Characteristics**:
- ✅ Test ONE thing each
- ✅ Run in seconds
- ✅ Static analysis (grep, file checks, pattern matching)
- ✅ No network calls, no downloads
- ✅ Can run anytime without side effects

**Examples**:
```bash
test-no-aba-root-in-registry-scripts.sh  # Grep for $ABA_ROOT in specific files
test-run-once-task-consistency.sh         # Verify task ID usage patterns
test-symlinks-exist.sh                    # Check expected symlinks exist
test-aba-root-only-in-aba-sh.sh          # Verify only aba.sh uses $ABA_ROOT
```

**When to Run**: After every code change, before committing

#### 2. **Integration Tests** (Slow, Real Operations)

**Purpose**: Verify actual functionality works end-to-end

**Characteristics**:
- ✅ Test complete workflows
- ⏱️ May take minutes (network calls, downloads)
- 🌐 Real operations (downloads, file creation)
- 📝 Validates entire feature chains

**Examples**:
```bash
test-aba-root-cleanup.sh         # Downloads catalogs, tests run_once, verifies paths
test-catalog-helpers.sh          # Tests catalog helper functions
test-download-catalog-simple.sh  # Tests catalog download scripts
test-run-once-ttl.sh            # Tests run_once TTL behavior
```

**When to Run**: 
- After significant changes
- Before major releases
- When testing specific features
- Can be run repeatedly to verify fixes

### Running Tests

**Quick Unit Tests** (seconds):
```bash
# Run fast unit tests only
cd aba
test/func/test-no-aba-root-*.sh
test/func/test-symlinks-exist.sh
test/func/test-run-once-task-consistency.sh
```

**Full Integration Tests** (minutes):
```bash
# Run comprehensive tests (may download from network)
cd aba
test/func/test-aba-root-cleanup.sh
test/func/test-catalog-helpers.sh
```

**All Tests**:
```bash
cd aba
for test in test/func/test-*.sh; do 
    echo "=== Running $test ==="
    $test || echo "FAILED: $test"
done
```

### Creating New Tests

1. **Decide test type**: Unit (fast) vs Integration (slow)
2. **Name clearly**: `test-<feature>-<aspect>.sh`
3. **Make executable**: `chmod +x test/func/test-new.sh`
4. **Follow patterns**: Look at existing tests
5. **Use `aba_info_ok` and `aba_abort`** for output
6. **Test immediately**: Run `test/func/test-new.sh` to verify

### Test Maintenance

**AI Responsibility**:
- ✅ Keep tests up-to-date with code changes
- ✅ Fix broken tests immediately
- ✅ Add new tests for new features
- ✅ Run tests before declaring work complete

**User Responsibility**:
- ✅ Run tests after major changes
- ✅ Report test failures
- ✅ Approve/request new test scenarios

## Future Architecture: `/opt/aba`

**Vision**: Move to standard Linux FHS layout

```
/opt/aba/              # Static files (read-only)
  ├── scripts/         # All scripts
  ├── templates/       # Templates
  └── bin/aba          # Main command

~/aba/ OR /var/lib/aba/  # User data (read-write)
  ├── aba.conf         # User config
  ├── mirror/          # User data
  └── cli/             # Downloaded binaries
```

**Benefits**:
- Proper package management (RPM/DEB)
- Clear code vs data separation
- System-wide installation
- No path discovery needed
- Standard Linux conventions

**Current**: Everything in `~/aba/` (mixed code + data)

## Don't Forget!

- ✅ **Never commit without permission**: Always ask user first!
- ✅ **Remote-SSH workflow**: Already on registry4, no sync needed
- ✅ **Ask before modifying**: Unknown scripts
- ✅ **Use run_once**: For background/async work
- ✅ **Tabs only**: No spaces in indentation
- ✅ **Empty lines clean**: No whitespace
- ✅ **Stderr for messages**: Stdout for structured data
- ✅ **Relative paths**: Minimal $ABA_ROOT usage

## Troubleshooting Pattern for Users

**First Response to Issues**: Have user run `./install` to reset state.

```bash
./install  # Cleans ~/.aba/ state, reinstalls aba
```

The install script automatically:
- ✅ Cleans `~/.aba/*` including runner/ (stale locks, PIDs, exit codes)
- ✅ Reinstalls aba to $PATH
- ✅ Updates required RPM packages  
- ✅ Recreates SSH config

**Then retry the failing command.** This fixes most "weird state" issues.

**For deeper cleanup**:
```bash
./install
rm -rf mirror/.index/*     # Catalog indexes
make -C mirror clean       # Mirror state
```

**Why This Works**: 
- Removes stale `run_once` state that could block tasks
- Ensures latest aba version is installed
- Resets configuration to known-good state
- Idempotent - safe to run multiple times

---

**Last Updated**: January 20, 2026  
**Purpose**: Keep this document updated as rules evolve

