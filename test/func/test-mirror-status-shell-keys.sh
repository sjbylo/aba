#!/bin/bash
# Test: mirror-status.sh --shell outputs all expected keys
# Regression test for: TUI depends on a stable set of key=value pairs
# Verifies: all documented keys are present and output is sourceable

cd "$(dirname "$0")/../.." || exit 1
source scripts/include_all.sh 2>/dev/null

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }

echo "=== mirror-status.sh --shell key completeness ==="

_repo=$(pwd)
_tmp=$(mktemp -d)
trap 'rm -rf "$_tmp"' EXIT

# Replicate mirror directory structure
cp aba.conf "$_tmp/aba.conf"
mkdir -p "$_tmp/mirror/data"
cp mirror/mirror.conf "$_tmp/mirror/mirror.conf" 2>/dev/null || \
	echo "# minimal" > "$_tmp/mirror/mirror.conf"

ln -sf "$_repo/scripts" "$_tmp/scripts"
ln -sf "$_repo/cli" "$_tmp/cli"
ln -sf "$_repo/scripts" "$_tmp/mirror/scripts"
ln -sf "$_repo/cli" "$_tmp/mirror/cli"
ln -sf ../aba.conf "$_tmp/mirror/aba.conf"
ln -sfn . "$_tmp/mirror/mirror"
cp -a "$_repo/templates" "$_tmp/templates"
ln -sf "$_tmp/templates" "$_tmp/mirror/templates"

# Minimal ISC
cat > "$_tmp/mirror/data/imageset-config.yaml" <<'EOF'
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  platform:
    channels:
    - name: stable-4.22
      minVersion: "4.22.0"
      maxVersion: "4.22.0"
EOF

# Run mirror-status.sh --shell
output=$(cd "$_tmp/mirror" && bash scripts/mirror-status.sh --shell 2>/dev/null)
rc=$?

if [ $rc -ne 0 ]; then
	_fail "mirror-status.sh --shell exited with code $rc"
else
	_pass "mirror-status.sh --shell exits 0"
fi

# All keys the TUI and CLI consumers depend on
expected_keys=(
	# Mirror identity
	mirror_installed
	mirror_host
	mirror_port
	mirror_path
	mirror_has_release
	mirror_last_action
	mirror_last_action_at

	# Config
	ocp_version
	ocp_channel
	ocp_upgrade_to

	# Exclusions
	excl_platform
	excl_operators
	excl_additional

	# Operators
	operator_count
	operators

	# ISC state
	isc_exists
	isc_user_managed

	# Derived flags
	upgrade_needs_platform
	transfer_excl_release
	warn_operators_excluded
	warn_additional_excluded

	# Upgrade path
	upgrade_path_exists
	upgrade_path_conditional
	upgrade_risks

	# Disk space
	disk_save_summary
	disk_save_short
	disk_save_level
	disk_sync_summary
	disk_sync_short
	disk_sync_level
	disk_load_summary
	disk_load_short
	disk_load_level
)

for key in "${expected_keys[@]}"; do
	if echo "$output" | grep -q "^${key}="; then
		_pass "key '$key' present"
	else
		_fail "key '$key' missing from --shell output"
	fi
done

# Verify output is sourceable (no syntax errors)
if bash -c "eval \"$output\"" 2>/dev/null; then
	_pass "output is sourceable by bash"
else
	_fail "output is NOT valid bash (cannot eval)"
fi

# Verify no [ABA] prefix leaks into --shell output
if echo "$output" | grep -q '^\[ABA\]'; then
	_fail "[ABA] prefix found in --shell output (should be k=v only)"
else
	_pass "no [ABA] prefix in --shell output"
fi

# Verify no stderr leaks into stdout (all lines must be key=value or empty)
bad_lines=$(echo "$output" | grep -v '^[a-z_]*=' | grep -v '^$' || true)
if [ -n "$bad_lines" ]; then
	_fail "non-key=value lines in output: $(echo "$bad_lines" | head -1)"
else
	_pass "all lines are key=value format"
fi

# --- Summary ---
echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
