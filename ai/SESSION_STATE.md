# Session state

## Current goal
E2E testing on dev branch — gotest monitoring loop (8 hours).

## Done this session
- run_once pattern refactoring: renamed TASK_* vars, added -A flag, fixed download/install race (ADR-008)
- ESXi network comments consolidated, e2e deploy vmware.conf fix, branch sync after -V revert
- Committed and pushed both to dev (3 commits: run_once refactor, ESXi/e2e infra, session state)

## E2E Status (last check: 00:25 UTC+8)
- **9 suites PASS**: create-bundle-to-disk, config-validation, cli-validation, cluster-ops, connected-public, state-management, upgrade, vsphere-preflight, negative-paths
- **3 RUNNING**: airgapped-local-reg (con1, upgrade step), airgapped-existing-reg (con3, compact install), mirror-sync (con4, docker install)
- **1 PAUSED**: network-advanced (con2) — "VM Network not found" (ESXi MOB quirk, not code bug)
- **2 PENDING**: kvm-lifecycle, vmw-lifecycle

### con2 PAUSED investigation
- `govc: network 'VM Network' not found` during `aba refresh` for e2e-sno2
- `host.portgroup.info` confirms VM Network exists (2 active ports)
- `govc find / -type Network` only sees Lab Network + Private Network
- Root cause: Known ESXi MOB visibility issue. VM Network not registered in MOB.
- Fix: Recreate VM Network via ESXi web UI (see Troubleshooting.md)
- Suite was testing Non-VLAN SNO bonding which requires VM Network

## Next steps
- Continue monitoring E2E suites
- When suites complete and pools free up, dispatcher will auto-start pending suites
- con2 blocked until VM Network ESXi infra issue is resolved (user action needed)

## Decisions / notes
- Phase D (cli-install-all.sh --wait split) cancelled — already safe
- Phase E, G are low-priority consistency — skipped for now
