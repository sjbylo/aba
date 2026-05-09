# ADR-007: Unified state management for installed objects

## Status
Accepted

## Context
ABA stores mirror credentials externally (~/.aba/mirror/) but has no
equivalent for clusters. When a cluster working dir is deleted or config
is edited after install, ABA loses track of installed VMs (can't delete,
can't SSH). Config files serve dual duty as both desired state and
installed state, causing confusion when they drift apart.

ADR-001 established config files as the single source of truth. This
refines that: config files are authority for *desired* state; state.sh
is authority for *installed* state.

## Decision
Externalize installed-object state to ~/.aba/ for both mirrors and clusters:

- state.sh files use lowercase vars (same names as config files)
- Normalize functions source state.sh after config, override immutable
  fields, warn on drift via stderr
- Immutable fields (locked after install): reg_host, reg_port, reg_vendor,
  reg_root, reg_user, reg_pw (mirror); cluster_name, base_domain,
  starting_ip, cluster_type, machine_network, platform (cluster)
- Mutable fields: ops, op_sets (mirror, in aba.conf/mirror.conf)
- Config backups stored in backup/ subdir (cp -p for timestamps)
- Deleted cluster dirs are recreated from state backup on demand
- All cluster state dirs are mode 700 (contain kubeconfig)
- Convenience symlinks (clusterstate, regcreds) for humans; scripts use
  helper functions (cluster_state_dir(), cluster_kubeconfig(), etc.)

## Consequences
- Clusters survive working dir deletion (delete, startup, shutdown still work)
- Config drift is detected and reported (not silent)
- Old CAPS state.sh files from previous mirror installs require reinstall
- Slightly more disk usage (~/.aba/clusters/ stores config backups)
- aba reset does NOT delete ~/.aba/clusters/ (state is external)
