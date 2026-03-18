# ABA Technical Backlog

This file tracks architectural improvements and technical debt that should be addressed in future releases.

---

## High Priority

### Replace `oc-mirror list operators` With Podman-Based Catalog Extraction

**Status:** Backlog
**Priority:** High
**Estimated Effort:** Small
**Created:** 2026-03-15

**Problem:**
`download-catalog-index.sh` depends on `oc-mirror list operators --catalog <url>` to generate
the operator index files (`.index/<catalog>-index-v<ver>`). This has several drawbacks:
- `oc-mirror` must be downloaded and installed before any catalog listing can happen
- `oc-mirror list operators` is slow and opaque (no display names, just name + channel)
- `oc-mirror v2` has known bugs (returns exit 0 on failure, intermittent hangs)
- Fedora requires a `/tmp` resize workaround because `oc-mirror` uses `/tmp` heavily

**Solution:**
Replace the `oc-mirror list operators` call in `download-catalog-index.sh` with the podman-based
extraction logic already implemented and tested in `scripts/extract-catalog-index.sh`. This script:
- Pulls the catalog image directly with `podman`
- Extracts `/configs` from the container
- Parses all FBC formats (split JSON, single JSON, index.json, YAML)
- Recursively searches bundle files for display names
- Outputs 3 columns: `<name> <display_name> <default_channel>`

The 3-column format is backward-compatible with existing consumers:
- `add-operators-to-imageset.sh` uses `awk '{print $1, $NF}'` (first + last column)
- `tui/abatui.sh` uses `${line%%[[:space:]]*}` (first field only)

**Integration steps:**
1. Replace `download-catalog-index.sh` contents with `extract-catalog-index.sh` logic
   (or rename `extract-catalog-index.sh` to `download-catalog-index.sh`)
2. Remove `ensure_oc_mirror` call — podman + jq are the only prerequisites
3. Remove Fedora `/tmp` resize workaround (no longer needed)
4. Remove `oc-mirror` from `download-catalogs-start.sh` prerequisite
5. Update `aba.sh` lines ~382-383 to not download `oc-mirror` for catalog operations
6. Keep `oc-mirror` in `cli-download-all.sh` — still needed for `reg-save.sh`/`reg-sync.sh`/`reg-load.sh`
7. Update error messages in `add-operators-to-imageset.sh` (line ~111 references `oc-mirror`)

**Note:** `oc-mirror` is still required for image mirroring (`oc-mirror --v2 --config`).
This change only removes it as a dependency for catalog *listing*.

**Tested:** `extract-catalog-index.sh` produces identical name + default_channel output as
`oc-mirror list operators` for v4.20 (149 ops) and v4.21 (138 ops), plus display names.

**Where:** `scripts/download-catalog-index.sh`, `scripts/extract-catalog-index.sh`,
`scripts/download-catalogs-start.sh`, `scripts/aba.sh`, `scripts/add-operators-to-imageset.sh`

**Also see:** `scripts/list-operators.sh` (standalone version for manual use / testing)

---

### Use Display Names in TUI Operator Search and Basket

**Status:** Backlog
**Priority:** High
**Estimated Effort:** Medium
**Created:** 2026-03-15
**Updated:** 2026-03-15

**Problem:**
The TUI operator basket and search results (`tui/abatui.sh`) currently show only raw
package names like `advanced-cluster-management` and `rhods-operator`. With the new
3-column index format (from the podman-based catalog extraction above), display names
are now available — e.g., "Advanced Cluster Management for Kubernetes" and
"Red Hat OpenShift AI".

Users searching for operators often know the product name (e.g., "OpenShift AI") but not
the package name (`rhods-operator`). Showing display names in search results would make
operator discovery far easier.

**Proposed UX:**

Search results (the checklist shown after typing a search term):
```
[ ] Red Hat OpenShift AI                         (rhods-operator)
[ ] Red Hat OpenShift AI Self-Managed            (rhoai-servicemesh-operator)
```

Operator basket / View/Edit checklist:
```
[X] Advanced Cluster Management for Kubernetes  (advanced-cluster-management)
[ ] Red Hat OpenShift AI                         (rhods-operator)
[ ] Red Hat Integration - 3scale                 (3scale-operator)
```

Search should also match against display names, not just package names. For example,
typing "AI" should find `rhods-operator` via its display name "Red Hat OpenShift AI".

**Implementation:**
- After replacing `download-catalog-index.sh` (see above), the `.index/` files will contain
  3 columns: `<name> <display_name> <default_channel>`
- `tui/abatui.sh` currently reads operator names with `${line%%[[:space:]]*}` (first field)
- Update the TUI to also extract the display name (middle columns) for presentation
- Update the search function to `grep` against both package name AND display name
- The `awk '{print $1, $NF}'` pattern still works for name + channel extraction
- Operators with `-` as display name (rare) should fall back to showing the package name

**Where:** `tui/abatui.sh` (operator search, basket / checklist rendering), the `.index/` files

---

### Catalog Download Dialog Should Show the OCP Version

**Status:** Backlog
**Priority:** High
**Estimated Effort:** Small
**Created:** 2026-02-26

**Problem:**
The TUI's "Downloading operator catalogs..." infobox (`tui/abatui.sh` ~line 1929) does not
mention which OCP version the catalogs are being downloaded for. When catalogs are downloading
in the background, the user only sees:

```
Downloading operator catalogs...
This may take a few minutes on first run.
```

**Fix:**
Include the OCP version in the message, e.g.:

```
Downloading operator catalogs for OCP 4.21...
This may take a few minutes on first run.
```

The version is available as `$ocp_ver_major` or can be derived from `$OCP_VERSION` at that
point in the flow.

---

### `aba reset` Should Delete Root `.index/` Directory

**Status:** Backlog
**Priority:** High
**Estimated Effort:** Small
**Created:** 2026-02-26

**Problem:**
`aba reset` (i.e. `make reset force=1`) does not remove the root-level `.index/` directory
where operator catalog indexes are cached. It only removes `mirror/.index/` (via
`make -sC mirror clean`), which is a different directory.

The `download-catalog-index.sh` script writes catalog indexes to `<aba-root>/.index/`,
not `mirror/.index/`. This means stale catalog indexes from previous runs survive a
full reset and can affect operator searches and ISC generation with outdated data.

**Fix:**
Add `rm -rf .index` to the root `Makefile`'s `reset` target, alongside the existing
cleanup of `cli`, `mirror`, and `test` subdirectories.

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

**Status:** Backlog
**Priority:** High
**Estimated Effort:** Small–Medium
**Created:** 2026-03-16

**Problem:**
`oc-mirror` fails when trying to download the OCP 4.19 catalog image, producing a v1/v2
compatibility error. This blocks catalog index downloads and operator listing for version 4.19.

**Context:**
Starting with OCP 4.18, `oc-mirror v1` is deprecated and Red Hat is transitioning to `oc-mirror v2`.
The 4.19 catalog images may require v2-only handling, causing the current v1-based catalog
download path to fail. The deprecation warnings are already visible:
```
⚠️  oc-mirror v1 is deprecated (started in 4.18 release) and will be removed in a future release
⚠️  starting with oc-mirror 4.21, the use of the flag --v1 or --v2 is mandatory
```

**Investigation needed:**
1. Reproduce: run `oc-mirror list operators --catalog registry.redhat.io/redhat/redhat-operator-index:v4.19`
   and capture the exact error
2. Determine if `--v2` flag resolves it (`oc-mirror --v2 list operators ...`)
3. Check if this is a known Red Hat bug or intentional v1 deprecation enforcement
4. If v2 fixes it, update `download-catalog-index.sh` to use `--v2` for OCP >= 4.19
5. Alternatively, this is another reason to accelerate the backlog item "Replace oc-mirror
   list operators With Podman-Based Catalog Extraction" — the podman-based approach
   (`extract-catalog-index.sh`) bypasses oc-mirror entirely and already works for 4.19+

**Workaround:** Use the podman-based extraction (`scripts/extract-catalog-index.sh`) which
pulls the catalog image directly with `podman` and doesn't depend on `oc-mirror` at all.

**Where:** `scripts/download-catalog-index.sh`, `scripts/extract-catalog-index.sh`

---

## Medium Priority

### oc-mirror v2 Load Failure: Replace `rm -rf mirror/data` With `aba clean` and Add FAQ

**Status:** Backlog
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

**Status:** Backlog
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

**Status:** Backlog
**Context:** `aba isconf` generates both `sync/imageset-config-sync.yaml` and `save/imageset-config-save.yaml`. Each target independently calls `add-operators-to-imageset.sh`, producing duplicate operator listings in the output. The user sees the same operator list printed twice, which looks like a bug.
**Fix options:**
- Suppress verbose operator output on the second run (e.g. a `--quiet` flag to `add-operators-to-imageset.sh`)
- Consolidate: generate one base config then copy/adapt for sync vs save
- Simply note in the first run's output that both configs are being generated

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

## Low Priority

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

**Status:** Backlog  
**Priority:** Low  
**Estimated Effort:** Small  
**Created:** 2026-02-21

**Problem:**
Suites rely on the next suite's `setup_aba_from_scratch()` to clean up. There is no per-suite teardown. Issues:
- Running a single suite leaves state behind on conN
- The last suite in `--all` leaves state behind
- `suite-cluster-ops` and `suite-network-advanced` don't call `setup_aba_from_scratch` and could be affected by prior suite state
- `cleanup_all()` in `test/e2e/lib/setup.sh` is dead code (never called)

**Action:** Remove dead `cleanup_all()` or wire it into a teardown hook. Consider adding per-suite cleanup.

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
