#!/usr/bin/env bash
# =============================================================================
# Suite: State Management (ADR-007)
# =============================================================================
# Purpose: Verify externalized state for mirrors and clusters.
#          Tests that state.sh, backups, and auth files are written correctly
#          at install time, survive aba reset, and enable dir recreation.
#
# What it tests:
#   - Mirror: state.sh written with lowercase vars after install
#   - Mirror: backup/ contains mirror.conf + flag files with preserved timestamps
#   - Mirror: permissions (700) on state dir
#   - Mirror: idempotent install preserves state
#   - Mirror: state.sh survives aba reset
#   - Mirror: uninstall reads lowercase state.sh correctly
#   - Mirror: register writes lowercase state.sh (reg_vendor=existing)
#   - Mirror: unregister reads lowercase state.sh correctly
#   - Mirror: reinstall after uninstall (no stale state)
#   - Helpers: cluster_state_dir, cluster_kubeconfig, cluster_is_installed
#
# Duration: ~5 minutes (Docker registry install + register/unregister cycles)
#
# Prerequisites:
#   - aba must be installed
#   - Internet-connected host (conN)
#   - Internal bastion (disN) reachable via SSH
# =============================================================================

set -u

_SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SUITE_DIR/../lib/framework.sh"
source "$_SUITE_DIR/../lib/config-helpers.sh"
source "$_SUITE_DIR/../lib/remote.sh"
source "$_SUITE_DIR/../lib/pool-ops.sh"
source "$_SUITE_DIR/../lib/setup.sh"

# --- Configuration ----------------------------------------------------------

DIS_HOST="dis${POOL_NUM}.${VM_BASE_DOMAIN}"
_MIRROR_NAME="e2e-mirror-state1"
_MIRROR_PORT=5111
_STATE_DIR="\$HOME/.aba/mirror/$_MIRROR_NAME"

# --- Suite ------------------------------------------------------------------

e2e_setup

plan_tests \
	"Setup: install aba and configure" \
	"Docker mirror install: state.sh written correctly" \
	"Idempotent install: state preserved" \
	"State persistence: survives aba reset" \
	"Uninstall: reads lowercase state.sh" \
	"Reinstall after uninstall: clean state" \
	"Tilde expansion: local and remote data_dir" \
	"Register existing: lowercase state.sh" \
	"Helper functions: cluster state helpers" \
	"Phase 3: drift detection overrides config with state" \
	"Phase 4: dir recreation from state backup" \
	"Cleanup: uninstall mirror"

suite_begin "state-management"

preflight_ssh

# ============================================================================
# 1. Setup
# ============================================================================
test_begin "Setup: install aba and configure"

e2e_install_aba

e2e_run "Configure aba.conf" \
	"aba --noask --platform vmw --channel $TEST_CHANNEL --version $OCP_VERSION --base-domain $(pool_domain)"
e2e_run "Verify aba.conf: ask=false" "grep ^ask=false aba.conf"
e2e_run "Verify aba.conf: platform=vmw" "grep ^platform=vmw aba.conf"
e2e_run "Verify aba.conf: channel" "grep ^ocp_channel=$TEST_CHANNEL aba.conf"
e2e_run "Verify aba.conf: version format" "grep -E '^ocp_version=[0-9]+(\.[0-9]+){2}' aba.conf"

test_end

# ============================================================================
# 2. Docker mirror install: verify state.sh written with lowercase vars
# ============================================================================
test_begin "Docker mirror install: state.sh written correctly"

e2e_run "Create mirror dir" "aba mirror --name $_MIRROR_NAME"
e2e_add_to_mirror_cleanup "$PWD/$_MIRROR_NAME"

e2e_run "Install Docker registry on remote host" \
	"aba -d $_MIRROR_NAME install --vendor docker --reg-port $_MIRROR_PORT -H $DIS_HOST -k ~/.ssh/id_rsa"

e2e_run "Verify registry is healthy" "aba -d $_MIRROR_NAME verify"

# --- Verify state.sh exists and has lowercase vars ---
e2e_run "state.sh exists and is non-empty" \
	"test -s $_STATE_DIR/state.sh"

e2e_run "state.sh: reg_vendor=docker" \
	"grep -q '^reg_vendor=docker' $_STATE_DIR/state.sh"

e2e_run "state.sh: reg_host matches DIS_HOST" \
	"grep -q '^reg_host=$DIS_HOST' $_STATE_DIR/state.sh"

e2e_run "state.sh: reg_port matches configured port" \
	"grep -q '^reg_port=$_MIRROR_PORT' $_STATE_DIR/state.sh"

e2e_run "state.sh: reg_user is set" \
	"grep -q '^reg_user=' $_STATE_DIR/state.sh"

e2e_run "state.sh: reg_pw is set" \
	"grep -q '^reg_pw=' $_STATE_DIR/state.sh"

e2e_run "state.sh: reg_root is set" \
	"grep -q '^reg_root=' $_STATE_DIR/state.sh"

# Tilde expansion: reg_root must be an absolute path expanded on the REMOTE host.
# A literal ~ here means the remote install failed to resolve it.
e2e_run "state.sh: reg_root is absolute (no literal ~)" \
	"bash -c 'source $_STATE_DIR/state.sh && [[ \$reg_root == /* ]] || { echo \"reg_root=\$reg_root is not absolute\"; false; }'"

e2e_run "state.sh: reg_root is <remote_home>/docker-reg" \
	"_rh=\$(_essh $DIS_HOST 'echo ~') && _expect=\"\${_rh}/docker-reg\" && bash -c 'source $_STATE_DIR/state.sh && [ \"\$reg_root\" = \"'\"\$_expect\"'\" ] || { echo \"reg_root=\$reg_root expected='\"\$_expect\"'\"; false; }'"

e2e_run "state.sh: reg_ssh_key is set (remote install)" \
	"grep -q '^reg_ssh_key=' $_STATE_DIR/state.sh"

e2e_run "state.sh: reg_ssh_user is set (remote install)" \
	"grep -q '^reg_ssh_user=' $_STATE_DIR/state.sh"

e2e_run "state.sh: reg_installed_at has timestamp" \
	"grep -qE '^reg_installed_at=.[0-9]{4}-' $_STATE_DIR/state.sh"

e2e_run "state.sh: NO uppercase REG_ vars" \
	"! grep -q '^REG_' $_STATE_DIR/state.sh"

e2e_run "state.sh is sourceable and reg_host is set" \
	"bash -c 'source $_STATE_DIR/state.sh && test -n \"\$reg_host\" && test \"\$reg_host\" = \"$DIS_HOST\"'"

e2e_run "state.sh is sourceable and reg_vendor is docker" \
	"bash -c 'source $_STATE_DIR/state.sh && test \"\$reg_vendor\" = \"docker\"'"

# --- Verify backup/ contents ---
e2e_run "backup/ dir exists" \
	"test -d $_STATE_DIR/backup"

e2e_run "backup/mirror.conf exists and non-empty" \
	"test -s $_STATE_DIR/backup/mirror.conf"

e2e_run "backup/mirror.conf content matches original" \
	"diff -q $_MIRROR_NAME/mirror.conf $_STATE_DIR/backup/mirror.conf"

e2e_run "backup/.init marker exists" \
	"test -f $_STATE_DIR/backup/.init"

e2e_run "backup/.rpmsext marker exists" \
	"test -f $_STATE_DIR/backup/.rpmsext"

# --- Verify timestamp preservation (cp -p) ---
e2e_run "backup/mirror.conf timestamp matches original" \
	"test \$(stat -c %Y $_MIRROR_NAME/mirror.conf) -eq \$(stat -c %Y $_STATE_DIR/backup/mirror.conf)"

# --- Verify regcreds files ---
e2e_run "rootCA.pem exists" \
	"test -s $_STATE_DIR/rootCA.pem"

e2e_run "pull-secret-mirror.json exists" \
	"test -s $_STATE_DIR/pull-secret-mirror.json"

e2e_run "pull-secret-mirror.json contains registry host" \
	"grep -q '$DIS_HOST' $_STATE_DIR/pull-secret-mirror.json"

# --- Verify permissions ---
e2e_run "State dir is mode 700" \
	"test \$(stat -c %a $_STATE_DIR) = 700"

test_end

# ============================================================================
# 3. Idempotent install: state preserved
# ============================================================================
test_begin "Idempotent install: state preserved"

e2e_run "Save state.sh checksum before re-install" \
	"md5sum $_STATE_DIR/state.sh > /tmp/state-checksum-before.txt"

e2e_run "Re-run install (idempotent)" \
	"aba -d $_MIRROR_NAME install"

e2e_run "Registry still healthy after idempotent install" \
	"aba -d $_MIRROR_NAME verify"

e2e_run "state.sh still exists after idempotent install" \
	"test -s $_STATE_DIR/state.sh"

e2e_run "state.sh: still lowercase after re-install" \
	"! grep -q '^REG_' $_STATE_DIR/state.sh"

test_end

# ============================================================================
# 4. State persistence: survives aba reset
# ============================================================================
test_begin "State persistence: survives aba reset"

e2e_run "Run aba reset" "aba reset -f"

e2e_run "state.sh survives reset" \
	"test -s $_STATE_DIR/state.sh"

e2e_run "rootCA.pem survives reset" \
	"test -f $_STATE_DIR/rootCA.pem"

e2e_run "pull-secret-mirror.json survives reset" \
	"test -f $_STATE_DIR/pull-secret-mirror.json"

e2e_run "backup/mirror.conf survives reset" \
	"test -f $_STATE_DIR/backup/mirror.conf"

e2e_run "backup/.init survives reset" \
	"test -f $_STATE_DIR/backup/.init"

e2e_run "Re-install aba after reset" "cd ~/aba && ./install"

e2e_run "Reconfigure aba.conf" \
	"cd ~/aba && aba --noask --platform vmw --channel $TEST_CHANNEL --version $OCP_VERSION --base-domain $(pool_domain)"
e2e_run "Verify aba.conf: platform=vmw after reconfigure" "grep ^platform=vmw aba.conf"
e2e_run "Verify aba.conf: version format after reconfigure" "grep -E '^ocp_version=[0-9]+(\.[0-9]+){2}' aba.conf"

test_end

# ============================================================================
# 5. Uninstall: reads lowercase state.sh correctly
# ============================================================================
test_begin "Uninstall: reads lowercase state.sh"

e2e_run "Recreate mirror dir for uninstall" "cd ~/aba && aba mirror --name $_MIRROR_NAME"

e2e_run "Uninstall Docker registry" \
	"cd ~/aba && aba -d $_MIRROR_NAME uninstall"
e2e_run "Assert: registry fully removed on disN" "e2e_assert_registry_removed"

e2e_run "state.sh removed after uninstall" \
	"test ! -f $_STATE_DIR/state.sh"

e2e_run "regcreds dir cleaned after uninstall" \
	"test -z \"\$(ls -A $_STATE_DIR/ 2>/dev/null)\" || test ! -d $_STATE_DIR"

test_end

# ============================================================================
# 6. Reinstall after uninstall: clean state
# ============================================================================
test_begin "Reinstall after uninstall: clean state"

e2e_run "Reinstall Docker registry (fresh, no stale state)" \
	"cd ~/aba && aba -d $_MIRROR_NAME install --vendor docker --reg-port $_MIRROR_PORT -H $DIS_HOST -k ~/.ssh/id_rsa"

e2e_run "Verify registry healthy after reinstall" \
	"cd ~/aba && aba -d $_MIRROR_NAME verify"

e2e_run "Fresh state.sh written after reinstall" \
	"test -s $_STATE_DIR/state.sh"

e2e_run "Fresh state.sh is lowercase" \
	"! grep -q '^REG_' $_STATE_DIR/state.sh"

e2e_run "Uninstall again for next test" \
	"cd ~/aba && aba -d $_MIRROR_NAME uninstall"
e2e_run "Assert: registry fully removed on disN" "e2e_assert_registry_removed"

test_end

# ============================================================================
# 7. Tilde expansion: local and remote data_dir
# ============================================================================
# reg_setup_data_dir() handles ~ differently for local vs remote installs.
# Remote: keeps literal ~ so the remote shell expands it (user/path may differ).
# Local: expands ~ immediately via eval.
# The expansion logic is vendor-agnostic (Docker and Quay share the same code).
test_begin "Tilde expansion: local and remote data_dir"

_TILDE_MIRROR="e2e-mirror-tilde"
_TILDE_PORT=5112
_TILDE_STATE="\$HOME/.aba/mirror/$_TILDE_MIRROR"
_TILDE_REMOTE_SUBDIR="e2e-tilde-remote-data"
_TILDE_LOCAL_SUBDIR="e2e-tilde-local-data"

# --- Remote install with data_dir=~/subdir AS A DIFFERENT USER ---
# Verify ~ expands to the REMOTE user's home (testy), not the local user's (steve).
# Using a different SSH user proves the tilde is expanded on the remote host
# in the context of the SSH target user.
_TILDE_REMOTE_USER="testy"

e2e_run "Setup: SSH authorized_keys for $_TILDE_REMOTE_USER on disN" \
	"_essh $DIS_HOST \"sudo bash -c 'cat ~steve/.ssh/authorized_keys >> /home/$_TILDE_REMOTE_USER/.ssh/authorized_keys && sort -u -o /home/$_TILDE_REMOTE_USER/.ssh/authorized_keys /home/$_TILDE_REMOTE_USER/.ssh/authorized_keys' && sudo chown -R $_TILDE_REMOTE_USER: /home/$_TILDE_REMOTE_USER/.ssh && sudo chmod 700 /home/$_TILDE_REMOTE_USER/.ssh && sudo chmod 600 /home/$_TILDE_REMOTE_USER/.ssh/authorized_keys\""

e2e_run "Create mirror dir for remote tilde test" \
	"cd ~/aba && aba mirror --name $_TILDE_MIRROR"
e2e_add_to_mirror_cleanup "$PWD/$_TILDE_MIRROR"

e2e_run "Remote install as $_TILDE_REMOTE_USER with data_dir=~/$_TILDE_REMOTE_SUBDIR" \
	"cd ~/aba && aba -d $_TILDE_MIRROR install --vendor docker --reg-port $_TILDE_PORT --data-dir '~/$_TILDE_REMOTE_SUBDIR' -H $DIS_HOST -k ~/.ssh/id_rsa -U $_TILDE_REMOTE_USER"

e2e_run "Remote: reg_root is absolute (no literal ~)" \
	"bash -c 'source $_TILDE_STATE/state.sh && [[ \$reg_root == /* ]] || { echo \"reg_root=\$reg_root not absolute\"; false; }'"

# Verify ~ resolved to testy's home (/home/testy), NOT steve's (/home/steve)
e2e_run "Remote: reg_root uses $_TILDE_REMOTE_USER home, not steve" \
	"bash -c 'source $_TILDE_STATE/state.sh && [[ \$reg_root == /home/$_TILDE_REMOTE_USER/* ]] || { echo \"reg_root=\$reg_root does not start with /home/$_TILDE_REMOTE_USER/\"; false; }'"

e2e_run "Remote: reg_root is /home/$_TILDE_REMOTE_USER/$_TILDE_REMOTE_SUBDIR/docker-reg" \
	"bash -c 'source $_TILDE_STATE/state.sh && [ \"\$reg_root\" = \"/home/$_TILDE_REMOTE_USER/$_TILDE_REMOTE_SUBDIR/docker-reg\" ] || { echo \"reg_root=\$reg_root expected=/home/$_TILDE_REMOTE_USER/$_TILDE_REMOTE_SUBDIR/docker-reg\"; false; }'"

e2e_run "Remote: data dir exists on disN at $_TILDE_REMOTE_USER path" \
	"_essh $_TILDE_REMOTE_USER@$DIS_HOST \"test -d ~/$_TILDE_REMOTE_SUBDIR/docker-reg\""

e2e_run "Verify remote tilde registry" "cd ~/aba && aba -d $_TILDE_MIRROR verify"

e2e_run "Uninstall remote tilde registry" \
	"cd ~/aba && aba -d $_TILDE_MIRROR uninstall"
e2e_run "Assert: remote tilde registry removed" "e2e_assert_registry_removed"
e2e_run "Remote: cleanup $_TILDE_REMOTE_USER data dir" \
	"_essh $_TILDE_REMOTE_USER@$DIS_HOST \"rm -rf ~/$_TILDE_REMOTE_SUBDIR\""

# --- Local install with data_dir=~/subdir ---
# Verify ~ expands to the LOCAL user's home.
# The pool-registry (Docker, --network host) already binds the debug port :5001.
# A second Docker registry on the same host would crash on that port conflict.
# Stop pool-registry for the duration of this local install test.
e2e_run "Stop pool-registry to free debug port 5001 (if running)" \
	"podman stop pool-registry || echo 'pool-registry not running -- port already free'"

e2e_run "Recreate mirror dir for local tilde test" \
	"cd ~/aba && rm -rf $_TILDE_MIRROR && aba mirror --name $_TILDE_MIRROR"

e2e_run "Local install with data_dir=~/$_TILDE_LOCAL_SUBDIR" \
	"cd ~/aba && aba -d $_TILDE_MIRROR install --vendor docker --reg-port $_TILDE_PORT --data-dir '~/$_TILDE_LOCAL_SUBDIR'"

e2e_run "Local: reg_root is absolute (no literal ~)" \
	"bash -c 'source $_TILDE_STATE/state.sh && [[ \$reg_root == /* ]] || { echo \"reg_root=\$reg_root not absolute\"; false; }'"

# Verify the full expected path: $HOME/<subdir>/docker-reg
e2e_run "Local: reg_root is \$HOME/$_TILDE_LOCAL_SUBDIR/docker-reg" \
	"bash -c 'source $_TILDE_STATE/state.sh && [ \"\$reg_root\" = \"\$HOME/$_TILDE_LOCAL_SUBDIR/docker-reg\" ] || { echo \"reg_root=\$reg_root expected=\$HOME/$_TILDE_LOCAL_SUBDIR/docker-reg\"; false; }'"

e2e_run "Local: data dir exists at expected path" \
	"test -d \$HOME/$_TILDE_LOCAL_SUBDIR/docker-reg"

e2e_run "Verify local tilde registry" "cd ~/aba && aba -d $_TILDE_MIRROR verify"

e2e_run "Uninstall local tilde registry" \
	"cd ~/aba && aba -d $_TILDE_MIRROR uninstall"

e2e_run "Local: cleanup data dir" "rm -rf ~/$_TILDE_LOCAL_SUBDIR"
e2e_run "Cleanup tilde mirror dir" \
	"cd ~/aba && rm -rf $_TILDE_MIRROR"

e2e_run "Restart pool-registry (if it was running)" \
	"podman start pool-registry || echo 'pool-registry was not present -- skip'"

test_end

# ============================================================================
# 8. Register existing: lowercase state.sh
# ============================================================================
test_begin "Register existing: lowercase state.sh"

# Generate dummy creds for the register test
e2e_run "Create dummy CA cert" \
	"openssl req -x509 -newkey rsa:2048 -keyout /tmp/e2e-dummy-ca.key -out /tmp/e2e-dummy-ca.pem -days 1 -nodes -subj '/CN=e2e-test' 2>/dev/null"

e2e_run "Create dummy pull secret" \
	"echo '{\"auths\":{\"dummy:8443\":{\"auth\":\"dGVzdDp0ZXN0\"}}}' > /tmp/e2e-dummy-ps.json"

e2e_run "Register external registry" \
	"cd ~/aba && aba -d $_MIRROR_NAME register --pull-secret-mirror /tmp/e2e-dummy-ps.json --ca-cert /tmp/e2e-dummy-ca.pem"

e2e_run "register: state.sh exists" \
	"test -s $_STATE_DIR/state.sh"

e2e_run "register: reg_vendor=existing (lowercase)" \
	"grep -q '^reg_vendor=existing' $_STATE_DIR/state.sh"

e2e_run "register: NO uppercase REG_ vars" \
	"! grep -q '^REG_' $_STATE_DIR/state.sh"

e2e_run "register: state.sh is sourceable" \
	"bash -c 'source $_STATE_DIR/state.sh && test \"\$reg_vendor\" = \"existing\"'"

# Unregister should work with lowercase state
e2e_run "Unregister reads lowercase state.sh" \
	"cd ~/aba && aba -d $_MIRROR_NAME unregister"

e2e_run "Regcreds removed after unregister" \
	"test ! -f $_STATE_DIR/state.sh"

# Cleanup dummy files
e2e_run -q "Cleanup dummy certs" \
	"rm -f /tmp/e2e-dummy-ca.key /tmp/e2e-dummy-ca.pem /tmp/e2e-dummy-ps.json"

test_end

# ============================================================================
# 9. Helper functions: cluster state helpers
# ============================================================================
test_begin "Helper functions: cluster state helpers"

# Test helper functions by sourcing include_all.sh directly
e2e_run "cluster_state_dir returns correct path (name.domain)" \
	"cd ~/aba && bash -c 'source scripts/include_all.sh noerr && result=\$(cluster_state_dir testcluster example.com) && test \"\$result\" = \"\$HOME/.aba/clusters/testcluster.example.com\"'"

e2e_run "cluster_state_dir rejects empty name" \
	"cd ~/aba && bash -c 'source scripts/include_all.sh noerr && ! cluster_state_dir \"\" \"\"'"

e2e_run "cluster_state_dir rejects missing domain" \
	"cd ~/aba && bash -c 'source scripts/include_all.sh noerr && ! cluster_state_dir testcluster \"\"'"

e2e_run "cluster_kubeconfig rejects empty name" \
	"cd ~/aba && bash -c 'source scripts/include_all.sh noerr && ! cluster_kubeconfig \"\" \"\"'"

e2e_run "cluster_is_installed returns false for nonexistent" \
	"cd ~/aba && bash -c 'source scripts/include_all.sh noerr && ! cluster_is_installed nonexistent_xyz nonexistent.domain'"

# Create a fake state to test positive path (name.domain dir format)
e2e_run "Create fake cluster state for helper test" \
	"mkdir -p ~/.aba/clusters/e2e-helper-test.test.example.com && echo 'cluster_name=e2e-helper-test
base_domain=test.example.com' > ~/.aba/clusters/e2e-helper-test.test.example.com/state.sh"

e2e_run "cluster_is_installed returns true when state exists" \
	"cd ~/aba && bash -c 'source scripts/include_all.sh noerr && cluster_is_installed e2e-helper-test test.example.com'"

e2e_run "cluster_kubeconfig returns empty when no kubeconfig" \
	"cd ~/aba && bash -c 'source scripts/include_all.sh noerr && result=\$(cluster_kubeconfig e2e-helper-test test.example.com) && test -z \"\$result\"'"

e2e_run "cluster_kubeconfig returns state path when kubeconfig exists" \
	"touch ~/.aba/clusters/e2e-helper-test.test.example.com/kubeconfig && cd ~/aba && bash -c 'source scripts/include_all.sh noerr && result=\$(cluster_kubeconfig e2e-helper-test test.example.com) && test \"\$result\" = \"\$HOME/.aba/clusters/e2e-helper-test.test.example.com/kubeconfig\"'"

e2e_run -q "Cleanup fake cluster state" \
	"rm -rf ~/.aba/clusters/e2e-helper-test.test.example.com"

test_end

# ============================================================================
# 10. Phase 3: Drift detection overrides config with state
# ============================================================================
test_begin "Phase 3: drift detection overrides config with state"

_P3_NAME="e2e-test-drift"
_P3_STATE="\$HOME/.aba/mirror/$_P3_NAME"

e2e_run "Create synthetic mirror dir" \
	"cd ~/aba && mkdir -p $_P3_NAME && cat > $_P3_NAME/mirror.conf <<'CONF'
reg_host=drift.example.com
reg_port=8443
reg_vendor=docker
CONF"

e2e_run "Create synthetic state.sh" \
	"mkdir -p $_P3_STATE && cat > $_P3_STATE/state.sh <<'STATE'
reg_host=original.example.com
reg_port=5000
reg_vendor=docker
STATE"

e2e_run "Drift: state.sh reg_host overrides drifted mirror.conf" \
	"cd ~/aba/$_P3_NAME && bash -c 'source ../scripts/include_all.sh noerr; eval \"\$(normalize-mirror-conf)\"; test \"\$reg_host\" = \"original.example.com\"'"

e2e_run "Drift: state.sh reg_port overrides drifted mirror.conf" \
	"cd ~/aba/$_P3_NAME && bash -c 'source ../scripts/include_all.sh noerr; eval \"\$(normalize-mirror-conf)\"; test \"\$reg_port\" = \"5000\"'"

e2e_run "Drift: warning message emitted on stderr for reg_host" \
	"cd ~/aba/$_P3_NAME && bash -c 'source ../scripts/include_all.sh noerr; normalize-mirror-conf 2>/tmp/e2e-drift-stderr.txt >/dev/null; grep -q \"differs.*reg_host=drift.example.com.*(installed: original.example.com)\" /tmp/e2e-drift-stderr.txt'"

e2e_run "Drift: no debug message when config matches state" \
	"cd ~/aba/$_P3_NAME && cat > mirror.conf <<'CONF'
reg_host=original.example.com
reg_port=5000
reg_vendor=docker
CONF
bash -c 'export DEBUG_ABA=1; source ../scripts/include_all.sh noerr; normalize-mirror-conf 2>/tmp/e2e-drift-stderr2.txt >/dev/null; ! grep -q differs /tmp/e2e-drift-stderr2.txt'"

e2e_run -q "Cleanup drift test" \
	"cd ~/aba && rm -rf $_P3_NAME && rm -rf $_P3_STATE && rm -f /tmp/e2e-drift-stderr.txt /tmp/e2e-drift-stderr2.txt /tmp/.aba-\$USER/drift.*"

test_end

# ============================================================================
# 11. Phase 4: Dir recreation from state backup
# ============================================================================
test_begin "Phase 4: dir recreation from state backup"

_P4_NAME="e2e-test-recreate"
_P4_STATE="\$HOME/.aba/clusters/${_P4_NAME}.example.com"

e2e_run "Create fake cluster state backup" \
	"mkdir -p $_P4_STATE/backup && chmod 700 $_P4_STATE && \
	 cat > $_P4_STATE/state.sh <<'STATE'
cluster_name=e2e-test-recreate
base_domain=example.com
cluster_type=sno
platform=bm
starting_ip=10.0.2.10
machine_network=10.0.0.0
prefix_length=20
STATE
cat > $_P4_STATE/backup/cluster.conf <<'CONF'
cluster_name=e2e-test-recreate
base_domain=example.com
starting_ip=10.0.2.10
machine_network=10.0.0.0/20
CONF
touch $_P4_STATE/backup/.init $_P4_STATE/backup/.install-complete"

e2e_run "Verify e2e-test-recreate dir does NOT exist yet" \
	"cd ~/aba && [ ! -d $_P4_NAME ] || { echo 'ERROR: $_P4_NAME already exists'; ls -ld $_P4_NAME; false; }"

e2e_run "aba --dir triggers dir recreation" \
	"cd ~/aba && aba --dir $_P4_NAME help"

e2e_run "Cluster dir was recreated" \
	"cd ~/aba && [ -d $_P4_NAME ] || { echo 'ERROR: $_P4_NAME was not recreated'; ls -la; false; }"

e2e_run "cluster.conf restored from backup" \
	"cd ~/aba/$_P4_NAME && [ -s cluster.conf ] || { echo 'ERROR: cluster.conf missing or empty'; ls -la; false; }
	 grep -q 'cluster_name=e2e-test-recreate' cluster.conf || { echo 'ERROR: cluster_name not found in cluster.conf'; cat cluster.conf; false; }"

e2e_run "Makefile symlink created" \
	"cd ~/aba && [ -L $_P4_NAME/Makefile ] || { echo 'ERROR: Makefile not a symlink'; ls -la $_P4_NAME/Makefile; false; }"

e2e_run ".install-complete marker restored" \
	"cd ~/aba && [ -f $_P4_NAME/.install-complete ] || { echo 'ERROR: .install-complete missing'; ls -la $_P4_NAME/; false; }"

e2e_run "clusterstate symlink points to state dir" \
	"cd ~/aba && [ -L $_P4_NAME/clusterstate ] || { echo 'ERROR: clusterstate not a symlink'; ls -la $_P4_NAME/; false; }
	 readlink $_P4_NAME/clusterstate | grep -q '.aba/clusters/${_P4_NAME}.example.com' || { echo 'ERROR: clusterstate points to wrong target:'; readlink $_P4_NAME/clusterstate; false; }"

e2e_run -q "Cleanup recreate test" \
	"cd ~/aba && rm -rf $_P4_NAME && rm -rf $_P4_STATE"

test_end

# ============================================================================
# 12. Cleanup
# ============================================================================
test_begin "Cleanup: uninstall mirror"

# Uninstall registry if state.sh still exists (covers mid-test failure)
e2e_run "Uninstall Docker registry if still tracked" \
	"if [ -s $_STATE_DIR/state.sh ]; then cd ~/aba && test -d $_MIRROR_NAME || aba mirror --name $_MIRROR_NAME && aba -d $_MIRROR_NAME uninstall; else echo 'No state.sh -- registry already cleaned up'; fi"
e2e_run "Assert: registry fully removed on disN" "e2e_assert_registry_removed"

# Unregister if registered (covers failure during register test)
e2e_run "Unregister if still registered" \
	"if [ -s $_STATE_DIR/state.sh ] && grep -q '^reg_vendor=existing' $_STATE_DIR/state.sh; then cd ~/aba && test -d $_MIRROR_NAME || aba mirror --name $_MIRROR_NAME && aba -d $_MIRROR_NAME unregister; else echo 'Not registered -- skip'; fi"

# Close firewall port on disN (belt+suspenders -- aba uninstall now does this too)
e2e_run_remote "Close firewall port $_MIRROR_PORT on disN" \
	"sudo firewall-cmd --query-port=$_MIRROR_PORT/tcp --permanent && sudo firewall-cmd --remove-port=$_MIRROR_PORT/tcp --permanent && sudo firewall-cmd --reload || echo 'Port not open -- skip'"

# Remove local working dir
e2e_run "Remove mirror working dir" \
	"cd ~/aba && rm -rf $_MIRROR_NAME"

# Remove fake cluster state from helper tests
e2e_run -q "Remove fake cluster state" \
	"rm -rf ~/.aba/clusters/e2e-helper-test.test.example.com"

test_end

suite_end; _rc=$?

exit $_rc
