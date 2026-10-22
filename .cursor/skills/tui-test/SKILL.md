---
name: tui-test
description: >-
  Test ABA's TUI interactively using the tmux-based test harness. Use when
  the user says "test the TUI", "check the wizard", "verify the menu",
  "explore the TUI", "test this TUI change", or asks you to navigate or
  verify any TUI dialog, menu, or workflow.
---

# AI-Driven TUI Testing

Drive the ABA TUI (`abatui`) interactively using the same helper library
that the scripted tests use. This gives you screen-aware navigation,
pattern-based assertions, and the ability to adapt to unexpected dialogs.

## Setup

The CLI wrapper runs from bastion (the workspace host) and SSHs into the
test host to drive the TUI via tmux.

```bash
# Default host: conno.example.com
# Override with: export TUI_TEST_HOST=disco.example.com
CLI="bash test/func/tui-test-cli.sh"
```

## Core workflow

### 1. Start the TUI

```bash
$CLI tui_start
```

This kills any existing session, clears failed `run_once` tasks, and launches
`abatui` in a tmux session (`tui-test`) on the remote host.

### 2. See the screen

```bash
$CLI tui_capture
```

Read the output to understand what's on screen — dialog titles, menu items,
buttons, content. This is your eyes.

### 3. Interact

```bash
# Send keystrokes
$CLI tui_keys Enter
$CLI tui_keys Escape
$CLI tui_keys Tab
$CLI tui_keys Down Down Enter

# Select a menu item by label (finds shortcut key, sends it + Enter)
$CLI tui_select_item "Day-2"
$CLI tui_select_item "Mirror Payload"

# Press a button by label (navigates with Tab, presses Enter)
$CLI tui_press_button "Help"
$CLI tui_press_button "Cancel"
```

### 4. Discover what's on screen

```bash
# List menu items as KEY<tab>LABEL
$CLI tui_menu_items

# List button labels
$CLI tui_buttons

# Get dialog title
$CLI tui_dialog_title
```

### 5. Assert

```bash
# Assert pattern is present
$CLI tui_assert_contains "OperatorHub" "Has OperatorHub item"

# Assert pattern is NOT present
$CLI tui_assert_not_contains "Error" "No errors on screen"

# Wait for pattern to appear (with timeout)
$CLI tui_assert_appears "Actions" "Main menu loaded" 15
```

### 6. Navigate

```bash
# Press Escape until a known screen appears
$CLI tui_back_to "Actions"

# Wait for a pattern
$CLI tui_wait_for "Additional Images" 15

# Wait for ISC generation to complete (handles error dialogs too)
$CLI tui_wait_isc_done 120
```

### 7. Stop

```bash
$CLI tui_stop
```

## How to test a TUI workflow

Follow this loop:

1. **Capture** — `tui_capture` to see the screen
2. **Reason** — read the output, understand what dialog/menu you're on
3. **Act** — send keys, select items, press buttons
4. **Assert** — verify expected content appeared
5. **Repeat** — navigate to the next thing to test

### Example: verify Day-2 menu has all expected items

```bash
CLI="bash test/func/tui-test-cli.sh"

$CLI tui_start
# Wait for splash, press Enter to continue
$CLI tui_assert_appears "OpenShift Installer" "Splash appeared" 15
$CLI tui_keys Enter
sleep 1

# Navigate to Day-2
$CLI tui_select_item "Day-2"
sleep 1

# Check what's on screen
$CLI tui_capture

# Assert expected items
$CLI tui_assert_contains "OperatorHub" "Has OperatorHub"
$CLI tui_assert_contains "NTP" "Has NTP"
$CLI tui_assert_contains "OSUS" "Has OSUS"
$CLI tui_assert_contains "Upgrade" "Has Upgrade"
$CLI tui_assert_contains "Shutdown" "Has Shutdown"

# Check help
$CLI tui_press_button "Help"
sleep 2
$CLI tui_capture
$CLI tui_assert_contains "Configuration" "Help has Configuration section"
$CLI tui_keys Enter  # dismiss help

# Clean up
$CLI tui_stop
```

## Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `TUI_TEST_HOST` | `conno.example.com` | Target host |
| `TUI_TEST_SESSION` | `tui-test` | tmux session name |

For DISCO mode testing on the disco host:

```bash
export TUI_TEST_HOST=disco.example.com
```

## Important patterns

### ISC generation blocking

When entering the Mirror Payload menu, the TUI may block on ISC generation.
Use `tui_wait_isc_done` after navigating there:

```bash
$CLI tui_select_item "Mirror Payload"
$CLI tui_wait_isc_done 120
```

This handles both the "Generating..." infobox and ISC error dialogs.

### Handling unexpected dialogs

If `tui_capture` shows something unexpected (a confirmation, error, or gate
dialog you didn't expect), handle it:

```bash
# Dismiss with Enter (OK/msgbox dialogs)
$CLI tui_keys Enter

# Or cancel out
$CLI tui_press_button "Cancel"

# Or escape back to a known screen
$CLI tui_back_to "Actions"
```

### DISCO mode

The disco host may detect as CONNO (it has internet). To force DISCO mode,
create a `.bundle` marker before starting — and clean it up after:

```bash
ssh -F ~/.aba/ssh.conf disco.example.com "touch ~/aba/.bundle"
$CLI tui_start
# ... test DISCO flows ...
$CLI tui_stop
ssh -F ~/.aba/ssh.conf disco.example.com "rm -f ~/aba/.bundle"
```

### Sleep after interactions

Always add a short sleep after key actions to let the TUI render:

```bash
$CLI tui_select_item "Configure"
sleep 1                              # let dialog render
$CLI tui_capture                     # now read the result
```

## Relationship to scripted tests

The scripted tests (`test-tui-*.sh`) and AI-driven testing share the same
library (`tui-test-lib.sh`). They complement each other:

| Aspect | Scripted | AI-driven |
|--------|----------|-----------|
| **When** | CI, regression, batch | Exploratory, after TUI changes |
| **Adapts to changes** | No — update script | Yes — AI reads screen |
| **Depth** | Fixed path | Can go deeper on interesting areas |
| **Repeatability** | Exact same run every time | Varies (AI reasoning) |
| **Speed** | ~12 min for full suite | Depends on exploration depth |

Use scripted tests for regression safety. Use AI-driven testing for
exploration, verifying new features, and debugging TUI issues.
