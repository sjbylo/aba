# run_once Task ID Audit (TUI v2 + core)

Scope: `tui/v2/*.sh`, `scripts/aba.sh`, `scripts/include_all.sh`, `scripts/prefetch-catalogs.sh`.  
Generated for the TUI v2 UX gap fixes batch; no code changes in this doc.

Convention: **`shared`** = same task ID appears in both `scripts/aba.sh` (and/or core helpers in `include_all.sh`) **and** TUI v2, so caches are interchangeable.

---

## Inventory by task ID

| Task ID | File(s) | Shared with CLI/core? |
|--------|---------|------------------------|
| *(none)* `run_once -F` purge | `scripts/aba.sh`, `scripts/include_all.sh` (`aba_bg_cleanup`) | N/A |
| `ocp:stable:latest_version` | `scripts/aba.sh`, `tui-direct.sh`, `scripts/include_all.sh` (`aba_version_fetch_start`) | Yes |
| `ocp:stable:latest_version_previous` | `scripts/aba.sh`, `scripts/include_all.sh` | Yes |
| `ocp:fast:latest_version` | `scripts/aba.sh`, `scripts/include_all.sh` | Yes |
| `ocp:fast:latest_version_previous` | `scripts/aba.sh`, `scripts/include_all.sh` | Yes |
| `ocp:candidate:latest_version` | `scripts/aba.sh`, `scripts/include_all.sh` | Yes |
| `ocp:candidate:latest_version_previous` | `scripts/aba.sh`, `scripts/include_all.sh` | Yes |
| `ocp:${channel}:latest_version` | `tui-direct.sh` (stable/fast/candidate) | Yes *(same canonical strings as rows above)* |
| `ocp:${channel}:latest_version_previous` | `tui-direct.sh` | Yes |
| `ocp:${channel}:latest_version_older` | `tui-direct.sh`, `scripts/include_all.sh` | Yes *(aba.sh does not prefetch “older”; TUI/start helper does)* |
| `cli:install:oc-mirror` (`TASK_OC_MIRROR`) | `scripts/aba.sh`, `scripts/include_all.sh` | Yes |
| `mirror:reg:install` (`TASK_QUAY_REG`) | `scripts/aba.sh` | Core only *(TUI invokes make/aba indirectly, not this line)* |
| `mirror:reg:download` (`TASK_QUAY_REG_DOWNLOAD`) | `scripts/aba.sh`, `tui-direct.sh` | Yes |
| *(script)* catalog prefetch wrapper | `scripts/prefetch-catalogs.sh` — pull secret/auth then `aba_prefetch_catalogs` | Shares `catalog:*` with core/TUI |
| `tui:prefetch:catalogs` | *(removed)* — replaced by `(aba_prefetch_catalogs &) ` in `tui/abatui2.sh` | — |
| `aba:isconf:generate` | `tui-lib.sh`, `tui-mirror.sh` | Yes *(same ID as `aba_isconf_generate_start` in `include_all.sh`)* |
| `catalog:${version_short}:redhat-operator` | `tui-direct.sh`, `tui-lib.sh` (`tui_ensure_catalogs_ready`), `scripts/include_all.sh` (`download_all_catalogs`) | Yes |
| `catalog:${version_short}:certified-operator` | `tui-lib.sh`, `scripts/include_all.sh` | Yes |
| `catalog:${version_short}:community-operator` | `tui-lib.sh`, `scripts/include_all.sh` | Yes |
| `cli:download:openshift-install:${ocp_version}` | `tui-mirror.sh` | Parity with core download path IDs |
| `aba:check:internet` | `scripts/include_all.sh` *(inet helpers)* | Core/TUI indirect |
| `aba:check:api.openshift.com` | `scripts/include_all.sh` | Prefix-scoped probes |
| `aba:check:mirror.openshift.com` | `scripts/include_all.sh` | Prefix-scoped probes |
| `aba:check:registry.redhat.io` | `scripts/include_all.sh` | Prefix-scoped probes |
| `${prefix}:check:*` | `scripts/include_all.sh` (`check_internet_connectivity`) | Prefix from caller; **`aba`** is the shared CLI+TUI choice (ABA v2 UX batch) |
| `aba:mirror:check-image` | `scripts/include_all.sh` | Core helpers |
| `cli:download:oc-mirror` | `scripts/include_all.sh` | Core |
| `cli:download:oc:${ocp_version}` | `scripts/include_all.sh` | Core |
| `cli:download:openshift-install:${ocp_version}` | `scripts/include_all.sh` | Core |
| `cli:download:govc` | `scripts/include_all.sh` | Core |
| `cli:download:butane` | `scripts/include_all.sh` | Core |
| `cli:install:*` (`TASK_OC`, `TASK_GOVC`, `TASK_BUTANE`, etc.) | `scripts/include_all.sh` | Core |

Files with **no** `-i`/`-w` task literals (comments only): `tui-cluster.sh`, `tui-disco.sh`, `tui-strings2.sh`.

---

## Inconsistencies and notes

1. **`ocp:stable:latest_version` vs channel-specific IDs**  
   `tui-direct.sh` occasionally waits on **`ocp:stable:latest_version`** during pull-secret onboarding even when the user’s channel is not stable. That duplicates the **`ocp:${ocp_channel}:latest_version`** pipeline but stays **consistent** because the stable ID is intentionally used as a bootstrap for catalog hinting when patch version is missing.

2. **`aba.sh` prefetch vs TUI prefetch**  
   `aba_version_fetch_start` in `include_all.sh` kicks off `latest` / `previous` / `older` for stable, fast, and candidate. **`older`** is prefetched via `run_once` in TUI start but **not** started in `aba.sh` initial block (non-blocking divergence of *scope*, not conflicting IDs).

3. **ISC generator command wording**  
   `aba_isconf_generate_start` uses `aba -d mirror isconf` while some TUI paths use `aba isconf -d mirror`. Same **`aba:isconf:generate`** ID; callers should remain equivalent wrappers (not an ID clash).

4. **`check_internet_connectivity` prefix (`cli` vs `aba`)**  
   Historical `scripts/aba.sh` used **`check_internet_connectivity "cli"`** while `check_internet_connectivity "aba"` and `aba_inet_*` used **`aba:check:*`**. Same logical probes but **separate caches** → fixed in core by standardizing **`aba`** (this batch).

5. **`mirror:reg:install` naming**  
   Task constant `$TASK_QUAY_REG` resolves to **`mirror:reg:install`**; download is **`mirror:reg:download`**. Naming is asymmetric but deliberate (install vs tarball download).

6. **No canonical `latest_z:${channel}:${minor}` run_once task**  
   `fetch_latest_z_version` uses **`_fetch_graph_cached`** file cache under **`$ABA_CACHE_DIR`**, **not** `run_once -o`. Adding a **`run_once -o`** path would require paired **`run_once -i`** writers; none existed at audit time.

---

## Summary

- TUI v2 aligns with **`ocp:*:latest_*`**, **`catalog:*`**, **`aba:isconf:generate`**, **`mirror:reg:download`**, **`cli:download:openshift-install:*`** — these match or extend core caches.  
- The only notable **dual-prefix** friction was **`cli:check:*` vs `aba:check:*`** for connectivity; aligning **`aba`** removes split caches.  
- **`tui:prefetch:catalogs`** was a TUI-only shell wrapper; consolidating logic into **`aba_prefetch_catalogs`** drops the extra task boundary while catalog **`catalog:*`** tasks remain canonical.
