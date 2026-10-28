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
source "$_SUITE_DIR/../lib/suite-helpers.sh"

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
    "Debug mode on/off" \
    "images.conf: CLI and merge" \
    "disk_hint and bond_mode CLI flags" \
    "image set: CLI add/remove/list" \
    "ABA installer: git and curl"

suite_begin "cli-validation"

# ============================================================================
# 1. Setup: install aba
# ============================================================================
test_begin "Setup: install aba"

e2e_install_aba --curl

suite_configure_aba
suite_verify_aba_conf

test_end 0

# ============================================================================
# 2. Reset + catalog download (regression: oc-mirror must survive reset)
# ============================================================================
test_begin "Reset + catalog download"

e2e_run "Reset aba" "aba reset -f"

e2e_run "Remove oc-mirror caches" \
    "sudo find /root/ /home/ -maxdepth 3 -type d -name .oc-mirror | xargs sudo rm -rf"

e2e_run "Verify / available space > ${E2E_MIN_DISK_GB}GB after reset" \
    "avail_gb=\$(df / --output=avail -BG | tail -1 | tr -d ' G'); echo \"[setup] / available: \${avail_gb}GB\"; [ \$avail_gb -gt ${E2E_MIN_DISK_GB} ]"

e2e_run "Reconfigure after reset" \
    "aba --noask --platform vmw --channel $TEST_CHANNEL --version $OCP_VERSION --base-domain $(pool_domain)"
e2e_run "Verify aba.conf: version format after reset" "grep -E '^ocp_version=[0-9]+(\.[0-9]+){2}' aba.conf"

e2e_run "Start save, Ctrl-C after 20s" \
    'rc=0; timeout 20 bash -c "aba -d mirror save" || rc=$?; [ "$rc" -eq 124 ]'

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
# images.conf: CLI add/remove/list and merge logic
# ============================================================================
test_begin "images.conf: CLI and merge"

# --- aba image add: syntax validation ---
e2e_run_must_fail "Reject garbage image ref" \
    "aba image add notvalid"

e2e_run_must_fail "Reject image with no repo" \
    "aba image add just-a-name"

e2e_run "Add valid image (registry/repo:tag)" \
    "aba image add registry.redhat.io/ubi9/ubi:latest"

e2e_run "Add valid image (registry/repo@digest)" \
    "aba image add quay.io/openshift/cli@sha256:abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"

e2e_run "Add valid image (nested repo path)" \
    "aba image add registry.redhat.io/rhel9/support-tools:latest"

# --- aba image add: dedup ---
e2e_run "Add duplicate is idempotent" \
    "aba image add registry.redhat.io/ubi9/ubi:latest 2>&1 | grep -i 'already'"

# --- aba image list ---
e2e_run "List shows added images" \
    "aba image list | grep 'registry.redhat.io/ubi9/ubi:latest'"

e2e_run "List shows source column" \
    "aba image list | grep 'images.conf'"

# --- Verify images.conf file content ---
e2e_run "images.conf has 3 entries" \
    "grep -c '^[^#]' images.conf | grep -q 3"

# --- aba image remove ---
e2e_run "Remove an image" \
    "aba image remove quay.io/openshift/cli@sha256:abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"

e2e_run "Removed image is gone from file" \
    "! grep -q 'openshift/cli@sha256' images.conf"

e2e_run "List shows 2 remaining" \
    "[ \$(aba image list | grep -c '/') -eq 2 ]"

e2e_run_must_fail "Remove non-existent image fails" \
    "aba image remove no.such/image:v1"

# --- Per-mirror images.conf ---
e2e_run "Add image to mirror-level images.conf" \
    "aba -d mirror image add docker.io/library/nginx:latest"

e2e_run "Mirror images.conf exists" \
    "test -f mirror/images.conf && grep -q 'nginx' mirror/images.conf"

e2e_run "List from mirror dir shows both sources" \
    "aba -d mirror image list | grep 'images.conf' && aba -d mirror image list | grep 'mirror/images.conf'"

# --- _merge_images_conf: JSON output ---
e2e_run "Merge produces valid JSON with all images" \
    "source scripts/include_all.sh && cd mirror && json=\$(_merge_images_conf .) && echo \"\$json\" | python3 -m json.tool > /dev/null && [ \$(echo \"\$json\" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))') -eq 3 ]"

# --- ISC generation includes additionalImages ---
e2e_run "ISC contains additionalImages from images.conf" \
    "aba -d mirror imagesetconf && grep -A5 'additionalImages' mirror/data/imageset-config.yaml | grep -q 'ubi9/ubi'"

# --- Cleanup ---
e2e_run -q "Remove test images.conf files" \
    "rm -f images.conf mirror/images.conf"

test_end 0

# ============================================================================
# --disk-hint and --bond-mode CLI flags
# ============================================================================
test_begin "disk_hint and bond_mode CLI flags"

# --- Global flags during cluster creation ---
e2e_run -q "Cleanup: remove test cluster dirs" \
    "rm -rf e2e-dh1 e2e-dh2 e2e-dh3"

e2e_run "Create SNO with --disk-hint and --bond-mode" \
    "aba cluster --name e2e-dh1 --type sno --starting-ip 10.0.0.100 --disk-hint /dev/sda --bond-mode active-backup --step cluster.conf"

e2e_run "Verify global disk_hint written" \
    "grep -q '^disk_hint=/dev/sda' e2e-dh1/cluster.conf"

e2e_run "Verify global bond_mode written" \
    "grep -q '^bond_mode=active-backup' e2e-dh1/cluster.conf"

e2e_run "Verify no per-role clutter in clean create" \
    "! grep -q '^disk_hint_master=' e2e-dh1/cluster.conf && ! grep -q '^bond_mode_master=' e2e-dh1/cluster.conf"

# --- Per-role flags (append-on-demand) ---
e2e_run "Create compact with per-role flags only" \
    "aba cluster --name e2e-dh2 --type compact --starting-ip 10.0.0.100 --disk-hint-master /dev/nvme0n1 --disk-hint-worker /dev/sdb --bond-mode-master 802.3ad --bond-mode-worker balance-xor --step cluster.conf"

e2e_run "Verify per-role disk_hint_master appended" \
    "grep -q '^disk_hint_master=/dev/nvme0n1' e2e-dh2/cluster.conf"

e2e_run "Verify per-role disk_hint_worker appended" \
    "grep -q '^disk_hint_worker=/dev/sdb' e2e-dh2/cluster.conf"

e2e_run "Verify per-role bond_mode_master appended" \
    "grep -q '^bond_mode_master=802.3ad' e2e-dh2/cluster.conf"

e2e_run "Verify per-role bond_mode_worker appended" \
    "grep -q '^bond_mode_worker=balance-xor' e2e-dh2/cluster.conf"

e2e_run "Verify global disk_hint stays empty when per-role only" \
    "grep -qP '^disk_hint=(\t| |$)' e2e-dh2/cluster.conf"

# --- Update existing cluster.conf ---
e2e_run "Update existing cluster.conf with --disk-hint" \
    "aba -d e2e-dh2 --disk-hint /dev/vda --validate"

e2e_run "Verify updated disk_hint" \
    "grep -q '^disk_hint=/dev/vda' e2e-dh2/cluster.conf"

# --- Combined global + per-role ---
e2e_run "Create standard with global + per-role" \
    "aba cluster --name e2e-dh3 --type standard --starting-ip 10.0.0.100 --disk-hint /dev/sda --disk-hint-master /dev/nvme0n1 --bond-mode active-backup --bond-mode-worker balance-tlb --step cluster.conf"

e2e_run "Verify combined: global disk_hint" \
    "grep -q '^disk_hint=/dev/sda' e2e-dh3/cluster.conf"

e2e_run "Verify combined: per-role disk_hint_master" \
    "grep -q '^disk_hint_master=/dev/nvme0n1' e2e-dh3/cluster.conf"

e2e_run "Verify combined: per-role bond_mode_worker" \
    "grep -q '^bond_mode_worker=balance-tlb' e2e-dh3/cluster.conf"

# --- Criteria-style disk hint ---
e2e_run "Criteria-style disk_hint" \
    "aba -d e2e-dh1 --disk-hint 'model=VBOX,minSizeGigabytes=200' --validate"

e2e_run "Verify criteria disk_hint written" \
    "grep -q '^disk_hint=model=VBOX,minSizeGigabytes=200' e2e-dh1/cluster.conf"

# --- Validation: invalid bond mode rejected ---
e2e_run_must_fail "Reject invalid bond mode" \
    "aba -d e2e-dh1 --bond-mode nonsense --validate"

# --- Validation: missing argument rejected ---
e2e_run_must_fail "Reject missing --disk-hint argument" \
    "aba -d e2e-dh1 --disk-hint"

e2e_run_must_fail "Reject missing --bond-mode argument" \
    "aba -d e2e-dh1 --bond-mode"

# --- Cleanup ---
e2e_run -q "Cleanup test cluster dirs" \
    "rm -rf e2e-dh1 e2e-dh2 e2e-dh3"

test_end 0

# ============================================================================
# image set: CLI add/remove/list
# ============================================================================
test_begin "image set: CLI add/remove/list"

# Save original images.conf
e2e_run -q "Backup images.conf" \
    "[ -f images.conf ] && cp images.conf images.conf.e2e-bak || true"

# --- list ---
e2e_run "image set list shows all 3 sets" \
    "aba image set list | grep -q 'ocp' && aba image set list | grep -q 'virt' && aba image set list | grep -q 'ai'"

# --- add virt ---
e2e_run "image set add virt" \
    "aba image set add virt 2>&1 | grep -qi 'added.*images'"

e2e_run "Verify virt marker in images.conf" \
    "grep -q '^# image-set: virt' images.conf"

e2e_run "Verify virt contains expected image" \
    "grep -q 'rhel-guest-image' images.conf"

e2e_run "image set list shows virt as added" \
    "aba image set list | grep 'virt' | grep -q 'added'"

# --- re-add (replace, not duplicate) ---
e2e_run "image set re-add virt replaces cleanly" \
    "aba image set add virt"

e2e_run "Only one virt marker block" \
    "[ \$(grep -c '^# image-set: virt' images.conf) -eq 1 ]"

# --- remove ---
e2e_run "image set remove virt" \
    "aba image set remove virt 2>&1 | grep -qi 'removed'"

e2e_run "Verify virt marker gone" \
    "! grep -q '^# image-set: virt' images.conf"

# --- error cases ---
e2e_run_must_fail "Reject image set add bogus" \
    "aba image set add bogus"

e2e_run_must_fail "Reject image set remove bogus" \
    "aba image set remove bogus"

e2e_run_must_fail "Reject image set with no action" \
    "aba image set"

e2e_run_must_fail "Reject image set add with no name" \
    "aba image set add"

# --- add ocp set ---
e2e_run "image set add ocp" \
    "aba image set add ocp 2>&1 | grep -qi 'added'"

# --- Restore ---
e2e_run -q "Restore images.conf" \
    "if [ -f images.conf.e2e-bak ]; then mv images.conf.e2e-bak images.conf; else rm -f images.conf; fi"

test_end 0

# ============================================================================
# Installer validation: test both git and curl install methods into /tmp
# ============================================================================
test_begin "ABA installer: git and curl"

e2e_run "Install ABA via git into /tmp" \
    "rm -rf /tmp/aba-install-test && git clone --depth 1 -b \$E2E_GIT_BRANCH \$E2E_GIT_REPO /tmp/aba-install-test && cd /tmp/aba-install-test && ./install"

e2e_run "Verify git install" \
    "cd /tmp/aba-install-test && test -x scripts/aba.sh && aba --aba-version"

e2e_run "Install ABA via curl into /tmp" \
    "rm -rf /tmp/aba-install-test && mkdir -p /tmp/aba-install-test && cd /tmp/aba-install-test && bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/\$E2E_GIT_REPO_SLUG/refs/heads/\$E2E_GIT_BRANCH/install)\" -- \$E2E_GIT_BRANCH \$E2E_GIT_REPO_SLUG"

e2e_run "Verify curl install" \
    "cd /tmp/aba-install-test/aba && test -x scripts/aba.sh && aba --aba-version"

e2e_run "Cleanup" "rm -rf /tmp/aba-install-test"

test_end 0

# ============================================================================

suite_end; _rc=$?

exit $_rc
