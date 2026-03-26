# ABA Technical Backlog

This file tracks architectural improvements and technical debt that should be addressed in future releases.

---

## Critical

### install-config.yaml.j2 Platform Detection: Corrected to Match Design (RESOLVED)

**Status:** Resolved — not a regression, this is a design-correct fix
**Priority:** N/A (was Critical, downgraded after investigation)
**Created:** 2026-03-23
**Resolved:** 2026-03-23

**Summary:**
On `main`, `install-config.yaml.j2` used `{%- elif GOVC_URL is defined %}` and
`create-install-config.sh` unconditionally sourced `normalize-vmware-conf`. This violated
ABA's core design principle: **config files are the single source of truth**.

The feature branch correctly changed both to check `platform == 'vmw'` (from `aba.conf`),
making `aba.conf`'s `platform` variable authoritative and treating `vmware.conf` as a
supporting file loaded only when `platform=vmw`.

**Verified by template rendering test:**
- `main` with `platform=bm` + `GOVC_URL` defined → generates `vsphere:` section (WRONG — vmware.conf presence overrides aba.conf)
- HEAD with `platform=bm` (no GOVC_URL sourced) → generates `baremetal:` section (CORRECT — respects aba.conf)
- HEAD with `platform=vmw` → generates `vsphere:` section (CORRECT)

**Impact on tests:** None. All old test scripts (`test/test[1-5]*.sh`) and all E2E suites
already set `--platform vmw` explicitly. SNO clusters use `none: {}` regardless of platform.

**Design principle documented:** Added as section 7 ("Config Files Are the Single Source of
Truth") in `ai/RULES_OF_ENGAGEMENT.md`.

---

### `aba delete` After `aba clean` Fails to Destroy VMs (Re-initializes Instead)

**Status:** Backlog
**Priority:** Critical
**Estimated Effort:** Small-Medium
**Created:** 2026-03-23

**Problem:**
Running `aba clean` followed by `aba delete` does not destroy the VMs on the hypervisor.
Instead, `aba delete` sees that configuration files are missing (cleaned by `aba clean`),
re-initializes the cluster directory from scratch, then fails because `install-config.yaml`
doesn't exist:

```
[steve@rhel-baseline sno]$ aba clean
[steve@rhel-baseline sno]$ aba delete
[ABA] Initialized cluster directory /home/steve/subdir/aba/sno successfully
[ABA] vmware.conf initialized
[ABA] 1 port(s): ens160
[ABA] Adding DNS server(s): 10.0.1.8 10.0.2.8
[ABA] Adding NTP server(s): 10.0.1.8 ntp.example.com
[ABA] Generating Agent-based configuration file: .../sno/agent-config.yaml
...
[ABA] Error: Cannot parse cluster configuration. 'install-config.yaml' and/or 'agent-config.yaml' do not exist.
```

The VMs remain powered on with their IPs, causing IP conflicts for subsequent installs.

**Observed in E2E testing:**
- `connected-public` suite test [7] "Proxy mode: verify and delete" ran
  `aba --dir e2e-sno1 delete` which completed in 1 second (!) without destroying the VM.
  The VM `e2e-sno1-e2e-sno1` remained poweredOn at IP 10.0.2.12.
- The next test (no_proxy validation) failed with "IP conflict: 10.0.2.12 is already in use!"
- The E2E framework's orphan VM cleanup (`--force` dispatch) caught the leftover VM.

**Root cause:**
`aba delete` depends on Makefile targets that require cluster config files
(`install-config.yaml`, `agent-config.yaml`, `cluster.conf`). If these were removed by
`aba clean`, the Makefile re-initializes the directory instead of proceeding to VM deletion.
The delete path needs the `vmware.conf` (or `kvm.conf`) and the VM/cluster name, but
NOT the full agent config. It should be able to destroy VMs even when config files are missing.

**Proposed fix:**
1. `aba delete` should check for VMs on the hypervisor FIRST (using `govc find` / `virsh list`)
   before requiring cluster config files. If VMs exist matching the cluster name pattern,
   destroy them regardless of local config state.
2. Alternatively, `aba clean` should NOT remove files that `aba delete` needs (e.g., keep
   `vmware.conf`, `cluster.conf`, or a minimal state file with VM names/paths).
3. At minimum, `aba delete` should warn loudly if it can't find VM info instead of silently
   re-initializing the directory.

**Additional variant -- `aba delete` on platform=bm requires vmware.conf (2026-03-23):**
The E2E `create-bundle-to-disk` suite creates a standard cluster with `platform=bm`
(bare-metal simulation). When the cleanup test runs `aba --dir e2e-standard2 delete`, it
fails with `vmware.conf not found. Run 'aba vmw' first.` A bare-metal cluster has no
hypervisor VMs to delete, so `aba delete` should not require `vmware.conf` for platform=bm.
This also caused the test to exhaust 5 retries and PAUSE.

**Where:** `templates/Makefile.cluster` (the `delete` / `clean` targets and their dependencies),
`scripts/vmw-delete.sh`, `scripts/kvm-delete.sh`

**Full fix plan:** See saved plan `aba_delete_and_cluster_state_f6e8ad9a.plan.md`:
- Part 1: `aba.sh` delete case — handle platform=bm as no-op (clean stamp+bm gate files)
- Part 2: Externalize minimal cluster state to `~/.aba/cluster/<name>/state` AFTER successful
  install (in `monitor-install.sh`). Read as fallback in `aba delete` to survive aba.conf changes
  and `aba clean`. Remove on successful delete.
- Part 3: E2E suites — reorder cleanup to delete bm clusters before restoring platform=vmw
Deferred to post-release — test-side workaround applied for now.

**Related: E2E orphan VM cleanup should use `aba delete`, not sweeping govc destroy (2026-03-23):**
The E2E framework's `run.sh` has a "sweeping pass" that finds orphaned VMs in pool folders
and destroys them directly via `govc vm.destroy`. This bypasses ABA's own `aba delete` command.
The proper approach is to use `aba delete` (or the suite's registered cleanup functions) to
remove cluster VMs, so the same code path used by users is tested.

Example of the sweeping pass (should be replaced):
```
=== Sweeping pool folders for orphaned cluster VMs ===
  The following VMs will be DESTROYED:
    /Datacenter/vm/aba-e2e/pool1/e2e-sno1/e2e-sno1-e2e-sno1
  Destroy these VMs? (Y/n):
  Destroying /Datacenter/vm/aba-e2e/pool1/e2e-sno1/e2e-sno1-e2e-sno1 ...
```

Once `aba delete` is fixed (handles platform=bm, survives aba.conf changes via externalized
state), the sweeping pass should be replaced with proper `aba delete` calls. This also
means the E2E cleanup/crash-recovery code (`_pre_suite_cleanup`, `run.sh destroy --clean`)
should iterate registered cluster dirs and run `aba delete` on each, rather than raw govc.

---

### Old E2E test5: SNO VM Still Running at ISO Upload, Causing Install Failure

**Status:** Backlog (investigation needed)
**Priority:** Critical
**Estimated Effort:** Small
**Created:** 2026-03-23

**Problem:**
In `test/test5-airgapped-install-local-reg.sh`, the SNO install fails quickly (exit=2 after
only ~4 minutes, retries also fail instantly) because the previous SNO VM (10.0.1.203) is
still powered on. The test flow is:

1. Earlier in test5, a SNO cluster is installed and tested (with Docker registry)
2. `rm -rf subdir/aba/sno` cleans the local directory on the internal bastion
3. A new `aba cluster ... --step cluster.conf` creates a fresh SNO config
4. `aba cluster ... -s install` fails because the old VM is still running at the same IP

The `rm -rf sno` at line "Tidying up internal bastion" only removes local files -- it does
NOT destroy the VM on the hypervisor. This is the same root cause as the `aba delete` bug
(see "aba delete After aba clean Fails to Destroy VMs" above).

**Observed in test.log on registry2:**
```
Mar 23 07:37:57 R Tidying up internal bastion (rm -rf subdir/aba/sno)
Mar 23 07:38:11 R Installing sno (aba --dir subdir/aba cluster -n sno ... -s install)
Mar 23 07:42:11 Non-zero return value: 2    <-- fails after ~4 min (preflight IP conflict)
Mar 23 07:42:17 Attempting command again (2/5)
Mar 23 07:42:22 Non-zero return value: 2    <-- fails in 5 seconds (same conflict)
```

**Root cause:**
The test should run `aba --dir subdir/aba/sno delete` BEFORE `rm -rf subdir/aba/sno` to
destroy the VM on the hypervisor first. Without this, the VM remains powered on and its
IP (10.0.1.201/203) causes an IP conflict in the preflight check.

**Proposed fix:**
In `test/test5-airgapped-install-local-reg.sh`, before the `rm -rf subdir/aba/sno` line,
add an explicit VM deletion:
```bash
test-cmd -h $DIS_SSH_USER@$int_bastion_hostname -m "Delete sno cluster VMs" \
    "aba --dir subdir/aba/sno delete || true"
```

Also audit all other `rm -rf` of cluster directories in `test/test*.sh` to ensure they
are preceded by `aba delete`. See also the related E2E backlog item "Delete VMs Before
`rm -rf` Cluster Directory".

**Where:** `test/test5-airgapped-install-local-reg.sh` (search for `rm -rf.*sno`),
also audit `test/test2-airgapped-existing-reg.sh` and other test scripts.

---

### Bundle Makefile: `make NAME=opp` Without `OP_SETS` Silently Builds Empty-Operator Bundle

**Status:** Resolved
**Priority:** Critical
**Estimated Effort:** Small
**Created:** 2026-03-23
**Resolved:** 2026-02-26

**Fix applied:** Added a safety check in `bundles/v2/Makefile` that errors out when
`NAME != release` and `OP_SETS` is empty (using `$(strip ...)` to handle whitespace).
This prevents silently building empty-operator bundles when invoking `make` directly
without passing `OP_SETS`.

---

## High Priority

### Replace `oc-mirror list operators` With Podman-Based Catalog Extraction

**Status:** Done (2026-03-18)
**Priority:** High
**Created:** 2026-03-15

Replaced `oc-mirror list operators` with direct podman-based extraction from catalog
container images. Eliminates oc-mirror dependency for operator listing, improves accuracy,
and enables display name extraction. Tested across OCP 4.16-4.22 and all 3 catalogs.

**See:** `ai/PODMAN_CATALOG_EXTRACTION.md` for full details.

---

### Use Display Names in TUI Operator Search and Basket

**Status:** Done (2026-03-18)
**Priority:** High
**Created:** 2026-03-15

TUI operator list and basket now show display names from the catalog index. Search
matches against both package name and display name (case-insensitive), excluding
default channel. Search optimised from awk forks to pure bash parameter expansion.

**See:** `ai/TUI_OPERATOR_DISPLAY_ENHANCEMENT.md` for full details.

---

### Catalog Download Dialog Should Show the OCP Version

**Status:** Done (2026-03-18)
**Priority:** High
**Created:** 2026-02-26

TUI catalog download dialog now shows OCP version:
`"Downloading operator catalogs for OCP 4.21..."`

---

### `aba reset` Should Delete Root `.index/` Directory

**Status:** Done (2026-03-18)
**Priority:** High
**Created:** 2026-02-26

Added `rm -rf .index` to the root Makefile `reset` target.

---

### Investigate and Reduce Pool Registry Disk Usage in E2E Tests

**Status:** Backlog
**Priority:** High
**Estimated Effort:** Medium
**Created:** 2026-03-16

**Problem:**
The pool-registry on conN hosts (`/opt/pool-reg/`) consumes 27–57GB per host. Combined
with the oc-mirror workspace (~9.4GB), each pool devotes ~36–66GB just to the pre-populated
registry. The conN/disN VMs are thin-provisioned and already large (con1: 367GB used,
dis1: 304GB used on Datastore4-1). As tests run, accumulated registry data risks
out-of-disk errors.

**Findings (2026-03-16):**
- `setup-pool-registry.sh` correctly pins oc-mirror to exactly ONE OCP version
  (`minVersion` = `maxVersion`), but:
  - Each single-version sync costs ~27GB in registry blob storage (1309 blobs for OCP
    4.20.15 + 3 operators + graph data).
  - The oc-mirror workspace (`/opt/pool-reg/sync/`) adds ~9.4GB on top.
  - Data accumulates across suite runs: con2 had 57GB / 2883 blobs vs con1's 27GB / 1309
    blobs, despite both having only `.synced-4.20.15`. Prior runs left behind orphan blobs.
- The Docker distribution registry has no built-in garbage collection that runs automatically.
  Stale blobs from previous versions persist indefinitely.
- Four suites use the pool-registry: `network-advanced`, `connected-public`, `cluster-ops`,
  `airgapped-existing-reg`. All read the version from `aba.conf` at runtime — if a pool
  previously ran with version X and now runs with version Y, both versions' blobs accumulate.

**Questions to investigate:**
1. Do we really need the full OCP release payload in the pool-registry for all suites?
   Some suites (e.g. `cluster-ops`) need release images to install a cluster, but others
   (e.g. `connected-public` in public mode) may only need operator catalogs.
2. Can we use `oc-mirror --dry-run` or a more selective imageset config to reduce what
   gets synced? E.g. skip graph data (`graph: false`), skip unused architectures.
3. Should `setup-pool-registry.sh` run Docker registry GC (`registry garbage-collect`)
   before or after each sync to reclaim stale blobs?
4. Should the pool-registry data be wiped when the pool gets a new suite with a different
   OCP version, instead of accumulating?
5. Can we reduce the 3 test operators to 1 small one (e.g. `flux` community operator only)?

**Proposed improvements (pick and test):**
- Add `registry garbage-collect /etc/docker/registry/config.yml` step to
  `setup-pool-registry.sh` after each sync.
- Wipe `/opt/pool-reg/data` when the requested version differs from the last-synced version
  (delete old `.synced-*` markers + data, fresh start).
- Set `graph: false` in the imageset config if graph data isn't needed for pool tests.
- Reduce operator set to a single small operator.
- Consider pre-baking the pool-registry data into the VM snapshot so each revert starts clean.

**Where:** `test/e2e/scripts/setup-pool-registry.sh`, `test/e2e/lib/vm-helpers.sh`,
`test/e2e/lib/pool-lifecycle.sh`

---

### oc-mirror Fails With v1/v2 Error on OCP 4.19 Catalog Image

**Status:** Resolved (2026-03-18) -- eliminated by podman catalog extraction
**Priority:** High
**Created:** 2026-03-16

No longer relevant. Podman-based extraction bypasses oc-mirror entirely for catalog
listing. Tested and working for OCP 4.16-4.22 across all catalogs.

---

### Fix `oc debug node/` Failure in Mirror-Based Disconnected Clusters

**Status:** Backlog (investigation needed)
**Priority:** High
**Estimated Effort:** Medium
**Created:** 2026-03-20

**Problem:**
`oc debug node/` fails with `ErrImagePull` for `registry.redhat.io/rhel9/support-tools`
on mirror-based disconnected clusters (observed on both KVM and VMware E2E installs).
The command works on connected-install clusters only because the image is cached from
installation time.

**Key findings so far:**
- `oc debug node/` defaults to `registry.redhat.io/rhel9/support-tools:latest`.
- IDMS/ITMS rules generated by `oc-mirror` only cover `quay.io/openshift-release-dev/*`
  -- there is no redirect rule for `registry.redhat.io`.
- The `support-tools` image is NOT in the E2E pool mirror.
- On a connected-install VMware cluster, the image is cached from install time -- that is
  why `oc debug` "always worked" there.
- **Not yet verified on a proper mirror-based disconnected cluster** -- need to install one
  and test `oc debug` to confirm the behavior and determine the correct fix.

**Current band-aid:**
`cluster-graceful-shutdown.sh` resolves the `tools` image from the release payload
(`oc adm release info --image-for=tools`) and passes `--image=<tools>` to all `oc debug`
calls. The `tools` image IS in the mirror (covered by the IDMS rule for
`quay.io/openshift-release-dev/ocp-v4.0-art-dev`). This works but is a workaround.

**Investigation needed (once a mirror-based cluster is available):**
1. Confirm `oc debug node/` fails without the `--image` workaround.
2. Check whether adding `registry.redhat.io/rhel9/support-tools` to the
   `ImageSetConfiguration` (`additionalImages`) causes `oc-mirror` to mirror it and
   generate a matching IDMS/ITMS rule.
3. Decide on the proper fix:
   - **Option A:** Add `support-tools` to the default `ImageSetConfiguration` template so
     it is always mirrored. Pros: fixes all `oc debug` usage cluster-wide. Cons: adds
     ~390 MB to every mirror.
   - **Option B:** Keep the `--image` approach in `cluster-graceful-shutdown.sh` using the
     release payload `tools` image. Pros: zero extra mirror size. Cons: only fixes the
     shutdown script; manual `oc debug` still fails.
   - **Option C:** Hybrid -- keep `--image` in the shutdown script AND document how users
     can add `support-tools` to their `ImageSetConfiguration` if they need manual
     `oc debug`.

**Where:** `scripts/cluster-graceful-shutdown.sh`, `templates/imageset-config*.yaml`,
`ai/BACKLOG.md`

---

## Medium Priority

### Review vmware.conf / kvm.conf Symlink and ~/.vmware.conf Default File Approach

**Status:** Backlog
**Priority:** Medium
**Estimated Effort:** Medium
**Created:** 2026-03-26

**Problem:**
The current approach for hypervisor config files uses a chain of files and symlinks:
1. `templates/vmware.conf` (or `templates/kvm.conf`) — the default template
2. `~/.vmware.conf` (or `~/.kvm.conf`) — user's working config, saved after first `aba vmw`
3. `vmware.conf` in the aba root dir — created by `install-vmware.conf.sh` (copies from
   `~/.vmware.conf` or template, then prompts for editing)
4. `vmware.conf` symlink in cluster subdirectory — points to `../vmware.conf`

This multi-level chain has caused confusion and regressions:
- Commit `77b909a` externalized Makefile targets to `aba.sh`, losing the auto-symlink
  creation that was previously handled by Make dependencies (fixed in `_ensure_hv_ready()`)
- `aba clean` may or may not delete the symlinks depending on branch
- `~/.vmware.conf` silently overrides the template on subsequent installs, which can be
  surprising if the user expected fresh defaults
- The E2E test infrastructure copies `~/.kvm.conf` from bastion to VMs during golden
  template creation, adding another layer to track

**Questions to investigate:**
1. Is the `~/.vmware.conf` / `~/.kvm.conf` home-directory default necessary, or could
   `aba vmw` / `aba kvm` always work from the aba root copy?
2. Should the symlink from cluster subdir to `../vmware.conf` be replaced with a direct
   copy, eliminating symlink fragility?
3. Can the auto-symlink in `_ensure_hv_ready()` be made unnecessary by creating the
   symlink at a more natural point (e.g., during `cluster.conf` generation when platform
   is known)?
4. Same review applies to `kvm.conf` — ensure both VMware and KVM follow the same pattern.

**Where:** `scripts/install-vmware.conf.sh`, `scripts/install-kvm.conf.sh`,
`scripts/aba.sh` (`_ensure_hv_ready`), `templates/Makefile.cluster` (`.init`, `clean`,
`vmware.conf`, `kvm.conf` targets)

---

### `kvm.conf` Template Should Not Hardcode a Username

**Status:** Backlog
**Priority:** Medium
**Created:** 2026-03-20

The `templates/kvm.conf` template currently uses `root@kvmhost.lan` as the example `LIBVIRT_URI`.
This is misleading for environments where root SSH is disabled and a non-root user with sudo is
required (which is the common setup). The template should either:

- Auto-detect the current user (e.g. `$(whoami)`) during `aba kvm` configuration, or
- Use a clear placeholder like `<user>@kvmhost.lan` that forces the user to fill in their own name

The `install-kvm.conf.sh` script (which generates `kvm.conf` from the template) is the right place
to inject the current username automatically.

**Where:** `templates/kvm.conf`, `scripts/install-kvm.conf.sh`

---

### Eject/Clean CDROM ISO From All Nodes After Install Completes

**Status:** Backlog
**Priority:** Medium
**Estimated Effort:** Small
**Created:** 2026-03-20

**Problem:**
After a successful cluster installation, the boot ISO remains attached to VMs:
- **VMware:** The ISO stays mounted in the CDROM device permanently. While harmless
  (UEFI boot order prefers disk), it's untidy and keeps a reference to the datastore
  ISO file, preventing cleanup.
- **KVM:** `virt-install --cdrom` auto-ejects after first boot, so the CDROM source
  is already empty. However, the ISO file itself remains on the KVM host storage pool.

**Proposed fix:**
After `.install-complete` is set, eject/clean the CDROM from all cluster VMs:
- **VMware:** `govc device.cdrom.eject -vm <vm-name>` for each node.
- **KVM:** No CDROM action needed (already ejected). Optionally remove the ISO file
  from `$KVM_STORAGE_POOL/agent-<cluster>.iso` to reclaim disk space.

This could be a post-install step in `monitor-install.sh` or a new cleanup target
that runs after `install-complete`.

**Where:** `scripts/monitor-install.sh` or new `scripts/vmw-eject-iso.sh` /
`scripts/kvm-cleanup-iso.sh`, `templates/Makefile.cluster`

---

### Audit: Is the `regcreds` Symlink in Cluster Directories Still Needed?

**Status:** Backlog
**Priority:** Medium
**Estimated Effort:** Medium
**Created:** 2026-03-20

**Problem:**
Each cluster directory contains a `regcreds` symlink pointing to
`~/.aba/mirror/<mirror_name>` (e.g. `regcreds -> /home/steve/.aba/mirror/mirror`).
This symlink is created by `Makefile.cluster` (lines 72, 96) and `Makefile.mirror`
(line 71).

Meanwhile, many scripts already compute `regcreds_dir` dynamically via
`reg_load_config()` in `reg-common.sh`, which derives it as
`$HOME/.aba/mirror/$(basename "$PWD")` or reads it from `mirror.conf`. This means
there are two parallel mechanisms for locating mirror credentials:
1. The `regcreds` symlink in the cluster directory (filesystem-level).
2. The `regcreds_dir` variable computed at runtime (script-level).

**Questions to answer:**
1. Which scripts actually use the `regcreds` symlink directly (e.g. `$PWD/regcreds/`)
   vs the `regcreds_dir` variable? Audit all ~25 scripts that reference `regcreds`.
2. Can all symlink users be migrated to use `regcreds_dir` instead?
3. If the symlink is eliminated, does anything break for users who `ls` or manually
   inspect the cluster directory?
4. Does the `mirror` symlink (also in the cluster dir) overlap with `regcreds`?

**If redundant:** Remove the symlink creation from `Makefile.cluster` and
`Makefile.mirror`, update any scripts that rely on it, and clean it up in `make clean`.

**If still needed:** Document why and ensure both mechanisms stay in sync.

**Where:** `templates/Makefile.cluster` (lines 72, 96), `templates/Makefile.mirror`
(line 71), `scripts/reg-common.sh`, and all ~25 scripts in `scripts/` that reference
`regcreds`.

---

### Reconsider `shutdown -h now` vs `shutdown -h 1` in Graceful Shutdown

**Status:** Backlog
**Priority:** Medium
**Estimated Effort:** Small
**Created:** 2026-03-20

**Problem:**
`cluster-graceful-shutdown.sh` was changed from `shutdown -h 1` (halt in 1 minute)
to `shutdown -h now` (halt immediately) to speed up E2E test runs. The 1-minute
grace period existed to give the OS time to cleanly terminate remaining processes
(journald, kubelet, etcd, etc.) before halting.

For SNO this is likely fine (no etcd quorum concerns). For multi-node clusters,
an immediate halt could risk etcd data corruption if a member is mid-write when
the OS yanks the disk. The cordon+drain step runs beforehand, but etcd itself is
not drained -- it relies on the OS shutdown sequence to flush and close cleanly.

**Action needed:**
- Test `shutdown -h now` on a multi-node cluster (compact/standard) with a
  shutdown+startup cycle and verify etcd health afterwards.
- If etcd issues appear, revert to `shutdown -h 1` (or a shorter grace like
  `shutdown -h +0` which is equivalent to `now`, or use `systemctl poweroff`
  which lets systemd orchestrate a clean unit shutdown).
- Consider whether the grace period should differ by cluster type (SNO vs multi-node).

**Where:** `scripts/cluster-graceful-shutdown.sh` lines 135, 144

---

### Fix KVM VM Reboot Behavior (VMs shut off instead of rebooting)

**Status:** Fix applied -- needs validation
**Priority:** High
**Estimated Effort:** Medium
**Created:** 2026-03-20
**Updated:** 2026-03-21

**Root cause:**
`virt-install --cdrom` silently forces `on_reboot=destroy` on QEMU 9.1+ /
libvirt 10.10+ (RHEL 9.7). The `--events on_reboot=restart` flag is ignored
when `--cdrom` is used. This causes VMs to shut off instead of rebooting after
the RHCOS agent writes the image to disk.

**Fix applied in `scripts/kvm-create.sh`:**
- Replaced `--cdrom "$iso_path"` with `--disk "$iso_path",device=cdrom`
- Added `--events on_reboot=restart`
- Changed `--boot uefi` to `--boot uefi,hd,cdrom`

Verified on kvm1: VM stays `running` through `virsh reboot` with this config.

**Remaining work:**
- Validate with a full cluster install (SNO + compact + standard via E2E suite)
- Once validated, remove the band-aid workaround from `suite-kvm-lifecycle.sh`
  (search for `TODO: remove once root cause in kvm-create.sh / virt-install is fixed`)

**Current workaround (in `suite-kvm-lifecycle.sh`):**
Applied to all three cluster types (SNO, compact, standard) as a safety net:
```
# Poll until all VMs shut off after image write
e2e_poll 1200 30 "Wait for VMs to shut off" "... | grep -ci 'shut.off' ..."
aba --dir $CLUSTER start
# Continue with bootstrap / install
```

**Where:** `scripts/kvm-create.sh`, `test/e2e/suites/suite-kvm-lifecycle.sh`

---

### Rename E2E Cluster Hostnames: Move `e2e` Suffix After Cluster Type

**Status:** Backlog
**Priority:** Medium
**Estimated Effort:** Medium
**Created:** 2026-03-20

**Problem:**
Current E2E cluster names use the pattern `e2e-<type><pool>` (e.g. `e2e-sno1`, `e2e-compact1`,
`e2e-standard-vlan1`). This front-loads the `e2e` prefix, making it harder to visually scan
cluster types. The naming should follow `<type>-e2e<pool>` instead.

**Proposed renaming:**

| Current | New |
|---|---|
| `e2e-sno1` | `sno-e2e1` |
| `e2e-sno-mirror1` | `sno-mirror-e2e1` |
| `e2e-sno-proxyonly1` | `sno-proxyonly-e2e1` |
| `e2e-sno-noproxy1` | `sno-noproxy-e2e1` |
| `e2e-compact1` | `compact-e2e1` |
| `e2e-standard1` | `standard-e2e1` |
| `e2e-sno-vlan1` | `sno-vlan-e2e1` |
| `e2e-compact-vlan1` | `compact-vlan-e2e1` |
| `e2e-standard-vlan1` | `standard-vlan-e2e1` |

**Files to update:** `test/e2e/lib/config-helpers.sh` (`pool_cluster_name` and related functions),
all suite scripts under `test/e2e/suites/`, dnsmasq DNS records on pool hosts, `test/e2e/config.env`.

---

### Bundle Script: Smart Cluster Reuse Instead of Automatic Delete

**Status:** Backlog
**Priority:** Medium
**Estimated Effort:** Small-Medium
**Created:** 2026-03-22

**Problem:**
The bundle pipeline's cluster install step currently checks if a cluster already exists and
deletes it unconditionally before re-installing. This wastes 30-60 minutes rebuilding a
cluster that may already be perfectly healthy.

**Proposed behavior:**
When an existing cluster is detected, check its health before deciding to delete:
1. Is the API endpoint reachable?
2. Are all ClusterOperators available (`True False False`)?
3. (Optional) Does the cluster version match the expected OCP version?
4. (Optional) Are all nodes Ready?

If the cluster is healthy (all COs available), skip deletion and reuse it.
If the cluster is unhealthy (some COs degraded/unavailable), delete and reinstall.

**Example logic:**
```bash
if cluster_exists "$cluster_dir"; then
    if all_cos_available "$cluster_dir"; then
        echo "Existing cluster is healthy -- reusing"
    else
        echo "Existing cluster is unhealthy -- deleting and reinstalling"
        aba --dir "$cluster_dir" delete
        aba --dir "$cluster_dir" install
    fi
else
    aba --dir "$cluster_dir" install
fi
```

**Where:** `bundles/v2/scripts/` (cluster install phase), potentially also useful
in E2E suites that pre-check cluster state.

---

### E2E Suite: Delete VMs Before `rm -rf` Cluster Directory

**Status:** Backlog
**Priority:** Medium
**Estimated Effort:** Small
**Created:** 2026-03-20

**Problem:**
E2E test suites (e.g. `suite-kvm-lifecycle.sh`) do `rm -rf e2e-sno1` to clean up a previous
cluster directory without first deleting the VMs on the hypervisor. This leaves orphan VMs on
the KVM/VMware host. If someone has a shell `cd`'d into the directory, they also get an ugly
error cascade (see separate backlog item).

**Proposed fix:**
Before `rm -rf <cluster>`, run `aba --dir <cluster> delete || true` to clean up VMs on the
hypervisor. The `|| true` handles the case where VMs don't exist.

**Where:** `test/e2e/suites/suite-kvm-lifecycle.sh` and any other suites that `rm -rf` cluster dirs.

---

### E2E Suite: Consolidate Complex Test Assertions Into Helper Functions

**Status:** Backlog
**Priority:** Medium
**Estimated Effort:** Small-Medium
**Created:** 2026-03-20

**Problem:**
E2E test suites contain long, complex inline shell commands for assertions -- especially the
operator health check pattern:
```bash
e2e_poll 600 30 "Wait for all operators fully available" \
    "lines=\$(aba --dir $SNO run | tail -n +2 | awk 'NR>1{print \$3,\$4,\$5}'); [ -n \"\$lines\" ] && echo \"\$lines\" | grep -v '^True False False$' | wc -l | grep ^0\$"
```
These are hard to read, error-prone to escape correctly, and duplicated across multiple tests
and suites. The complex quoting (nested `\$`, `\"`, single quotes inside double quotes) makes
them fragile to edit.

**Proposed fix:**
Create helper functions in `test/e2e/lib/framework.sh` (or a new `test/e2e/lib/assertions.sh`):
```bash
e2e_wait_operators_healthy() {
    local dir=$1 timeout=${2:-600} interval=${3:-30}
    e2e_poll "$timeout" "$interval" "Wait for all operators fully available" \
        "e2e_assert_operators_healthy $dir"
}

e2e_assert_operators_healthy() {
    local dir=$1
    local lines
    lines=$(aba --dir "$dir" run | tail -n +2 | awk 'NR>1{print $3,$4,$5}')
    [ -n "$lines" ] && echo "$lines" | grep -v '^True False False$' | wc -l | grep -q ^0$
}

e2e_wait_api_ready() {
    local dir=$1 timeout=${2:-300} interval=${3:-15}
    e2e_poll "$timeout" "$interval" "Wait for cluster API to become reachable" \
        "aba --dir $dir run --cmd 'oc get nodes' 2>&1 | grep -q Ready"
}
```
Then suite tests become one-liners: `e2e_wait_operators_healthy "$SNO"`.

**Where:** `test/e2e/lib/framework.sh` or new `test/e2e/lib/assertions.sh`,
then refactor all suites that use operator health checks.

---

### E2E Suite: Extract Long Inline Commands Into Helper Functions

**Status:** Backlog
**Priority:** Medium
**Estimated Effort:** Medium
**Created:** 2026-03-20

**Problem:**
E2E test suites contain very long inline shell commands that are hard to read,
maintain, and debug. The complex quoting and escaping makes them fragile.

Example (SSH into a node to verify network):
```bash
e2e_poll 300 15 "SSH into compact master 0 (verify network)" \
    "cd $COMPACT && source cluster.conf && eval \$(scripts/cluster-config.sh) && _ips=(\$CP_IP_ADDRESSES) && ssh -F ~/.aba/ssh.conf -i \$ssh_key_file -o ConnectTimeout=10 core@\${_ips[0]} 'hostname && ip -4 addr show | grep inet'"
```

**Action needed:**
1. Audit both lifecycle suites for long inline commands (especially the `e2e_poll`
   and `e2e_run` one-liners that span multiple concepts).
2. Extract common patterns into helper functions in `test/e2e/lib/` (e.g. a new
   `assertions.sh` or extend `config-helpers.sh`). Candidates:
   - `e2e_ssh_node <cluster_dir> <node_index> <command>` -- loads cluster.conf +
     cluster-config.sh, SSHes into node by index, runs command.
   - `e2e_wait_agent_api <cluster_dir> [timeout] [interval]` -- polls agent port 8090.
   - `e2e_wait_bootstrap <cluster_dir> [timeout]` -- wraps `openshift-install agent
     wait-for bootstrap-complete`.
   - `e2e_verify_vm_count <cluster_dir> <count> <state>` -- checks `aba ls` output.
3. Keep the helpers parameterized so they work across KVM and VMware suites.

**Related:** See also "Consolidate Complex Test Assertions Into Helper Functions"
backlog item, which covers the operator health check pattern specifically.

**Where:** `test/e2e/suites/suite-kvm-lifecycle.sh`, `test/e2e/suites/suite-vmw-lifecycle.sh`,
new `test/e2e/lib/assertions.sh` or extend existing helpers.

---

### E2E Runner: Audit and Fix Pre-Suite Cleanup Scope

**Status:** Backlog
**Priority:** Medium
**Estimated Effort:** Medium
**Created:** 2026-03-20

**Problem (two sides):**

**1. Fresh runs delete too much:**
`_cleanup_wasteful_dirs_local()` in `runner.sh` does `rm -rf ~/bin`, which
nukes every CLI binary (`aba`, `oc`, `kubectl`, `openshift-install`, `oc-mirror`,
`govc`). It also deletes `~/.oc-mirror`, `~/.cache/agent`, and `~/tmp/*`. The
comment says "suite reinstalls via setup_aba_from_scratch → make install", but
this is fragile: if any path changes, CLI tools vanish silently. Consider a
more targeted cleanup (e.g. only remove known test artifacts, not the entire
`~/bin` directory).

**2. `--resume` had no cleanup skip (now fixed, but needs review):**
A quick fix was applied: `--resume` now skips ALL pre-suite cleanup (disN revert,
conN quay cleanup, wasteful dirs, firewall reset, pool registry ensure). This
is correct for the common case but may be too broad -- e.g. if a previous run
left stale firewall ports or oc-mirror caches, `--resume` won't clean them.
The right approach is probably to skip only the destructive steps (`rm -rf ~/bin`,
disN revert, cluster deletion from `.cleanup` files) while keeping lightweight
hygiene steps (firewall reset, oc-mirror cache purge).

**3. Dispatcher retry dispatches to occupied pools:**
The `run.sh` dispatcher auto-started a `vmw-lifecycle retry` on pool 1 while
a KVM suite was already running there (started manually). The dispatcher should
check for ANY running suite (including manual tmux sessions) before dispatching.

**4. `.cleanup` file scope:**
`_pre_suite_cleanup()` iterates ALL `.cleanup` files, not just the current
suite's. This means clusters from a still-running resumed suite can be deleted
by a concurrent cleanup. `.cleanup` files should be namespaced per-suite and
only processed for the current suite.

**Where:** `test/e2e/runner.sh` (`_cleanup_wasteful_dirs_local`,
`_pre_suite_cleanup`, the `--resume` skip block), `test/e2e/run.sh`
(retry dispatch logic)

---

### `aba startup` Fails When `.install-complete` Exists

**Status:** Backlog
**Priority:** Medium
**Estimated Effort:** Small
**Created:** 2026-03-20

**Problem:**
Running `aba startup` on an already-installed cluster fails because the `start`
target internally hits the `check` target, which sees `.install-complete` and
aborts with:
```
This cluster has already been deployed successfully!
Run 'aba clean; aba install' to re-install the cluster or remove the
'.install-complete' flag file and try again.
```
This guard is meant to prevent accidentally re-running `install` on a completed
cluster, but `aba startup` is a post-install operation -- it should not trigger
the install-complete guard at all.

**Workaround:** `rm .install-complete` before running `aba startup`, but then
`aba startup` re-runs `openshift-install agent wait-for install-complete` which
is wrong -- it should just start VMs and wait for the API, not re-run the
installer.

**Root cause:**
`aba startup` calls `aba -s start`, which maps to a Makefile target that
depends on `check`. The `check` target guards against re-installation but
doesn't distinguish between "install" and "start/startup" operations.

**Proposed fix:**
- The `startup` / `start` code path should NOT depend on the `check` target.
  These are VM lifecycle operations, not install operations.
- Alternatively, the `check` target should only fire for install-related
  targets (`install`, `mon`, `wait-for-install`), not for lifecycle targets
  (`start`, `stop`, `kill`, `ls`, `startup`, `shutdown`).

**Where:** `templates/Makefile.cluster` (the `check` target and its
dependents), `scripts/cluster-startup.sh`

---

### Graceful Error When CWD Is Deleted

**Status:** Backlog
**Priority:** Medium
**Estimated Effort:** Small
**Created:** 2026-03-20

**Problem:**
Running any `aba` command from a directory that has been deleted (e.g. by another process doing
`rm -rf`) produces a long cascade of errors:
```
shell-init: error retrieving current directory: getcwd: cannot access parent directories
/home/steve/bin/aba: line 160: /install: No such file or directory
/home/steve/bin/aba: line 168: /scripts/include_all.sh: No such file or directory
/home/steve/bin/aba: line 169: aba_debug: command not found
... (30+ lines of noise)
```

**Proposed fix:**
Add an early guard at the top of `aba.sh` (before sourcing any scripts):
```bash
if ! pwd >/dev/null 2>&1; then
    echo "[ABA] Error: current directory no longer exists. Please cd to a valid directory." >&2
    exit 1
fi
```

**Where:** `scripts/aba.sh` (near the top, before `source scripts/include_all.sh`)

---

### SNO VM Name Duplication: `clustername-clustername`

**Status:** Done (2026-03-19)
**Priority:** Medium
**Created:** 2026-03-19

For SNO clusters, the agent-config template (`templates/agent-config.yaml.j2` line 25) sets the hostname to `{{ cluster_name }}`. The VM creation scripts (`kvm-create.sh`, `vmw-create.sh`) then construct the VM name as `${CLUSTER_NAME}-${hostname}`, producing `e2e-sno1-e2e-sno1`.

For multi-node clusters this works fine (`mycluster-master1`), but for SNO the name is redundantly doubled. The VM name should just be `e2e-sno1`.

**Fix:** Add a `vm_name()` helper function to `include_all.sh` that encapsulates the naming convention. When hostname equals cluster name (SNO), return just the hostname; otherwise return `${cluster}-${host}`. Replace all hardcoded `"${CLUSTER_NAME}-${name}"` occurrences in `kvm-*.sh` and `vmw-*.sh` scripts with `$(vm_name "$CLUSTER_NAME" "$name")`.

**Files to update:** `scripts/include_all.sh` (add helper), then all lifecycle scripts: `kvm-create.sh`, `kvm-ls.sh`, `kvm-start.sh`, `kvm-stop.sh`, `kvm-kill.sh`, `kvm-delete.sh`, `kvm-exists.sh`, `kvm-on.sh`, and their `vmw-` counterparts.

---

### Validate `mirror_name` Points to a Valid Mirror With Credentials

**Status:** Open
**Priority:** Medium
**Created:** 2026-03-19

When `cluster.conf` sets `mirror_name=xxx`, ABA should verify early (during `verify-cluster-conf()` or at the start of `create-install-config.sh`) that `~/.aba/mirror/<mirror_name>/` exists and contains the expected credential files (`rootCA.pem`, `pull-secret-mirror.json` or `pull-secret-full.json`). Currently a wrong `mirror_name` silently generates an ISO without the correct root CA, causing `x509: certificate signed by unknown authority` errors at install time -- which is hard to diagnose.

---

### oc-mirror v2 Load Failure: Replace `rm -rf mirror/data` With `aba clean` and Add FAQ

**Status:** Done (2026-03-18)
**Priority:** Medium
**Estimated Effort:** Small
**Created:** 2026-03-18
**Plan:** `.cursor/plans/oc-mirror_working-dir_fix_1b917b02.plan.md`

**Problem:**
After consolidating `mirror/save/` and `mirror/sync/` into `mirror/data/`, all oc-mirror workflows share `data/working-dir/`. The `oc-mirror v2` `diskToMirror` (load) has a known bug where it tries to ping the source registry even in air-gapped mode. Clearing working-dir before load helps. Two test files use raw `rm -rf mirror/data` which is unrealistic user behavior and destroys saved tar archives.

**Proposed fix:**
1. Replace `rm -rf mirror/data` in `suite-mirror-sync.sh` (line 259) and `test1-basic-sync-test-and-save-load-test.sh` (line 332) with `aba -d mirror clean` (which only removes `data/working-dir`).
2. Add README FAQ entry explaining the "collect catalog ... network is unreachable" error during load and the `aba -d mirror clean` workaround.
3. Advise users to run `clean` before switching between `sync` and `save/load` workflows.

**Where:** `test/e2e/suites/suite-mirror-sync.sh`, `test/test1-basic-sync-test-and-save-load-test.sh`, `README.md`

---

### Rename E2E SNO Cluster Names to Avoid Clashes

**Status:** Done (2026-03-18)
**Priority:** Medium
**Estimated Effort:** Small-Medium
**Created:** 2026-02-26

**Problem:**
The new E2E test suites use SNO cluster names `sno1`, `sno2`, `sno3`, `sno4` which clash with other tests that also use the same names. This can cause cross-test interference when multiple suites run concurrently on different pools.

**Proposed fix:**
Rename the E2E SNO clusters to `e2e-sno1`, `e2e-sno2`, `e2e-sno3`, `e2e-sno4` (or similar unique prefix). Update all E2E suite scripts, cluster config templates, and dnsmasq DNS records accordingly.

**Where:** `test/e2e/suites/`, dnsmasq config on pool hosts, any cluster config templates used by E2E tests.

---

### Check VM Existence Before Prompting to Power Down

**Status:** Backlog
**Priority:** Medium
**Estimated Effort:** Small
**Created:** 2026-03-17

**Problem:**
After generating the agent ISO, ABA lists the VM paths and asks "Immediately power down the above virtual machine(s)? (Y/n):" — even when the VMs do not exist yet. If the user answers Yes, `govc` fails with `vm 'sno4-sno4' not found`.

**Observed output:**
```
[ABA] The agent based ISO has been created in the /home/steve/aba/sno4/iso-agent-based directory

/Datacenter/vm/abatesting/sno4/sno4-sno4
[ABA] Immediately power down the above virtual machine(s)? (Y/n):
govc: vm 'sno4-sno4' not found
```

**Expected behavior:**
ABA should check (`govc vm.info` or similar) whether each VM exists before prompting. If no VMs exist yet, skip the prompt entirely. If some exist and some don't, only list and act on the ones that exist.

**Where:** `scripts/vmw-create.sh` or wherever the power-down prompt is issued after ISO generation.

---

### Empty Values in aba.conf Propagate Into cluster.conf via Template Generation

**Status:** Backlog
**Priority:** Medium
**Estimated Effort:** Medium
**Created:** 2026-03-12

**Problem:**
When `cluster.conf` is generated from `templates/cluster.conf.j2`, it uses Jinja2 variables
like `{{ machine_network }}/{{ prefix_length }}`. If aba.conf does not yet have these values
set (e.g., the user hasn't finished the TUI wizard, or aba.conf was just created from the
template with defaults), the rendered cluster.conf ends up with malformed entries such as:

```
machine_network=/               # CIDR for all cluster nodes
```

This causes `aba agentconf` to fail later with a confusing error like:
```
Error: machine_network is invalid (//24) in aba.conf
```

The error is misleading because aba.conf is actually correct — it's the stale cluster.conf
that has the bad value. The flow is:
1. `verify-config.sh` sources `normalize-aba-conf` (correct: `machine_network=148.100.112.0`)
2. Then sources `normalize-cluster-conf`, which reads cluster.conf's `machine_network=/`
3. This **overwrites** the good aba.conf value with `/`
4. `verify-aba-conf` then validates the now-corrupted `machine_network` variable

**Root Cause:**
There is no guard preventing cluster.conf generation when required aba.conf fields are empty.
The Jinja2 template blindly substitutes whatever values are available, including empty strings.

**Potential Fixes (investigate):**
- **Guard in create-cluster-conf.sh:** Refuse to generate cluster.conf if critical aba.conf
  values (`machine_network`, `domain`, `ocp_version`) are empty. Abort with a clear message.
- **Guard in the Jinja2 template:** Add a check at the top of `cluster.conf.j2` that fails
  if required variables are undefined or empty.
- **Guard in normalize-cluster-conf:** If cluster.conf has `machine_network=/` (no IP),
  skip exporting it so the aba.conf value is preserved.
- **Guard in verify-config.sh:** Source normalize-cluster-conf selectively — don't let it
  overwrite aba.conf values for fields that are shared (machine_network, prefix_length).
- **TUI ordering:** Verify the TUI wizard doesn't trigger cluster.conf generation before
  aba.conf is fully populated. Check `summary_apply()` and the background `isconf` task.

**User workaround:** Manually fix `machine_network=148.100.112.0/24` in cluster.conf, or
delete cluster.conf and re-run `aba agentconf`.

**Where:** `templates/cluster.conf.j2`, `scripts/create-cluster-conf.sh`,
`scripts/verify-config.sh`, `scripts/include_all.sh:normalize-cluster-conf()`

### `reg_detect_existing()` Should Probe Before Aborting on Stale `state.sh`

**Status:** Backlog
**Priority:** Medium
**Estimated Effort:** Small
**Created:** 2026-03-12

**Problem:**
`reg_detect_existing()` in `scripts/reg-common.sh` (lines 93-104) aborts if `~/.aba/mirror/<name>/state.sh` contains a `REG_HOST` matching the current `reg_host`. It trusts `state.sh` blindly, but the remote registry may no longer exist (e.g., VM was reverted to a snapshot, or the registry was manually removed). This causes `aba sync -H <host>` to fail with "Mirror registry is already installed" even when it isn't.

**Root cause:**
`state.sh` is designed to survive `aba clean` and `aba reset`. If the registry is removed by external means (VM revert, manual cleanup), `state.sh` becomes stale. The current code has no fallback — it aborts unconditionally.

**Proposed fix:**
Before aborting, probe the registry to verify it's actually running:
```bash
if [ "$_saved_host" = "$reg_host" ]; then
    if probe_host "$reg_url/v2/" "existing registry" 2>/dev/null; then
        aba_abort "Mirror registry is already installed at $reg_host" ...
    else
        aba_warning "Stale registry state: $reg_host is unreachable. Clearing state and proceeding with fresh install."
        rm -f "$regcreds_dir/state.sh"
    fi
fi
```

**Where:** `scripts/reg-common.sh` function `reg_detect_existing()` (line 98)

### Docker Registry v3.0.0 Debug Port Collision

**Status:** Backlog
**Priority:** Medium
**Estimated Effort:** Small
**Created:** 2026-03-12

**Problem:**
Docker registry v3.0.0 (`docker.io/library/registry:latest`) uses port 5001 for its debug/metrics interface by default. If a user sets `reg_port=5001` in `mirror.conf`, the main HTTP server and the debug server both try to bind to port 5001, causing the container to crash-loop with `bind: address already in use`.

**Root cause:**
In `scripts/reg-install-docker.sh`, the `podman run` command sets `REGISTRY_HTTP_ADDR=0.0.0.0:${reg_port}` but does not override the debug server address. The Docker registry v3.0.0 default debug addr is `:5001`.

**Proposed fix:**
Add `-e REGISTRY_HTTP_DEBUG_ADDR=127.0.0.1:0` (or a different port like `127.0.0.1:5002`) to the `podman run` command in `reg-install-docker.sh` to prevent the collision regardless of the user's chosen port.

**Where:** `scripts/reg-install-docker.sh`, the `podman run` block (around line 74-87)

### `aba install` Downloads Quay Binary Even When `reg_vendor=docker`

**Status:** Backlog
**Priority:** Medium
**Estimated Effort:** Small
**Created:** 2026-03-11

**Problem:**
Running `aba install` with `reg_vendor=docker` in `mirror.conf` downloads and extracts `mirror-registry-amd64.tar.gz` (the Quay appliance binary). This is wrong — Docker installs only need the Docker registry image, not the ~1GB Quay tarball. Wastes time and bandwidth.

**Root cause:**
In `templates/Makefile.mirror` line 230, `.available` has `mirror-registry` as an order-only prerequisite:
```makefile
.available: mirror.conf | .init .rpmsext mirror-registry
```
This runs the `mirror-registry` target (line 164, extracts Quay tarball) unconditionally before every install, regardless of `reg_vendor`.

**Proposed fix:**
Make the `mirror-registry` prerequisite conditional on vendor. Options:
- Use a Make conditional: `$(if $(filter quay auto,$(reg_vendor)),mirror-registry)`
- Or move the `ensure_quay_registry` call into `reg-install.sh` / `reg-install-quay.sh` and remove `mirror-registry` from the `.available` prerequisites entirely (let the script handle it)

**Where:** `templates/Makefile.mirror` line 230

### Deduplicate `aba isconf` output

**Status:** Partially done (2026-03-18)
**Priority:** Medium
**Context:** The duplicate operator listing within a single `add-operators-to-imageset.sh` run
has been fixed (removed the redundant summary line). However, `aba isconf` still calls the
script twice (once for save, once for sync), so operators appear in both invocations.
**Remaining:** Suppress output on the second run or consolidate into a single generation.
**Note:** Would be fully resolved by the `mirror/save` + `mirror/sync` consolidation (#35).

### Option to preserve registry data on `aba uninstall`

**Status:** Backlog
**Context:** `aba uninstall` removes the Docker registry container/service AND deletes the data directory (e.g. `/home/steve/docker-reg`). Users may want to uninstall and reinstall without re-syncing/loading gigabytes of images.
**Proposed UX:**
```
[ABA] Uninstall Docker registry on localhost at bastion.example.com:8443? (Y/n): Y
[ABA] Also delete registry data at /home/steve/docker-reg? (y/N):
```
Default "No" for data deletion to be safe. This applies to Docker registries; Quay may have its own handling.

### Wrong path in mirror credential error message

**Status:** Partially done
**Context:** Main credential error message (reg-verify.sh lines 28-33) now uses user-facing commands. However, lines 41-42, 49, and 64 still reference `$regcreds_dir` and expose `~/.aba/mirror/` internal paths.

**Remaining:** Audit ALL `aba_abort` / `aba_warning` messages across `scripts/reg-*.sh` for any references to `$regcreds_dir` or `~/.aba/mirror/`. Replace with user-facing paths and commands.

### 3. Evaluate Selective `set -euo pipefail` Adoption

**Status:** Backlog  
**Priority:** Medium  
**Estimated Effort:** Very Large  
**Created:** 2026-02-18

**Problem:**
ABA core scripts do not use strict bash mode (`set -euo pipefail`). This means unhandled errors, unset variables, and broken pipelines can silently produce wrong results. However, enabling it globally is high-risk for existing code.

**Assessment:**
- `set -e` (errexit): HIGH RISK. Hundreds of patterns would break: `grep -q` returning 1 on no match, `(( counter++ ))` returning 1 when counter is 0, `diff` returning 1 on differences, etc. Many bash experts advise against global `-e`.
- `set -u` (nounset): MODERATE RISK. ABA uses many optional config variables that may be unset. Every `$var` reference would need `${var:-}` or `${var:-default}`.
- `set -o pipefail`: LOW RISK. Safest option, but patterns like `grep | head` would need review.

**Recommendation -- Incremental approach (do NOT enable globally):**
1. Use `set -euo pipefail` in all NEW scripts (already done for `setup-pool-registry.sh`)
2. Add `set -u` to core scripts incrementally, fixing unset variable references
3. Add `set -o pipefail` to core scripts incrementally
4. Add explicit error handling (`|| exit 1`, `|| return 1`) at critical points instead of relying on `-e`
5. Run ShellCheck on all scripts for static analysis (catches real bugs without `-e` foot-guns)

**Do NOT:**
- Enable `set -e` globally in `include_all.sh`
- Bulk-convert existing scripts without individual testing

**References:**
- http://mywiki.wooledge.org/BashFAQ/105 (why `set -e` is unreliable)
- The `(( running++ ))` bug in `download_all_catalogs()` was caused by `set -e` + post-increment returning 0

---

### E2E: `create-bundle-to-disk` Leaves 57GB on conN After Cleanup

**Status:** Backlog (deferred -- re-apply if it recurs)
**Priority:** Medium
**Context:** The `suite-create-bundle-to-disk.sh` creates large bundles (OCP images in `mirror/save/`, oc-mirror caches) on conN, but its end-of-suite cleanup only cleans up on disN (remote). These artifacts remain on conN. Although the next suite's `aba reset -f` would clean it, a disk check at the end of the suite can fail.
**Fix:** Add conN self-cleanup (`aba reset -f` and `sudo find ~/ -type d -name .oc-mirror | xargs sudo rm -rf`) to the end-of-suite cleanup block in `test/e2e/suites/suite-create-bundle-to-disk.sh`.

---

### `aba day2` CatalogSource Errors Go Unnoticed, Causing Downstream Operator Failures

**Status:** Backlog
**Priority:** Medium
**Estimated Effort:** Medium
**Created:** 2026-03-13

**Problem:**
During `aba day2`, after IDMS/ITMS resources are applied, OpenShift may begin MachineConfigPool rollouts that cause temporary API unavailability. CatalogSources that were just applied can disappear (`NotFound`) during the rollout. The background wait sub-processes in `day2.sh` (lines 264-299) print errors to stderr but the overall script may not exit with non-zero, allowing execution to continue.

This means downstream operator installs (e.g., `aba day2-osus`) fail with confusing "package not found" errors because the CatalogSources never became ready.

**Observed output:**
```
[ABA] Waiting for CatalogSource certified-operators to become 'ready' ...
[ABA] Waiting for CatalogSource community-operators to become 'ready' ...
[ABA] Waiting for CatalogSource redhat-operators to become 'ready' ...
####Error from server (NotFound): catalogsources.operators.coreos.com "certified-operators" not found
Error from server (NotFound): catalogsources.operators.coreos.com "community-operators" not found
```

The `####` shows TRANSIENT_FAILURE states, then the CatalogSources vanish entirely. The script should exit non-zero here.

**Investigation pointers:**
- `scripts/day2.sh` lines 264-303: background sub-processes wait for CatalogSources
- Line 268: `until oc get catalogsource "$cs_name" >/dev/null; do sleep 1; done` — stderr not suppressed, but loop keeps retrying. If the CatalogSource was deleted by MCP rollout, this loop spins forever or until the 99-iteration timeout
- Line 303: `[ "$wait_for_cs" ] && wait` — need to verify this propagates non-zero exit from background processes
- The `aba_abort` at line 298 exits the sub-process, but does `wait` in the parent properly capture and fail?
- Consider: should `day2.sh` wait for MCP rollout to stabilize before applying CatalogSources?
- Also check: should the `until` loop at line 268 have a timeout to avoid spinning indefinitely?
- Consider adding retries: if a CatalogSource disappears during MCP rollout, the script could wait for the rollout to settle and then re-apply the CatalogSources rather than just failing

---

### TUI Operator Add Causes `aba sync` to Skip ISC Regeneration

**Status:** Fixed (2026-03-13)
**Priority:** Medium
**Estimated Effort:** Medium
**Created:** 2026-03-13

**Problem:**
After adding an operator via the TUI and running `aba sync`, ABA refuses to regenerate `sync/imageset-config-sync.yaml`, saying the file won't be updated. This means newly added operators never make it into the ImageSet Config (ISC).

**Root cause (two bugs):**

1. **Erroneous `rm -f` of save ISC:** The TUI unconditionally deleted `mirror/save/imageset-config-save.yaml` every time the action menu was shown (`tui/abatui.sh` line 3214). This destroyed user edits silently.

2. **Race condition between background isconf and action handlers:** The TUI launched `aba -d mirror isconf` in the background (non-blocking `run_once` without `-w`) before showing the action menu. Only the "View ISC" handler waited for this task to complete. The other action handlers (local registry, remote registry, bundle, save) ran `aba` commands immediately, creating concurrent `make` processes that raced over `sync/imageset-config-sync.yaml` and `sync/.created` timestamps. When timing was unlucky, the ISC ended up newer than `.created`, tricking the regeneration guard into thinking the user had hand-edited the file.

**Fix:**
- Removed the `rm -f` of save ISC
- Added `run_once -p/-w` wait blocks in all action handlers before they run `aba` commands, matching the pattern already used by `handle_action_view_isconf`

---

### TUI Test Framework: Replace `sleep` With `wait_for` Polling

**Status:** Backlog
**Priority:** Medium
**Estimated Effort:** Medium
**Created:** 2026-02-26

**Problem:**
The TUI test framework (`test/func/tui-test-lib.sh` and test files) uses `sleep 1` between
nearly every tmux `send-keys` call and the next assertion/action. Since tmux interaction is
asynchronous, these sleeps are dead wait time. The framework already has `wait_for()` which
polls the screen every 1s until a target string appears.

Most `sleep 1` calls occur right before a `wait_for` and are therefore redundant — `wait_for`
already handles the timing. Removing them would significantly speed up the test suite.

**Proposed refactor:**
- Remove `sleep` calls that immediately precede a `wait_for` (the polling handles it).
- Keep `sleep 1` only in: (a) `send()` for `--slow` mode visibility, (b) before a raw
  `capture` with no `wait_for`, (c) after the final action before script exit.
- Consider adding a tiny `sleep 0.1` in `send()` (non-slow mode) to let tmux process
  keystrokes, if any races appear after removing the larger sleeps.

**Files:** `test/func/tui-test-lib.sh`, `test/func/test-tui-v2-01-wizard.sh`,
`test/func/test-tui-v2-02-basket.sh`, `test/func/test-tui-v2-03-actions.sh`

---

### E2E Cleanup: `_cleanup_dis_aba()` Does Not Clean Testy User's Quay

**Status:** Backlog
**Priority:** High
**Estimated Effort:** Small
**Created:** 2026-03-22

**Problem:**
`suite-mirror-sync.sh` installs a Quay registry on the dis host as the `testy` user
(`reg_ssh_user=testy`, `data_dir=~/my-quay-mirror-test1`). If the suite fails or is
interrupted before its cleanup block runs, testy's Quay stays running (port 8443 occupied).
The next suite (e.g. `airgapped-local-reg`) fails with "Existing Quay registry found"
because `aba -d mirror install` detects port 8443 is occupied.

**Root cause (three gaps in `_cleanup_dis_aba()` in `runner.sh`):**
1. `rm -rf ~/quay-install $_E2E_WASTEFUL_DIRS` runs as `steve` via SSH, so `~` expands
   to `/home/steve`. Testy's data at `/home/testy/my-quay-mirror-test1/` is untouched.
2. `$_E2E_WASTEFUL_DIRS` contains `$HOME/my-quay-mirror-test1` but `$HOME` is steve's.
3. No container/service cleanup: even if files were removed, the running Quay pod,
   systemd user services (`quay-app`, `quay-redis`, `quay-pod`), and `rootlessport`
   process under testy keep binding port 8443.

**Proposed fix:**
Add testy-specific cleanup to `_cleanup_dis_aba()`:
```bash
# Kill any registry occupying port 8443 (regardless of which user owns it)
_essh "$dis_host" "sudo fuser -k 8443/tcp 2>/dev/null" 2>&1 || true

# Clean testy's Quay: SSH as testy to run aba uninstall (uses testy's systemd context)
_essh "$dis_host" "sudo -u testy bash -c '
    export XDG_RUNTIME_DIR=/run/user/\$(id -u testy)
    systemctl --user stop quay-app quay-redis quay-pod 2>/dev/null
    systemctl --user disable quay-app quay-redis quay-pod 2>/dev/null
    rm -f ~/.config/systemd/user/quay-*.service
    systemctl --user daemon-reload 2>/dev/null
'" 2>&1 || true
_essh "$dis_host" "sudo rm -rf /home/testy/quay-install /home/testy/my-quay-mirror-test1" 2>&1 || true
```

Alternatively: uninstall via `ssh testy@dis aba -d mirror uninstall -y` if aba is
present on testy's side, so testy's own aba handles the full cleanup properly.

**Where:** `test/e2e/runner.sh` `_cleanup_dis_aba()` (around line 351)

---

### Test5: `aba mon` Failure After Reboot Is Silently Ignored

**Status:** Backlog
**Priority:** High
**Estimated Effort:** Small
**Created:** 2026-03-22

**Problem:**
In `test/test5-airgapped-install-local-reg.sh` line 726, after a cluster install fails
(operators not stable within timeout), the script reboots all nodes and runs `aba mon`
directly -- NOT via `test-cmd`. Since the test scripts do not use `set -e`, this `mon`
failure is completely silent. The script continues to subsequent checks ("Waiting forever
for all cluster operators available") which eventually succeed as operators settle, making
the test appear to pass despite a significant install issue.

**Observed behavior:**
```
ERROR Error checking cluster operator Progressing status: "context deadline exceeded"
ERROR These cluster operators were not stable: [authentication, openshift-apiserver]
[ABA] Error: Something went wrong with the installation...
make: *** [Makefile:190: mon] Error 7
Returning failed result [2]    <-- test-cmd -i returns the error
CLUSTER INSTALL FAILED: REBOOTING ALL NODES ...
... (reboot + restart) ...
aba --dir ... mon              <-- bare call, no test-cmd, failure silently ignored
... (test continues as if install succeeded) ...
```

**Root cause:**
Line 713: `test-cmd -i` properly catches the initial failure and enters the recovery path.
Line 726: `aba --dir ... mon` is called directly (no `test-cmd`), so its non-zero exit
is silently ignored. The script proceeds to the operator wait loops (lines 739/742)
which eventually succeed because the operators settle over time.

**Impact:** Real installation problems (30-minute operator timeout!) are masked. The test
appears green even though the cluster needed emergency intervention (reboot) to recover.

**Proposed fix:**
Replace line 726 with a `test-cmd` call that will fail the test if the second `mon` also fails:
```bash
# Before (silent failure):
aba --dir $subdir/aba/$cluster_name mon

# After (proper error propagation):
test-cmd -h $reg_ssh_user@$int_bastion_hostname -r 2 5 -m \
    "Retry: checking cluster with mon after node reboot" \
    "aba --dir $subdir/aba/$cluster_name mon"
```

Also consider: should the test fail immediately if the initial `mon` times out, rather
than attempting a recovery path that masks the issue? The reboot-and-retry logic makes
it impossible to distinguish between "flaky infrastructure" and "real code bug".

**Where:** `test/test5-airgapped-install-local-reg.sh` lines 713-729

---

## Low Priority

### Bundle Pipeline: Empty Google Drive Trash After Sync

**Status:** Backlog
**Priority:** Low
**Created:** 2026-03-23

**Problem:**
After synchronizing a new bundle to Google Drive, the old bundle files remain in the
Drive trash, consuming storage quota. The trash must be emptied manually.

**Proposed fix:**
Use the `gdrive` CLI tool to empty the trash folder after a successful bundle upload/sync.
Add a `gdrive files trash empty` (or equivalent) command at the end of the bundle sync
step in `bundles/v2/`.

**Where:** `bundles/v2/go.sh` or `bundles/v2/phases/` (whichever handles the GDrive upload)

---

### Clean Up TUI Debug Logging

**Status:** Backlog
**Priority:** Low
**Created:** 2026-03-13

**Problem:**
`tui/abatui.sh` contains leftover debug logging that writes to `/tmp/aba-tui-debug.log` (e.g., lines near the background isconf launch: `echo "[DEBUG ..." >> /tmp/aba-tui-debug.log`). These were added during investigation of the ISC regeneration bug and should be removed or converted to proper `log` calls.

**Files:** `tui/abatui.sh` — search for `/tmp/aba-tui-debug.log`

---

### Suppress `[ABA] Using .../mirror.conf file` for Simple Commands

**Status:** Backlog
**Priority:** Low
**Context:** Running `aba ls` (or other quick informational commands) outputs `[ABA] Using /home/steve/testing/aba/sno/mirror.conf file`, which is noise for the user. This message should be downgraded to `aba_debug` so it only appears with `-v`/verbose mode, or suppressed entirely for simple read-only commands like `ls`, `status`, `run --cmd`.

### Suppress `[ABA] Ensuring CLI binaries are installed` for VM Operations

**Status:** Backlog
**Priority:** Low
**Created:** 2026-03-13

**Problem:**
Simple VM management commands like `aba shutdown`, `aba start`, `aba ls`, `aba delete` etc. print `[ABA] Ensuring CLI binaries are installed` before doing anything. This is unnecessary noise — these commands only need `govc` (already ensured separately), not the full OpenShift CLI stack.

**Example:**
```
steve@bastion:demo1 (dev)$ aba shutdown
[ABA] Ensuring CLI binaries are installed      <<<< not needed here
```

**Fix:** Skip the CLI binary check for VM-only operations (shutdown, start, ls, delete, ssh, etc.) or move it to `aba_debug` for those commands. The CLI ensure step should only run for commands that actually need `oc`, `openshift-install`, or `oc-mirror`.

### E2E: default to git-based aba install, not local repo copy

**Status:** Backlog
**Priority:** Low
**Context:** `run.sh deploy` currently tars the entire local aba repo and scps it to conN. This is only needed by developers testing uncommitted changes. By default, the suites should install aba from git (the real user path), and `run.sh deploy` should only copy the test framework (`test/e2e/`).
**Proposed design:**
- Default: `run.sh deploy` copies only the test framework to conN. The suite setup step does `git clone`/`git pull` + `./install` to get aba -- testing the real user install path.
- `--local` flag: copies the full local repo (current behaviour) for developers testing uncommitted changes. Suite setup skips git clone since aba is already present.
- Benefits: tests the actual user journey, catches missing files in git, CI-ready.
- The suite setup step needs a conditional: if aba repo already exists (local deploy), use it; otherwise, git clone from the configured branch.

### 4. Improve vmw-create.sh Output Formatting

**Status:** Backlog  
**Priority:** Low  
**Estimated Effort:** Small  
**Created:** 2026-02-26

**Problem:**
The VM creation output from `vmw-create.sh` is a dense wall of text with all parameters crammed onto one long line:
```
[ABA] Create VM: [ABA] sno-sno: [8C/20G] [Datastore4-2] [VMNET-DPG] [00:50:56:09:c9:01] [Datastore4-2:images/agent-sno.iso] [/Datacenter/vm/abatesting/sno]
```

**Proposed Solution:**
Format the VM creation output to be more readable, e.g.:
```
[ABA] Creating VM: sno-sno
        CPU/Mem:    8C / 20G
        Datastore:  Datastore4-2
        Network:    VMNET-DPG
        MAC:        00:50:56:09:c9:01
        ISO:        Datastore4-2:images/agent-sno.iso
        Folder:     /Datacenter/vm/abatesting/sno
```

**Where:**
- `scripts/vmw-create.sh`, the `create_node()` function (around line 91-92)

**Benefits:**
- Easier to read and verify at a glance
- Each parameter on its own line aids troubleshooting

### 5. Persistent Registry State in `~/.aba/mirror/`

**Status:** Completed  
**Completed:** Already implemented  
**Created:** 2026-02-21  

**Resolution:** Registry state (`state.sh`, `pull-secret-mirror.json`, `rootCA.pem`) is already persisted in `~/.aba/mirror/<name>/` via `reg-common.sh` `reg_post_install()`. This directory is outside the workspace and survives `aba reset -f`. The `regcreds_dir` is derived as `$HOME/.aba/mirror/$(basename "$PWD")` in `reg_load_config()`.

### 6. `aba mirror uninstall` Must Fully Clean Up Quay

**Status:** Backlog  
**Priority:** Medium  
**Estimated Effort:** Medium  
**Created:** 2026-02-21

**Problem:**
`aba -d mirror uninstall` does not fully tear down Quay. Rootless containers started with `--cgroups=no-conmon` are managed by systemd user services that survive the uninstall. Orphan `rootlessport`/`conmon` processes hold port 8443 and block subsequent installs.

**Required:** `aba mirror uninstall` must handle:
- Stopping and disabling Quay systemd user services (`quay-app`, `quay-redis`, `quay-pod`)
- Killing orphan `rootlessport`/`conmon` processes
- Removing Quay data directories (`~/quay-install`, etc.)
- Verifying port 8443 is free after teardown

### 7. `aba` CLI Fails to Bootstrap Empty `aba.conf`

**Status:** Backlog  
**Priority:** Medium  
**Estimated Effort:** Small  
**Created:** 2026-02-21

**Problem:**
After `aba reset -f` or `./install`, calling `aba` with CLI flags that should configure `aba.conf` fails because the Makefile guard checks `ocp_version` before the CLI flags get a chance to write it:

```
Feb 21 06:33:44      >> aba --noask --platform vmw --channel stable --version p --base-domain p1.example.com
Makefile:116: *** "Value 'ocp_version' not set in aba.conf! Run aba in the root of Aba's repository or read the README.md file on how to get started.".  Stop.
```

**Fix:** The `aba` CLI should write config values to `aba.conf` before invoking `make`, or the Makefile guard should be deferred until an actual build target is invoked (not config-setting flags).

### 8. E2E Suite Teardown / Cleanup Independence

**Status:** Partially done (2026-03-23)
**Priority:** Low  
**Estimated Effort:** Small  
**Created:** 2026-02-21

**Problem:**
Suites relied on the next suite's `setup_aba_from_scratch()` to clean up. Now each suite
installs ABA from scratch inline (git clone or curl), so they are self-contained.
`setup_aba_from_scratch()` and `cleanup_all()` have been removed from `setup.sh`.

**Remaining:** Running a single suite still leaves state behind on conN (clusters, mirrors).
Consider adding per-suite teardown hooks for environments that need a clean slate after each suite.

### 9. New Command: `aba status`

**Status:** Backlog  
**Priority:** Low  
**Estimated Effort:** Medium  
**Created:** 2026-02-21

**Problem:**
Users have no way to see how far along the aba setup pipeline they are.

**Proposed:**
A new `aba status` command that inspects existing state and shows pipeline progress:

```
$ aba status
aba.conf            OK  (version=4.16.12, channel=stable, platform=vmw)
vmware.conf         OK
mirror.conf         OK  (registry=registry.example.com:8443)
Mirror installed    OK
Mirror synced       OK  (last sync: 2026-02-20 14:30)
cluster.conf (sno)  OK  (nodes=1, network=10.0.1.0/24)
Cluster (sno)       NOT INSTALLED
```

### 16. Audit All `[ABA]` Output for Left-Justification

**Status:** Backlog  
**Priority:** Low  
**Estimated Effort:** Medium  
**Created:** 2026-02-28

**Problem:**
Some `[ABA]` messages appear indented or mid-line rather than at column 0. The
expectation is that `[ABA]` is ALWAYS left-justified. In cases where the prefix
is not appropriate (e.g., sub-messages like "invalid!"), only the message string
should be output without the `[ABA]` prefix. In other cases, a `\n` is needed
before the message.

**Action:** Audit all `aba_log`, `echo "[ABA]"`, and similar patterns across
`scripts/*.sh` and `*/Makefile` to ensure consistent left-justification.

### Reduce Verbose Pre-flight Check Output

**Status:** Backlog  
**Priority:** Low  
**Estimated Effort:** Small  
**Created:** 2026-03-21

**Problem:**
`scripts/preflight-check.sh` prints a line for every successful DNS/NTP reachability check
(e.g. "DNS server 10.0.1.8 is reachable", "NTP server ntp.example.com is reachable").
For clusters with many servers this is noisy and buries important information.

**Expected Behavior:**
- Only print individual lines when a check **fails** (e.g. "DNS server 10.0.1.8 is NOT reachable").
- On success, show a single summary line at the end: e.g. "All DNS/NTP servers reachable".
- Keep the "No IP conflicts detected" and "Pre-flight validation passed" summary lines.

**Files:** `scripts/preflight-check.sh`

### 11. E2E Framework: Graceful Stop / Signal Handling

**Status:** Partially done  
**Priority:** Low  
**Estimated Effort:** Small (remaining)  
**Created:** 2026-02-21

**Done:**
- `run.sh stop` subcommand: SSHes to each conN, kills the runner PID from lock file, removes lock/rc files, kills tmux session.
- `runner.sh` has `trap 'rm -f "$LOCK_FILE"' EXIT` for lock cleanup.

**Remaining:**
- Add `trap` in `run.sh` coordinator for SIGINT/SIGTERM (propagate stop to conN)
- Write a PID file for `run.sh` itself so a second invocation can signal/stop the first
- Propagate stop signal to all pool dispatchers in parallel mode

---

## Unimplemented plans (from sessions)

*These were raised in sessions or other docs; added here so we don't forget them.*

### 18. E2E `--resume` Remaining Bug (1 of 4)

**Status:** Backlog (bugs 2 & 3 fixed)  
**Priority:** Medium  
**Estimated Effort:** Small  
**Created:** 2026-03-03  
**Ref:** HANDOFF_CONTEXT.md §2

- ~~**Bug 2:** Fixed — `suite_begin` now copies resume file to `.resume` backup before truncating.~~
- ~~**Bug 3:** Fixed — `test_begin`/`test_end`/`e2e_run` now use `should_skip_checkpoint` and `_E2E_SKIP_BLOCK`.~~
- **Bug 4:** `--resume` not passed through dispatch — `_dispatch_suite` in run.sh doesn't append `--resume` to `runner_cmd`. Only restart mode passes it.

### 19. E2E dnsmasq Registry DNS Record

**Status:** Backlog  
**Priority:** Low  
**Estimated Effort:** Small  
**Created:** 2026-03-03  
**Ref:** HANDOFF_CONTEXT.md §3

`dig registry.pN.example.com +short` returns nothing on conN. `_vm_setup_dnsmasq` doesn't add a record for `registry.pN.example.com`. An incomplete fix exists in `git stash`.

### 20. E2E Error Suppression Audit (remaining files)

**Status:** Backlog  
**Priority:** Medium  
**Estimated Effort:** Small  
**Created:** 2026-03-03  
**Ref:** HANDOFF_CONTEXT.md §4

Audit `|| true` and `2>/dev/null` in: `test/e2e/lib/remote.sh`, `framework.sh`, `parallel.sh`, `config-helpers.sh`. Never silently swallow failures in test suites.

### 21. E2E Pool Affinity for Dispatch

**Status:** Backlog  
**Priority:** Low  
**Estimated Effort:** Medium  
**Created:** 2026-03-03  
**Ref:** HANDOFF_CONTEXT.md §6

Dispatcher assigns next suite to first free pool. Suites that share prerequisites (e.g. `cluster-ops` + `network-advanced` both use pool registry) could be chained to the same pool to reuse registry. Add lightweight chaining hints.

### 22. ~~Rename `.installed` / `.uninstalled` to `.available` / `.unavailable`~~

**Status:** Done (2026-03-06)  
**Priority:** Low  
**Estimated Effort:** Small  
**Created:** 2026-03-03  
**Ref:** E2E_FIXES_LOG.md B1

Done. Renamed all marker files from `.installed`/`.uninstalled` to `.available`/`.unavailable` across the codebase.

### 23. Cluster VMs in Wrong vCenter Folder

**Status:** Backlog  
**Priority:** Low  
**Estimated Effort:** Small  
**Created:** 2026-03-03  
**Ref:** E2E_FIXES_LOG.md A

Compact/cluster VMs land in shared `abatesting` folder instead of pool-specific folder (e.g. `pool3/`). vCenter folder path during cluster creation should incorporate pool number.

### 24. `run.sh deploy --force` Confirmation Prompt

**Status:** Backlog  
**Priority:** Low  
**Estimated Effort:** Trivial  
**Created:** 2026-03-03

When using `deploy --force`, prompt user: "Really do this? (Y/N)?" to avoid accidental wipe of remote state.

### 25. E2E PAUSED State: Clear Flag File Promptly

**Status:** Backlog  
**Priority:** Low  
**Estimated Effort:** Trivial  
**Created:** 2026-03-03

Clear the PAUSED flag file as soon as it is reasonable so it doesn't persist and confuse status. Documented during run.sh status / interactive menu work.

### 26. E2E Spring-Clean Function

**Status:** Backlog  
**Priority:** Low  
**Estimated Effort:** Small  
**Created:** 2026-03-03

Function to remove state data and run verification routines to bring conN/disN back to a known good state (e.g. before a fresh full run or after debugging).

### 27. E2E `--loop` Option for Continuous Dispatch

**Status:** Backlog  
**Priority:** Low  
**Estimated Effort:** Medium  
**Created:** 2026-03-03

Option to continuously re-queue completed (or failed) suites so pools keep getting work without user re-running `reschedule`. Deferred in favor of one-shot retry + reschedule.

### 28. Investigate: Why Does `suite-connected-public` Install a Registry?

**Status:** Backlog  
**Priority:** Low  
**Estimated Effort:** Small  
**Created:** 2026-03-03

Suite only tests public registry path; clarify whether installing a reg is necessary or leftover. Add to backlog for investigation.

### ~~29. Docker Registry as First-Class Citizen~~

**Status:** Done (2026-03-10)  
**Created:** 2026-03-03  
**Ref:** ai/DESIGN-docker-registry-first-class.md

Done. Docker registry is now first-class: `reg-install-docker.sh`, `reg-uninstall-docker.sh`, remote install via `reg-install-remote.sh`, TUI support (Auto/Quay/Docker), `reg_vendor` config in `mirror.conf`, CLI `--vendor docker`.

### 31. Warn When Registry Data Directory Already Contains Data

**Status:** Backlog  
**Priority:** Medium  
**Estimated Effort:** Small  
**Created:** 2026-03-08

**Problem:**
When installing a Quay or Docker registry, if the destination `data_dir` already exists and contains data from a previous installation (or unrelated files), ABA silently proceeds. This can lead to confusing failures or data corruption.

**Proposed Fix:**
In `reg-install-quay.sh` and `reg-install-docker.sh` (and the remote variants), after `reg_setup_data_dir` resolves the path, check if the directory exists and is non-empty. If so, show a prominent red warning via `aba_warning`:
```bash
if [ -d "$data_dir" ] && [ "$(ls -A "$data_dir" 2>/dev/null)" ]; then
    aba_warning "Data directory '$data_dir' already exists and is not empty!" \
        "This may contain data from a previous registry installation." \
        "Proceeding will install on top of existing data."
fi
```
For remote installs, the check should run on the remote host via SSH.

### 32. Skip Remote Copy of Registry Tarball if Already Present (and valid)

**Status:** Backlog  
**Priority:** Low  
**Estimated Effort:** Small  
**Created:** 2026-03-08

**Problem:**
`reg-install-remote.sh` always copies `mirror-registry-amd64.tar.gz` (~1GB) to the remote host via `scp`, even if an identical copy already exists there from a previous install. The same may apply to the Docker registry image (`docker-reg-image.tgz`). On slow links this wastes significant time.

**Proposed Fix:**
Before copying, check if the file already exists on the remote host with a matching size (or checksum):
```bash
local_size=$(stat -c %s "$tarball")
remote_size=$(ssh "$remote" "stat -c %s '$remote_path' 2>/dev/null" || echo 0)
if [ "$local_size" != "$remote_size" ]; then
    scp "$tarball" "$remote:$remote_path"
fi
```
Or use `rsync --checksum` / `rsync --size-only` instead of `scp` for a one-line fix.

### 33. `verify` Target Runs Multiple Times Unnecessarily

**Status:** Backlog  
**Priority:** Medium  
**Estimated Effort:** Small  
**Created:** 2026-03-08

**Problem:**
When running `aba` commands, the Make `verify` target is executed multiple times in a row, which is unnecessary and wastes time. Need to investigate what triggers repeated `verify` runs and ensure it only executes once per invocation.

**Action:** Trace which Make dependency chains pull in `verify` and add appropriate sentinel files or order-only prerequisites to prevent redundant runs.

### 34. Mirror-Registry Install Files Sometimes Missing on Remote Host

**Status:** Backlog  
**Priority:** Medium  
**Estimated Effort:** Medium  
**Created:** 2026-03-08

**Problem:**
During remote Quay registry installation (`aba -d mirror install -H <host>`), the `mirror-registry` binary or its supporting files are sometimes not found on the remote host, causing `./mirror-registry: No such file or directory` errors. This has been seen on `registry4` and other hosts. The root cause may involve `run_once` markers persisting across `clean`/`reset` cycles, or files not being properly copied/extracted on the remote side.

**Action:** Make the remote install flow more robust:
- Verify the binary exists on the remote host before attempting to run it
- Re-copy/re-extract if missing, regardless of `run_once` state
- Add pre-flight checks in `reg-install-remote.sh`

### 38. `aba register` Should Validate Required Options Before Invoking Make

**Status:** Backlog  
**Priority:** Medium  
**Estimated Effort:** Small  
**Created:** 2026-03-08

**Problem:**
Running `aba register` without the required `--pull-secret-mirror` and `--ca-cert` flags produces a raw Make error:
```
[ABA] Error: pull_secret_mirror= is required (path to pull secret JSON file)
make: *** [Makefile:73: register] Error 1
```
The error comes from the Makefile recipe, not from `aba.sh`. The UX should catch missing required options early in `aba.sh` (before invoking `make`) and show a helpful message with correct usage, e.g.:
```
[ABA] Error: 'aba register' requires --pull-secret-mirror and --ca-cert options.
[ABA] Usage: aba -d mirror register --pull-secret-mirror <file> --ca-cert <file>
[ABA] See 'aba mirror --help' for details.
```

**Action:** In `aba.sh`, when `cur_target` is `mirror` and `BUILD_COMMAND` contains `register`, verify that `pull_secret_mirror=` and `ca_cert=` are present in `BUILD_COMMAND` before calling `eval make`. If missing, print usage and exit. The same pattern could apply to other targets that require specific options (e.g., `password` requiring `--reg-host`).

### Validate vmware.conf Parameters Are Not Empty

**Status:** Backlog
**Priority:** Medium
**Estimated Effort:** Small
**Created:** 2026-03-12

**Problem:**
When `vmware.conf` is loaded, critical variables like `GOVC_URL`, `GOVC_DATACENTER`, `GOVC_CLUSTER`, `GOVC_DATASTORE`, `GOVC_NETWORK`, `GOVC_USERNAME`, `GOVC_PASSWORD` may be empty or undefined. ABA does not validate these before passing them to Jinja2 templates (`install-config.yaml.j2`) or to `govc` commands. Empty values cause cryptic template errors or silent misconfigurations (e.g., blank `server:` in failureDomains).

**Proposed Fix:**
Add a `verify-vmware-conf()` function (similar to `verify-aba-conf`) that checks all required GOVC variables are non-empty when `platform=vmw`. Call it early in the cluster config pipeline (e.g., in `scripts/setup-cluster.sh` or `scripts/create-cluster-conf.sh` after sourcing vmware.conf). Abort with a clear message listing which variables are missing.

**Where:** New function in `scripts/include_all.sh` or `scripts/verify-config.sh`, called from cluster setup paths.

### Re-enable Quay Mirror-Registry on arm64

**Status:** Backlog (waiting on Red Hat)
**Priority:** Medium
**Estimated Effort:** Small
**Created:** 2026-03-11

**Problem:**
Quay mirror-registry binary is not published for arm64 (as of 2026-03). We added conditionals to skip the download and use Docker registry instead. When Red Hat publishes the arm64 binary, we need to re-enable Quay support.

**What to change (3 places):**
1. `templates/Makefile.mirror` lines 30-35: Remove `_REGISTRY_PREREQ` conditional — revert to just `mirror-registry`
2. `templates/Makefile.mirror` `download-registries` target: Remove `$(if $(filter aarch64,...))` — revert to `$(MR_TARBALL) docker-reg-image.tgz`
3. `scripts/reg-install.sh`: Update `auto` resolution logic to allow `auto` -> `quay` on arm64

**How to verify:** Check `https://mirror.openshift.com/pub/cgw/mirror-registry/latest/` for `mirror-registry-arm64.tar.gz`.

### 35. Consolidate `mirror/save` and `mirror/sync` Into `mirror/data`

**Status:** Backlog  
**Priority:** Medium  
**Estimated Effort:** Large  
**Created:** 2026-03-08

**Problem:**
The current split between `mirror/save/` and `mirror/sync/` directories adds complexity. Both hold imageset configs and oc-mirror workspace data for essentially the same purpose (getting images into the mirror registry). Consolidating them into a single `mirror/data/` directory would simplify the codebase, reduce user confusion, and eliminate duplicated imageset config generation logic.

**Action:** Design and implement the consolidation. Key considerations:
- Unified imageset config (currently separate `imageset-config-save.yaml` and `imageset-config-sync.yaml`)
- Backward compatibility for existing users with save/sync directories
- Impact on `aba save`, `aba load`, `aba sync` CLI commands
- Bundle workflow (save on connected side, load on disconnected side)

### 40. Improve `day2.sh` Screen Output and UX

**Status:** Backlog  
**Priority:** Medium  
**Estimated Effort:** Medium  
**Created:** 2026-03-08

**Problem:**
The `day2.sh` script output is noisy and hard to follow. Users see walls of `oc apply` output, raw YAML, and unclear progress indicators. The script should provide a cleaner, step-by-step experience showing what it's doing and whether each step succeeded.

**Action:** Review and improve `day2.sh` output:
- Clear step headers (e.g., "Step 1/4: Configuring OperatorHub...")
- Suppress raw `oc apply` output unless in debug mode
- Show success/failure status per step
- Summarize what was applied at the end

### 41. Improve Overall ABA UX and Screen Output

**Status:** Backlog  
**Priority:** Medium  
**Estimated Effort:** Large  
**Created:** 2026-03-08

**Problem:**
ABA's screen output across all commands could be more polished and user-friendly. Issues include:
- Inconsistent `[ABA]` prefix formatting (sometimes indented, sometimes missing)
- Raw `make` errors shown to users instead of friendly messages
- Internal paths (`~/.aba/...`) exposed in error messages
- Verbose output from underlying tools (curl, podman, oc-mirror) not suppressed in normal mode
- No clear progress indication for long-running operations
- No summary at completion of multi-step operations

**Action:** Systematic UX audit across all user-facing commands:
- Audit all `aba_abort`, `aba_warning`, `aba_info` messages for clarity and consistency
- Ensure `[ABA]` prefix is always left-justified (see backlog #16)
- Suppress tool output unless `--debug` is set
- Add progress indicators or step counters for long operations (sync, save, load, install)
- Wrap `make` errors with user-friendly messages in `aba.sh`
- Never expose internal paths to users (see "Wrong path in mirror credential error message")

### Investigate Why `cli/Makefile` Is Missing on Bundle-Deployed Bastions

**Status:** Backlog
**Priority:** Medium
**Estimated Effort:** Small
**Created:** 2026-03-12

**Problem:**
On a s390x bastion that received ABA via a bundle, `cli/` was completely empty (no `Makefile`). This caused `aba clean` to fail with `No rule to make target 'out-download-all'` because `aba.sh` unconditionally calls `cli-download-all.sh`, which requires `cli/Makefile`.

The immediate crash is fixed (skip CLI downloads for housekeeping commands). But the deeper question remains: why was `cli/Makefile` missing? `backup.sh` includes `${repo_dir}/cli` in the `find` list, so `cli/Makefile` should be in any bundle. Possible causes:
- Bundle was created from a source where `cli/Makefile` was accidentally deleted
- An older ABA version had a different `cli/` structure
- The `install` script or `aba reset` somehow removes `cli/Makefile`
- Bundle extraction issue on s390x

**Action:** Reproduce on a clean s390x bundle deployment. Verify `cli/Makefile` is present in the tar archive (`tar tf bundle.tar | grep cli/Makefile`). Check if `./install` or `aba reset` removes it.

**Where:** `scripts/backup.sh`, `install`, `cli/Makefile` reset target

### Smarter Catalog Index Download Scheduling

**Status:** Backlog
**Priority:** Medium
**Estimated Effort:** Medium
**Created:** 2026-03-13

**Problem:**
ABA downloads catalog indexes (via `download-catalog-index.sh` / `download_all_catalogs()`) eagerly, even when no operators are defined in `aba.conf` (`ops=` and `op_sets=` are empty). The download still has value (the indexes will be needed if the user later adds operators), but running it in the **foreground** blocks the user's current operation unnecessarily. If no operators are defined for this run, the indexes won't be consumed, so the user is waiting for something that has no immediate benefit.

**Desired behavior:**
- If operators ARE defined (`ops` or `op_sets` non-empty): download catalogs in the foreground as today (they're needed now).
- If NO operators are defined: still download the catalogs (speculative prefetch), but do it in the **background** so it doesn't block the user's current command. The indexes will be ready if the user adds operators later.
- If catalogs are already cached and fresh (within TTL): skip entirely regardless of operator config.

**Where:** `scripts/include_all.sh` (`download_all_catalogs()`), `scripts/aba.sh` (where catalog downloads are triggered), `scripts/download-catalog-index.sh`

**Considerations:**
- Background downloads must not interfere with foreground operations (file locking, `run_once` state)
- Need to handle the case where a background download is still running when the user adds operators and runs a command that needs the indexes
- The `run_once` mechanism already provides locking; verify it handles concurrent foreground + background correctly

### 36. CLI Download Retry Gaps

**Status:** Backlog  
**Priority:** Low  
**Estimated Effort:** Small  
**Created:** 2026-03-04

**Problem:**
Two gaps in CLI download retry coverage:

1. **`run_once` level:** If a CLI download/install task fails with a regular exit code (e.g., exit 1 from checksum failure or disk full), `run_once` records the failure and never retries. Only signal kills (exit 128-165) trigger automatic restart. A failed task stays failed until manually reset (`run_once -r`).

2. **`curl --retry` scope:** All downloads use `curl --retry 8` with default exponential backoff (1s, 2s, 4s... up to ~4 min total). However, `--retry` only covers transient HTTP errors (5xx, 408) and connection failures. HTTP 4xx errors (404, 403) are treated as permanent and not retried. Adding `--retry-all-errors` would cover these cases.

**Proposed Fix (if needed):**
- Add `--retry-all-errors` to curl invocations in `cli/Makefile` (trivial, one-line per call)
- Consider adding a `run_once -w --retry N` flag that clears exit state and restarts on non-zero exit (more complex, only if flaky failures recur)

**Current mitigation:** curl's `--retry 8` handles most transient issues. E2E test framework has its own `e2e_run -r` retry logic. Issue would only manifest during persistent CDN/mirror outages.

### 37. CLI Ensure Analysis — Add Ensures to 6 Scripts

**Status:** Backlog  
**Priority:** Low  
**Estimated Effort:** Medium  
**Created:** 2026-03-03  
**Ref:** ai/CLI_ENSURE_ANALYSIS.md

When moving logic out of Makefiles, add "ensure" patterns to 6 scripts as proposed in CLI_ENSURE_ANALYSIS.md.

---

## Completed

### `verify_conf=all/conf/off` -- Configurable Preflight Validation Strictness
**Completed:** 2026-03-19
Added three-state `verify_conf` setting (`all`/`conf`/`off`) to control preflight and config
validation. When the bastion is on a different network than the cluster nodes, `conf` skips
DNS, NTP, IP conflict, DNS record validation, and registry release image checks while keeping
config file validation. CLI flag: `aba --verify <all|conf|off>`. Backward-compatible with
legacy boolean values. E2E test added in `suite-cluster-ops.sh`. README documented
(Pre-flight section + FAQ).

### Improve `arping` IP Conflict Detection on Multi-Homed Hosts
**Completed:** 2026-03-19
`preflight-check.sh` now uses `ip route get` to auto-detect the correct outgoing interface
for `arping -I`, fixing silent failures on multi-homed E2E hosts. Falls back to `ping` if
interface detection fails.

### Improve Release Image Error Message
**Completed:** 2026-03-19
`verify-release-image.sh` now captures `skopeo` stderr and includes it in the error message.
Replaced generic "not found" text with actionable troubleshooting hints (credentials, mirroring,
version mismatch).

### Ask User Before Bumping Master Memory (OCPBUGS-62790)
**Completed:** 2026-03-19
Changed the silent 16GB-to-20GB master memory bump in `vmw-create.sh` from an automatic
adjustment to an interactive `ask()` prompt. Users can now confirm or decline the increase.

### E2E Workaround for OCP ImagePrunerJobFailed Bug
**Completed:** 2026-03-19
Added `_e2e_fix_image_pruner_if_needed()` to `test/e2e/lib/framework.sh`. Detects
`ImagePrunerJobFailed` in command output, suspends the image pruner, and deletes failed
jobs before retry. Workaround for Red Hat KCS 5367151.

### Delete SNO Clusters Before `rm -rf` in Old E2E Tests
**Completed:** 2026-03-19
Added explicit `aba delete` before `rm -rf sno` in `test2` and `test5` to prevent IP
conflict failures from stale clusters. Also added deliberate negative IP conflict test
to `test1` and `suite-cluster-ops.sh`.

### ISC Display Name Comments With Fuzzy Filtering
**Completed:** 2026-03-18
Generated ISC files now include display names as YAML comments (e.g. `- name: cincinnati-operator  # OpenShift Update Service`).
Fuzzy logic (`_display_name_adds_info()`) skips redundant comments where the display name is just a
reformatted version of the package name. See `ai/TUI_OPERATOR_DISPLAY_ENHANCEMENT.md`.

### Catalog Canary Test Script
**Completed:** 2026-03-18
`test/func/test-catalog-canary.sh` -- standalone canary that auto-detects available OCP versions
(including pre-GA), runs the production extraction entry point, and validates output. Designed
for cron-based periodic execution. See `ai/PODMAN_CATALOG_EXTRACTION.md`.

### `aba shutdown` Debug Pod Warning Shown After Successful Priming

**Status:** Backlog
**Priority:** Low
**Created:** 2026-03-25

**Problem:**
`aba shutdown` shows "Still waiting for VMs to power off (10s) ..." polling messages that
are noisy and unhelpful. Also, when `--wait` is provided, there is no indication that the
user can safely interrupt the wait.

**Requested changes (both `cluster-graceful-shutdown.sh` and `cluster-startup.sh`):**

1. Replace the polling message:
   - **Remove:** `[ABA] Still waiting for VMs to power off (10s) ...`
   - **Replace with:** `[ABA] Waiting for all nodes to power down. You may safely hit ctrl+c to stop waiting.`
   (Show once, not repeatedly every 10s)

2. Apply the same pattern to `cluster-startup.sh` when `--wait` is provided:
   - `[ABA] Waiting for all nodes to power up. You may safely hit ctrl+c to stop waiting.`

**Where:** `scripts/cluster-graceful-shutdown.sh`, `scripts/cluster-startup.sh`

---

### E2E: No "Silently Skipped" Tests in Test Code

**Status:** Backlog
**Priority:** Medium
**Created:** 2026-03-25

**Problem:**
Test code must never silently skip tests or assertions. Every test block registered in
`plan_tests` must have a corresponding `test_begin` with an exact name match, and every
`test_begin` must appear in `plan_tests`. A mismatch causes the dashboard to show `--`
instead of `PASS`/`FAIL`, hiding whether the test actually ran.

**Found and fixed (2026-03-25):**
- `suite-airgapped-existing-reg.sh`: `plan_tests` had "Load without save dir (must fail)"
  but `test_begin` had "Load without data dir (must fail)" -- name mismatch.
- `suite-cluster-ops.sh`: `test_begin "verify_conf=conf skips network checks"` was missing
  from `plan_tests` entirely.

**Action:**
Consider adding a runtime check in `test_begin()` that warns (or aborts) if the test name
is not found in `_E2E_PLAN_NAMES`. This would catch mismatches immediately instead of
silently showing `--` on the dashboard.

**Where:** `test/e2e/lib/framework.sh` (`test_begin` function), all suite files.

---

### `aba shutdown` Retry and Verify
**Completed:** 2026-03-10  
`cluster-graceful-shutdown.sh` has 3-attempt retry logic (lines 116-145) and verification via `make -s ls` when `wait=1` and `vmware.conf` exists.

### Suppress Curl Error Output During Registry Probing
**Completed:** 2026-03-10  
`probe_host()` in `include_all.sh` suppresses curl stderr during probing. ABA reports results in its own messaging.

### Mirror Config Flags Work With Named Mirror Directories (#17)
**Completed:** 2026-03-10  
`aba.sh` uses `$WORK_DIR/mirror.conf` dynamically. With `-d mymirror`, `WORK_DIR` points to the named mirror directory.

### E2E `_essh: command not found` in Framework Cleanup
**Completed:** 2026-03-10  
`runner.sh` sources `vm-helpers.sh` before `framework.sh`, making `_essh` available in cleanup paths.

### E2E Dispatcher: Detect Crashed Suites (#15)
**Completed:** 2026-03-10  
`_check_pool()` in `run.sh` has tmux session fallback: if no `.rc` file and tmux session is gone after 5s grace, returns 255 ("Suite died without writing .rc").

### Improve `.install.source` Breadcrumb File UX (#39)
**Completed:** 2026-03-10  
Renamed to `INSTALLED_BY_ABA.md` with verify/uninstall commands and date. Created by Quay, Docker, and remote install scripts.

### Rename `CATALOG_CACHE_TTL_SECS` to `CATALOG_CACHE_TTL_MINS` (#10)
**Status:** Won't fix  
Name is accurate — value is in seconds (`43200`), so `_SECS` suffix is correct.

### `run.sh verify` -- Pool Verification Subcommand
**Completed:** 2026-03-02  
Extracted `_verify_con_vm()` / `_verify_dis_vm()` into standalone functions in `setup-infra.sh`. Added `--verify` flag to `setup-infra.sh` and `verify` subcommand to `run.sh`. Supports `--pool N` for single-pool checks. Streaming output (no hang), separate per-VM logs, `_fail()` helper with bold red output, summary table with failure reasons. Auto-detects pool count from `pools.conf`.

### Dynamic Suite Dispatcher (Work-Queue Model)
**Completed:** 2026-03-02  
`run.sh` dispatches one suite at a time to free pools, polls for completion, and assigns the next from the queue. Added `reschedule` subcommand to re-queue completed suites. Full CLI rationalization with consistent subcommand+flag structure.

### Simplify E2E Suite Regcreds Setup With `aba register`
**Completed:** 2026-03-02  
Refactored `suite-airgapped-existing-reg.sh` to use `aba -d mirror register` with the pool registry on conN instead of manual `mkdir`/`cp` of credentials. Also added `aba -d mirror unregister` core command for externally-managed registries.

### E2E Suite Banner in tmux on Dispatch
**Completed:** 2026-02-23  
`runner.sh` now prints a large `####` banner with suite name, pool number, hostname, and timestamp before each suite starts. Makes it easy to find suite boundaries when scrolling tmux scrollback.

### E2E Clone-Check: Parallelize VM Cloning and Configuration
**Completed:** 2026-02-22  
`setup-infra.sh` Phase 1 clones all conN in parallel (background `&` + `wait`), then all disN. Phase 2 runs `_configure_con_vm` and `_configure_dis_vm` in parallel per pool. disN waits for conN NAT internally.

### E2E VM Reuse: Snapshot-Based Fast Restart
**Completed:** 2026-02-22  
Implemented via `pool-ready` snapshots. `setup-infra.sh` reverts existing VMs instead of re-cloning when the snapshot exists, and skips configuration. `runner.sh` reverts disN to `pool-ready` before each suite.

### `imagesetconf` with `op-sets=all` Missing Catalog
**Completed:** 2026-02-23  
Verified working: `add-operators-to-imageset.sh` (lines 122-130) correctly writes the `redhat-operator-index` catalog for `op-sets=all`. E2E test in `suite-create-bundle-to-disk.sh` verifies it. Original report was likely a transient test environment issue.

### E2E Suites: Refactor Embedded SSH to `e2e_run -h`
**Completed:** 2026-02-21
Converted ~46 embedded `ssh`/`_essh` calls across `suite-clone-and-check.sh` and `suite-mirror-sync.sh` to use the framework's `e2e_run -h "user@host"` / `e2e_run_remote` / `e2e_diag_remote` mechanisms. Commands now properly show `R` (remote) in logs with the target host displayed. Exceptions: pipe patterns (`local | ssh remote`), custom SSH key tests (`ssh -i`), and `_escp` (local scp) remain as `L`. Also fixed `e2e_diag` and `e2e_run_must_fail` to show `hostname -s` instead of hardcoded `localhost`. Added Golden Rule 14 to document this convention.

### E2E `--resume` Bug: Framework Clobbered Resume State
**Completed:** 2026-02-21  
`framework.sh` line 62 unconditionally set `E2E_RESUME_FILE=""`, overwriting the exported value from `run.sh`. Suites run via `bash "$suite_file"` (child process) source `framework.sh`, which wiped the resume file path before `e2e_begin_suite` could read it. Fixed by changing to `E2E_RESUME_FILE="${E2E_RESUME_FILE:-}"`.

### E2E Clone-and-Check: Inline Simple `_vm_*` Wrappers
**Completed:** 2026-02-21  
Replaced 5 trivial wrapper function calls (`_vm_remove_rpms`, `_vm_remove_pull_secret`, `_vm_remove_proxy`, `_vm_setup_vmware_conf`, `_vm_install_aba`) in `suite-clone-and-check.sh` with their actual `_essh`/`_escp` commands inline. Test logs now show the real ssh/scp commands instead of opaque function names. Functions remain in `pool-lifecycle.sh` for `create_pools` use.

### E2E Connected-Public: Missing `agentconf` Step
**Completed:** 2026-02-21  
`suite-connected-public.sh` "Proxy mode" test created `cluster.conf` via `aba cluster ... --step cluster.conf` but never ran `aba -d $SNO agentconf`, so `install-config.yaml` was never generated. The subsequent `assert_file_exists sno1/install-config.yaml` failed. Fixed by adding the missing `e2e_run "Generate agent config" "aba -d $SNO agentconf"` call.

### E2E Clone-and-Check: Permission and Assertion Fixes
**Completed:** 2026-02-21  
Fixed two test failures: (1) `sshd_config` grep needed `sudo` since the file is root-readable only on hardened RHEL; (2) `VC_FOLDER` assertion expected a pool-specific path pattern but the actual value was the shared datacenter folder. Relaxed to `grep -q 'VC_FOLDER=.'`.

### Systematic Script Directory Management Cleanup
**Completed:** 2026-02-19  
Cleaned up inconsistent `cd` patterns across 16+ scripts. Scripts now consistently trust Makefile CWD + symlinks per architecture principles.

### Validate starting_ip Is Within machine_network CIDR
**Completed:** 2026-02-18 (commit d190310)  
Added `ip_to_int`, `int_to_ip`, `ip_in_cidr` helpers to `scripts/include_all.sh`.  
`verify-cluster-conf()` now checks: starting_ip within CIDR, all nodes fit, VIPs within CIDR (non-SNO).
