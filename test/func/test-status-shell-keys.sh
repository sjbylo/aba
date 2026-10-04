#!/bin/bash
# Test: aba status --shell outputs all expected keys
# Regression test for: status command (ADR-015)
# Verifies: repo-status.sh --shell produces all documented keys

cd "$(dirname "$0")/../.."
source scripts/include_all.sh 2>/dev/null

echo "Test: aba status --shell output keys"

failed=0

# Run repo-status.sh --shell and capture output
output=$(bash scripts/repo-status.sh --shell 2>&1)
rc=$?

if [ $rc -ne 0 ]; then
	echo "✗ FAIL: repo-status.sh --shell exited with code $rc"
	failed=1
fi

# All expected keys from the --shell output
expected_keys=(
	aba_installed
	aba_version
	aba_conf_exists
	ocp_version
	ocp_channel
	pull_secret
	internet
	mode
	bundle_flag
	infra_platform
	cli_oc
	cli_oc_mirror
	cli_openshift_install
	reg_installer_quay
	reg_installer_docker
	saved_archives
	mirror_installed
	mirror_has_release
	cluster_count
	cluster_installed_count
	cluster_installing_count
	cluster_configured_count
)

for key in "${expected_keys[@]}"; do
	if echo "$output" | grep -q "^${key}="; then
		echo "✓ PASS: key '$key' present"
	else
		echo "✗ FAIL: key '$key' missing from --shell output"
		failed=1
	fi
done

# Verify output is sourceable (no syntax errors)
if bash -c "eval '$output'" 2>/dev/null; then
	echo "✓ PASS: output is sourceable by bash"
else
	echo "✗ FAIL: output is NOT valid bash (cannot eval)"
	failed=1
fi

# Verify no [ABA] prefix leaks into --shell output
if echo "$output" | grep -q '^\[ABA\]'; then
	echo "✗ FAIL: [ABA] prefix found in --shell output (should be k=v only)"
	failed=1
else
	echo "✓ PASS: no [ABA] prefix in --shell output"
fi

exit $failed
