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

## Known Limitations / Gaps (v1)

1. **KVM platform** not available in TUI (bare-metal and VMware only)
2. **`handle_action_local_docker`** function exists but is not wired to any menu item (orphaned code)
3. **Resume dialog** displays `vsphere` for the platform name but the wizard uses `vmw` — minor display inconsistency
4. **Retry values** in help text say "off/3/8" but implementation cycles "off/2/8"
5. **`aba load`** is not available as a TUI action (images can be saved but not loaded to a registry from disk via TUI)

---

## TUI v2 (tui/v2/)

TUI v2 is a **complete replacement** for v1, covering the entire ABA workflow:

- **DISCO mode** (disconnected) — registry install, load images, install cluster, Day-2
- **CONNO mode** (connected with mirror) — full v1 wizard + mirror ops + install cluster + Day-2
- **DIRECT mode** (connected, no mirror) — minimal wizard + install cluster + Day-2

### Key Design Change: Unified "Install Cluster"

There is NO separate "Configure Cluster" menu item. "Install Cluster" is a **single unified flow**:

1. Multi-page wizard: Basics → Networking → Interfaces → VM Resources
2. **Review/Confirm page** — shows ALL values including cluster FQDN (`<name>.<base_domain>`)
3. Buttons: **"Install"** (runs `aba cluster ... -s install`) or **"Back"** (edit values)

The `-s install` flag configures AND installs the cluster in one shot. No intermediate "configure then install" dance.

### Offline DISCO Mode (No Internet, No Bundle — Bundle Equivalent)

When no internet and no `.bundle` exist but `aba.conf` + sufficient payload are present,
the TUI enters DISCO mode. The minimum "bundle equivalent" is validated before entry.

**How users reach this state:**
- **Sync path:** `aba sync` (installs mirror + syncs images) → downloads CLI → go offline
- **Save path:** `aba save` (saves tar + installs mirror + downloads CLI) → go offline
- **Save+Load path:** `aba save` → `aba load` → go offline (fully ready)

**Required (payload-ready check — "is this a usable bundle?"):**
1. `mirror/data/imageset-config.yaml` — exists and non-empty
2. CLI tools present and >1MB each:
   - `cli/openshift-client-linux*.tar.gz`
   - `cli/openshift-install-linux*.tar.gz`
   - `cli/oc-mirror*.tar.gz`
3. Registry install files (at least one >1MB):
   - `mirror/mirror-registry*.tar.gz` (Quay) OR
   - `mirror/docker-reg-image.tgz` (Docker)
4. Image source (at least one — file presence only, no network calls):
   - `mirror/.available` exists — sync path (mirror installed, images synced)
   - OR tar archives `mirror/data/*.tar` (>1MB) — save path (need Load)

**If validation fails:** error dialog listing what's needed. TUI exits.

**If validation passes:** DISCO menu shown:
- Install Registry — available (or `(installed)` if already running)
- Load Images — available (for save path: user needs this; for sync path: skip)
- Install Cluster ✓
- Day-2, Monitor ✓ (if cluster installed)
- View ISC ✓ (read-only)
- Reset to Connected `[no internet]`

**Note:** `mirror/.available` is NOT required for entry — the mirror might not be
installed yet (save path). "Install Registry" is then the first action.

**Future: `aba status`** — structured command (text + JSON) for programmatic state checks.

### Code Patterns

**dlg() wrapper** — ALL dialog calls go through `dlg()` in `tui-lib.sh`, which automatically:
- Pads `--title` values with spaces: `"Foo"` → `" Foo "`
- Prepends `\n` to prompt/message text (empty line below title)
- Strings stay CLEAN (no manual formatting)

**String centralization** — ALL user-visible strings live in `tui-strings2.sh` (205+ constants).
Dynamic strings (containing runtime `$variables`) use `printf "$TUI2_MSG_*" "$var"`.

**Single-letter tags** — Menu items use mnemonic capital letters (M, S, V, I, D, N, X) as
keyboard shortcuts. Displayed on the left. Section separators use whitespace tags.

**Menu-style pages** — ALL cluster configuration pages use `--menu` (select row → edit in
sub-dialog). Dialog `--form` is NOT used (confusing Tab behavior, see plan A.31).

**Connection toggle** — Page 3 (Interfaces) has a "Connection" field that cycles:
`mirror → proxy → direct`. These are DISPLAY values in the TUI. When generating the
`aba cluster` command, "mirror" means "use local mirror" which is ABA's DEFAULT — so
the `--int-connection` flag is OMITTED entirely. Only `proxy` and `direct` emit the flag.
The underlying `int_connection` variable in `cluster.conf` uses empty/unset for mirror mode.
Future: will be consolidated into a single `mirror_conn` variable (see BACKLOG.md).

**DISCO mode filter** — `filter_disco_values()` strips public NTP/DNS from input fields.
Only active when `_TUI_MODE == "DISCO"`. Does not modify config files.

**MAC addresses (bare-metal)** — Page 3 shows "MACs" row if platform=bm. User enters
comma-separated MACs in an inputbox. Written to `$cluster_dir/macs.conf` before install.
VMs use "MAC template" (`mac_prefix`) on Page 4 instead.

**ISO vs Full Install (bare-metal)** — After review confirmation, platform=bm shows a
choice: "Create ISO only" (`-s iso`) or "Full Install" (`-s install`).

**Per-page cluster.conf persistence** — The cluster wizard saves `cluster.conf` after EVERY
page (Basics, Networking, Interface, VM Resources). This means:
- If the user cancels at any point, their entered values survive in `<cluster-dir>/cluster.conf`.
- If the TUI crashes or SSH drops, values are not lost.
- On re-entry to "Install Cluster", values are loaded from the existing `cluster.conf`.
- On cluster name change, if that cluster already has a `cluster.conf`, offer to load it.
The draft `cluster.conf` is a full valid config file — ABA can use it directly via CLI too.
On first save, the template (`templates/cluster.conf.j2`) is copied to seed all keys with
comments. All subsequent writes use `replace-value-conf -q` — NEVER raw heredocs or sed.
This preserves user comments and ABA's standard config format.

**starting_ip default** — The TUI does NOT compute `starting_ip`. The core
(`create-cluster-conf.sh`) auto-generates a sensible default from the CIDR via
`suggest_starting_ip()`. The TUI reads and displays whatever value is in
`cluster.conf`. VIPs (`api_vip`, `ingress_vip`) are similarly not computed by
the TUI — they are resolved from DNS at display time (pre-population only).

**Platform config gate (VMware/KVM)** — When the user hits NEXT on the Basics page with
platform=vmw or platform=kvm, the TUI checks if the platform config file exists:
1. If `vmware.conf`/`kvm.conf` exists in `$ABA_ROOT` → proceed silently.
2. If a cached config exists in `~/.vmware.conf`/`~/.kvm.conf` → offer to reuse it
   ("Use Saved" / "Configure New" / "Skip").
3. If nothing exists → prompt "Configure Now" or "Skip".
"Configure Now" opens the template in `dialog --editbox`, validates connection
(`govc about` / `virsh version`), and caches to `~/.<conf>` on success.
"Skip" proceeds — the user will be caught again at install time (`_check_platform_config`)
and ultimately by ABA core's hard abort.

**Platform status indicator** — The Basics page shows config status next to the platform:
- `vmw (VMware/ESXi) ✓` — config found
- `vmw (VMware/ESXi) ⚠ not configured` — no config file

**ERR trap disabled** — `trap - ERR` immediately after sourcing `include_all.sh`. Dialog
returns non-zero by design (1=Back, 2=Help, 3=Next).

**Internet check once** — Checked at startup, stored in `_TUI_INET` flag. No per-loop
re-checking. If network changes, user restarts TUI.

**Mode switching from CONNO** — The CONNO action menu offers two mode switches:
- "Switch to DIRECT mode" (X) — enters DIRECT action menu; requires internet.
- "Switch to DISCO mode" (Z) — runs `_ensure_offline_prereqs()` (downloads CLI tools +
  registry installers if missing), then enters DISCO action menu using the in-place repo
  as the "bundle equivalent". No tar file is created. Always available (prereq download
  fails gracefully if internet is unavailable and files are missing).
- Both return to CONNO when the user exits the sub-mode.

**"Create Bundle" vs "Switch to DISCO"** — These are distinct operations:
- "Create Bundle" (B) = exports a portable tar file to a USB/thumb drive for transfer
  to a physically disconnected host.
- "Switch to DISCO" (Z) = treats the current in-place repo as if it arrived via bundle.
  The user works offline here, no tar is produced.

### Entry Point

`tui/v2/abatui2.sh` — mode auto-detection, then routes to DISCO/CONNO/DIRECT.

### See Also

- `~/.cursor/plans/tui_v2_consolidated_f466c9ed.plan.md` — full design plan
- `tui/v2/tui-strings2.sh` — all string constants
