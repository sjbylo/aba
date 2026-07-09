#!/bin/bash
# test-primed-bundle-scenarios.sh — Validate --primed bundle mtime pinning and marker logic
#
# Tests that backup.sh --primed produces bundles where:
# 1. Make will NOT regenerate pre-built install-config.yaml/agent-config.yaml
# 2. .bm-message is only set for pre-built dirs (not cluster.conf-only)
# 3. mirror.conf is included/excluded based on .available
# 4. No dangling symlinks exist in the bundle
#
# Verification uses `make -q` (asks Make directly: "would you rebuild?")
# with mtime assertions as diagnostics on failure.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ABA_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Colors
_green() { echo -e "\033[0;32m$*\033[0m"; }
_red() { echo -e "\033[0;31m$*\033[0m"; }
_yellow() { echo -e "\033[1;33m$*\033[0m"; }

PASS=0
FAIL=0
SKIP=0

assert_pass() {
	local desc="$1"
	PASS=$(( PASS + 1 ))
	_green "  ✓ $desc"
}

assert_fail() {
	local desc="$1"
	FAIL=$(( FAIL + 1 ))
	_red "  ✗ $desc"
}

assert_eq() {
	local desc="$1" expected="$2" actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		assert_pass "$desc"
	else
		assert_fail "$desc (expected: $expected, got: $actual)"
	fi
}

# Check: file A is NOT newer than file B (A <= B)
assert_not_newer() {
	local desc="$1" file_a="$2" file_b="$3"
	if [[ "$file_a" -nt "$file_b" ]]; then
		local mt_a mt_b
		mt_a=$(stat -c %Y "$file_a")
		mt_b=$(stat -c %Y "$file_b")
		assert_fail "$desc ($file_a mtime=$mt_a > $file_b mtime=$mt_b)"
	else
		assert_pass "$desc"
	fi
}

assert_file_exists() {
	local desc="$1" path="$2"
	if [[ -e "$path" ]]; then
		assert_pass "$desc"
	else
		assert_fail "$desc (file not found: $path)"
	fi
}

assert_file_not_exists() {
	local desc="$1" path="$2"
	if [[ ! -e "$path" ]]; then
		assert_pass "$desc"
	else
		assert_fail "$desc (file should not exist: $path)"
	fi
}

assert_not_dangling_symlink() {
	local desc="$1" path="$2"
	if [[ -L "$path" && ! -e "$path" ]]; then
		assert_fail "$desc (dangling symlink: $path → $(readlink "$path"))"
	else
		assert_pass "$desc"
	fi
}

# Ask Make: "would you rebuild this target?"
# For install-config.yaml, we check if create-install-config.sh would run
# (not just any prerequisite like .cli which is order-only and harmless)
assert_make_uptodate() {
	local desc="$1" dir="$2" target="$3"
	local dry_run
	dry_run=$(make -n -C "$dir" "$target" 2>&1)
	if echo "$dry_run" | grep -q "create-install-config\|create-agent-config"; then
		assert_fail "$desc (make would regenerate $target in $dir)"
		_yellow "    Diagnostic: make -n $target:"
		echo "$dry_run" | head -5 | sed 's/^/    /'
	else
		assert_pass "$desc"
	fi
}

assert_make_would_rebuild() {
	local desc="$1" dir="$2" target="$3"
	local dry_run
	dry_run=$(make -n -C "$dir" "$target" 2>&1)
	if echo "$dry_run" | grep -q "create-install-config\|create-agent-config"; then
		assert_pass "$desc"
	else
		assert_fail "$desc (make says $target is up-to-date, expected rebuild)"
	fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Setup: Create a mock ABA repo with controlled timestamps
# ─────────────────────────────────────────────────────────────────────────────

TEST_DIR=$(mktemp -d /tmp/test-primed-XXXXXX)
trap "rm -rf $TEST_DIR" EXIT

echo "=== Test: --primed bundle scenarios ==="
echo "Test dir: $TEST_DIR"
echo ""

MOCK_REPO="$TEST_DIR/aba"
mkdir -p "$MOCK_REPO"/{scripts,templates,cli,rpms,others,mirror/data,.index}

# Copy required scripts and templates
cp "$ABA_ROOT/scripts/backup.sh" "$MOCK_REPO/scripts/"
cp "$ABA_ROOT/scripts/include_all.sh" "$MOCK_REPO/scripts/"
cp "$ABA_ROOT/templates/Makefile.cluster" "$MOCK_REPO/templates/"

# Create minimal required bundle files
touch "$MOCK_REPO"/{install,aba,Makefile,README.md,VERSION,LICENSE,Troubleshooting.md}
echo "ocp_version=4.21" > "$MOCK_REPO/aba.conf"
echo "platform=vmw" >> "$MOCK_REPO/aba.conf"
mkdir -p "$MOCK_REPO/tui/v2" && touch "$MOCK_REPO/tui/v2/.keep"

# Create vmware.conf at repo root
cat > "$MOCK_REPO/vmware.conf" <<'VMWEOF'
vcenter_host=vcenter.example.com
vcenter_user=admin
vcenter_pass=secret
VMWEOF

# Create mirror/mirror.conf
cat > "$MOCK_REPO/mirror/mirror.conf" <<'MIREOF'
reg_host=mirror.example.com
reg_port=8443
MIREOF

# ─────────────────────────────────────────────────────────────────────────────
# Helper: create a cluster dir with controlled timestamps
# ─────────────────────────────────────────────────────────────────────────────

create_cluster_dir() {
	local name="$1" platform="$2" pre_built="$3" timestamp="$4"
	local dir="$MOCK_REPO/$name"

	mkdir -p "$dir"

	# Makefile (from template)
	cp "$MOCK_REPO/templates/Makefile.cluster" "$dir/Makefile"

	# cluster.conf
	cat > "$dir/cluster.conf" <<-EOF
		cluster_name=$name
		base_domain=example.com
		machine_network=10.0.0.0/16
	EOF
	touch -d "$timestamp" "$dir/cluster.conf"

	# aba.conf (parent) — platform needed for Makefile
	# Already at $MOCK_REPO/aba.conf

	# Symlinks (as a real cluster dir would have)
	ln -sf ../vmware.conf "$dir/vmware.conf"
	ln -sf mirror/mirror.conf "$dir/mirror.conf"
	mkdir -p "$dir/mirror"
	ln -sf ../../mirror/mirror.conf "$dir/mirror/mirror.conf"

	if [[ "$pre_built" == "yes" ]]; then
		# Simulate pre-built configs (generated AFTER cluster.conf)
		local cfg_time
		cfg_time=$(date -d "$timestamp + 1 minute" '+%Y-%m-%d %H:%M:%S')

		cat > "$dir/install-config.yaml" <<-EOF
			apiVersion: v1
			baseDomain: example.com
			metadata:
			  name: $name
		EOF
		touch -d "$cfg_time" "$dir/install-config.yaml"

		cat > "$dir/agent-config.yaml" <<-EOF
			apiVersion: v1beta1
			metadata:
			  name: $name
		EOF
		touch -d "$cfg_time" "$dir/agent-config.yaml"

		# .cli would exist in a real pre-built dir (order-only dep of install-config.yaml)
		touch -d "$cfg_time" "$dir/.cli"
	fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: run backup.sh --primed and extract
# ─────────────────────────────────────────────────────────────────────────────

run_bundle_and_extract() {
	local extract_dir="$TEST_DIR/extracted"
	rm -rf "$extract_dir"
	mkdir -p "$extract_dir"

	local tar_file="$TEST_DIR/bundle.tar"
	rm -f "$tar_file"

	# Run backup.sh from the mock repo
	(cd "$MOCK_REPO" && bash scripts/backup.sh --primed "$tar_file") >/dev/null 2>&1

	# Extract
	tar xf "$tar_file" -C "$extract_dir"

	echo "$extract_dir/aba"
}

# ═══════════════════════════════════════════════════════════════════════════════
# SCENARIO 1: Single cluster, pre-built (VMware)
# ═══════════════════════════════════════════════════════════════════════════════

_yellow "Scenario 1: Single pre-built VMware cluster"

# Clean and setup
rm -rf "$MOCK_REPO"/sno* "$MOCK_REPO"/compact*
create_cluster_dir "sno1" "vmw" "yes" "2026-07-01 10:00:00"

EXTRACTED=$(run_bundle_and_extract)

# Assertions
assert_file_exists "vmware.conf exists in sno1" "$EXTRACTED/sno1/vmware.conf"
assert_not_newer "vmware.conf <= install-config.yaml in sno1" \
	"$EXTRACTED/sno1/vmware.conf" "$EXTRACTED/sno1/install-config.yaml"
assert_file_exists ".bm-message exists (pre-built)" "$EXTRACTED/sno1/.bm-message"
assert_file_exists ".init exists" "$EXTRACTED/sno1/.init"
assert_not_dangling_symlink "mirror.conf not dangling" "$EXTRACTED/sno1/mirror.conf"
# make -q check (need aba.conf for platform detection)
assert_make_uptodate "Make would NOT rebuild install-config.yaml" "$EXTRACTED/sno1" "install-config.yaml"

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# SCENARIO 2: Single cluster, cluster.conf-only
# ═══════════════════════════════════════════════════════════════════════════════

_yellow "Scenario 2: Single cluster.conf-only cluster"

rm -rf "$MOCK_REPO"/sno* "$MOCK_REPO"/compact*
create_cluster_dir "sno1" "vmw" "no" "2026-07-01 10:00:00"

EXTRACTED=$(run_bundle_and_extract)

assert_file_not_exists ".bm-message should NOT exist (cluster.conf-only)" "$EXTRACTED/sno1/.bm-message"
assert_file_exists ".init exists" "$EXTRACTED/sno1/.init"
# For cluster.conf-only: Make SHOULD want to generate install-config.yaml
assert_make_would_rebuild "Make WOULD generate install-config.yaml (expected)" "$EXTRACTED/sno1" "install-config.yaml"

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# SCENARIO 3: Multi-cluster, all pre-built, same day
# ═══════════════════════════════════════════════════════════════════════════════

_yellow "Scenario 3: Multi-cluster, all pre-built, same day"

rm -rf "$MOCK_REPO"/sno* "$MOCK_REPO"/compact*
create_cluster_dir "sno1" "vmw" "yes" "2026-07-01 10:00:00"
create_cluster_dir "sno2" "vmw" "yes" "2026-07-01 10:05:00"

EXTRACTED=$(run_bundle_and_extract)

assert_not_newer "vmware.conf <= sno1/install-config.yaml" \
	"$EXTRACTED/sno1/vmware.conf" "$EXTRACTED/sno1/install-config.yaml"
assert_not_newer "vmware.conf <= sno2/install-config.yaml" \
	"$EXTRACTED/sno2/vmware.conf" "$EXTRACTED/sno2/install-config.yaml"
assert_make_uptodate "sno1: Make would NOT rebuild install-config.yaml" "$EXTRACTED/sno1" "install-config.yaml"
assert_make_uptodate "sno2: Make would NOT rebuild install-config.yaml" "$EXTRACTED/sno2" "install-config.yaml"

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# SCENARIO 4: Multi-cluster, all pre-built, DIFFERENT days (the Mateusz bug)
# ═══════════════════════════════════════════════════════════════════════════════

_yellow "Scenario 4: Multi-cluster, different days (regression test)"

rm -rf "$MOCK_REPO"/sno* "$MOCK_REPO"/compact*
create_cluster_dir "sno1" "vmw" "yes" "2026-07-01 10:00:00"  # Monday
create_cluster_dir "sno2" "vmw" "yes" "2026-07-03 14:00:00"  # Wednesday

EXTRACTED=$(run_bundle_and_extract)

assert_not_newer "vmware.conf <= sno1/install-config.yaml (Monday cluster)" \
	"$EXTRACTED/sno1/vmware.conf" "$EXTRACTED/sno1/install-config.yaml"
assert_not_newer "vmware.conf <= sno2/install-config.yaml (Wednesday cluster)" \
	"$EXTRACTED/sno2/vmware.conf" "$EXTRACTED/sno2/install-config.yaml"
assert_make_uptodate "sno1: Make would NOT rebuild install-config.yaml" "$EXTRACTED/sno1" "install-config.yaml"
assert_make_uptodate "sno2: Make would NOT rebuild install-config.yaml" "$EXTRACTED/sno2" "install-config.yaml"

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# SCENARIO 5: Multi-cluster, mixed (pre-built + cluster.conf-only)
# ═══════════════════════════════════════════════════════════════════════════════

_yellow "Scenario 5: Mixed — pre-built + cluster.conf-only"

rm -rf "$MOCK_REPO"/sno* "$MOCK_REPO"/compact*
create_cluster_dir "sno1" "vmw" "yes" "2026-07-01 10:00:00"
create_cluster_dir "sno2" "vmw" "no"  "2026-07-02 12:00:00"

EXTRACTED=$(run_bundle_and_extract)

assert_file_exists ".bm-message on pre-built sno1" "$EXTRACTED/sno1/.bm-message"
assert_file_not_exists ".bm-message NOT on cluster.conf-only sno2" "$EXTRACTED/sno2/.bm-message"
assert_not_newer "vmware.conf <= sno1/install-config.yaml" \
	"$EXTRACTED/sno1/vmware.conf" "$EXTRACTED/sno1/install-config.yaml"
assert_make_uptodate "sno1: Make would NOT rebuild install-config.yaml" "$EXTRACTED/sno1" "install-config.yaml"

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# SCENARIO 6: mirror.conf included (.available absent — save-only workflow)
# ═══════════════════════════════════════════════════════════════════════════════

_yellow "Scenario 6: mirror.conf included (.available absent)"

rm -rf "$MOCK_REPO"/sno* "$MOCK_REPO"/compact*
rm -f "$MOCK_REPO/mirror/.available"
create_cluster_dir "sno1" "vmw" "yes" "2026-07-01 10:00:00"

EXTRACTED=$(run_bundle_and_extract)

assert_file_exists "mirror/mirror.conf included in bundle" "$EXTRACTED/mirror/mirror.conf"
assert_not_newer "mirror.conf <= sno1/install-config.yaml" \
	"$EXTRACTED/sno1/mirror.conf" "$EXTRACTED/sno1/install-config.yaml"

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# SCENARIO 7: mirror.conf excluded (.available present)
# ═══════════════════════════════════════════════════════════════════════════════

_yellow "Scenario 7: mirror.conf excluded (.available present)"

rm -rf "$MOCK_REPO"/sno* "$MOCK_REPO"/compact*
touch "$MOCK_REPO/mirror/.available"
create_cluster_dir "sno1" "vmw" "yes" "2026-07-01 10:00:00"

EXTRACTED=$(run_bundle_and_extract)

assert_file_not_exists "mirror/mirror.conf NOT in bundle" "$EXTRACTED/mirror/mirror.conf"
# Check no dangling symlinks in cluster dir
if [[ -L "$EXTRACTED/sno1/mirror.conf" ]]; then
	assert_not_dangling_symlink "sno1/mirror.conf not dangling" "$EXTRACTED/sno1/mirror.conf"
fi

# Cleanup .available for subsequent tests
rm -f "$MOCK_REPO/mirror/.available"

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# SCENARIO 8: kvm.conf instead of vmware.conf
# ═══════════════════════════════════════════════════════════════════════════════

_yellow "Scenario 8: KVM platform (kvm.conf)"

rm -rf "$MOCK_REPO"/sno* "$MOCK_REPO"/compact*
rm -f "$MOCK_REPO/vmware.conf"
cat > "$MOCK_REPO/kvm.conf" <<'KVMEOF'
kvm_host=kvm1.example.com
KVMEOF
sed -i 's/platform=vmw/platform=kvm/' "$MOCK_REPO/aba.conf"

create_cluster_dir "sno1" "kvm" "yes" "2026-07-01 10:00:00"
# Fix symlink for kvm
rm -f "$MOCK_REPO/sno1/vmware.conf"
ln -sf ../kvm.conf "$MOCK_REPO/sno1/kvm.conf"

EXTRACTED=$(run_bundle_and_extract)

assert_file_exists "kvm.conf exists in bundle" "$EXTRACTED/kvm.conf"
if [[ -f "$EXTRACTED/sno1/kvm.conf" ]]; then
	assert_not_newer "kvm.conf <= sno1/install-config.yaml" \
		"$EXTRACTED/sno1/kvm.conf" "$EXTRACTED/sno1/install-config.yaml"
fi

# Restore for remaining tests
cat > "$MOCK_REPO/vmware.conf" <<'VMWEOF'
vcenter_host=vcenter.example.com
vcenter_user=admin
vcenter_pass=secret
VMWEOF
sed -i 's/platform=kvm/platform=vmw/' "$MOCK_REPO/aba.conf"

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# SCENARIO 9: No hypervisor conf (bare-metal, platform=bm)
# ═══════════════════════════════════════════════════════════════════════════════

_yellow "Scenario 9: Bare-metal (no vmware.conf/kvm.conf)"

rm -rf "$MOCK_REPO"/sno* "$MOCK_REPO"/compact*
rm -f "$MOCK_REPO/vmware.conf" "$MOCK_REPO/kvm.conf"
sed -i 's/platform=vmw/platform=bm/' "$MOCK_REPO/aba.conf"

create_cluster_dir "sno1" "bm" "yes" "2026-07-01 10:00:00"
rm -f "$MOCK_REPO/sno1/vmware.conf"  # No HV conf for bare-metal

EXTRACTED=$(run_bundle_and_extract)

assert_file_exists "sno1/install-config.yaml in bundle" "$EXTRACTED/sno1/install-config.yaml"
assert_file_exists ".bm-message exists (pre-built)" "$EXTRACTED/sno1/.bm-message"
# No vmware.conf to worry about

# Restore
cat > "$MOCK_REPO/vmware.conf" <<'VMWEOF'
vcenter_host=vcenter.example.com
vcenter_user=admin
vcenter_pass=secret
VMWEOF
sed -i 's/platform=bm/platform=vmw/' "$MOCK_REPO/aba.conf"

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# SCENARIO 10: Cluster dir with macs.conf
# ═══════════════════════════════════════════════════════════════════════════════

_yellow "Scenario 10: Cluster with macs.conf"

rm -rf "$MOCK_REPO"/sno* "$MOCK_REPO"/compact*
create_cluster_dir "sno1" "vmw" "yes" "2026-07-01 10:00:00"
cat > "$MOCK_REPO/sno1/macs.conf" <<'MACEOF'
00:50:56:ab:cd:01
00:50:56:ab:cd:02
00:50:56:ab:cd:03
MACEOF

EXTRACTED=$(run_bundle_and_extract)

assert_file_exists "macs.conf included in bundle" "$EXTRACTED/sno1/macs.conf"

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════

echo "═══════════════════════════════════════════════════"
echo -n "Results: "
_green "$PASS passed"
echo -n ", "
if [[ $FAIL -gt 0 ]]; then
	_red "$FAIL failed"
else
	echo "$FAIL failed"
fi
echo "═══════════════════════════════════════════════════"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
