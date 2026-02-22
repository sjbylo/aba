# E2E Test Framework -- Plan & Status

## Golden VM Provisioning

### Design

Replace the old per-pool "clone template + full setup" flow with a two-tier
approach: build one **golden VM** from the template, snapshot it, then
linked-clone all pool VMs from that snapshot.

### Phases

| Phase | What | Where | Duration |
|-------|------|-------|----------|
| 0 | Build/refresh golden VM | `prepare_golden_vm()` in `pool-lifecycle.sh` | ~5-10 min (first build) |
| 1 | Clone conN/disN from golden snapshot | `create_pools()` Phase 1 | ~15s per clone |
| 2 | Lightweight per-pool config | `create_pools()` Phase 2 (parallel) | ~2-5 min per pool |

### Golden VM setup steps (Phase 0, new build)

1. `clone_vm` from raw template
2. `_vm_setup_ssh_keys` -- root authorized_keys
3. `_vm_fix_proxy_noproxy` -- fix no_proxy for lab
4. `_vm_setup_firewall` -- firewalld + NAT masquerade + ip_forward
5. `_vm_setup_time` -- chrony/NTP + timezone
6. `_vm_dnf_update` -- `dnf clean all && dnf update -y` + reboot
7. `_vm_cleanup_caches` -- remove agent cache, old binaries, oc-mirror cache
8. `_vm_cleanup_podman` -- prune images + remove storage
9. `_vm_cleanup_home` -- remove stale dirs from home
10. `_vm_create_test_user` -- create `testy` with sudo, SSH key, SELinux context
11. `_vm_set_aba_testing` -- set `ABA_TESTING=1` in bashrc for root/steve/testy
12. `_vm_verify_golden` -- sanity checks (SSH, sudo, ABA_TESTING, firewalld, chrony)
13. Power off + snapshot `golden-ready` + write stamp file

### Golden VM refresh steps (snapshot exists, age > 24h)

1. Revert to `golden-ready` snapshot + power on
2. `_vm_dnf_update` -- catch up packages
3. `_vm_cleanup_caches`
4. `_vm_verify_golden`
5. Power off + re-snapshot + update stamp

### Per-pool config (Phase 2)

**conN (connected bastion):**
- `_vm_dnf_update` + `_vm_wait_ssh`
- `_vm_setup_network` (ens192/ens224.10/ens256 + static VLAN IP)
- `_vm_setup_dnsmasq` (DNS for pN.example.com)
- Signal disN that conN is ready
- `_vm_setup_vmware_conf`, `_vm_cleanup_caches`, `_vm_verify_golden`
- `_vm_install_aba` (git clone aba + ./install on bastion)

**disN (disconnected bastion):**
- `_vm_setup_network` (ens192/ens224.10, no ens256)
- Wait for conN's dnsmasq signal
- `_vm_setup_vmware_conf`, `_vm_cleanup_caches`, `_vm_verify_golden`
- `_vm_remove_pull_secret`, `_vm_remove_proxy`
- `_vm_disconnect_internet` (remove ens256 default route)

### Key implementation notes

- **`set -e` in bash conditionals**: Bash suppresses `set -e` inside subshells
  that are part of `if`/`||`/`&&` constructs. `prepare_golden_vm` is called
  outside any conditional context: the subshell runs bare, and `$?` is captured
  on the next line for manual error checking.

- **`_vm_wait_ssh` after disruptive steps**: `_vm_setup_ssh_keys` restarts sshd
  and `_vm_setup_firewall` reloads firewalld, both of which temporarily break
  SSH. Explicit `_vm_wait_ssh` calls follow these steps.

- **`dnf clean all` before `dnf update`**: Cloned VMs inherit the template's
  stale dnf metadata cache. Without `dnf clean all`, dnf reports "Nothing to do"
  because it trusts the cached metadata.

- **Staleness**: `~/.cache/aba-e2e/<name>.stamp` stores the epoch of the last
  snapshot. Reuse if < `GOLDEN_MAX_AGE_HOURS` (default 24h). `--rebuild-golden`
  forces a full teardown.

## Current status

- [x] `prepare_golden_vm` implemented (new build + refresh paths)
- [x] `create_pools` Phase 0 integration
- [x] `create_pools` Phase 1 clones from golden snapshot
- [x] `create_pools` Phase 2 lightweight per-pool config
- [x] `--rebuild-golden` CLI flag in `run.sh`
- [x] 24h staleness check with stamp file
- [x] `dnf clean all` before `dnf update`
- [x] `set -e` subshell fix (bare subshell, no conditional context)
- [x] `_vm_wait_ssh` after sshd/firewall disruptions
- [x] `_vm_create_test_user` uses bastion's `id_rsa.pub` + restorecon + AllowUsers
- [x] End-to-end verification (golden build completes without errors)
- [x] Verify Phase 1 + Phase 2 produce working pool (suite run)

## Backlog

- [ ] Rename `CATALOG_CACHE_TTL_SECS` to `CATALOG_CACHE_TTL_MINS`
- [x] Reduce clone_vm MAC address warning noise for golden VMs (downgraded to info)
- [ ] Consider `set -o pipefail` in `prepare_golden_vm` for pipeline error detection
- [ ] Audit remaining `2>/dev/null || true` suppressions across all `_vm_*` helpers
