# TUI Specification (abatui)

## Overview

The ABA TUI (`./abatui`) is an interactive terminal wizard built with `dialog` that guides users through environment preparation for OpenShift disconnected installations. It covers version selection, operator configuration, mirror registry setup, bundle creation, and image save/sync operations.

**Scope:** The TUI covers environment preparation only. Cluster installation, Day-2 operations, and KVM platform configuration are handled via the CLI.

**Entry:** `./abatui` or `tui/abatui.sh`

**Dependencies:** `dialog` package, `scripts/include_all.sh`, `tui/tui-strings.sh`

---

## Use-Cases

### UC-1: First-time Setup (Fresh Configuration)

**Preconditions:** No `aba.conf` exists or it is incomplete.

**Flow:**
1. Welcome screen → Continue
2. Pull secret configuration (UC-2)
3. Channel selection (UC-3)
4. Version selection (UC-4)
5. Platform & network configuration (UC-5)
6. Operator selection (UC-6)
7. Summary & action menu (UC-7)

**Postconditions:** `aba.conf` fully populated, user directed to action menu.

---

### UC-2: Pull Secret Configuration

**Preconditions:** Wizard at "pull_secret" step.

**Flow:**
1. Check if `~/.pull-secret.json` exists
2. If missing: prompt user to paste or provide path
3. Validate JSON structure (`jq empty`)
4. Validate contains `registry.redhat.io` auth
5. Optionally validate credentials against registry (live auth test)

**Postconditions:** `~/.pull-secret.json` exists and is valid.

**Validation:**
- JSON syntax check
- Required registry key present
- Optional live authentication test

---

### UC-3: Channel Selection

**Preconditions:** Pull secret configured.

**Flow:**
1. Display radio list: `stable`, `fast`, `candidate`
2. User selects channel

**Postconditions:** `OCP_CHANNEL` set.

---

### UC-4: Version Selection

**Preconditions:** Channel selected.

**Flow:**
1. Display menu options:
   - Latest (fetched from Cincinnati)
   - Previous (one minor behind latest)
   - Older (two minors behind)
   - Current (if `openshift-install` is installed)
   - Manual entry
2. For manual entry: validate against Cincinnati API via `scripts/ocp-version-validate`
3. Confirmation dialog showing channel + version

**Postconditions:** `ocp_channel` and `ocp_version` written to `aba.conf`. Background tasks triggered:
- CLI tool downloads (`scripts/cli-download-all.sh`)
- Catalog prefetch (`scripts/prefetch-catalogs.sh`)
- oc-mirror download

---

### UC-5: Platform & Network Configuration

**Preconditions:** Version confirmed.

**Flow:**
1. Platform selection: `bm` (bare-metal) or `vmw` (VMware vSphere)
2. Base domain (optional — auto-detected if empty)
3. Machine network CIDR
4. DNS servers (comma-separated IP list)
5. Gateway / next-hop address
6. NTP servers (comma-separated, hostnames or IPs allowed)

**Validation:**
- CIDR format check
- IP list validation (DNS)
- Single IP validation (gateway)
- NTP server format validation

**Postconditions:** `platform`, `domain`, `machine_network`, `dns_servers`, `next_hop_address`, `ntp_servers` written to `aba.conf`.

**Note:** KVM (`kvm`) is not available in the TUI — CLI only.

---

### UC-6: Operator Selection

**Preconditions:** Platform configured; catalog indexes downloaded.

**Flow:**
1. Main operator menu with options:
   - **Operator sets** — checklist of predefined sets from `templates/operator-set-*`
   - **Search** — free-text search (≥2 chars, AND logic) across catalog indexes
   - **View/edit basket** — checklist to remove operators
   - **Clear basket** — removes all selected operators
2. For operator sets: toggling a set adds/removes all its operators from the basket
3. For search: results shown as checklist; selected items added to basket
4. "Next" advances; warns if basket is empty

**Data:**
- `OP_BASKET` (associative array of selected operators)
- `OP_SET_ADDED` (tracks which sets are active)
- Indexes located at `.index/*-index-v${OCP_VERSION%.*}`

**Postconditions:** Operator selections stored in memory, persisted at summary/apply time.

---

### UC-7: Summary & Action Menu

**Preconditions:** All wizard steps complete.

**Flow:**
1. Write all configuration to `aba.conf`:
   - `ocp_channel`, `ocp_version`, `platform`, `domain`, `machine_network`
   - `dns_servers`, `next_hop_address`, `ntp_servers`
   - `ops=""` (individual ops cleared — handled via sets)
   - `op_sets` (space-separated list of active set names)
2. Create/reuse custom operator set file (`templates/operator-set-custom-YYYYMMDD-HHMMSS`)
3. Clean up older custom set files
4. Trigger background ImageSetConfiguration generation (`aba isconf -d mirror`)
5. Display action menu (UC-8)

**Postconditions:** Configuration finalized in `aba.conf`.

---

### UC-8: Action Menu

**Preconditions:** Configuration applied.

**Menu options:**

| # | Action | Use-Case |
|---|--------|----------|
| 1 | Create Install Bundle | UC-9 |
| 2 | Install & Sync to Local Registry | UC-10 |
| 3 | Install & Sync to Remote Registry | UC-11 |
| 4 | Save Images to Disk | UC-12 |
| 5 | View/Edit ImageSet Configuration | UC-13 |
| 6 | Settings | UC-14 |
| 7 | Advanced | UC-15 |

**Navigation:** "Back" returns to operator selection; "Exit" shows exit summary.

---

### UC-9: Create Install Bundle

**Preconditions:** ImageSetConfiguration generated.

**Flow:**
1. Wait for `tui:isconf:generate` background task
2. Prompt for output path (default: `/tmp/ocp-bundle`)
3. If output on same device as `mirror/data/`:
   - Offer `--light` option (yes/no)
   - If full bundle: show disk space warning (data duplicated)
4. Confirm and execute

**Command:** `aba bundle -o '<path>' [--light] [--retry N] [-y]`

**Execution:** Via `confirm_and_execute` (run in TUI or terminal).

---

### UC-10: Install & Sync to Local Registry

**Preconditions:** Action menu displayed.

**Flow:**
1. Form dialog collecting:
   - Registry hostname (FQDN)
   - Registry user
   - Registry password
   - Registry path (namespace)
   - Data directory
2. Write values to `mirror/mirror.conf`
3. Confirm and execute

**Command:** `aba sync -d mirror --vendor <auto|quay|docker> -H '<host>' [--retry N] [-y]`

**Registry type:** Determined by `ABA_REGISTRY_TYPE` setting (Auto/Quay/Docker).

---

### UC-11: Install & Sync to Remote Registry

**Preconditions:** Action menu displayed.

**Flow:**
1. Same form as UC-10, plus:
   - SSH user
   - SSH key path
2. Write values to `mirror/mirror.conf` (including `reg_ssh_user`, `reg_ssh_key`)
3. Confirm and execute

**Command:** `aba sync -d mirror --vendor <auto|quay|docker> -H '<host>' -k '<key>' [--retry N] [-y]`

---

### UC-12: Save Images to Disk

**Preconditions:** Action menu displayed.

**Flow:**
1. Confirm and execute (no additional input needed)

**Command:** `aba save -d mirror`

**Purpose:** Pull images from Internet and save to `mirror/data/mirror_000001.tar` for air-gapped transfer.

---

### UC-13: View/Edit ImageSet Configuration

**Preconditions:** ImageSetConfiguration generated.

**Flow (View):**
1. Wait for generation task
2. Display `mirror/data/imageset-config.yaml` in textbox

**Flow (Edit):**
1. Open in editbox dialog
2. Save overwrites the YAML file
3. File marked as user-owned (timestamp newer than `mirror/data/.created`)

**Flow (Reset):**
1. Touch `mirror/data/.created` to reclaim ownership
2. Re-trigger generation via `run_once`

**User ownership detection:** If `imageset-config.yaml` mtime > `.created` mtime, the file is considered user-edited and will not be auto-regenerated.

---

### UC-14: Settings

**Preconditions:** Action menu displayed.

**Options:**
| Setting | Values | Effect |
|---------|--------|--------|
| Auto-answer | On / Off | Sets `ask=` in `aba.conf`; appends `-y` to commands |
| Registry type | Auto / Quay / Docker | Sets `reg_vendor` in `mirror.conf` |
| Retry count | Off / 2 / 8 | Appends `--retry N` to commands |

---

### UC-15: Advanced Menu

**Preconditions:** Action menu displayed.

**Options:**

| # | Action | Description |
|---|--------|-------------|
| 1 | Generate ImageSet & Exit | Run `aba isconf -d mirror -y`, then exit TUI |
| 2 | Edit ImageSet Config | Open editbox (same as UC-13 Edit) |
| 3 | Uninstall Registry | `aba uninstall -d mirror -y` (only if mirror.conf exists) |
| 4 | Exit | Show exit summary and quit |

---

### UC-16: Resume Existing Configuration

**Preconditions:** `aba.conf` exists and `config_is_complete` returns true.

**Flow:**
1. Display summary of current config (channel, version, platform, operators)
2. Options:
   - **Continue** → jump directly to action menu (UC-8)
   - **Reconfigure** → restart wizard from pull secret (UC-2)
   - **Exit** → quit

**`config_is_complete` checks:**
- Channel and version set
- `~/.pull-secret.json` exists
- Pull secret validates against registry
- Domain is non-empty

---

### UC-17: Execution (confirm_and_execute)

**Preconditions:** A command is ready to run.

**Options:**
1. **Run in TUI** — executes in a `dialog --progressbox`, output logged and shown on completion (success or failure textbox with retry option)
2. **Run in Terminal** — clears screen, runs command directly in the terminal, returns to TUI on ENTER

**Behavior:**
- Appends `-y` automatically in TUI mode
- Strips ANSI escape codes for TUI display
- On failure: shows error output with Back/Exit/Retry options

---

## Configuration Files Modified

| File | Fields written by TUI |
|------|----------------------|
| `aba.conf` | `ocp_channel`, `ocp_version`, `platform`, `domain`, `machine_network`, `dns_servers`, `next_hop_address`, `ntp_servers`, `ops`, `op_sets`, `ask` |
| `mirror/mirror.conf` | `reg_host`, `reg_port`, `reg_user`, `reg_pw`, `reg_path`, `data_dir`, `reg_ssh_user`, `reg_ssh_key`, `reg_vendor` |
| `templates/operator-set-custom-*` | Custom operator set file (operators not in any predefined set) |

---

## Background Tasks

| Task ID | Command | Trigger |
|---------|---------|---------|
| `tui:isconf:generate` | `aba isconf -d mirror` | After summary_apply |
| `tui:prefetch:catalogs:t2` | `scripts/prefetch-catalogs.sh` | After version confirmation |
| `TASK_OC_MIRROR` | `make -sC cli oc-mirror` | Startup |
| `TASK_QUAY_REG_DOWNLOAD` | `make -s -C mirror download-registries` | Before operator selection |
| `stable:latest`, `fast:latest`, etc. | `fetch_latest_version` | Startup (parallel) |
| `catalog:${ver}:${name}` | Catalog index downloads | After version set |

---

## Known Limitations / Gaps

1. **KVM platform** not available in TUI (bare-metal and VMware only)
2. **Cluster installation** not in TUI scope (CLI only)
3. **Day-2 operations** not in TUI scope (CLI only)
4. **`handle_action_local_docker`** function exists but is not wired to any menu item (orphaned code)
5. **Resume dialog** displays `vsphere` for the platform name but the wizard uses `vmw` — minor display inconsistency
6. **Retry values** in help text say "off/3/8" but implementation cycles "off/2/8"
7. **`aba load`** is not available as a TUI action (images can be saved but not loaded to a registry from disk via TUI)
8. **Connected installation** workflow not covered by TUI

---

## Future Use-Cases (Planned)

- Connected & disconnected OCP installation from TUI
- `aba load` as a TUI action (load images from disk to registry)
- KVM platform support
- Remote command execution
