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

## Clean-slate testing (bootstrap from scratch)

The AI can run the full TUI test suite even on a freshly installed ABA with
no config files — by reading reference credential files and entering all
values through the TUI.

### Reference credential files

These files live on each test host. They are placed there once by the user
and contain the real credentials for the test environment. **Never commit
these files or their contents to the repo.**

| File | Host | Contents |
|------|------|----------|
| `~/.vmware.conf.test` | conno, disco | vCenter/ESXi credentials (GOVC_URL, GOVC_USERNAME, GOVC_PASSWORD, GOVC_DATASTORE, GOVC_NETWORK, GOVC_DATACENTER, GOVC_CLUSTER, VC_FOLDER) |
| `~/.pull-secret.json.test` | conno, disco | Red Hat pull secret JSON (from console.redhat.com) |
| `~/.kvm.conf.test` | conno, disco | KVM/libvirt config (LIBVIRT_URI, KVM_STORAGE_POOL, KVM_NETWORK) — if KVM testing is needed |

### Full clean-slate wipe

Before a from-scratch bootstrap, wipe everything on the test host:

```bash
_host="${TUI_TEST_HOST:-conno.example.com}"
ssh -F ~/.aba/ssh.conf "$_host" "
  # Back up real credentials (safety — never lose passwords)
  cp ~/.vmware.conf ~/.vmware.conf.bak 2>/dev/null
  cp ~/.pull-secret.json ~/.pull-secret.json.bak 2>/dev/null

  # Stop and remove mirror containers and pods
  podman stop --all 2>/dev/null
  podman rm --all --force 2>/dev/null
  podman pod rm --all --force 2>/dev/null
  podman volume prune --force 2>/dev/null
  podman secret rm --all 2>/dev/null

  # Stop and remove systemd user units (Quay, registry)
  systemctl --user stop quay-app quay-pod quay-redis quay 2>/dev/null
  systemctl --user disable quay-app quay-pod quay-redis quay 2>/dev/null
  systemctl --user reset-failed 2>/dev/null
  rm -f ~/.config/systemd/user/quay-*.service 2>/dev/null
  rm -f ~/.config/containers/systemd/quay.container 2>/dev/null
  systemctl --user daemon-reload 2>/dev/null

  # Remove mirror data
  sudo rm -rf /opt/quay 2>/dev/null
  rm -rf ~/quay-install 2>/dev/null

  # Remove ABA installation and state
  rm -rf ~/aba
  rm -rf ~/.aba

  # Remove config files (NOT the .test or .bak copies)
  rm -f ~/.vmware.conf ~/.pull-secret.json
"
```

After this, only `~/.vmware.conf.test`, `~/.pull-secret.json.test`, and
`.bak` backups remain. The host is ready for a fresh `git clone` + `./install`.

### Bootstrap flow (TUI only — no CLI shortcuts)

When configs are missing, the AI reads values from the `.test` files and
enters them through the TUI:

1. **Fresh install** — clone and install ABA:
   ```bash
   ssh -F ~/.aba/ssh.conf "$_host" "
     git clone -b dev https://github.com/sjbylo/aba.git ~/aba
     cd ~/aba && ./install
   "
   ```
2. **Read** `~/.vmware.conf.test` via SSH — extract GOVC_URL, GOVC_PASSWORD, etc.
3. **Read** `~/.pull-secret.json.test` via SSH — note the path
4. **Launch** TUI → at the pull-secret gate, enter the `.test` file path
   through the TUI input dialog
5. **Setup wizard** → channel, version, platform — enter values through
   each wizard page
6. **Platform config** → if TUI shows "Platform not configured", navigate to
   Settings → Platform and enter vCenter values from the `.test` file
7. **Mirror install** → navigate to Install Mirror → configure → install
8. **Mirror sync** → navigate to Sync → confirm → wait for completion
9. **Cluster install** → navigate to Install Cluster → wizard pages → enter
   values → install
10. **Day-2, Upgrade, Lifecycle** → test all remaining workflows

Every step above IS a test — the AI verifies the TUI handles each
workflow correctly while bootstrapping the environment.

### Key rules

- **Check progress every ≤10 minutes**: Never block/wait longer than 10
  minutes without checking the TUI screen or test output. Long operations
  (mirror install, image load, cluster install) can take 30-60 min — poll
  them in ≤10 min intervals so you can detect stalls, dismiss unexpected
  dialogs, and report progress to the user.
- **TUI only**: Enter all values through TUI dialogs. Do not use `aba` CLI
  or copy config files directly — this is a TUI test skill.
- **Never commit credentials**: The `.test` files and their contents must
  never appear in git, commits, SKILL files, or chat output.
- **Read, don't display**: When reading `.test` files, extract the values
  into variables. Do not echo passwords to the terminal or chat.
- **Restore after testing**: If `.bak` files exist, restore them when done:
  ```bash
  ssh -F ~/.aba/ssh.conf "$_host" "
    mv ~/.vmware.conf.bak ~/.vmware.conf 2>/dev/null
    mv ~/.pull-secret.json.bak ~/.pull-secret.json 2>/dev/null
  "
  ```

## Valid cluster names (DNS pre-configured)

Cluster install requires DNS `A` records for `api.<name>.example.com` and
`*.apps.<name>.example.com` on the lab DNS server (10.0.1.8). Only these
names have records:

| Name | api IP | *.apps IP | Type |
|------|--------|-----------|------|
| `sno` | 10.0.1.201 | 10.0.1.201 | SNO |
| `compact2` | 10.0.1.212 | 10.0.1.222 | Compact |
| `standard` | 10.0.1.217 | 10.0.1.227 | Standard |
| `ocp` | 10.0.1.100 | 10.0.1.100 | SNO |

**Do NOT use arbitrary names** like `tuitest` — install will fail with
"DNS record does not resolve". Use one of the names above or add DNS
records first.

### Deleting test clusters before install

The AI is allowed to delete these test clusters (VMs in vCenter) if they
block a new install (e.g. IP conflict from arping pre-flight):

- `sno`, `sno2`, `sno3`, `sno4`
- `compact`, `compact2`
- `standard`, `standard2`

To delete a cluster and its VMs before installing, use the ABA CLI:

```bash
_host="${TUI_TEST_HOST:-conno.example.com}"
ssh -F ~/.aba/ssh.conf "$_host" "cd ~/aba && aba -d <name> delete --yes 2>/dev/null; rm -rf ~/aba/<name>"
```

**Always use `aba -d <name> delete`** — never use `govc vm.power` / `govc vm.destroy`
directly. The ABA CLI handles VM discovery, power-off, destruction, folder
cleanup, and state file removal atomically.

**Never delete** `e2e-*` VMs (E2E pool VMs) or `con*`/`dis*` hosts.

When running `test-tui-all.sh`, set the cluster name:

```bash
TUI_CLUSTER_NAME=sno test/func/test-tui-all.sh
```

## Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `TUI_TEST_HOST` | `conno.example.com` | Target host |
| `TUI_CLUSTER_NAME` | `tuitest` | Cluster name — **override with a valid name** (see above) |
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
