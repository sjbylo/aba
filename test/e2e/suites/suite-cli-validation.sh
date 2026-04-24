#!/usr/bin/env bash
# =============================================================================
# Suite: CLI Validation (negative path tests for aba.sh input parsing)
# =============================================================================
# Purpose: Verify that invalid CLI inputs to `aba` are rejected with proper
#          error messages. These are fast (~2-3 min), need no cluster or mirror.
#
# What it tests:
#   - Reset + catalog download (oc-mirror survives aba reset)
#   - Bad --version / --channel arguments
#   - Bad --dir targets (missing, not a dir)
#   - Invalid --platform, --vendor, --type
#   - Invalid IP addresses, CIDRs, port numbers
#   - Unknown flags
#   - --out to existing file
#
# Prerequisites:
#   - aba must be installed (./install)
#   - aba.conf must exist
# =============================================================================

set -u

_SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SUITE_DIR/../lib/framework.sh"
source "$_SUITE_DIR/../lib/config-helpers.sh"

# --- Suite ------------------------------------------------------------------

e2e_setup

plan_tests \
    "Setup: install aba" \
    "Reset + catalog download" \
    "Bad version arguments" \
    "Bad channel arguments" \
    "Bad --dir targets" \
    "Invalid platform, vendor, type" \
    "Invalid network arguments" \
    "Unknown flags" \
    "Bundle output collision" \
    "Debug mode on/off"

suite_begin "cli-validation"

# ============================================================================
# 1. Setup: install aba
# ============================================================================
test_begin "Setup: install aba"

e2e_install_aba --curl

e2e_run "Configure aba.conf" \
    "aba --noask --platform vmw --channel $TEST_CHANNEL --version $OCP_VERSION --base-domain $(pool_domain)"
e2e_run "Set dns_servers" \
    "sed -i 's/^dns_servers=.*/dns_servers=$(pool_dns_server)/' aba.conf"

test_end 0

# ============================================================================
# 2. Reset + catalog download (regression: oc-mirror must survive reset)
# ============================================================================
test_begin "Reset + catalog download"

e2e_run "Reset aba" "aba reset -f"

e2e_run "Remove oc-mirror caches" \
    "sudo find /root/ /home/ -maxdepth 3 -type d -name .oc-mirror 2>/dev/null | xargs sudo rm -rf"

e2e_run "Verify / available space > 200GB after reset" \
    "avail_gb=\$(df / --output=avail -BG | tail -1 | tr -d ' G'); echo \"[setup] / available: \${avail_gb}GB\"; [ \$avail_gb -gt 200 ]"

e2e_run "Reconfigure after reset" \
    "aba --noask --platform vmw --channel $TEST_CHANNEL --version $OCP_VERSION --base-domain $(pool_domain)"
e2e_run "Set dns_servers" \
    "sed -i 's/^dns_servers=.*/dns_servers=$(pool_dns_server)/' aba.conf"

e2e_run "Start save, Ctrl-C after 20s" \
    'timeout 20 bash -c "aba -d mirror save"; rc=$?; [ "$rc" -eq 124 ] || exit $rc'

e2e_run "Verify catalog task not failed" \
    'ocp_short=$(source aba.conf && echo "${ocp_version%.*}"); task_dir=~/.aba/runner/catalog:${ocp_short}:redhat-operator; if [ -f "$task_dir/exit" ]; then rc=$(cat "$task_dir/exit"); [ "$rc" -eq 0 ] || { echo "Task failed (exit=$rc):"; cat "$task_dir/log.err"; exit 1; }; echo "Task completed successfully"; else echo "Task still running (oc-mirror found, download in progress)"; fi'

test_end 0

# ============================================================================
# 3. Bad version arguments
# ============================================================================
test_begin "Bad version arguments"

e2e_run_must_fail "Bad version format (not x.y.z)" \
    "aba --version NOTAVERSION"

e2e_run_must_fail "Missing --version argument" \
    "aba --version --channel stable"

test_end 0

# ============================================================================
# 4. Bad channel arguments
# ============================================================================
test_begin "Bad channel arguments"

e2e_run_must_fail "Invalid channel name" \
    "aba --channel boguschannel"

e2e_run_must_fail "Missing --channel argument" \
    "aba --channel --version 4.16.0"

test_end 0

# ============================================================================
# 5. Bad --dir targets
# ============================================================================
test_begin "Bad --dir targets"

e2e_run_must_fail "Dir does not exist" \
    "aba --dir /nonexistent/path/that/does/not/exist status"

e2e_run_must_fail "Not a directory (file instead)" \
    "aba --dir /etc/hosts status"

test_end 0

# ============================================================================
# 6. Invalid platform, vendor, type
# ============================================================================
test_begin "Invalid platform, vendor, type"

e2e_run_must_fail "Invalid platform" \
    "aba cluster --platform bogusplatform"

e2e_run_must_fail "Invalid vendor" \
    "aba mirror --vendor bogusvendor"

e2e_run_must_fail "Invalid cluster type" \
    "aba cluster --type bogustype"

test_end 0

# ============================================================================
# 7. Invalid network arguments
# ============================================================================
test_begin "Invalid network arguments"

e2e_run_must_fail "Invalid --reg-port (non-numeric)" \
    "aba mirror --reg-port abc"

e2e_run_must_fail "Invalid --api-vip (bad IP)" \
    "aba cluster --api-vip 999.999.999.999"

e2e_run_must_fail "Invalid --machine-network (not CIDR)" \
    "aba cluster --machine-network notacidr"

e2e_run_must_fail "Invalid --dns (not an IP)" \
    "aba --dns not-an-ip-address"

test_end 0

# ============================================================================
# 8. Unknown flags
# ============================================================================
test_begin "Unknown flags"

e2e_run_must_fail "Unknown flag rejected" \
    "aba --does-not-exist-flag"

test_end 0

# ============================================================================
# 9. Bundle output collision
# ============================================================================
test_begin "Bundle output collision"

e2e_run -q "Create dummy tar for collision test" \
    "touch /tmp/e2e-cli-collision-test.tar"

e2e_run_must_fail "Bundle --out to existing tar" \
    "aba bundle --out /tmp/e2e-cli-collision-test"

e2e_run -q "Clean up collision test file" \
    "rm -f /tmp/e2e-cli-collision-test.tar"

test_end 0

# ============================================================================
# 10. Debug mode on/off
# ============================================================================
test_begin "Debug mode on/off"

# --debug / -D must produce [ABA_DEBUG] markers on stderr.
# Using --help as test vehicle: fast, no side effects, goes through main parser.
e2e_run "aba --debug produces ABA_DEBUG output" \
    "aba --debug --help 2>&1 | grep -q ABA_DEBUG"

e2e_run "aba -D produces ABA_DEBUG output" \
    "aba -D --help 2>&1 | grep -q ABA_DEBUG"

# DEBUG_ABA env var has the same effect as --debug flag
e2e_run "DEBUG_ABA=1 env var produces ABA_DEBUG output" \
    "DEBUG_ABA=1 aba --help 2>&1 | grep -q ABA_DEBUG"

# Without --debug and with DEBUG_ABA unset, no ABA_DEBUG output
e2e_run "No debug output without --debug flag" \
    "unset DEBUG_ABA; aba --help 2>&1 | { ! grep -q ABA_DEBUG; }"

# --debug with a make target: verify debug messages appear during real execution
e2e_run "Debug mode with make target produces ABA_DEBUG" \
    "aba --debug -d mirror init 2>&1 | grep -q ABA_DEBUG"

# Same target without debug: no ABA_DEBUG in output
e2e_run "Non-debug mode: no ABA_DEBUG in output" \
    "unset DEBUG_ABA; aba -d mirror init 2>&1 | { ! grep -q ABA_DEBUG; }"

test_end 0

# ============================================================================

suite_end

echo "SUCCESS: suite-cli-validation.sh"
