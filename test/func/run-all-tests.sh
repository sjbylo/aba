#!/bin/bash
# Test runner - runs all functional tests and reports results
#
# Usage: test/func/run-all-tests.sh [--unit|--integration|--all|--env]
#
#   --unit          Fast tests, no downloads, no side effects
#   --integration   Slower tests, may download files, still safe
#   --all           Unit + integration (default) -- safe to run anytime
#   --env           Tests requiring special environment (E2E pools, remote
#                   hosts, root/sudo, tmux, s390x). NEVER run automatically
#                   -- these touch real infrastructure.

cd "$(dirname "$0")/../.."

mode="${1:---all}"

# Acquire lock to prevent multiple test runs
TEST_LOCK_FILE="$HOME/.aba/test-runner.lock"
mkdir -p "$HOME/.aba"

exec 200>"$TEST_LOCK_FILE"
if ! flock -n 200; then
	echo "Error: Another test run is already in progress." >&2
	echo "Wait for it to complete, or remove: $TEST_LOCK_FILE" >&2
	exit 1
fi
# Lock automatically released when script exits

# Color output helpers
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

run_test() {
	local test_file="$1"
	local test_name=$(basename "$test_file" .sh)
	
	echo ""
	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	echo "Running: $test_name"
	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	
	if "$test_file"; then
		echo -e "${GREEN}✓ PASSED${NC}: $test_name"
		return 0
	else
		echo -e "${RED}✗ FAILED${NC}: $test_name"
		return 1
	fi
}

# ─────────────────────────────────────────────────────────────────────────────
# UNIT TESTS — fast, no downloads, no network, no side effects
# ─────────────────────────────────────────────────────────────────────────────
unit_tests=(
	# Architecture / lint
	test/func/test-no-aba-root-in-registry-scripts.sh
	test/func/test-aba-root-only-in-aba-sh.sh
	test/func/test-symlinks-exist.sh
	test/func/test-preflight-check.sh
	test/func/test-externalized-targets.sh

	# Core functions
	test/func/test-aba-wait-show.sh
	test/func/test-ask-function.sh
	test/func/test-try-cmd.sh
	test/func/test-replace-value-conf.sh
	test/func/test-password-handling.sh

	# run_once subsystem
	test/func/test-run-once-task-consistency.sh
	test/func/test-run-once-failed-cleanup.sh
	test/func/test-run-once-reliability.sh
	test/func/test-run-once-ttl.sh
	test/func/test-run-once-ttl-race.sh
	test/func/test-run-once-parallel-validation.sh
	test/func/test-run-once-validation-cwd-mismatch.sh
	test/func/test-run-once-validation-reread-race.sh
	test/func/test-run-once-waiting-message.sh
	test/func/test-run-once-wait-start-race.sh
	test/func/test-self-heal-validation.sh

	# Config / normalize
	test/func/test-normalize-conf-pipeline.sh
	test/func/test-config-value-downstream.sh
	test/func/test-cluster-flag-forwarding.sh
	test/func/test-resource-pool-resolution.sh

	# Cluster / VM
	test/func/test-cluster-readiness.sh
	test/func/test-vip-collision.sh
	test/func/test-vip-dig-line.sh
	test/func/test-cluster-config-counts.sh
	test/func/test-vlan-bond-prefix.sh
	test/func/test-write-usb-override.sh
	test/func/test-auth-backup.sh
	test/func/test-install-stamp.sh
	test/func/test-oc-mirror-url.sh
	test/func/test-container-auth-merge.sh
	test/func/test-agent-wait-skip.sh
	test/func/test-make-regen-install-config.sh
	test/func/test-vm-power-helpers.sh
	test/func/test-vm-provider.sh
	test/func/test-vmw-kvm-verify.sh
	test/func/test-preflight-check-vsphere.sh
	test/func/test-vmware-required-privileges.sh

	# Mirror / registry
	test/func/test-reg-stale-report.sh
	test/func/test-state-management.sh

	# Bundle / backup
	test/func/test-primed-bundle-scenarios.sh
	test/func/test-backup-repo-dir-name.sh
	test/func/test-bundle-sort-order.sh
	test/func/test-transfer-primed.sh
	test/func/test-deploy-primed.sh

	# Day2 / operators
	test/func/test-day2-connected-cluster.sh
	test/func/test-day2-waves.sh
	test/func/test-operator-sets.sh
	test/func/test-catalog-index-format.sh

	# Status / CLI
	test/func/test-status-shell-keys.sh

	# CLI tools
	test/func/test-extra-clis.sh
)

# ─────────────────────────────────────────────────────────────────────────────
# INTEGRATION TESTS — may download files, use podman, take minutes; still safe
# ─────────────────────────────────────────────────────────────────────────────
integration_tests=(
	# CLI download pipeline
	test/func/test-cli-download-wait.sh
	test/func/test-cli-download-pipeline.sh
	test/func/test-download-before-install-race.sh
	test/func/test-download-install-race.sh

	# Catalog / ISC
	test/func/test-catalog-helpers.sh
	test/func/test-catalog-canary.sh
	test/func/test-catalog-temp-cleanup.sh
	test/func/test-download-catalog-simple.sh
	test/func/test-extract-catalog-index.sh
	test/func/test-isc-generation.sh
	test/func/test-show-ops.sh

	# Bundle
	test/func/test-bundle-tar-output.sh
)

# ─────────────────────────────────────────────────────────────────────────────
# ENVIRONMENT TESTS — require special infrastructure, NEVER run in --all
# These touch real VMs, remote hosts, or need root/sudo/tmux/s390x.
# Run only with explicit: run-all-tests.sh --env
# ─────────────────────────────────────────────────────────────────────────────
env_tests=(
	# Destructive: deletes real ~/bin tools, run_once state, or modifies core scripts
	test/func/test-bundle-mode-background-extraction.sh  # Deletes ~/bin/{oc,oc-mirror,...}, .bundle
	test/func/test-bg-download-fg-make-race.sh           # Deletes ~/bin/govc, cli tarballs
	test/func/test-mirror-save-workflow.sh                # Deletes ~/bin/oc-mirror, mirror data
	test/func/test-aba-root-cleanup.sh                    # Clears .index/ and catalog state
	test/func/test-connectivity-checks.sh                 # sed -i on real scripts/include_all.sh

	# Requires special infrastructure (real VMs, remote hosts, root, tmux, s390x)
	test/func/test-e2e-framework.sh        # Deploys/stops real E2E pool VMs
	test/func/test-e2e-cleanup.sh          # Installs registry on conN, cleans clusters
	test/func/test-docker-registry.sh      # Installs real Docker registry on conN
	test/func/test-reg-uninstall-idempotent.sh  # Must run ON conno.example.com
	test/func/test-govc-error-handling.sh  # Needs real govc + vCenter + VM
	test/func/test-infra-auto.sh           # Needs root/sudo, dnsmasq, chrony
	test/func/test-linuxone.sh             # Must run on s390x LinuxONE host
)

passed=0
failed=0
skipped=0

echo "╔════════════════════════════════════════════════════════════╗"
echo "║          ABA Functional Test Suite                        ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Working directory: $PWD"
echo "Test mode: $mode"

run_category() {
	local label="$1"
	shift
	local -n tests_ref=$1

	echo ""
	echo "┌────────────────────────────────────────────────────────┐"
	printf "│  %-55s│\n" "$label"
	echo "└────────────────────────────────────────────────────────┘"

	for test in "${tests_ref[@]}"; do
		if [ -f "$test" ]; then
			if run_test "$test"; then
				passed=$(( passed + 1 ))
			else
				failed=$(( failed + 1 ))
			fi
		else
			echo -e "${YELLOW}⊘ SKIPPED${NC}: $test (not found)"
			skipped=$(( skipped + 1 ))
		fi
	done
}

# Run unit tests
if [ "$mode" = "--unit" ] || [ "$mode" = "--all" ]; then
	run_category "UNIT TESTS (fast, no side effects)" unit_tests
fi

# Run integration tests
if [ "$mode" = "--integration" ] || [ "$mode" = "--all" ]; then
	run_category "INTEGRATION TESTS (may take several minutes)" integration_tests
fi

# Run environment-specific tests (only when explicitly requested)
if [ "$mode" = "--env" ]; then
	echo ""
	echo -e "${YELLOW}⚠  WARNING: Environment tests touch real infrastructure (E2E pools, remote hosts).${NC}"
	echo -e "${YELLOW}   Only run these when no E2E tests are active and the target hosts are available.${NC}"
	run_category "ENVIRONMENT TESTS (real infrastructure)" env_tests
fi

# Summary
echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                    TEST SUMMARY                            ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo -e "  ${GREEN}Passed${NC}:  $passed"
echo -e "  ${RED}Failed${NC}:  $failed"
echo -e "  ${YELLOW}Skipped${NC}: $skipped"
echo ""

if [ $failed -eq 0 ]; then
	echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
	echo -e "${GREEN}║          ✓ ALL TESTS PASSED                                ║${NC}"
	echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
	exit 0
else
	echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
	echo -e "${RED}║          ✗ SOME TESTS FAILED                               ║${NC}"
	echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
	exit 1
fi
