# bm-install-simplify — fix backlog

Working list for this branch. Do not implement while the TUI freeze run is in progress. The suite must keep testing the tree as it was when that run started.

Two buckets. Bare-metal refactor fixes land in the bare-metal commit. Everything else gets its own commit and is not folded into that one.

## How to commit

One bare-metal commit for the refactor still in the working tree, plus the bare-metal rows below once the freeze ends. Not a squash of the whole branch. The `aba_wait_show` commits already on this branch are not bare-metal. Leave them as their own commits. `c7375ae2` already mixes a bare-metal ask tidy-up with wait_show and the disN push rule. Do not rewrite it.

Do not put `bundles/v2/go.sh` in the bare-metal commit. That edit is already the local `dev` commit `01b0bc73` (Cincinnati GA tips). Merging `dev` brings it.

A later commit, not part of the bare-metal set, sweeps the rest of `scripts/` onto the helpers. It can sit on this branch after the bare-metal commit, or land on `dev` after the merge.

## A. Bare-metal refactor

These belong in the bare-metal commit.

### A0. cluster.conf outranks macs.conf — done

A newer `cluster.conf` (standard → SNO, node counts, IPs) rebuilds `agent-config.yaml` even when `macs.conf` is older. `macs.conf` only supplies the MAC addresses inside that rebuild. A hand-edited YAML is kept only when it is newer than both files. Make already expresses this: `agent-config.yaml` depends on `cluster.conf`. The review target depends on `agent-config.yaml`, so Make writes the file and then asks the user to edit it. The ISO target depends on `install-config.yaml` and `agent-config.yaml`, because those files are what the ISO is built from.

### A1. Re-run commands in the bare-metal prompts

Seen 2026-11-05. Working directory was `ocp`. Command was `aba install` (no `-d`). The boot prompt still said:

- `aba -d ocp write-usb` (the info block, and again inside the question)
- `aba -d ocp install`
- `aba -d ocp mon`

From inside `ocp` those must be `aba write-usb`, `aba install`, and `aba mon`. `aba -d ocp …` stays correct only when the user actually passed `-d`.

The No-path follow-up in `scripts/bm-ask-boot.sh` is inconsistent on its own: the install example uses `-d`, and the tip's `aba mon` does not.

| File | What it prints |
|---|---|
| `scripts/bm-ask-boot.sh` | `write-usb`, `install`, `mon`, and `install -y` in the manual-boot info, the ask, the abort text, and the No follow-up |
| `scripts/bm-ask-edit.sh` | `aba -d $_cluster_dir install` in all three CLI fix texts (`_bm_fix_text`) |
| `scripts/monitor-install.sh` | `aba -d $CLUSTER_NAME mon` and `aba -d $CLUSTER_NAME unstick` when install monitoring stops early |

TUI next-step text in `bm-ask-edit.sh` does not use `aba -d`. Leave that path alone.

Add the helpers in section B1 in this same commit, and call them from the three files above. Also switch `show_cluster_summary` over to the helpers so that inline copy is not a second implementation. Do not sweep the other scripts in this commit.

### A2. Short summary of agent-config.yaml before Yes

`scripts/agent-config-summary.sh` is the standalone summary (`[-s|-v] [agent-config.yaml]`). It reads the file with `yaml2json` and formats the lines with `jq`. The review ask does not call it yet. Do not shell the install ask out to the example script in a cluster directory. That file is only a guide for the shape.

The review ask in `scripts/bm-ask-edit.sh` prints the path and stops:

```
[ABA] agent-config.yaml: /home/steve/aba/ocp/agent-config.yaml
```

The user should be able to answer Yes without opening the file. One line is the goal when it still reads clearly. More lines are fine when one line would be a blob. Easy and fast to scan either way. Not a dump of the YAML.

Example the user wrote, local only (`ocp/` is gitignored): `ocp/agent-config-summary.sh`. Default is the compact form (1–3 lines). `-v` is a node-by-node dump and is too long for the ask. Real compact output for this `ocp` file:

```
ocp | 3 master (master1-3) | RV: 10.0.1.100
IPs: master1=10.0.1.100/20, master2=10.0.1.101/20, master3=10.0.1.102/20 | GW: 10.0.0.1
NIC: eno1 | Bond: none | DNS: 10.0.1.8 | NTP: 10.0.1.8
```

That shape is the target: cluster, role counts and compressed names, rendezvous IP, per-node IPs, gateway, NIC, bond or none, DNS, NTP. MACs stay out of these lines when `macs_report` has already printed them. The example script puts MACs only in `-v`. Call out placeholders and a disk hint when they would make Yes the wrong answer. The example needs `yq` v4 and `python3`. The ask should print the same three lines from data ABA already has, not by calling that script.

### A3. Review bare-metal tests, find gaps, fill them

Do this as part of the bare-metal work. Three steps, in order:

1. Review the bare-metal tests we already have.
2. Find the gaps.
3. Fill those gaps in `test/func/` or `test/e2e/`. Func for behavior that does not need a pool. E2E when the case needs a real host, ISO, or boot.

Start from these. This is not the review.

- Func: `test/func/test-bm-continuous-install.sh`, `test/func/test-macs-helpers.sh`, `test/func/test-preflight-check-bm.sh`, `test/func/test-bmc-boot.sh`, `test/func/test-agent-wait-skip.sh`, plus the bare-metal parts of `test/func/test-ask-function.sh`, `test/func/test-progress-events.sh`, and `test/func/test-primed-bundle-scenarios.sh`.
- E2E: `test/e2e/suites/suite-mirror-sync.sh` (ISO simulation, full out-of-band SNO), `test/e2e/suites/suite-create-bundle-to-disk.sh` (platform=bm continuous ISO), and the `platform=bm` case in `test/e2e/suites/suite-state-management.sh`.

The TUI cluster install test is VMware SNO, not bare metal. There is no TUI bare-metal test today.

### A4. Add a TUI bare-metal test

Required. Add it under `test/func/`, same style as `test/func/test-tui-cluster.sh`, and run it from `test/func/test-tui-all.sh`. Platform is bare metal, not VMware.

Cover the path this refactor added:

- The cluster wizard collects the MACs. That is the preferred TUI fix, not `macs.conf`.
- A short MAC list warns and does not block the wizard.
- Install shows the progress steps, including Stage nodes as a no-op on bare metal, then the boot ask.
- Placeholders just written ask. Placeholders still there on a re-run stop, with next steps that say go back to the wizard and add the MACs, then Retry.
- Retry does not succeed until those MACs are actually fixed.

### A5. Bare-metal progress dialogs run the question into one paragraph

Seen 2026-11-05, more than one bare-metal flow dialog. Screenshot is the manual boot ask while working in `ocp`. The body is one wrapped blob. "ISO file:", the path, the virtual-media line, the `dd` command, PXE, and the Yes/No sentences sit on the same lines. The `dd` line breaks in the middle of `of=/dev/sdX`.

The script text already has the line breaks (`scripts/bm-ask-boot.sh`, the manual-boot `ask`). The progress dialog does not keep them. `tui/v2/tui-progress.sh` `_tp_handle_prompt` turns the FIFO `\\n` back into newlines, then passes the whole string to `dialog --yesno`. What is on screen is a single paragraph.

Same dialog path for every bare-metal `ask` during install:

| Ask | Script |
|---|---|
| Manual boot (the screenshot) | `scripts/bm-ask-boot.sh` |
| BMC / Redfish boot | `scripts/bm-ask-boot.sh` |
| MAC check / edit `agent-config.yaml` | `scripts/bm-ask-edit.sh` |

The Yes and No buttons are already on the dialog. The body also says "Yes: …" and "No: …", so that choice is printed twice and adds to the jumble.

Keep the script's lines in the dialog: a blank line between sections, one bullet per line, the ISO path on its own line, the `dd` command on its own line. Do not break a path or a command in the middle of a word. The command-form fix is A1 and stays separate.

## B. Not bare-metal

Own commit. Do not include these hunks in the bare-metal commit.

### B1. Helpers, then the rest of the command strings

`ABA_TARGET_DIR` is set only when `scripts/aba.sh` entered the directory via `aba -d` / `--dir`. It is unset when the user is already in that directory.

- `aba_cmd [words...]` — command for the current directory. `aba <words>` when `ABA_TARGET_DIR` is unset. `aba -d $(basename "$PWD") <words>` when it is set.
- `aba_cmd_for <dir> [words...]` — command for a named directory, which may not be cwd (`aba status` listing other clusters, a directory just created, an imported cluster). If `<dir>` is this cwd and `ABA_TARGET_DIR` is unset, same as `aba_cmd`. Otherwise `aba -d <dir> <words>`.

The helper functions are added with the bare-metal commit (section A), because those prompts need them. This commit only changes the other call sites.

Text that is read later, away from this shell, stays `aba -d <name>`. Example: the VM annotation in `scripts/include_all.sh` (`Manage from … — aba -d ${CLUSTER_NAME} …`). The person reading it is not in this cwd.

Comments, README, and tests that invoke a fixed `aba -d mirror …` from the repo root stay as they are.

### B2. TUI progress waiter quits a live install

Seen on the freeze run, 2026-11-05, VMware SNO on conno (not bare metal). Not a bare-metal product change.

`test/func/test-tui-cluster.sh` reported the install done after 198s. `~/aba/sno/.install-complete` was missing. The ISO and `.bm-config-reviewed` were present. At 120s the dialog still showed Build agent ISO in progress, and Review/generate configs already said No-op. `tui_wait_for_progress` treated No-op and no In Progress as finished, then sent `q`, which stopped the install before stage, boot, and monitor. Day-2, upgrade, and lifecycle then failed only because `sno` was not installed.

Fixed in `tui_wait_for_progress`: while any step still says N/A and none have Failed, keep waiting. Re-run of cluster install through lifecycle is the check.

### B3. Every line of a multi-line question gets `[ABA]`

`ask()` in `scripts/include_all.sh` used to prefix only the first line. The loop that prefixes each physical line is a general CLI change, not a bare-metal one. `test/func/test-ask-function.sh` covers it. Split that hunk out of `include_all.sh` if it is still mixed with the MAC-placeholder edits.
