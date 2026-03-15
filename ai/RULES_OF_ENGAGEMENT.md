# ABA Development Rules of Engagement

> **RULE #1: NEVER commit or push without explicit user permission.**
> After making file edits, STOP. Show the user what changed. Ask: "Should I commit and push?"
> Do NOT proceed until the user explicitly says "commit", "push", or "commit and push".
> "yes" to a file edit does NOT mean "yes, commit it" — it only means "yes, make the edit".
> NEVER use `required_permissions: ["all"]` for `git commit` or `git push` commands.
> They must run inside the sandbox so Cursor's approval gate is enforced.

This document contains the key rules, workflow, and architectural principles for working on the ABA project with AI assistance.

## Workflow

**Development Environment**: Cursor Remote-SSH connected directly to `dev host`

```
Cursor (on dev host)
---------------------
1. Edit files directly on the dev host (usually bastion or registry4)
2. Test changes immediately
3. Commit to git (when user approves)
```

**Key Points:**
- ✅ **Edit**: Changes are made directly on dev host via Remote-SSH
- ✅ **Test**: Test immediately in the same environment
- ✅ **Commit**: Git operations happen on dev host (with user permission!)
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

**Default Workflow: Commit AND Push Together**

Unless explicitly told "commit only" or "don't push yet":
1. ✅ Commit the changes
2. ✅ Immediately push to origin/dev

**Why This Matters:**
- Bundles contain snapshots of code from the remote repo
- Testing disconnected bundles requires latest code on remote
- User's workflow depends on remote being current
- Provides immediate backup of work

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
   git push origin dev              # ALWAYS push after commit (unless explicitly told "commit only")
   ```

**Commit Message Rules:**
- ✅ **Clear, concise messages**: Describe what and why
- ❌ **NO "Co-authored-by" tags**: Never add `Co-authored-by: Cursor` or similar AI attribution
- ✅ **Multi-line format**: Use short summary, then detailed body if needed

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
- `aba/tui/*` - TUI work
- `aba/test/func/*` - Functional/unit tests
- `aba/test/e2e/*` - E2E test framework
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

# ❌ WRONG - In tui/abatui.sh
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

### TUI Peek-Then-Wait Pattern

**CRITICAL**: For optimal UX, always check if background tasks are done BEFORE showing a "Please wait..." dialog.

**The Pattern**:
1. Use `run_once -p` (peek) to check if task is complete
2. Only show `--infobox` if we actually need to wait
3. Use `run_once -q -w` (quiet wait) to prevent output from overwriting the infobox

```bash
# ✅ CORRECT - Peek first, then conditionally wait
local need_wait=0
if ! run_once -p -i "task:id"; then
    need_wait=1
fi

if [[ $need_wait -eq 1 ]]; then
    # Show infobox ONLY if we need to wait
    dialog --backtitle "$(ui_backtitle)" --infobox "Please wait… fetching data" 5 80
    # Use -q flag to prevent run_once from overwriting the infobox
    run_once -q -w -i "task:id" -- command args
else
    log "Data already available, no wait needed"
fi

# Now use the cached result
result=$(get_cached_data)
```

```bash
# ❌ WRONG - Always shows wait dialog, even when data is ready
dialog --infobox "Please wait..." 5 80
run_once -w -i "task:id"
result=$(get_cached_data)
```

**Benefits**:
- First time: Shows wait dialog (background task still running)
- Subsequent times: Instant display (data cached, no unnecessary wait dialog)
- Better UX: No flashing dialogs when data is already available

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

#### Never Pipe SSH Keys Through Multi-Hop SSH Chains

**CRITICAL**: Piping file content through multi-hop SSH (e.g. `cat key | ssh hop1 'ssh hop2 "cat >> authorized_keys"'`) can introduce **invisible corruption** — missing newlines, null bytes, or encoding artifacts that make the file unparsable by `sshd`, even though `cat` shows correct-looking content.

```bash
# ❌ DANGEROUS - Can corrupt authorized_keys silently
cat ~/.ssh/id_rsa.pub | ssh hop1 'ssh hop2 "cat >> ~/.ssh/authorized_keys"'

# ✅ SAFE - Use scp or write the key on the target host directly
scp ~/.ssh/id_rsa.pub hop1:/tmp/key.pub
ssh hop1 'scp /tmp/key.pub hop2:/tmp/key.pub'
ssh hop1 'ssh hop2 "cat /tmp/key.pub >> ~/.ssh/authorized_keys"'

# ✅ SAFEST - Recreate the file from scratch on the target
ssh target 'cp ~/.ssh/id_rsa.pub ~/.ssh/authorized_keys'
```

**Real example:** Multi-hop append corrupted `authorized_keys` on con3, breaking SSH for ALL sources. The file looked correct in `cat` output. `sshd` logged NO auth failures (silent rejection). Recreating the file from scratch fixed it.

#### Stderr Redirection Best Practice

**RULE**: Only use `2>/dev/null` or `2>&1` IF there is an **explicit reason** to do so.

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

#### Centralized CLI Tool Management Functions

**Purpose**: Single source of truth for CLI tool installation, preventing accidental task ID changes and ensuring consistency.

**Location**: `scripts/include_all.sh`

**Available Functions:**
```bash
# Task IDs (constants - NEVER change these!)
readonly TASK_OC_MIRROR="cli:install:oc-mirror"
readonly TASK_OC="cli:install:oc"
readonly TASK_OPENSHIFT_INSTALL="cli:install:openshift-install"
readonly TASK_GOVC="cli:install:govc"
readonly TASK_BUTANE="cli:install:butane"
readonly TASK_QUAY_REG="mirror:reg:install"

# Download all CLI tarballs (background, non-blocking)
start_all_cli_downloads()              # Starts downloads in background
wait_all_cli_downloads()               # Waits for all downloads to complete

# Ensure tools are installed (waits for download + installs)
ensure_oc_mirror()                     # Ensures oc-mirror in ~/bin
ensure_oc()                            # Ensures oc in ~/bin
ensure_openshift_install()             # Ensures openshift-install in ~/bin
ensure_govc()                          # Ensures govc in ~/bin
ensure_butane()                        # Ensures butane in ~/bin
ensure_quay_registry()                 # Ensures mirror-registry (Quay) is installed

# Get error output from failed task
get_task_error "$TASK_ID"              # Returns stderr from failed task
```

**Usage in Scripts:**
```bash
#!/bin/bash
source scripts/include_all.sh

# Ensure tool is available (waits if needed, starts download if not running)
if ! ensure_oc_mirror; then
	error_msg=$(get_task_error "$TASK_OC_MIRROR")
	aba_abort "Failed to install oc-mirror" "$error_msg"
fi

# Now use the tool
oc-mirror list operators ...
```

**Usage in Makefiles** (via wrapper script):
```makefile
# Use scripts/ensure-cli.sh wrapper
install-tool:
	@$(SCRIPTS)/ensure-cli.sh oc-mirror        # Ensures oc-mirror
	@$(SCRIPTS)/ensure-cli.sh mirror-registry  # Ensures mirror-registry
	@$(SCRIPTS)/ensure-cli.sh govc             # Ensures govc
	# ... rest of target
```

**The ensure-cli.sh Wrapper:**

**Location**: `scripts/ensure-cli.sh`

**Purpose**: Allows Makefiles to call `ensure_*()` functions without sourcing `include_all.sh`

**Implementation:**
```bash
#!/bin/bash
# Wrapper to call ensure_* functions from Makefiles
# Usage: ensure-cli.sh {oc-mirror|oc|openshift-install|govc|butane|mirror-registry}

cd "$(dirname "$0")/.." || exit 1
source scripts/include_all.sh

tool="$1"

case "$tool" in
    oc-mirror)
        ensure_oc_mirror
        ;;
    oc)
        ensure_oc
        ;;
    openshift-install)
        ensure_openshift_install
        ;;
    govc)
        ensure_govc
        ;;
    butane)
        ensure_butane
        ;;
    quay-registry)
        ensure_quay_registry
        ;;
    *)
        echo "Error: Unknown tool: $tool" >&2
        echo "Usage: $0 {oc-mirror|oc|openshift-install|govc|butane|mirror-registry}" >&2
        exit 1
        ;;
esac
```

**Example from mirror/Makefile:**
```makefile
.available: .init .rpmsext mirror.conf
	@$(SCRIPTS)/ensure-cli.sh mirror-registry  # Waits/starts download, shows message
	@make -sC . mirror-registry                 # Extracts tarball
	$(SCRIPTS)/reg-install.sh                   # Installs registry
	...
```

**Benefits:**
- ✅ **Single source of truth** - Task IDs defined once in `include_all.sh`
- ✅ **No accidental changes** - Task IDs are constants, hard to change by accident
- ✅ **Consistent behavior** - All scripts use same functions
- ✅ **Simple Makefile usage** - Just call `ensure-cli.sh <tool-name>`
- ✅ **Automatic error handling** - Functions handle download + install + errors
- ✅ **Prevents race conditions** - Properly waits for downloads before extraction

**Migration Pattern:**

**Before (problematic):**
```bash
# In scripts - error prone, task IDs can drift
run_once -w -m "Waiting for oc-mirror" -i cli:install:oc-mirror -- make -sC cli oc-mirror

# In Makefiles - can fail if task not started
@$(SCRIPTS)/run-once.sh -w -i mirror:reg:download  # ERROR if not started!
```

**After (correct):**
```bash
# In scripts - use centralized function
ensure_oc_mirror

# In Makefiles - use wrapper
@$(SCRIPTS)/ensure-cli.sh mirror-registry
```

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
- Examples: `download-catalog-index.sh`, `reg-sync.sh`, `reg-save.sh`

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

### 5. `clean` vs `reset` — Know the Difference

**`aba clean` / `make clean`**: Removes derived/temporary files only. The user can
continue using ABA afterwards — all workflows (save, load, sync, install, etc.)
will regenerate what they need.  Config files (`mirror.conf`, `cluster.conf`),
tarballs, registry state, and `~/.aba/mirror/` credentials are preserved.

**`aba reset` / `make reset`**: Nuclear option — returns the ABA directory to its
original post-clone state (like `make distclean`).  Deletes everything `clean`
does, plus tarballs, saved images, config files, and more.  ABA is **not expected
to work normally** after a reset without re-running `./install` and reconfiguring.
This is an internal/maintenance command and is not shown in user-facing help.

**Rules:**
- Use `clean` for mid-workflow restarts (e.g. repeat a `save` or `install`).
- Use `reset` only when the repo **must** be returned to its original state.
- Never use `reset` in the middle of a test suite — it destroys state that
  subsequent steps depend on.
- In E2E tests, prefer `aba clean` for end-of-test cleanup.  Use `rm -rf` only
  for pre-test removal of entire cluster directories.

### 6. `normalize*()` Functions: Config Values Only

**CRITICAL RULE**: `normalize-aba-conf()`, `normalize-mirror-conf()`, and `normalize-cluster-conf()` must **only** echo config file values with sensible defaults. They must **never** compute derived values.

**DON'T** put derived values in normalize functions:
```bash
# ❌ WRONG - in normalize-mirror-conf()
export regcreds_dir=$HOME/.aba/mirror/$mirror_name   # Derived from mirror_name!
```

**DO** compute derived values in the calling script:
```bash
# ✅ CORRECT - in the script that needs regcreds_dir
source <(normalize-mirror-conf)
regcreds_dir=$HOME/.aba/mirror/$mirror_name
```

**Why**: Two separate bugs were caused by putting derived values in normalize functions. The derived value was computed before dependent variables were set (e.g. `$mirror_name` was empty), producing wrong paths like `~/.aba/mirror/` instead of `~/.aba/mirror/sno`. The normalize function runs early in the pipeline and cannot know the calling context.

**Rule of thumb**: If a value does not appear in `aba.conf`, `mirror.conf`, or `cluster.conf`, it does not belong in the corresponding normalize function.

### 7. Make-First Architecture

**Key Principle**: ABA was primarily make-based from the start. The `aba` CLI (`scripts/aba.sh`) is a convenience wrapper that resolves directories, parses CLI flags, and calls `make`.

**Every operation must remain callable via `make` directly:**
```bash
# These must ALWAYS work, with or without the aba wrapper:
make -C mirror install          # Install registry
make -C mirror save             # Save images
make -C sno cluster             # Create cluster
make -C mirror unregister       # Deregister existing registry
```

**DON'T** put essential logic only in `aba.sh`:
```bash
# ❌ WRONG - logic that only works via "aba" CLI
# Adding a critical step inside aba.sh's flag handling that make can't reach
```

**DO** keep logic in scripts called by Makefile targets:
```bash
# ✅ CORRECT - Makefile target calls script, aba.sh calls same Makefile target
# mirror/Makefile:  unregister: ; $(SCRIPTS)/reg-unregister.sh
# aba.sh:           make -C "$dir" unregister
```

**Why**: Advanced users and automation systems use `make` directly. Breaking `make` targets silently degrades the product for power users and CI pipelines.

**DON'T** call scripts directly:
```bash
# ❌ WRONG - bypasses Makefile dependency tracking and marker management
bash scripts/reg-install.sh
bash scripts/reg-uninstall.sh
```

```bash
# ✅ CORRECT - Makefile manages .available, .init, .unavailable markers
make -C mirror install
make -C mirror uninstall
aba -d mirror install
aba -d mirror uninstall
```

**Why**: Makefile targets manage dependency markers (`.available`, `.init`, `.unavailable`).
Calling scripts directly skips this, leaving markers out of sync with actual state.
This also means scripts should NOT contain `rm -f .available` or `touch .available` —
that is the Makefile's responsibility.

## If Cursor Crashes

### What You'll Lose:
- Detailed conversation history from the session
- Context about current work
- Specific fixes and decisions made

### What's Preserved:
- All file changes (saved on dev host)
- Git diffs show what changed
- System may provide a session summary

### Recovery Steps:

1. **Remind AI of Key Rules** (paste this section):
   ```
   - Working via Cursor Remote-SSH on dev host
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
# Files are already on dev host, no sync needed!

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
2. Implement directly on dev host (via Remote-SSH)
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

### E2E Golden Rules

These are inviolable principles for writing and maintaining E2E tests.  They are also
documented at the top of `test/e2e/lib/framework.sh`.

1. **Tests MUST fail on error.**  Never mask underlying issues.
   If something breaks, the test must stop and report it.
   **Especially in test/infrastructure code: never silently skip over or work around
   an unexpected state.  Surface it loudly so the operator can act.**

2. **ABSOLUTELY NEVER use `2>/dev/null`, `>/dev/null`, or `>/dev/null 2>&1` in test commands.**
   Stderr output is diagnostic gold.  Suppressing it hides root causes and wastes
   hours of debugging when something goes wrong.  This applies to ALL commands inside
   `e2e_run`, `e2e_run_remote`, `e2e_run_must_fail`, and any command string passed to
   the E2E framework.

   **How to avoid it:**
   - If a command might fail harmlessly → use `e2e_diag` or `e2e_diag_remote`
     (exit code is ignored, but ALL output is preserved in the log)
   - If a file might not exist → use `rm -f` (already ignores missing files)
   - If a precondition is uncertain → use an explicit check:
     `if [ -f X ]; then rm X; fi`
   - If a container might not exist → `podman rm -f name` already tolerates
     "no such container" without needing `2>/dev/null`
   - If a service might already be stopped → check first:
     `systemctl is-active svc && systemctl stop svc`

   **Why this matters (real example):** A test added `podman system renew 2>/dev/null;
   podman rm -af 2>/dev/null; true` as a "harmless cleanup" step.  This masked the
   real error (podman lock corruption) and wasted an entire debug cycle before the
   root cause was discovered.  Without the suppression, the error would have been
   visible immediately in the test log.

3. **Never use `|| true` in test commands.**
   If a command can legitimately fail, use `e2e_diag` (diagnostic only) or embed an
   explicit precondition check in the command (e.g. `if [ -f X ]; then ...; fi`).

4. **When a test fails, check if the fix belongs in ABA code FIRST.**
   Tests exercise the product -- don't paper over product bugs.

5. **Never "fix" a test just to make it pass.**
   A passing test that hides a real failure is worse than a failing test.

6. **Uninstall from the same host that installed.**
   If the registry was installed from conN, uninstall from conN -- not disN.

7. **Never remove tools before operations that need them.**
   E.g. don't `dnf remove make` before `aba reset -f` (which needs make).

8. **Verify cleanup actually worked.**
   After uninstall, assert the service is down (e.g. curl check).
   After cleanup, assert the directory is gone.

9. **Use `e2e_diag` for diagnostic/informational commands** whose exit code
   does not matter.  Never use it for steps that must succeed.

10. **Prefer `aba` commands over raw `make` / scripts.**
    Eat your own dog food.  Use the product's CLI for setup and teardown.

11. **Suites MUST clean up their own resources before suite_end.**
    - SNO clusters: shutdown only (small, useful for post-suite debugging)
    - Compact / Standard clusters: MUST delete (large, hold VIPs that block future installs)
    - Mirrors on disN: MUST uninstall
    - OOB pool registry: NEVER touched by suites (managed by setup-pool-registry.sh)
    A suite NEVER installs a resource and leaves it for another suite.
    Register every cluster (`e2e_register_cluster`) and mirror (`e2e_register_mirror`)
    immediately before the install command -- this enables crash recovery via
    `_pre_suite_cleanup` in runner.sh, which iterates ALL leftover .cleanup files.

12. **Suites must be self-sufficient after clone-and-check.**
    Every suite (except `clone-and-check` itself) must be runnable independently
    after the pool VMs exist.  No suite may assume another suite has already run.
    Use idempotent setup helpers (e.g. `setup-pool-registry.sh`) for shared
    prerequisites.

13. **Prefer inline commands over trivial wrappers in suites.**
    If a `_vm_*` helper is just a one-liner around `_essh` / `_escp`, inline the
    actual command directly in the `e2e_run` call.  This makes the log output show
    the real ssh/scp command instead of an opaque function name.  Keep helper
    functions only when they contain non-trivial logic (conditionals, loops,
    multi-step setup) or are shared by `create_pools` provisioning.

14. **Use `e2e_run -h` for remote commands, not embedded SSH.**
    Suites that need to run a command on a remote host must use `e2e_run -h "user@host"`
    (or the `e2e_run_remote` / `e2e_diag_remote` shorthands for `$INTERNAL_BASTION`).
    Never put `ssh host 'cmd'` or `_essh host -- 'cmd'` inside the command string --
    the framework cannot detect embedded SSH and will mark the command as `L` (local)
    instead of `R` (remote), hiding where it actually runs.
    **Exceptions:** (a) Pipe patterns that mix local and remote (`local_cmd | ssh host 'tar xf -'`)
    must stay as `L` since the execution starts locally.  (b) Commands using custom SSH keys
    (`ssh -i ~/.ssh/testy_rsa`) may stay inline when testing specific key-based access.

15. **Error suppression in test code is almost NEVER acceptable.**
    In the rare case where `2>/dev/null`, `|| true`, or `|| echo ...` is genuinely
    needed (not a workaround), it MUST have a comment explaining the specific
    reason.  Uncommented suppression is treated as a bug.  Before adding any
    suppression, first consider these alternatives:
    - `e2e_diag` / `e2e_diag_remote` — runs command, logs output, ignores exit code
    - `rm -f` — already ignores "no such file"
    - `podman rm -f name` — already tolerates "no such container"
    - Explicit precondition: `if systemctl is-active svc; then systemctl stop svc; fi`
    ```bash
    # ✅ BEST - use e2e_diag instead of suppression
    e2e_diag "Power off VM (may already be off)" "govc vm.power -off $vm"

    # ✅ ACCEPTABLE - documented reason, no e2e_diag alternative
    # Tolerate exit 1: VM may already be powered off
    govc vm.power -off "$vm" 2>/dev/null || true

    # ❌ BAD - no explanation, hides real errors
    govc vm.power -off "$vm" 2>/dev/null || true
    ```

16. **No safety nets in framework code.**
    If a suite fails to clean up its resources, that is a bug in the suite --
    fix the suite.  Do not add fallback cleanup to `suite_end()` or
    `e2e_teardown()`.  Paper-over fixes violate rule #5.

17. **Always run `aba day2` after `mirror load` or `mirror sync`.**
    This applies the oc-mirror generated IDMS/ITMS/CatalogSources to the
    cluster.  Without it, the cluster has no mirror configuration for newly
    loaded images and deployments will fail with "image not found".

18. **Tests MUST NEVER create ABA-internal or ABA-generated files directly.**
    Do not write files like `cat > mirror/save/imageset-config-save.yaml <<EOF`
    unless there is no `aba` or `make` target that produces the needed format.
    Use `aba` CLI or `make` targets to generate files.

    **Exception:** Creating a minimal/custom config for an incremental operation
    that has no `aba` equivalent (e.g. operators-only imageset config without a
    platform section).  When this is unavoidable, the test MUST include a comment
    explaining why.

19. **Tests MUST NEVER call ABA-internal functions directly.**
    Do not call `run_once()`, `download_all_catalogs()`, `reg_detect_existing()`,
    or similar internal functions from test code.  Tests simulate user actions via
    `aba` CLI or `make` targets only.

    **Exception:** Sourcing `include_all.sh` for access to utility functions
    (e.g. `aba_info`) is acceptable in framework code.

20. **Tests MUST NOT use `aba reset` as a mid-process cleanup mechanism.**
    `aba reset` is a "distclean" -- it returns the repo to its original unpacked
    state.  It should only be used when a 100% fresh clean repo is genuinely
    required for the following test cases.  Valid uses:
    - Setup helpers like `setup_aba_from_scratch` (need pristine starting point)
    - Dedicated regression tests for reset behavior itself
    - Destroying a named mirror directory that is no longer needed

    For cleaning up derived files between test steps, use `aba clean`, targeted
    `aba uninstall` / `aba delete`, or `rm -rf` on specific directories.
    From the user's perspective, `aba reset` should almost never be needed.

21. **Every suite MUST have an explicit end-of-suite `Cleanup:` test block.**
    Every suite that creates clusters or mirrors MUST have an explicit
    `test_begin "Cleanup: ..."` block at the end that runs `aba delete` /
    `aba uninstall` / `aba unregister` for every resource created during the
    suite.  The EXIT trap and `_pre_suite_cleanup` are safety nets for crashes
    -- they are NOT the primary cleanup path.  Explicit cleanup also serves as
    a test of `aba delete`, `aba uninstall`, and `aba unregister`.

### Documentation

**Prefer adding documentation as comments inside the code** rather than in
separate files under `ai/`.  Code comments are the primary source of truth --
they stay with the code and don't drift out of sync.  Use `ai/` files only
for high-level project context that doesn't belong in any specific source file.

### E2E Log Monitoring and Fix Scope

**During test runs, continuously monitor ALL logs** from the current E2E run and
investigate any failures.

**Fix scope rules:**
- ✅ **Fix test code freely** — test suites, helpers, framework, config
- ❌ **Do NOT change ABA core code** (scripts/, Makefiles, tui/) unless a major
  product bug is found
- ⚠️ If ABA core needs changing, **describe what and why**, then **wait for
  explicit user permission** before making any edits

**Why:** E2E failures almost always stem from test assumptions (wrong IPs,
hardcoded values, missing setup) rather than product bugs. Fixing the test
preserves the integrity of the product code and avoids unintended regressions.

### Three Levels of Tests

#### E2E Tests in `test/e2e/` (Full Infrastructure)

**Purpose**: Validate ABA against real VMware infrastructure and OpenShift clusters.

**Characteristics**:
- ✅ Test complete workflows on real VMs (clone, configure, install, verify)
- ⏱️ Hours to complete (12+ hours for all suites)
- 🌐 Requires VMware vCenter, template VMs, network infrastructure
- 📝 Pool-based isolation for parallel execution

**Key suites**: `clone-and-check`, `create-bundle-to-disk`, `cluster-ops`, `mirror-sync`, `airgapped-local-reg`, `network-advanced`

**When to Run**:
- Before releases
- After significant architectural changes
- When testing VMware/cluster-related features

**How to Run**:
```bash
test/e2e/run.sh --suite vm-smoke           # Quick VMware sanity check
test/e2e/run.sh --suite clone-and-check    # Set up bastion pair
test/e2e/run.sh --all                      # Run everything
test/e2e/run.sh --suite cluster-ops --resume  # Resume after failure
```

See `test/e2e/README.md` for full documentation including IP/domain allocation, pool configuration, and how to write new suites.

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

## README.md TOC Rule

**CRITICAL**: When changing any heading in `README.md`, you MUST also update the Table of Contents (TOC) at the top of the file.

- The TOC uses markdown anchor links: `[Heading Text](#heading-text-lowercased-with-dashes)`
- If you rename a heading (e.g., "Running ABA on arm64" → "Supported Architectures"), update the corresponding TOC entry
- Search for the old heading text in the TOC to find the entry to update
- Verify the anchor link matches the new heading (lowercase, spaces → dashes, special chars removed)

**Example:**
```markdown
# Before:
  - [Running ABA on arm64](#running-aba-on-arm64)

# After renaming heading to "Supported Architectures":
  - [Supported Architectures](#supported-architectures)
```

## README.md Permalink Headings Rule

**CRITICAL**: Some headings in `README.md` have a `<!-- this is a perma-link ... -->` HTML comment immediately after them. These headings must **NOT** be renamed, because they are referenced from external sources (blog posts, other documentation, bundle README files).

- Before renaming any heading, check for a permalink comment on the line below it.
- If a permalink comment is present, leave the heading unchanged.

## Don't Forget!

- ✅ **Never commit without permission**: Always ask user first!
- ✅ **Remote-SSH workflow**: Already on dev host, no sync needed
- ✅ **Ask before modifying**: Unknown scripts
- ✅ **Use run_once**: For background/async work
- ✅ **Tabs only**: No spaces in indentation
- ✅ **Empty lines clean**: No whitespace
- ✅ **Stderr for messages**: Stdout for structured data
- ✅ **Relative paths**: Minimal $ABA_ROOT usage
- ✅ **README TOC**: Update TOC when changing any heading in README.md
- ✅ **Permalink headings**: Never rename README headings that have a `<!-- this is a perma-link ... -->` comment

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

**Last Updated**: March 1, 2026  
**Purpose**: Keep this document updated as rules evolve

