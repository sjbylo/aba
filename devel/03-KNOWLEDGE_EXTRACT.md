# Knowledge Extract

Extracted from ~1,180 Cursor plans, ai/*.md docs, and .cursor/rules/ on 2026-04-20.
One-time distillation for input to devel/01-SPEC.md and devel/adr/.
This file is a working artifact -- once knowledge flows into SPEC.md, ADRs, and
script contracts, this file becomes historical reference.

---

## Invariants

Things that must always be true in a correct ABA system.

1. **Config files are the single source of truth.** `aba.conf`, `mirror.conf`,
   `cluster.conf` are authoritative. CLI flags write TO config; scripts read FROM
   config. Never infer settings from file presence (e.g. `vmware.conf` existing
   does not mean `platform=vmw`). The `platform=` variable in `aba.conf` drives
   conditional loading of `vmware.conf`/`kvm.conf`.
   *Sources: DECISIONS.md, RULES_OF_ENGAGEMENT.md, rules-of-engagement.mdc,
   spec-driven plan*

2. **Scripts are called only via Make targets or `aba` CLI -- never directly.**
   Direct calls bypass Make's dependency tracking and marker management. There is
   a backlog item to add a runtime guardrail (env var check) that aborts scripts
   invoked outside of Make/aba.
   *Sources: RULES_OF_ENGAGEMENT.md, scripts-must-not-manage-markers plan*

3. **Makefiles own marker files.** Scripts must not `touch`/`rm` `.available`,
   `.unavailable`, `.init`, `.installed` markers -- that is the Makefile's job.
   *Sources: RULES_OF_ENGAGEMENT.md, scripts-must-not-manage-markers plan*

4. **Make targets must keep working directly.** Every workflow must remain
   invocable as `make -C <dir> <target>`; essential logic must not live only in
   `aba.sh`.
   *Sources: RULES_OF_ENGAGEMENT.md, ARCHITECTURE_VISION.md*

5. **`$ABA_ROOT` is only for `aba.sh` and `abatui.sh`.** All other scripts use
   relative paths. Test: `test/func/test-aba-root-only-in-aba-sh.sh`.
   *Sources: DECISIONS.md, RULES_OF_ENGAGEMENT.md*

6. **Only `run_once()` may access `~/.aba/runner/`.** No hand-rolled locks/PIDs.
   *Sources: RULES_OF_ENGAGEMENT.md*

7. **`normalize*()` outputs only config values/defaults.** Derived/computed values
   (e.g. `regcreds_dir`) belong in the calling script, not in normalize functions.
   *Sources: RULES_OF_ENGAGEMENT.md*

8. **After `mirror load` or `mirror sync`, always run `aba day2`.** This applies
   IDMS/ITMS/CatalogSources from oc-mirror output. Without it, image pulls fail.
   *Sources: RULES_OF_ENGAGEMENT.md, HANDOFF_CONTEXT.md*

9. **`aba bundle --out -` keeps stdout as pure tar.** All human output goes to
   stderr on that path.
   *Sources: RULES_OF_ENGAGEMENT.md*

10. **Three operator catalogs only.** `redhat-operator`, `certified-operator`,
    `community-operator`. The `redhat-marketplace` catalog was deliberately
    removed and must not return.
    *Sources: DECISIONS.md*

11. **Incremental mirror: save minimal, load full.** `save` uses a minimal
    imageset (new operators only); `load` uses the full imageset so the
    catalog/OperatorHub stays complete.
    *Sources: save-b_load-ab_refactor plan, OC-MIRROR-INTERNALS.md*

12. **Disconnected hosts must not assume internet.** Everything required must be
    in the bundle/repo the user transferred.
    *Sources: HANDOFF_CONTEXT.md*

13. **Uninstall from the same host that installed.** Registry installed from conN
    must be uninstalled from conN.
    *Sources: RULES_OF_ENGAGEMENT.md*

14. **`reg-save.sh` must source `normalize-mirror-conf`.** Without it, `data_dir`
    from `mirror.conf` is silently ignored and oc-mirror defaults to `$HOME`.
    *Sources: reg-save_mirror-conf_fix plan*

15. **Bundle builds must `unset OC_MIRROR_SINCE`.** Differential saves are wrong
    for the bundle pipeline; the shared oc-mirror cache needs full archives.
    *Sources: bundle_dir_restructure plan, DECISIONS.md*

---

## Design Decisions

Why X was chosen over Y.

1. **Keep Make for artifact/dependency graphs; avoid Make for orchestration.**
   Make excels at file-based dependencies -- e.g. "download oc-mirror tarball,
   then extract binary, then mark as available." These are `cli/`, `mirror/`, and
   `cluster-dir/` workflows where inputs and outputs are files on disk.
   "Orchestration paths" are things like the TUI wizard, the `aba` CLI's flag
   parsing and dispatch, or the E2E test dispatcher -- code paths that coordinate
   user interaction and workflow ordering but don't produce file artifacts. These
   don't benefit from Make's dependency graph.
   *Sources: ARCHITECTURE_VISION.md, MAKEFILE_SIMPLIFICATION.md*

2. **`run_once` complements Make -- they solve different problems.** Make tracks
   file dependencies: "if output is newer than input, skip." `run_once` tracks
   task completion for operations whose results are NOT files -- e.g. "is the
   connectivity check done?", "has the CLI tarball download started?" It provides:
   (a) mutual exclusion so two `aba` commands don't run the same task twice,
   (b) a "start now, wait later" pattern where a slow download kicks off early
   and a later step blocks until it finishes, and (c) cached exit status and
   stderr for error reporting. The tradeoff: `run_once` tracks state in
   `~/.aba/runner/`, which is separate from Make's file-based tracking. If you
   `rm` a file that Make produced but `run_once` wrapped, `run_once` still thinks
   the task is done. Cleanup must use `run_once -r <id>` alongside `rm`.
   *Sources: DECISIONS.md, RUN_ONCE_RELIABILITY.md*

3. **No automatic cleanup of `run_once` state on Ctrl-C.** Earlier versions had
   a Ctrl-C trap that wiped `~/.aba/runner/` state, but this caused more problems
   than it solved (partial cleanups, races). Now, `run_once` state persists across
   interrupts. If the user needs a full reset, they run `aba reset` explicitly.
   Failed tasks are cleaned on the next `aba` invocation via `run_once -F`.
   *Sources: DECISIONS.md*

4. **`OC_MIRROR_FLAGS` uses `${VAR-default}` not `${VAR:-default}`.** Unset means
   use default (`--remove-signatures=true`); empty string means user intentionally
   disabled flags.
   *Sources: fix_stale_aba_config plan*

5. **Re-source `~/.aba/config` on each retry iteration.** Live edits to config
   during long mirror retries take effect without restart.
   *Sources: fix_stale_aba_config plan*

6. **Podman-based catalog extraction replaces `oc-mirror list operators`.**
   All-in on podman; `insecureAcceptAnything` for pulls; metadata files `.done` /
   `.expected-count`; generic JSON fallback; canary tests for pre-GA catalogs.
   *Sources: PODMAN_CATALOG_EXTRACTION.md*

7. **oc-mirror exit codes are a bitmask** (1=generic, 2=release, 4=operator,
   8=additional, 16=helm). OR'd together. Category doesn't imply transient vs
   permanent. Retry policy treats non-zero as retryable.
   *Sources: OC-MIRROR-INTERNALS.md*

8. **Documentation in code, not separate files.** Comments in code are the primary
   source of truth -- they stay co-located and don't drift.
   *Sources: RULES_OF_ENGAGEMENT.md*

9. **Runner dir permissions: 711 for dirs, 644 for PID files.** So other users'
   wait paths can read PIDs. Deliberate 711 vs 700 tradeoff.
   *Sources: RUN_ONCE_RELIABILITY.md*

10. **`reg-save` skips `verify-mirror-conf`.** Save targets disk (`file://.`), not
    a registry. Full mirror validation would fail in connected-only phases.
    *Sources: reg-save_mirror-conf_fix plan*

11. **Selective `[ABA]` prefix.** Only operational messages, not banners or
    instructions.
    *Sources: DECISIONS.md*

---

## Gotchas

Things that broke and must not break again.

1. **`exit` inside functions sourced by TUI kills the whole TUI.** Same class:
   `aba_abort` in TUI context. Use dialogs and `return` instead.
   *Sources: ARCHITECTURE_VISION.md, RULES_OF_ENGAGEMENT.md*

2. **`(( var++ ))` under `set -e` crashes when var is 0.** `(( 0 ))` returns
   exit code 1. Use `var=$(( var + 1 ))`.
   *Sources: rules-of-engagement.mdc*

3. **`pre-commit-checks.sh` runs `git pull` which can overwrite local changes.**
   Always re-diff after running it.
   *Sources: rules-of-engagement.mdc*

4. **ESXi `killall` kills system processes.** BusyBox `killall` matches broadly.
   The 2026-04-14 incident killed hostd/vpxa/SSH on two hosts, requiring DCUI
   console access and full reboots. Only kill specific PIDs.
   *Sources: esxi-safety.mdc*

5. **`govc host.disconnect` breaks vCenter reconnection.** Causes EVC errors.
   Use vpxa restart instead.
   *Sources: esxi-safety.mdc*

6. **ESXi memory overcommit causes OOM in VMs.** Balloon driver can leave a 32GB
   VM with ~3.8GB physical memory. Check `govc host.info` / `govc vm.info -r`.
   *Sources: esxi-memory-overcommit.mdc*

7. **Parallel `run_once -w` start race.** Probe lock released too early caused
   false failures and empty error logs. Fix: hold lock into `_start_task`.
   *Sources: RUN_ONCE_WAIT_MODE_RACE_FIX.md*

8. **`ensure_oc_mirror` extracted before download finished.** After aggressive
   resets, extract ran on a partial tarball. Fix: download wait before extract.
   *Sources: RUN_ONCE_WAIT_MODE_RACE_FIX.md, CLI_ENSURE_ANALYSIS.md*

9. **`eval \`cluster-config.sh || exit 1\``: exit runs in subshell.** Caller
   does not exit on failure. Prefer `if ! cmd; then` over disabling `set -e`.
   *Sources: DECISIONS.md, normalize_conf_set_a_refactor plan*

10. **`aba delete` masked failures with `|| exit 0`.** Broken symlinks returned
    false OK. `aba delete` must propagate errors.
    *Sources: fix_delete_error_masking plan, reliable_vm_delete plan*

11. **Moving VM lifecycle from Makefile to `aba.sh` dropped auto-symlink** of
    `vmware.conf`/`kvm.conf` into cluster dirs. Fix: `_ensure_hv_ready` recreates
    symlinks.
    *Sources: fix_vmware.conf_symlink_regression plan*

12. **Stale `~/.aba/config` without `OC_MIRROR_FLAGS`** plus empty default caused
    oc-mirror 4.21+ unsigned operator failures.
    *Sources: fix_stale_aba_config plan*

13. **`verify_conf=conf` early-exit skipped mirror `openshift-install` extract.**
    Caused SNO/sigstore failures. `oc adm release extract` must still run.
    *Sources: mirror_binary_regression_test plan*

14. **Brute `sudo rm -rf ~/quay-install`** fails on immutable SQLite attributes
    and hides broken uninstall logic. Use `aba uninstall`.
    *Sources: remove_brute-force_rm-rf plan*

15. **Stale `quay-postgres.service` from old mirror-registry** survived uninstall
    and crash-looped, breaking pasta port forwards.
    *Sources: QUAY_STALE_SERVICE_BUG.md*

16. **Rootless podman/pasta Quay without default route**: hairpin to own IP fails
    TLS. Workaround: temporary default route during pod creation.
    *Sources: QUAY_PASTA_HAIRPIN.md*

17. **`$(<file 2>/dev/null)` returns empty in bash.** Must check file existence
    first, then `$(<file)`.
    *Sources: RULES_OF_ENGAGEMENT.md, RUN_ONCE_RELIABILITY.md*

18. **Replacing sourced framework files via `scp` while bash is running** can
    corrupt the interpreter. Use `run.sh restart` or deploy only when idle.
    *Sources: DECISIONS.md, E2E_PROPOSED_CORE_CHANGES.md*

19. **`chmod 700 /root` is required for SSH pubkey auth.** Wider permissions
    (e.g. 777 from careless provisioning) break sshd's strict checks.
    *Sources: vm-helpers.sh fix (this session)*

---

## Future Constraints

Things the spec should enforce going forward.

1. **Audit and fix `exit 0` endings.** Many scripts end with `exit 0` which masks
   the real exit code of the last command. Under the ERR trap (`set -e` behavior),
   a failing command would normally propagate its non-zero exit code -- but a
   trailing `exit 0` overrides that and reports success. Pre-commit should flag
   new `exit 0` terminators in `scripts/*.sh`.
   *Sources: audit-exit-codes plan, BACKLOG.md*

2. **Add runtime guardrail for direct script execution.** Scripts under `scripts/`
   should detect when they are invoked directly (not via Make or `aba`) and abort
   with a clear error. Implementation: env var check (`ABA_CALLED_VIA_MAKE` or
   `ABA_CALLED_VIA_ABA`), enforced in `include_all.sh`.
   *Sources: backlog item added 2026-04-20*

3. **Refactor `normalize-*-conf` with `set -a` and shared parser.** Phased:
   internal cleanup first, caller migration later.
   *Sources: normalize_conf_set_a_refactor plan*

4. **Per-operation flock** for concurrent `aba mirror save/sync/load/install/bundle`.
   Currently no locking exists between these operations; concurrent runs can
   corrupt shared state (oc-mirror workspace, registry data).
   *Sources: CONCURRENCY_PROTECTION.md*

5. **Replace dot-wait loops with `aba_wait_show`** across all scripts.
   *Sources: BACKLOG.md*

6. **Externalize installed-cluster VM metadata** to `~/.aba/clusters/<name>/state.sh`
   for robust `aba delete` when cluster dir is cleaned.
   *Sources: BACKLOG.md, reliable_vm_delete plan*

7. **Warn on mirror identity field changes** when registry already installed
   (`reg_host`/`reg_port`/`reg_vendor`).
   *Sources: BACKLOG.md*

8. **`install-config.yaml` Make deps** should include `aba.conf` and the J2
   template so edits trigger rebuilds.
   *Sources: aba_codebase_investigation_report plan*

9. **Promote `bundles/v2/` to `bundles/`** after v1 removal.
   *Sources: BACKLOG.md*
