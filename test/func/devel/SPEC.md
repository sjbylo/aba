# TUI Functional Test Specification

Authoritative reference for TUI test architecture, test inventory, and invariants.
For the system spec, see `devel/01-SPEC.md`. For TUI progress dialog design,
see ADR-016.

---

## Purpose

**If all TUI tests pass, the TUI is fully working and ABA is ready for
a new release.**

TUI functional tests verify that `abatui` (the interactive TUI) correctly
drives every ABA workflow end-to-end. Tests interact with the TUI via tmux
on a remote host — the same way a user would — sending keystrokes and
reading screen content. They are black-box tests: no internal TUI functions
are called; only the rendered dialog UI is observed.

Together with the E2E test suite (which covers the CLI and scripts), a
full pass of the TUI tests provides the release gate: every user-facing
workflow has been exercised through the actual UI and verified both on
screen and on the server side.

---

## Architecture

```
test runner (bastion)           remote host (conno / disco)
┌───────────────────┐          ┌───────────────────────┐
│ test-tui-*.sh      │   SSH    │ tmux session: tui-test│
│   sources          │ ──────>  │   └─ abatui           │
│   tui-test-lib.sh  │ <──────  │       └─ dialog       │
│                    │ capture  │           └─ scripts   │
│ assertions         │          │                       │
│ screenshots (.txt) │          │                       │
│ server-side checks │          │                       │
└────────────────────┘          └───────────────────────┘
```

### Key components

| Component | Path | Role |
|-----------|------|------|
| **Test library** | `test/func/tui-test-lib.sh` | Reusable helpers: tmux control, assertions, screenshots, progress waiting, retry, locking |
| **Test runner** | `test/func/test-tui-all.sh` | Master pipeline — runs all tests in dependency order |
| **Individual tests** | `test/func/test-tui-*.sh` | One test per TUI workflow area |
| **Screenshots** | `/tmp/tui-test/<test>-<timestamp>/` | Per-run text captures of every significant TUI state |

---

## Core Rules

### DRY (Don't Repeat Yourself)

DRY applies to ALL test files. Duplicated logic MUST be extracted into
helper functions in `tui-test-lib.sh`. Specific areas where DRY is enforced:

- **Progress/retry loops** — a single `tui_wait_for_progress` / `tui_run_operation`
  replaces all wait-for-completion loops. No test may contain its own inline
  progress polling loop.
- **Navigation sequences** — common sequences (start TUI, navigate to menu,
  dismiss dialogs) are helpers, not copy-pasted blocks.
- **Pre-cleanup** — `tui_delete_cluster()` replaces per-test cleanup logic.
- **Assertions** — `tui_assert_contains`, `tui_assert_appears`, etc. No
  raw `grep | if/else/echo PASS` patterns in test scripts.

When adding a new test, if the logic resembles something in another test,
extract it to `tui-test-lib.sh` first.

If a pattern appears in more than one test file, it should be a helper in
`tui-test-lib.sh`. Examples of patterns that benefit from extraction:
progress/retry loops, dialog dismissal sequences, DNS/IP resolution,
multi-page wizard navigation.

### TUI-first: all interaction through the TUI

Tests MUST drive operations through the TUI, not through the ABA CLI.
The purpose of these tests is to verify the TUI works correctly end-to-end.
Using the CLI bypasses the very thing being tested.

**Allowed uses of the CLI / SSH commands — ONLY for test validation and
pre-test setup, never for performing the workflow being tested:**

| Use case | Example | Why it's OK |
|----------|---------|------------|
| Read-only status/verification | `aba status`, `aba -d mirror status`, `aba -d cluster status` | Validating that a TUI operation actually succeeded |
| Server-side file checks | `$_TUI_SSH "test -f ~/aba/mirror/.available"` | Validating marker files, config, state after TUI action |
| Cluster API queries | `oc get nodes`, `oc get clusterversion` | Validating cluster state after TUI-driven install/upgrade |
| Pre-test configuration | `aba --version 4.22.17`, `aba -d mirror --upgrade-to 4.22.18` | Setting up config before the TUI workflow starts |
| Resolving upgrade pairs | `fetch_upgrade_targets`, OCP release graph API | Not a TUI feature — query only |
| `tui_deploy_code` | rsync of test code to the remote host | Infrastructure, not workflow |

**NOT allowed (must go through the TUI):**

- `aba sync` — use the TUI Sync menu item instead
- `aba -d cluster install` — use the TUI Install Cluster wizard instead
- `aba -d cluster delete` — use `tui_delete_cluster()` instead
- `aba -d mirror install` — use the TUI Install Mirror menu instead
- `aba day2`, `aba day2 --yes` — use the TUI Day-2 menu instead
- `aba save`, `aba load` — use the TUI Save / Load menu items instead
- `aba upgrade`  use the TUI Day-2 → Upgrade menu instead

**Rule of thumb**: if the command *changes* state (installs, syncs, deletes,
upgrades, configures), it MUST go through the TUI. CLI is ONLY allowed for
*reading* state to validate that the TUI operation actually worked (status,
verify, query) or for pre-test setup before the TUI workflow begins.

### No skipping — FAIL or PASS, never SKIP

If a test cannot start or complete for any reason, it MUST FAIL, not skip.
A skipped test is invisible — it silently hides broken functionality.

- **Missing prerequisites**: FAIL with a clear message ("Cluster not
  installed — cannot run day-2 test"). Do not print "SKIP" and exit 0.
- **Transient errors**: retry via `tui_run_operation`. If all retries
  fail, FAIL.
- **Upgrade pair not found**: FAIL ("Cannot resolve upgrade target").
  Do not say "SKIP: no upgrade available."
- **Host unreachable**: FAIL ("Cannot reach host"). Do not skip.

The only acceptable exit codes are 0 (all assertions passed) or non-zero
(at least one assertion failed, or a fatal error prevented the test).

### Test-file independence

Each test file MUST be as independent as possible from other test files.
A FAIL in one test file MUST NOT prevent the next test file from running.

- The test runner (`test-tui-all.sh`) calls each test with `|| true`,
  so it always proceeds to the next test regardless of exit code.
- Each test file starts its own TUI session (`tui_start_to_menu`) and
  cleans up after itself (`tui_cleanup`). Tests do not share TUI sessions.
- Tests MUST NOT assume that a previous test left the TUI in a particular
  state, menu, or dialog. Always start from a fresh TUI launch.

**Acknowledged dependency**: some destructive tests have an ordering
dependency — e.g., the cluster test depends on a synced mirror, the
upgrade test depends on an installed cluster. If a prerequisite test
failed, the dependent test will detect the missing state (e.g., no
`.install-complete` marker) and FAIL with a clear message — it does NOT
skip. The failure message tells you which prerequisite is missing.

### DISCO network isolation

The DISCO workflow test (`test-tui-disco-workflow.sh`) MUST ensure the disco
host has no internet access before running the TUI workflow. This proves
the air-gap workflow actually works without connectivity.

Use `~/bin/internet.sh` on the target host:

```bash
$_SSH_DISCO "~/bin/internet.sh down"   # before TUI workflow
# ... run TUI workflow ...
$_SSH_DISCO "~/bin/internet.sh up"     # restore in cleanup
```

The script safely identifies the management interface (the one carrying the
SSH session via `SSH_CONNECTION`) and only touches the *other* physical NIC.
It will **never** cut off SSH access. It also handles the pasta hairpin
route needed by rootless podman on RHEL 9.

If SSH access is ever lost (should not happen), reboot the host to restore
default network configuration.

---

## Design Principles

### 1. Helper functions abstract TUI navigation

Tests MUST NOT hard-code keystroke sequences to navigate the TUI. Instead,
they use helper functions that read the screen and navigate dynamically:

| Helper | What it does |
|--------|-------------|
| `tui_select_item "Sync"` | Reads visible menu items, finds the key for "Sync", sends that key |
| `tui_press_button "Continue"` | Finds a button labeled "Continue" on screen and presses it |
| `tui_back_to "Actions"` | Sends Escape repeatedly until the screen contains "Actions" |
| `tui_wait_for "pattern" timeout` | Polls the screen until pattern appears or timeout |
| `tui_menu_items` | Returns all visible menu items as `key\tlabel` pairs |
| `tui_start_to_menu` | Launches TUI, dismisses splash, detects mode, lands on main menu |

This means tests survive TUI changes — a renamed menu item, reordered options,
or new submenu requires updating the `tui_select_item` argument, not rewriting
keystroke sequences.

### 2. Easy to modify when the TUI changes

When the TUI introduces a new dialog in a wizard (e.g., a VLAN confirmation
page between Network and Interfaces):

- **No test rewrite needed** — the wizard test uses `tui_press_button "Next"`
  to advance pages. The new page will appear, the test will press Next on it.
- **To verify the new page** — add `tui_assert_contains "VLAN" "VLAN page"`
  and `tui_screenshot "new-vlan-page"` at the right position.

When a new submenu is added:

- The Navigation test (`test-tui-nav.sh`) automatically discovers it via
  `tui_menu_items` — no changes needed.
- The Help test (`test-tui-help.sh`) will catch if the new submenu lacks
  help text.

### 3. Progress dialog is a single abstraction

Every long-running TUI operation follows the same lifecycle:

```
Start operation
    ↓
Progress dialog (mixedgauge / terminal output)
    ↓
┌──────────────┐     ┌──────────────────────┐
│ Success      │     │ Error                │
│ "All steps   │     │ "FAILED (exit N)"    │
│  completed"  │     │ <Dismiss> <Retry>    │
│ <Done>       │     │ <View Output>        │
│ <View Output>│     │                      │
└──────────────┘     └──────────────────────┘
```

Two helper functions handle this for ALL operations:

```bash
# Simple: wait for a progress dialog to finish
tui_wait_for_progress "sync" 2700

# Full: navigate, start, wait, retry on failure, restart TUI if session dies
_nav_sync() {
    tui_back_to "Actions" 5
    tui_select_item "Sync"
    tui_wait_for "Continue" 30
    tui_press_button "Continue"
}
tui_run_operation "sync" _nav_sync 3 2700
```

No test should duplicate the progress/error/retry loop.

### 4. Diagnostic screenshots — take them often, if in doubt take one

**Every significant TUI state MUST be captured** via `tui_screenshot`.
**If in doubt whether a screenshot is needed — take one.** An extra
screenshot never hurts; a missing one makes debugging impossible.

This serves two purposes:

1. **Evidence for AI verification** — an AI agent can read the screenshots
   to independently verify that each step actually tested what it claims.
   A test that reports PASS with zero screenshots is suspect.

2. **Debugging failures** — when a test fails, the screenshot trail shows
   exactly where and why. The more screenshots, the easier the diagnosis.

**Rule of thumb**: take a diagnostic screenshot before and after every
navigation step, every button press, every wait, and every assertion.
Helper functions (`tui_select_item`, `tui_assert_appears`,
`tui_wait_for_progress`, etc.) take diagnostic screenshots automatically
on failure/timeout — but tests should ALSO take explicit screenshots at
each logical step to capture the happy path.

Screenshot naming convention: `<prefix>-<step>-<description>.txt`

```
cl-01-start.txt           # cluster test, step 1, starting state
cl-02-network.txt         # cluster test, step 2, network page
cl-06-install-fail.txt    # cluster test, step 6, install failure
mirr-04b-syncing.txt      # mirror test, step 4b, sync in progress
mirr-04c-error.txt        # mirror test, step 4c, error detected
mirr-04c-output.txt       # mirror test, step 4c, View Output content
```

The `tui_wait_for_progress` helper automatically captures:
- **Periodic screenshots** every N seconds (default 5 min) during long operations
- **Output view** (presses "View Output" button) on BOTH success AND error
- **Error dialog** with the error message and buttons visible

### 5. Dual verification: TUI screenshots + server-side state

Tests MUST NOT rely solely on TUI assertions ("screen says success").
They must ALSO verify server-side state on the remote host. Examples:

| Operation | TUI assertion | Server-side verification |
|-----------|--------------|------------------------|
| Mirror install | Screen shows "All steps completed" | `test -f ~/aba/mirror/.available` |
| Image sync | Progress dialog completes | `grep 'last_action=sync' ~/.aba/mirror/*/state.sh` |
| Cluster install | Screen shows "Install complete" | `test -f ~/aba/sno/.install-complete` |
| Cluster install | (none — check actual cluster) | `oc get nodes --no-headers \| wc -l` returns > 0 |
| Day-2 config | Progress completes | `oc get idms` shows entries |
| Upgrade | Screen shows completion | `oc get clusterversion` shows desired version |
| Cluster delete | TUI returns to menu | `test ! -f ~/aba/sno/.install-complete` |

**Why both?** The TUI can report success when the underlying command failed
silently. The server-side check catches this. Conversely, the TUI might show
an error dialog for a transient issue while the operation actually succeeded
(e.g., timeout on wait but cluster is running). The server-side check catches
this too.

Server-side checks use `$_TUI_SSH` (SSH to the test host):

```bash
_mirror_ok=$($_TUI_SSH "test -f ~/aba/mirror/.available && echo yes || echo no")
if [[ "$_mirror_ok" == "yes" ]]; then
    echo "  ✓ PASS: Mirror available (server-side)"
    _TUI_PASS=$(( _TUI_PASS + 1 ))
fi
```

### 6. AI agents can create and verify tests

The test library is designed so that an AI agent can:

**Create new tests** by:
1. Reading this spec and the helper function reference below
2. Reading an existing test as a template (e.g., `test-tui-smoke.sh`)
3. Writing a new test that uses the helpers to navigate, assert, and screenshot
4. Following the naming convention and structure

**Verify test results** by:
1. Reading the test output (stdout) for PASS/FAIL counts
2. Reading screenshots in `/tmp/tui-test/<test>-<timestamp>/` to see what
   each TUI screen actually showed
3. Reading the `-output.txt` screenshots to see actual command output
4. Running server-side checks via SSH to verify state on disk
5. Comparing expected vs actual screenshot count (if a test has 11
   `tui_screenshot` calls but only 5 files exist, something was skipped)

**Detect false PASSes** by:
- Screenshot shows an error dialog but test reported PASS → false positive
- Server-side marker file missing but test reported PASS → false positive
- Screenshot count doesn't match `tui_screenshot` call count → skipped steps
- Output view screenshot shows errors but test didn't count a FAIL

---

## Helper Function Reference

> **Note**: This section documents the current helper API in `tui-test-lib.sh`
> as a reference for writing and understanding tests. It is a snapshot of
> what exists today — new helpers may be added, existing ones may evolve.
> The authoritative source is always the code in `tui-test-lib.sh` itself.

### Startup and Lifecycle

**`tui_start_to_menu [cmd]`** — The primary way to launch the TUI in tests.
Creates a tmux session on the remote host, runs `abatui`, waits for the splash
screen to appear, presses Enter to dismiss it, detects the TUI mode
(CONNO/DISCO/DIRECT), and waits for the main Actions menu to appear.
Returns 1 if startup fails (e.g., "Internet Access Required" error on disco).

```bash
tui_start_to_menu || { tui_summary; exit 1; }
# TUI is now at the Actions menu, ready for navigation.
```

**`tui_cleanup`** — Graceful shutdown at the end of every test. Dismisses any
lingering dialogs, sends Escape back to the main menu, exits the TUI via the
Exit button, kills the tmux session, waits for processes to die, and checks
for stray `abatui` processes (PASS if clean, FAIL if strays found and killed).

```bash
tui_cleanup
tui_summary   # always call after cleanup
```

**`tui_deploy_code`** — Copies the latest TUI and script code to the remote
host via `scp`. Call this at the start of every test to ensure the test is
running against the latest code.

**`tui_session_alive`** — Returns 0 if the tmux session exists on the remote
host. Retries once on SSH failure (a dropped SSH connection doesn't mean the
tmux session died). Use this to check if the TUI is still running before
sending keys.

**`tui_clear_failed_tasks`** — Clears failed `run_once` tasks on the remote
host. Called automatically by `tui_start`, so tests rarely need to call this
directly. Useful when ISC generation failed in a prior test and left a stale
failure marker.

**`tui_dismiss_startup [timeout]`** — Handles all startup dialogs: splash
screen, "Internet Access Required" error, "Bundle on connected host" mode
selection, bundle info/payload summary. Returns 0 when the main menu
(Actions) is reached. Called automatically by `tui_start_to_menu`.

### Screen Reading

**`tui_capture`** — Returns the full text content of the tmux pane as a
string. This is the fundamental screen-reading primitive — all assertions,
navigation, and pattern detection build on this.

```bash
_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Sync"; then
    echo "Sync menu item visible"
fi
```

**`tui_menu_items`** — Parses the current screen and returns all menu items
with shortcut keys as `KEY<tab>LABEL` pairs (one per line). Works by
detecting the TUI's menu item format: `│   K  Some Label   │`.

```bash
tui_menu_items
# Output:
#   P	Mirror Payload  (4.22.18 stable)
#   M	Install Mirror (local or remote) (installed)
#   Y	Sync images to mirror (synced 4.22.18)
#   ...
```

**`tui_find_key "pattern"`** — Searches `tui_menu_items` output for a label
matching the pattern (case-insensitive), returns the shortcut key character.

```bash
key=$(tui_find_key "Sync")   # returns "Y"
```

**`tui_buttons`** — Parses the current screen and returns all button labels
(one per line, left-to-right order). Buttons appear as `< Label >` or
`<Label>` in the TUI.

```bash
tui_buttons
# Output:
#   Select
#   Exit
#   Help
```

**`tui_dialog_title`** — Extracts the dialog title from the screen. Titles
appear as `┌──── Some Title ────┐` in the TUI border.

### Navigation

**`tui_select_item "pattern"`** — The primary way to choose a menu item.
Reads the screen via `tui_menu_items`, finds the item matching the pattern
(case-insensitive), sends its shortcut key, then presses Enter. Returns 1
if the item is not found (and takes a diagnostic screenshot).

```bash
tui_select_item "Mirror Payload"   # sends 'P' then Enter
tui_select_item "Sync"             # sends 'Y' then Enter
tui_select_item "Day-2"            # sends 'D' then Enter
```

**`tui_press_button "label"`** — Navigates to a button by label and presses
Enter. Reads the screen to find all buttons, calculates how many Tab presses
are needed to reach the target (assuming focus starts on the first button),
sends the Tabs, then presses Enter.

```bash
tui_press_button "Continue"    # Tab to Continue, press Enter
tui_press_button "Help"        # Tab to Help, press Enter
tui_press_button "View Output" # Tab to View Output, press Enter
```

**`tui_back_to "pattern" [max]`** — Presses Escape repeatedly until the
screen contains the pattern (case-insensitive). Used to navigate back to
a known screen from deep in a wizard or submenu. Default max attempts is 5.

```bash
tui_back_to "Actions" 5       # Escape back to main Actions menu
tui_back_to "Day-2" 3         # Escape back to Day-2 submenu
```

**`tui_keys "keys"`** — Sends raw tmux keys to the session. Use for keys
that don't have a helper function: Enter, Escape, Tab, arrow keys, Ctrl
sequences, and literal text.

```bash
tui_keys Enter                 # press Enter
tui_keys Escape                # press Escape
tui_keys Tab                   # press Tab
tui_keys Up Up Up              # press Up arrow 3 times
tui_keys C-u                   # Ctrl-U (clear input field)
tui_keys Space                 # press Space (toggle checkbox)
```

For typing literal text into input fields, use the tmux `-l` flag via SSH:

```bash
$_TUI_SSH "tmux send-keys -t $_TUI_SESSION -l 'sno.example.com'"
```

**`tui_confirm_yes`** — Presses the Yes/OK button on a `--defaultno` yesno
dialog. Since `--defaultno` focuses the No/Cancel button, this sends Left
arrow then Enter.

**`tui_keys_wait "keys" "pattern" [timeout]`** — Sends keys and waits for
the expected pattern to appear. Combines `tui_keys` + `tui_wait_for` in
a single call.

### Waiting and Timing

**`tui_wait_for "pattern" [timeout]`** — Polls the screen every 0.5s until
the pattern appears (case-insensitive grep) or timeout expires. Default
timeout is 10 seconds. On timeout, takes a diagnostic screenshot and
returns 1.

```bash
tui_wait_for "Actions" 15          # wait up to 15s for Actions menu
tui_wait_for "Continue\|OCP" 30    # wait for Continue or OCP text
```

**`tui_wait_gone "pattern" [timeout]`** — Opposite of `tui_wait_for`. Polls
until the pattern disappears from the screen. Useful after pressing Enter
on a dialog to wait for it to close.

**`tui_wait_isc_done [timeout]`** — Waits for an ISC (ImageSet Config)
generation dialog to clear. ISC generation runs in the background when
entering certain menus (Mirror Payload, Operators). If an ISC error dialog
appears (catalog error, pull failure), it's automatically dismissed.
Default timeout is 120 seconds.

```bash
tui_select_item "Mirror Payload"
tui_wait_isc_done 120    # wait for ISC generation to finish
# Now the menu is ready for interaction
```

### Dismissing Dialogs

**`tui_dismiss_result`** — Dismisses post-command result screens. Handles
three patterns:
- Terminal mode: "Press ENTER to continue" / "Press R to retry"
- Progress mode: "All steps completed successfully" with Done button
- confirm_and_execute: "Success" msgbox with OK button

Returns 0 if a prompt was found and dismissed, 1 if no dismissable dialog
was present.

**`tui_dismiss_error`** — Dismisses error/failure dialogs and navigates
back to the Actions menu. Handles FAILED dialogs, "Press ENTER" prompts,
"steps completed/Done" dialogs. Tries up to 5 times, then falls back to
`tui_back_to "Actions"`.

**`tui_dismiss_cluster_select`** — Dismisses a "Select cluster" dialog if
present. Many Day-2 actions prompt for cluster selection when multiple
clusters exist. Presses Enter to select the default (first) cluster.

**`tui_dismiss_exec_mode`** — Dismisses an execution mode dialog ("Run in
Terminal" / "Run in TUI") if present. Presses Enter to accept the default.

### Assertions

All assertion functions increment `_TUI_PASS` on success or `_TUI_FAIL`
on failure and print a `✓ PASS:` or `✗ FAIL:` message.

**`tui_assert_contains "pattern" "description"`** — Captures the current
screen and checks if it contains the pattern (case-insensitive grep).

```bash
tui_assert_contains "OCP.*4\." "Shows OCP version"
tui_assert_contains "Operator" "Operator selection visible"
```

**`tui_assert_not_contains "pattern" "description"`** — Opposite: asserts
the pattern is NOT on screen.

```bash
tui_assert_not_contains "Error" "No errors on screen"
```

**`tui_assert_appears "pattern" "description" [timeout]`** — Waits up to
`timeout` seconds (default 10) for the pattern to appear. This is for
content that takes time to load (e.g., ISC generation, menu rendering).

```bash
tui_assert_appears "Actions" "Main menu appeared" 15
tui_assert_appears "Mirror Payload" "Payload menu loaded" 10
```

### Progress and Retry

**`tui_wait_for_progress "label" [timeout] [ss_interval]`** — Waits for a
TUI progress dialog to complete. Handles the full lifecycle:
- Polls the screen for completion ("All steps completed") or error ("FAILED")
- Takes periodic screenshots every `ss_interval` seconds (default 300)
- On success: presses "View Output" and screenshots the full output
- On error: screenshots the error dialog, presses "View Output" for output,
  then tries the TUI's built-in Retry button (up to 5 times)
- Returns: 0=success, 1=error (retries exhausted), 2=session died, 3=timeout

```bash
if tui_wait_for_progress "sync" 2700; then
    echo "  ✓ PASS: Sync completed"
    _TUI_PASS=$(( _TUI_PASS + 1 ))
fi
```

**`tui_run_operation "label" nav_func [max_retries] [timeout]`** — Full
outer retry wrapper around `tui_wait_for_progress`. On failure or session
death, it:
1. Restarts the TUI if the tmux session died
2. Calls `nav_func` to re-navigate to the operation and start it
3. Calls `tui_wait_for_progress` again
4. Repeats up to `max_retries` times (default 3)

The `nav_func` is a shell function (or commands in a string) that navigates
from the Actions menu to the operation and starts it:

```bash
_nav_sync() {
    tui_back_to "Actions" 5
    tui_select_item "Sync"
    tui_wait_for "Continue" 30
    tui_press_button "Continue"
    sleep 5
}
if tui_run_operation "sync" _nav_sync 3 2700; then
    echo "  ✓ PASS: Sync completed"
    _TUI_PASS=$(( _TUI_PASS + 1 ))
fi
```

**`tui_delete_cluster "name"`** — Navigates to Day-2 → Delete, selects the
named cluster, confirms, and waits for the delete to complete via
`tui_wait_for_progress`. Returns 0 if the cluster was deleted or didn't
exist in the first place.

```bash
tui_delete_cluster "sno"   # delete the sno cluster if it exists
```

### Mode Detection

**`tui_detect_mode`** — Reads the TUI backtitle to determine the mode.
Sets `_TUI_DETECTED_MODE` to `CONNO`, `DISCO`, or `DIRECT`. Called
automatically by `tui_start_to_menu`.

**`tui_is_disco`** — Returns 0 if the TUI is in disconnected mode.

**`tui_has_internet`** — Returns 0 if the TUI is NOT in disconnected mode.

**`tui_skip_if_disco "desc"`** / **`tui_require_internet "desc"`** — Skip
individual test steps that require internet when the TUI is in DISCO mode.
**Note**: these skip individual *steps* within a test, not the test file
itself. The test file still runs and reports PASS/FAIL. A step that's
inapplicable in DISCO mode (e.g., "verify online sync") is legitimately
skipped — this is different from a test file exiting 0 with "SKIP".

### Screenshots and Reporting

**`tui_screenshot "label"`** — Captures the current screen to a text file
in the run directory (`$_TUI_RUN_DIR/<label>.txt`) and creates a symlink
at `/tmp/tui-test-<label>.txt` for quick access. Prints the file path.

The library automatically prunes old screenshot directories, keeping the
3 most recent runs per test. This prevents disk fill-up during repeated
testing.

```bash
tui_screenshot "cl-02-network"
# Creates: /tmp/tui-test/test-tui-cluster-20261030-160618/cl-02-network.txt
# Symlink: /tmp/tui-test-cl-02-network.txt → (latest screenshot)
```

**`tui_summary`** — Prints the PASS/FAIL counts and screenshot directory.
Returns non-zero (`[ "$_TUI_FAIL" -eq 0 ]`) when any assertion failed,
causing the test script to exit non-zero.

### Variables available to tests

| Variable | Set by | Purpose |
|----------|--------|---------|
| `$_TUI_HOST` | `tui-test-lib.sh` | Remote host (from `$TUI_TEST_HOST`) |
| `$_TUI_SSH` | `tui-test-lib.sh` | Full SSH command prefix: `ssh -F ... host` |
| `$_TUI_SESSION` | `tui-test-lib.sh` | tmux session name (from `$TUI_TEST_SESSION`) |
| `$_TUI_PASS` | test script | PASS counter (increment on successful assertions) |
| `$_TUI_FAIL` | test script | FAIL counter (increment on failed assertions) |
| `$_TUI_RUN_DIR` | `tui-test-lib.sh` | Per-run screenshot directory |
| `$_TUI_DETECTED_MODE` | `tui_detect_mode` | `CONNO`, `DISCO`, or `DIRECT` |
| `$_TUI_TEST_NAME` | `tui-test-lib.sh` | Test script name (without path/extension) |

---

## Test Structure Template

Every test follows this general structure (shown as a reference example):

```bash
#!/bin/bash
# Test: TUI <feature> — <brief description>
# <DESTRUCTIVE or non-destructive>
# Prereqs: <what must be in place>

cd "$(dirname "$0")/../.."
source test/func/tui-test-lib.sh

echo "=== TUI <Feature> Test ==="
echo "  Host: $_TUI_HOST"

tui_deploy_code

# --- Setup / prereqs ---
# Check prerequisites — FAIL if not met (never skip)

# --- Start TUI ---
tui_start_to_menu || { tui_summary; exit 1; }

# --- Step 1: Navigate and verify ---
echo ""
echo "--- 1. <Step description> ---"
tui_select_item "<menu item>"
tui_screenshot "<prefix>-01-<desc>"           # diagnostic screenshot
tui_assert_contains "<pattern>" "<what we verify>"

# --- Step 2: Trigger operation ---
echo ""
echo "--- 2. <Operation> ---"
tui_screenshot "<prefix>-02-before"            # if in doubt, take one!
_nav_func() {
    tui_back_to "Actions" 5
    tui_select_item "<item>"
    tui_press_button "Continue"
}
if tui_run_operation "<label>" _nav_func 3 2700; then
    echo "  ✓ PASS: <operation> completed"
    _TUI_PASS=$(( _TUI_PASS + 1 ))
else
    echo "  ✗ FAIL: <operation> failed"
    _TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# --- Server-side verification ---
echo ""
echo "--- 3. Verify on server ---"
_result=$($_TUI_SSH "<check command>" 2>/dev/null)
if [[ "$_result" == "expected" ]]; then
    echo "  ✓ PASS: Server-side state correct"
    _TUI_PASS=$(( _TUI_PASS + 1 ))
else
    echo "  ✗ FAIL: Server-side state wrong"
    _TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# --- Cleanup ---
echo ""
echo "--- 4. Cleanup ---"
tui_cleanup
tui_summary
```

---

## How to Add a New Test

1. **Create the file**: `test/func/test-tui-<name>.sh`
2. **Source the library**: `source test/func/tui-test-lib.sh`
3. **Use helpers for ALL navigation** — never hard-code keystroke sequences
4. **Screenshot every significant state** — at least one per test step
5. **Assert on screen content** — use `tui_assert_contains` / `tui_assert_appears`
6. **Verify server-side** — check marker files, config files, or cluster state via SSH
7. **Use `tui_run_operation`** for any long-running action
8. **End with `tui_cleanup` + `tui_summary`**
9. **Add to `test-tui-all.sh`** in the correct pipeline position
10. **Update this SPEC** — add the test to the inventory table

### How to handle TUI changes

| Change | What to update |
|--------|---------------|
| Renamed menu item | Update `tui_select_item` argument in affected tests |
| New submenu | Navigation test auto-discovers it; add specific test if needed |
| New wizard page | Add assertions at the right step; existing `press_button "Next"` still works |
| New dialog in workflow | Add handler in `tui_wait_for_progress` or the nav function |
| Changed button label | Update `tui_press_button` argument |
| Removed feature | Remove corresponding test section and assertions |

---

## Concurrency Guard

Only one TUI test may run against a given host at a time. Enforced by `flock`
on `/tmp/tui-test-<hostname>.lock`.

- **Standalone test**: acquires the lock; second test on the same host gets
  `FATAL` with the holder's PID and test name, exits 99.
- **`test-tui-all.sh`**: acquires the outer lock on fd 8; child tests skip
  locking via `_TUI_LOCK_HELD=1`.
- **Different hosts**: separate lock files — conno and disco can run in parallel.

---

## Progress Dialog Pattern (DRY)

All long-running TUI operations (sync, install, load, save, upgrade) follow
the same lifecycle:

1. Progress dialog runs until completion or error
2. On **success** → "All steps completed" / back to Actions menu
3. On **error** → "FAILED" dialog with `<Dismiss> <Retry> <View Output>`

Two helper functions eliminate duplication:

| Function | Purpose |
|----------|---------|
| `tui_wait_for_progress(label, timeout, ss_interval)` | Single progress wait loop with inner Retry (TUI button), periodic screenshots, output capture on success/error |
| `tui_run_operation(label, nav_func, max_retries, timeout)` | Outer retry loop: session recovery, re-navigation via `nav_func`, calls `tui_wait_for_progress` per attempt |

**Invariant**: `tui_wait_for_progress` always presses "View Output" and
takes a screenshot of the full output — on both success AND error. This
provides evidence of what actually happened, not just the summary dialog.

---

## Test Inventory

> **Note**: This is the current set of tests. It represents what exists
> today and what is possible in the future. New tests may be added as the
> TUI evolves, existing tests may be split or merged. The list is not
> prescriptive — it is an example of the coverage we aim for.

### Quick tests (non-destructive, ~15 min total)

These tests do not modify mirror or cluster state. They can run on any
host with an existing ABA installation.

| # | Test | File | What it verifies |
|---|------|------|------------------|
| 1 | **Smoke** | `test-tui-smoke.sh` | Splash screen, main menu rendering, submenu entry/exit, TUI exit |
| 2 | **Help Consistency** | `test-tui-help.sh` | Every menu's Help text matches its actual menu items (no stale help) |
| 3 | **Navigation** | `test-tui-nav.sh` | Dynamic menu discovery: reads keys from screen, navigates every submenu, returns to root |
| 4 | **Wizard** | `test-tui-wizard.sh` | Setup wizard pages (channel, version, platform, operators) — field editing and navigation |
| 5 | **Operators** | `test-tui-operators.sh` | Operator workflows: sets, search, view/edit, clear, additional images |
| 6 | **Mirror Config** | `test-tui-mirror-config.sh` | Mirror config forms (local/remote choice, hostname, port, vendor fields), platform config |
| 7 | **Payload Deep** | `test-tui-payload-deep.sh` | Prepare Upgrade flow, version/channel change, settings toggles, bundle dialog |
| 8 | **Cluster Pages** | `test-tui-cluster-pages.sh` | Cluster wizard all 4 pages (Basics, Network, Interfaces, VM Resources) — non-destructive navigation |
| 9 | **DISCO Smoke** | `test-tui-disco-smoke.sh` | Forces DISCO mode on disco host; verifies DISCO menu, ISC view, settings, advanced, day-2 menus |
| 10 | **Operators Deep** | `test-tui-operators-deep.sh` | Operator set add/remove/search/clear permutations |
| 11 | **Settings Deep** | `test-tui-settings-deep.sh` | Vendor/retry toggles persist to config files; cycling preserves state |
| 12 | **Addl Images Deep** | `test-tui-addl-images-deep.sh` | Additional images add/remove/clear/persist permutations |
| 13 | **Platform Config** | `test-tui-platform-config-deep.sh` | VMware, KVM, pull secret config dialogs |
| 14 | **ISC Verify** | `test-tui-isc-verify.sh` | ISC YAML generation: operator toggles produce correct imageset-config.yaml content |
| 15 | **Progress Integration** | `test-tui-progress-integration.sh` | Progress dialog lifecycle with stub script: success path, error path, output viewer |

### Destructive tests (full mode, ~2–3 hours total)

These tests modify mirror and cluster state. They run in strict pipeline
order — each depends on the state left by the previous test.

| # | Test | File | What it verifies | Server-side checks | Est. time |
|---|------|------|------------------|--------------------|-----------|
| 16 | **Mirror Workflow** | `test-tui-mirror.sh` | Mirror install + sync via TUI | `mirror/.available`, `state.sh last_action=sync` | ~15 min |
| 17 | **Cluster Install** | `test-tui-cluster.sh` | Wizard → install SNO on VMware | `.install-complete`, `kubeconfig`, `oc get nodes` | ~45 min |
| 18 | **Day-2 Deep** | `test-tui-day2-deep.sh` | Status, OSUS, upgrade picker, confirmations | Cluster API reachable | ~10 min |
| 19 | **Day-2 Operations** | `test-tui-day2.sh` | OperatorHub, NTP, status, login | `oc get idms`, NTP config applied | ~10 min |
| 20 | **Upgrade** | `test-tui-upgrade.sh` | Full upgrade: pair resolution → install older → sync → day2 → upgrade | `oc get clusterversion` shows new version | ~90 min |
| 21 | **Lifecycle** | `test-tui-lifecycle.sh` | Shutdown, startup, clean, delete | Nodes Ready after startup, `.install-complete` gone after delete | ~30 min |

### Standalone / special tests (not in the pipeline)

| Test | File | Purpose |
|------|------|---------|
| **DISCO Workflow** | `test-tui-disco-workflow.sh` | Full air-gap: bundle → transfer → disco TUI (registry + load + cluster). |
| **Progress Smoke** | `test-tui-progress.sh` | Simulated progress events without a real cluster. |
| **Progress Real** | `test-tui-progress-real.sh` | Real `day2.sh` through TUI progress on a down cluster (error path). |
| **Progress Visual** | `test-tui-progress-visual.sh` | Interactive visual test — run manually on a terminal. |

---

## Pipeline Order and Dependencies

```
Quick tests (1-15): independent, any order, non-destructive
    │
    ▼
Mirror Workflow (16): installs registry, syncs images
    │
    ▼
Cluster Install (17): depends on synced mirror
    │
    ▼
Day-2 Deep (18): depends on installed cluster
Day-2 Operations (19): depends on installed cluster
    │
    ▼
Upgrade (20): reuses cluster from (17) — syncs upgrade images, day2 via
              TUI, upgrades via TUI. Leaves cluster running at new version.
    │
    ▼
Lifecycle (21): depends on installed cluster — shuts down, starts up, deletes
```

---

## Upgrade Test: Pair Resolution

The upgrade test reuses the cluster already installed by the Cluster Install
test (17). It does NOT reinstall the cluster — that would waste ~45 minutes.
Instead, it queries the OCP release graph to find a version that the
already-running cluster can upgrade TO, syncs that version, and upgrades.

### Requirements

- The upgrade target MUST be resolved from the OCP release graph — never
  hardcoded, never "noted" as unavailable. If no target exists, FAIL.
- All state-changing steps (sync, day2, upgrade) MUST go through the TUI.
- The cluster installed by the cluster test MUST be reused — never reinstalled.
- The test MUST clean up after itself (remove `ocp_upgrade_to`, etc.).

**Invariant**: The mirror only contains versions that were explicitly synced.
`oc adm upgrade` on a mirror-based cluster will not show upgrade targets
until the target version's images are synced to the mirror and OSUS/IDMS
are configured via `day2`.

**Invariant**: Day-2 configuration (OSUS/IDMS) is driven through the TUI,
not via CLI. The test navigates Day-2 → OperatorHub Config (or equivalent)
to apply IDMS/ITMS and configure OSUS.

---

## Pre-cleanup: Cluster Deletion via TUI

Tests that install clusters use `tui_delete_cluster()` for pre-cleanup
instead of CLI-based `aba delete`. This ensures:

- The TUI navigates to Day-2 → Delete → select cluster → confirm → wait
- VM destruction goes through the full ABA stack (including vmware.conf)
- No dependency on the cluster directory existing (handles missing `sno/`)
- The delete workflow itself is tested as a side effect

---

## Verification Strategy

### What "verified" means

A test step is considered verified when BOTH of these are true:

1. **TUI assertion passed** — the screen showed the expected content
   (captured in a screenshot)
2. **Server-side state is correct** — a file, marker, or API response
   on the remote host confirms the operation actually succeeded

A step verified by only TUI assertion (no server-side check) is a
**weak verification** — acceptable for UI-only tests (smoke, nav, help)
but not for destructive tests.

### AI verification workflow

After a test run, an AI agent verifies results by:

1. **Read test output** — check PASS/FAIL counts and exit code
2. **Count screenshots** — compare actual files in the run directory
   against expected `tui_screenshot` calls in the test script. Missing
   screenshots indicate skipped steps.
3. **Read key screenshots** — especially:
   - `*-output.txt` (View Output captures) — shows actual command output
   - `*-error*.txt` — shows error dialog content
   - `*-final.txt` — shows final state before cleanup
4. **Run server-side checks** — SSH to the host and verify marker files,
   config state, cluster health
5. **Cross-reference** — if a test reports "PASS: Sync completed" but the
   output screenshot shows errors, or `state.sh` doesn't show
   `last_action=sync`, flag it as a false positive

### Key marker files for verification

| Marker | Path on remote host | What it proves |
|--------|-------------------|----------------|
| Mirror available | `~/aba/mirror/.available` | Registry is installed and reachable |
| Mirror state | `~/.aba/mirror/*/state.sh` | `last_action=`, `mirror_ocp_version=` |
| Cluster installed | `~/aba/<cluster>/.install-complete` | Cluster installation finished |
| Kubeconfig | `~/aba/<cluster>/iso-agent-based/auth/kubeconfig` | Cluster credentials exist |
| Cluster nodes | `oc get nodes --no-headers` | Cluster is alive and has Ready nodes |
| Cluster version | `oc get clusterversion version -o jsonpath='{.status.desired.version}'` | Running OCP version |

---

## Test Environment

### Required hosts

Test hosts are configurable via environment variables — they are NOT
hard-coded in test scripts. The defaults match the standard lab environment.

| Host | Default | Env variable | Role |
|------|---------|-------------|------|
| Connected | `conno.example.com` | `TUI_TEST_HOST` | Partially disconnected bastion with internet — runs all quick tests, mirror, cluster, day2, upgrade, lifecycle |
| Disconnected | `disco.example.com` | `TUI_DISCO_HOST` | Fully disconnected host (no internet) — runs DISCO smoke, DISCO workflow |

Both hosts must be reachable via SSH through `~/.aba/ssh.conf`.

**DISCO network isolation**: before running TUI workflows on the disco host,
its internet access must be disabled. Use the `~/bin/internet.sh` script
on each host:

```bash
ssh -F ~/.aba/ssh.conf disco.example.com "~/bin/internet.sh down"  # disconnect
ssh -F ~/.aba/ssh.conf disco.example.com "~/bin/internet.sh up"    # reconnect
```

The script safely identifies the management NIC (via `SSH_CONNECTION`) and
only touches the internet-facing NIC — SSH access is preserved.

### Prerequisites

- SSH access via `~/.aba/ssh.conf` to target hosts
- `tmux` installed on target hosts
- Pull secret at `~/.pull-secret.json` on target hosts (for mirror/sync tests)
- VMware environment accessible from target hosts (for cluster install tests)
- DNS records for test cluster (e.g., `api.sno.example.com`, `*.apps.sno.example.com`)
- `~/bin/internet.sh` on target hosts (for DISCO network isolation)

### Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `TUI_TEST_HOST` | `conno.example.com` | Target host for tests |
| `TUI_TEST_SESSION` | `tui-test` | tmux session name |
| `TUI_CLUSTER_NAME` | `sno` | Cluster name for destructive tests |
| `TUI_SKIP_DELETE` | unset | Set to 1 to skip cluster deletion in lifecycle test |

---

## Running Tests

```bash
# Full suite (quick + destructive, ~3 hours)
test/func/test-tui-all.sh

# Quick tests only (~15 min)
test/func/test-tui-all.sh --quick

# Full suite, keep cluster at end
test/func/test-tui-all.sh --no-delete

# Single test (standalone)
bash test/func/test-tui-smoke.sh

# DISCO workflow (standalone, requires both hosts)
bash test/func/test-tui-disco-workflow.sh
```

---

## Failure Handling and Error Recovery

### Within a test step

When an assertion fails (`tui_assert_contains` returns 1), the test
increments `_TUI_FAIL` and **continues** to the next step. This collects
maximum evidence — a single failure doesn't abort the entire test.

Exception: **fatal prerequisites** may cause early exit. If the mirror is
not available, there's no point trying to sync. In that case, FAIL and
exit immediately — but still call `tui_summary` so counts are reported:

```bash
if [[ "$_mirror_ok" != "yes" ]]; then
    echo "  ✗ FAIL: Mirror not available"
    _TUI_FAIL=$(( _TUI_FAIL + 1 ))
    tui_cleanup; tui_summary; exit 1
fi
```

### Long-running operations

All long-running operations use `tui_run_operation` which provides:

- **Inner retry**: presses the TUI's built-in Retry button (up to 5 times)
- **Session recovery**: if the tmux session dies, restarts the TUI
- **Outer retry**: dismisses the error, re-navigates, and retries (up to 3 times)
- **Evidence capture**: screenshots the error dialog AND the View Output content

Only after all retries are exhausted does the operation report FAIL.

### TUI session death

If the tmux session dies mid-test (crash, OOM, SSH drop):

- `tui_session_alive` returns false
- `tui_run_operation` automatically restarts the TUI and retries
- Standalone wait loops (`tui_wait_for_progress`) return 2 (session died)

Tests MUST NOT treat session death as a permanent failure on the first
occurrence — retry logic handles transient issues.

---

## Screenshot Naming Convention

Screenshots are named `<prefix>-<step>-<description>.txt`.

### Prefixes by test

| Test | Prefix | Example |
|------|--------|---------|
| Smoke | `sm-` | `sm-01-splash.txt` |
| Cluster | `cl-` | `cl-02-network.txt` |
| Mirror | `mirr-` | `mirr-04b-syncing.txt` |
| Upgrade | `upg-` | `upg-05b-versions.txt` |
| Day-2 | `d2-` | `d2-01-menu.txt` |
| DISCO workflow | `disco-wf-` | `disco-wf-03-menu.txt` |
| Progress | `pi-` | `pi-a1-progress.txt` |

### Special suffixes

| Suffix | Meaning |
|--------|---------|
| `-output` | View Output button content (full command output) |
| `-error` | Error dialog screenshot |
| `-error-attemptN` | Error on retry attempt N |
| `-progress-Ns` | Periodic capture at N seconds elapsed |
| `-timeout` | Captured at timeout |
| `-final` | Last screenshot before cleanup |
| `-fail` | Failure state captured |

### Diagnostic screenshots

Helper functions take diagnostic screenshots automatically on failure,
timeout, and unexpected state — but tests should also take explicit
screenshots at every logical step. **If in doubt, take one.** Name them
with the step prefix and a descriptive suffix:

```bash
tui_screenshot "cl-03-before-confirm"    # about to press Confirm
tui_screenshot "cl-03-after-confirm"     # just pressed Confirm
tui_screenshot "cl-03-unexpected"        # screen wasn't what we expected
```

### Auto-generated screenshots

`tui_wait_for_progress` automatically generates:
- `<label>-progress-<N>s.txt` — every `ss_interval` seconds
- `<label>-output.txt` — View Output content (success or error)
- `<label>-error.txt` — error dialog when failure detected
- `<label>-timeout.txt` — screen state at timeout

---

## File Layout

> **Note**: Current layout. Files may be added or reorganized as needed.

```
test/func/
├── devel/
│   └── SPEC.md                        # This file
├── tui-test-lib.sh                    # Shared helper library (sourced by all tests)
├── test-tui-all.sh                    # Master test runner (pipeline)
├── test-tui-smoke.sh                  # Quick test: splash, menus, exit
├── test-tui-help.sh                   # Quick test: help text consistency
├── test-tui-nav.sh                    # Quick test: dynamic menu navigation
├── test-tui-wizard.sh                 # Quick test: setup wizard pages
├── test-tui-operators.sh              # Quick test: operator workflows
├── test-tui-operators-deep.sh         # Quick test: operator permutations
├── test-tui-mirror-config.sh          # Quick test: mirror config forms
├── test-tui-payload-deep.sh           # Quick test: payload, upgrade prep
├── test-tui-cluster-pages.sh          # Quick test: cluster wizard pages
├── test-tui-disco-smoke.sh            # Quick test: DISCO mode on disco host
├── test-tui-settings-deep.sh          # Quick test: settings persistence
├── test-tui-addl-images-deep.sh       # Quick test: additional images
├── test-tui-platform-config-deep.sh   # Quick test: platform config dialogs
├── test-tui-isc-verify.sh             # Quick test: ISC YAML content
├── test-tui-progress-integration.sh   # Quick test: progress dialog lifecycle
├── test-tui-mirror.sh                 # Destructive: mirror install + sync
├── test-tui-cluster.sh                # Destructive: cluster wizard + install
├── test-tui-day2-deep.sh              # Destructive: day-2 with live cluster
├── test-tui-day2.sh                   # Destructive: day-2 operations
├── test-tui-upgrade.sh                # Destructive: full upgrade workflow
├── test-tui-lifecycle.sh              # Destructive: shutdown/startup/delete
├── test-tui-disco-workflow.sh         # Standalone: full air-gap workflow
├── test-tui-progress.sh               # Standalone: simulated progress
├── test-tui-progress-real.sh          # Standalone: real progress on down cluster
└── test-tui-progress-visual.sh        # Standalone: interactive visual test

/tmp/tui-test/                         # Screenshot directories (per-run)
├── test-tui-smoke-20261030-140800/
│   ├── sm-01-splash.txt
│   ├── sm-02-menu.txt
│   └── ...
├── test-tui-cluster-20261030-143026/
│   ├── cl-01-start.txt
│   ├── cl-06-install-fail.txt
│   ├── cl-06-output.txt               # View Output capture
│   └── ...
└── ...

/tmp/tui-test-<hostname>.lock          # Per-host flock files
```

---

## Cleanup

Tests MUST clean up after themselves:

- **Restore `aba.conf`**: if a test changes `ocp_version` or other settings,
  it must restore the original values in its cleanup section
- **Remove `ocp_upgrade_to`**: the upgrade test must clear this from
  `mirror.conf` after completion
- **TUI session**: `tui_cleanup` handles graceful TUI exit and stray process
  detection
- **No orphaned VMs**: cluster tests that create VMs must delete them (via
  `tui_delete_cluster` or the lifecycle test)
- **Screenshot cleanup**: old screenshot directories are automatically pruned
  (keeps 3 most recent per test)

The lifecycle test (`test-tui-lifecycle.sh`) serves as the final cleanup —
it shuts down, starts up, and then deletes the cluster, leaving the
environment clean for the next suite run.

---

## Non-goals

- **TUI tests do not test the underlying ABA scripts.** The E2E test suite
  covers CLI commands, Make targets, and script logic. TUI tests verify that
  the TUI correctly drives those scripts via the UI.
- **TUI tests do not test oc-mirror, openshift-install, or govc behavior.**
  If a mirror sync fails due to an oc-mirror bug, the TUI test verifies the
  error is properly displayed and retried — not the root cause.
- **TUI tests do not manage test infrastructure.** VMs, DNS, vCenter, and
  network configuration are prerequisites, not test responsibilities (except
  DISCO network isolation).
- **TUI tests are not unit tests.** They are end-to-end integration tests
  that install real clusters on real VMs. Expect 15–180 minute runtimes.
- **TUI tests do not test CLI flags.** `aba --version`, `aba --channel`, etc.
  are tested by the E2E suite.

---

## Known Limitations

- **Upgrade test requires a newer version to exist in the OCP channel.**
  If the cluster is at the absolute latest z-stream, the upgrade test FAILs.
  To avoid this, install at a version that has known upgrades available.
- **DISCO workflow test requires two hosts** (conno + disco) with specific
  network configuration. It cannot run in a single-host environment.
- **VMware platform only.** Cluster install/lifecycle tests assume VMware
  (`platform=vmw`). KVM and bare-metal TUI test coverage is future work.
- **Single cluster name.** All destructive tests use the same cluster name
  (`$TUI_CLUSTER_NAME`, default `sno`). Running two test suites with
  different cluster names on the same host is not supported.
- **Screenshot-based verification is text-only.** Screenshots are text
  captures of the tmux pane, not pixel images. Unicode box-drawing characters
  are preserved but color information is lost.
- **Progress engine tests are not TUI tests.** `test-tui-progress.sh`,
  `test-tui-progress-real.sh`, and `test-tui-progress-visual.sh` source
  internal ABA scripts directly (`scripts/include_all.sh`,
  `tui/v2/tui-progress.sh`). They are unit/integration tests for the
  progress engine, not black-box TUI tests. They intentionally break the
  "no internal functions" rule.

---

## Coding Conventions

All ABA core coding conventions apply. Key rules for TUI test code:

- **Tabs** for indentation, never spaces
- Empty lines must be truly empty (no trailing whitespace)
- **Never use `(( var++ ))`** — use `var=$(( var + 1 ))` (crashes under `set -e`)
- Comments explain **WHY**, not what
- Function naming: `tui_` for public helpers, `_tui_` for private internals
- Screenshot labels: lowercase, hyphens, `<prefix>-<step>-<desc>` format
- PASS/FAIL messages: `✓ PASS:` and `✗ FAIL:` with description
- Section headers: `echo "--- N. Description ---"` for test steps
- Never suppress stderr (`2>/dev/null`) on test actions — only on
  server-side verification queries where errors are expected

---

## Invariants

1. **No concurrent tests on the same host.** Enforced by per-host `flock`.
   Violation exits 99 with the holder's identity.
2. **DRY everywhere.** No duplicated logic across test files. Progress
   loops, navigation sequences, cleanup patterns — all in `tui-test-lib.sh`.
   If you copy-paste from another test, extract a helper instead.
3. **TUI-first.** All workflow operations go through the TUI. CLI/SSH is
   only for server-side verification and pre-test configuration. If an
   operation can't be done through the TUI, that's a TUI bug, not a reason
   to use the CLI.
4. **FAIL, never SKIP.** Tests that cannot start or complete MUST fail with
   a clear message. No `exit 0` with "SKIP" — that hides broken functionality.
5. **Tests must detect failures.** Every long-running operation uses
   `tui_wait_for_progress` which detects errors, captures output, and
   retries. No silent failures.
6. **Tests must produce evidence.** Screenshots capture every significant
   state. Output views are always captured. PASS/FAIL is never trusted
   without screenshot + server-side evidence.
7. **Pre-cleanup via TUI.** Cluster deletion uses `tui_delete_cluster()`
   which navigates the TUI itself — no CLI fallback that breaks when
   directories are missing.
8. **Upgrade tests use real upgrade pairs.** The upgrade target is resolved
   from the OCP release graph — never hardcoded, never skipped, never
   "noted" as unavailable. The upgrade test reuses the cluster installed by
   the cluster test — it does NOT reinstall. If no target exists, the test
   FAILs.
9. **Tests exit non-zero on failure.** `tui_summary` returns
   `[ "$_TUI_FAIL" -eq 0 ]` — any failed assertion causes a non-zero exit.
10. **Navigation via helpers, not keystrokes.** Tests use `tui_select_item`,
    `tui_press_button`, `tui_back_to` — never hard-coded key sequences.
    This makes tests resilient to menu reordering and label changes.
11. **Dual verification for destructive tests.** TUI screen assertions are
    always paired with server-side state checks (marker files, API queries).
    UI-only tests (smoke, nav, help) may use TUI assertions alone.
12. **Screenshot every step — if in doubt, take one.** Each test section
    must call `tui_screenshot` at least once. Progress helpers capture
    periodic + output screenshots automatically. An extra diagnostic
    screenshot never hurts; a missing one makes debugging impossible.
13. **DISCO tests must isolate the network.** Before running TUI workflows
    on disco, internet access must be disabled. This proves the air-gap
    workflow works without connectivity.
14. **Tests must clean up after themselves.** Restore `aba.conf` version,
    remove `ocp_upgrade_to`, exit TUI gracefully. The environment after a
    test run must be usable for the next test.
15. **Test files are independent.** A FAIL in one test file must not prevent
    the next from running. Each test starts its own TUI session, checks its
    own prerequisites, and cleans up after itself.
