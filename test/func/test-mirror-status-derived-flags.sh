#!/bin/bash
# Test: mirror-status.sh derived flags (upgrade, transfer, ISC, operator count)
# Regression test for: TUI consumes these flags for warnings and menu behavior
# Verifies: upgrade_needs_platform, transfer_excl_release, isc_exists,
#           isc_user_managed, operator_count

cd "$(dirname "$0")/../.." || exit 1
source scripts/include_all.sh 2>/dev/null

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }

echo "=== mirror-status.sh derived flags ==="

_repo=$(pwd)
_tmp=$(mktemp -d)
trap 'rm -rf "$_tmp"' EXIT

setup_mirror_dir() {
	rm -rf "$_tmp/mirror"
	mkdir -p "$_tmp/mirror/data"
	cp "$_repo/aba.conf" "$_tmp/aba.conf"
	cp "$_repo/mirror/mirror.conf" "$_tmp/mirror/mirror.conf" 2>/dev/null || \
		echo "# minimal" > "$_tmp/mirror/mirror.conf"

	ln -sfn "$_repo/scripts" "$_tmp/scripts"
	ln -sfn "$_repo/cli" "$_tmp/cli"
	ln -sfn "$_repo/scripts" "$_tmp/mirror/scripts"
	ln -sfn "$_repo/cli" "$_tmp/mirror/cli"
	ln -sf ../aba.conf "$_tmp/mirror/aba.conf"
	ln -sfn . "$_tmp/mirror/mirror"
	cp -a "$_repo/templates" "$_tmp/templates" 2>/dev/null || true
	ln -sf "$_tmp/templates" "$_tmp/mirror/templates"
	> "$_tmp/images.conf"
	> "$_tmp/mirror/images.conf"
}

# Write a minimal ISC with given operator count
write_isc() {
	local op_count="${1:-0}"
	cat > "$_tmp/mirror/data/imageset-config.yaml" <<'HEADER'
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  platform:
    channels:
    - name: stable-4.22
      minVersion: "4.22.0"
      maxVersion: "4.22.0"
HEADER

	if [ "$op_count" -gt 0 ]; then
		echo "  operators:" >> "$_tmp/mirror/data/imageset-config.yaml"
		local i
		for (( i=1; i<=op_count; i++ )); do
			echo "  - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.22" >> "$_tmp/mirror/data/imageset-config.yaml"
			echo "    packages:" >> "$_tmp/mirror/data/imageset-config.yaml"
			echo "    - name: test-operator-${i}" >> "$_tmp/mirror/data/imageset-config.yaml"
		done
	fi
}

get_key() {
	local output="$1" key="$2"
	echo "$output" | grep "^${key}=" | cut -d= -f2- | sed 's/^"//; s/"$//'
}

run_status() {
	cd "$_tmp/mirror" && bash scripts/mirror-status.sh --shell 2>/dev/null
}

# ── ISC state ───────────────────────────────────────────

echo ""
echo "--- ISC state detection ---"

setup_mirror_dir

# No ISC file → isc_exists=false
rm -f "$_tmp/mirror/data/imageset-config.yaml"
out=$(run_status)
if [ "$(get_key "$out" isc_exists)" = "false" ]; then
	_pass "No ISC file → isc_exists=false"
else
	_fail "No ISC file → isc_exists should be false, got '$(get_key "$out" isc_exists)'"
fi

# ISC exists → isc_exists=true
setup_mirror_dir
write_isc 0
out=$(run_status)
if [ "$(get_key "$out" isc_exists)" = "true" ]; then
	_pass "ISC present → isc_exists=true"
else
	_fail "ISC present → isc_exists should be true, got '$(get_key "$out" isc_exists)'"
fi

# ISC not user-managed (no .created marker)
if [ "$(get_key "$out" isc_user_managed)" = "false" ]; then
	_pass "No .created marker → isc_user_managed=false"
else
	_fail "No .created marker → isc_user_managed should be false, got '$(get_key "$out" isc_user_managed)'"
fi

# ISC user-managed: ISC is newer than data/.created
setup_mirror_dir
touch "$_tmp/mirror/data/.created"
sleep 0.1
write_isc 0
out=$(run_status)
if [ "$(get_key "$out" isc_user_managed)" = "true" ]; then
	_pass "ISC newer than .created → isc_user_managed=true"
else
	_fail "ISC newer than .created → isc_user_managed should be true, got '$(get_key "$out" isc_user_managed)'"
fi

# ISC older than .created → not user-managed
setup_mirror_dir
write_isc 0
sleep 0.1
touch "$_tmp/mirror/data/.created"
out=$(run_status)
if [ "$(get_key "$out" isc_user_managed)" = "false" ]; then
	_pass "ISC older than .created → isc_user_managed=false"
else
	_fail "ISC older than .created → isc_user_managed should be false, got '$(get_key "$out" isc_user_managed)'"
fi

# ── Operator count from ISC ─────────────────────────────

echo ""
echo "--- Operator count ---"

setup_mirror_dir
write_isc 0
out=$(run_status)
if [ "$(get_key "$out" operator_count)" = "0" ]; then
	_pass "ISC with 0 operators → operator_count=0"
else
	_fail "ISC with 0 operators → operator_count should be 0, got '$(get_key "$out" operator_count)'"
fi

setup_mirror_dir
write_isc 3
out=$(run_status)
if [ "$(get_key "$out" operator_count)" = "3" ]; then
	_pass "ISC with 3 operators → operator_count=3"
else
	_fail "ISC with 3 operators → operator_count should be 3, got '$(get_key "$out" operator_count)'"
fi

setup_mirror_dir
write_isc 1
out=$(run_status)
if [ "$(get_key "$out" operator_count)" = "1" ]; then
	_pass "ISC with 1 operator → operator_count=1"
else
	_fail "ISC with 1 operator → operator_count should be 1, got '$(get_key "$out" operator_count)'"
fi

# ── upgrade_needs_platform ──────────────────────────────

echo ""
echo "--- upgrade_needs_platform ---"

# No upgrade target → false
setup_mirror_dir
write_isc 0
sed -i "s/^#\{0,1\}ocp_upgrade_to=.*/ocp_upgrade_to=/" "$_tmp/mirror/mirror.conf" 2>/dev/null || \
	echo "ocp_upgrade_to=" >> "$_tmp/mirror/mirror.conf"
out=$(run_status)
if [ "$(get_key "$out" upgrade_needs_platform)" = "false" ]; then
	_pass "No upgrade target → upgrade_needs_platform=false"
else
	_fail "No upgrade target → should be false, got '$(get_key "$out" upgrade_needs_platform)'"
fi

# Upgrade target set + platform included → false
setup_mirror_dir
write_isc 0
sed -i "s/^excl_platform=.*/excl_platform=false/" "$_tmp/aba.conf"
sed -i "s/^#\{0,1\}ocp_upgrade_to=.*/ocp_upgrade_to=4.22.1/" "$_tmp/mirror/mirror.conf" 2>/dev/null || \
	echo "ocp_upgrade_to=4.22.1" >> "$_tmp/mirror/mirror.conf"
out=$(run_status)
if [ "$(get_key "$out" upgrade_needs_platform)" = "false" ]; then
	_pass "Upgrade target + platform included → upgrade_needs_platform=false"
else
	_fail "Upgrade target + platform included → should be false, got '$(get_key "$out" upgrade_needs_platform)'"
fi

# Upgrade target set + platform excluded → true
setup_mirror_dir
write_isc 0
sed -i "s/^excl_platform=.*/excl_platform=true/" "$_tmp/aba.conf"
sed -i "s/^#\{0,1\}ocp_upgrade_to=.*/ocp_upgrade_to=4.22.1/" "$_tmp/mirror/mirror.conf" 2>/dev/null || \
	echo "ocp_upgrade_to=4.22.1" >> "$_tmp/mirror/mirror.conf"
out=$(run_status)
if [ "$(get_key "$out" upgrade_needs_platform)" = "true" ]; then
	_pass "Upgrade target + platform excluded → upgrade_needs_platform=true"
else
	_fail "Upgrade target + platform excluded → should be true, got '$(get_key "$out" upgrade_needs_platform)'"
fi

# Upgrade target == current version → false (no upgrade)
setup_mirror_dir
write_isc 0
sed -i "s/^excl_platform=.*/excl_platform=true/" "$_tmp/aba.conf"
_cur_ver=$(grep "^ocp_version=" "$_tmp/aba.conf" | cut -d= -f2 | sed 's/[[:space:]]*#.*//')
sed -i "s/^#\{0,1\}ocp_upgrade_to=.*/ocp_upgrade_to=$_cur_ver/" "$_tmp/mirror/mirror.conf" 2>/dev/null || \
	echo "ocp_upgrade_to=$_cur_ver" >> "$_tmp/mirror/mirror.conf"
out=$(run_status)
if [ "$(get_key "$out" upgrade_needs_platform)" = "false" ]; then
	_pass "Upgrade target == current → upgrade_needs_platform=false"
else
	_fail "Upgrade target == current → should be false, got '$(get_key "$out" upgrade_needs_platform)'"
fi

# ── transfer_excl_release ───────────────────────────────

echo ""
echo "--- transfer_excl_release ---"

# Platform included → false
setup_mirror_dir
write_isc 0
sed -i "s/^excl_platform=.*/excl_platform=false/" "$_tmp/aba.conf"
out=$(run_status)
if [ "$(get_key "$out" transfer_excl_release)" = "false" ]; then
	_pass "Platform included → transfer_excl_release=false"
else
	_fail "Platform included → should be false, got '$(get_key "$out" transfer_excl_release)'"
fi

# Platform excluded, ISC not user-managed → true
setup_mirror_dir
write_isc 0
sed -i "s/^excl_platform=.*/excl_platform=true/" "$_tmp/aba.conf"
out=$(run_status)
if [ "$(get_key "$out" transfer_excl_release)" = "true" ]; then
	_pass "Platform excluded + auto-managed ISC → transfer_excl_release=true"
else
	_fail "Platform excluded + auto-managed ISC → should be true, got '$(get_key "$out" transfer_excl_release)'"
fi

# Platform excluded, ISC user-managed → false (user owns the config)
setup_mirror_dir
touch "$_tmp/mirror/data/.created"
sleep 0.1
write_isc 0
sed -i "s/^excl_platform=.*/excl_platform=true/" "$_tmp/aba.conf"
out=$(run_status)
if [ "$(get_key "$out" transfer_excl_release)" = "false" ]; then
	_pass "Platform excluded + user-managed ISC → transfer_excl_release=false"
else
	_fail "Platform excluded + user-managed ISC → should be false, got '$(get_key "$out" transfer_excl_release)'"
fi

# --- Summary ---
echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
