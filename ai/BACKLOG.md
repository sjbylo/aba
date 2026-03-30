# ABA Backlog

## Bug: CLI flags silently ignored via `aba cluster` when cluster.conf exists

**Two code paths exist, only one works:**

**Path A (WORKS): `aba -d mycluster -I proxy install`**
- `-d mycluster` does `cd mycluster/` in the first pass (aba.sh line 82)
- `-I proxy` finds `cluster.conf` in CWD, calls `replace-value-conf` directly
- All flags work correctly in this path

**Path B (BROKEN): `aba cluster -n mycluster -I proxy`**
- No `-d`, CWD stays as ABA root during flag parsing
- All flags fall to `BUILD_COMMAND` (the `else` branch)
- `BUILD_COMMAND` reaches `setup-cluster.sh` which calls `create-cluster-conf.sh`
- `create-cluster-conf.sh` line 21: `[ -s cluster.conf ] && exit 0` -- exits immediately, ignoring all values

**ALL flags have this bug in Path B** (not just `int_connection`):
- `api_vip` (aba.sh line 542)
- `ingress_vip` (line 569)
- `master_cpu` (line 681)
- `master_mem` (line 693)
- `worker_cpu` (line 705)
- `worker_mem` (line 717)
- `starting_ip` (line 729)
- `data_disk` (line 741)
- `int_connection` (line 771)
- `num_workers` (line 833)
- `num_masters` (line 844)
- `vlan` (line 859)
- `ssh_key_file` (line 871)
- `http_proxy`/`https_proxy` (line 883)
- `no_proxy` (line 896)

**Proposed fix options:**
- **Option 1**: In `setup-cluster.sh`, after `$create_cluster_cmd`, apply all non-empty CLI-passed values to existing `cluster.conf` via `replace-value-conf`
- **Option 2**: Rework `create-cluster-conf.sh` to not exit early, and instead merge CLI values into existing `cluster.conf`
- **Option 3**: Make `aba.sh` detect the cluster subdir path and `cd` into it before flag parsing so Path A logic handles it

**Design principle**: `aba.conf` and `mirror.conf` support updating values via CLI flags at any time. `cluster.conf` should work the same way.

**References:**
- `aba.sh` lines 58-104: first pass does `cd` for `-d` before flag parsing
- `aba.sh` lines ~530-900: all flag handlers with `if [ -f cluster.conf ]` pattern
- `setup-cluster.sh` lines 28-30: commented-out code showing prior rejection of full overwrite
- `create-cluster-conf.sh` line 21: `[ -s cluster.conf ] && exit 0` (early exit on existing file)
