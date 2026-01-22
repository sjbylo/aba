#!/bin/bash
# Test script for registry refactoring (quay-registry and docker-registry)
# Verifies that registry artifacts are properly managed in cli/ directory

cd "$(dirname "$0")/../.." || exit 1

source scripts/include_all.sh

# Test counter
TESTS_RUN=0
TESTS_PASSED=0

test_check() {
	TESTS_RUN=$((TESTS_RUN + 1))
	local desc="$1"
	shift
	
	if "$@" >/dev/null 2>&1; then
		aba_info_ok "✓ $desc"
		TESTS_PASSED=$((TESTS_PASSED + 1))
		return 0
	else
		aba_abort "✗ $desc"
		return 1
	fi
}

aba_info "=== Testing Registry Refactoring ==="
echo

aba_info "1. Testing cli/Makefile targets..."
test_check "quay-registry target exists" make -n -C cli quay-registry
test_check "docker-registry target exists" make -n -C cli docker-registry
test_check "quay-registry in out-install-all" bash -c "make -C cli out-install-all | grep -q quay-registry"
test_check "registry files in out-download-all" bash -c "make -C cli out-download-all | grep -q 'mirror-registry-amd64.tar.gz'"
test_check "docker image in out-download-all" bash -c "make -C cli out-download-all | grep -q 'docker-reg-image.tgz'"
echo

aba_info "2. Testing include_all.sh functions..."
test_check "TASK_QUAY_REG constant defined" bash -c "source scripts/include_all.sh && [[ -n \$TASK_QUAY_REG ]]"
test_check "TASK_DOCKER_REG constant defined" bash -c "source scripts/include_all.sh && [[ -n \$TASK_DOCKER_REG ]]"
test_check "ensure_quay_registry function exists" bash -c "source scripts/include_all.sh && type ensure_quay_registry"
test_check "ensure_docker_registry function exists" bash -c "source scripts/include_all.sh && type ensure_docker_registry"
test_check "Old ensure_mirror_registry removed" bash -c "! grep -q 'ensure_mirror_registry()' scripts/include_all.sh"
echo

aba_info "3. Testing ensure-cli.sh wrapper..."
test_check "quay-registry accepted by ensure-cli.sh" bash -c "scripts/ensure-cli.sh 2>&1 | grep -q quay-registry"
test_check "docker-registry accepted by ensure-cli.sh" bash -c "scripts/ensure-cli.sh 2>&1 | grep -q docker-registry"
test_check "Old mirror-registry removed from ensure-cli.sh" bash -c "! grep -q 'mirror-registry)' scripts/ensure-cli.sh || grep -q 'quay-registry)' scripts/ensure-cli.sh"
echo

aba_info "4. Testing mirror/Makefile..."
test_check "mirror/Makefile uses ensure-cli.sh quay-registry" bash -c "make -n -C mirror install 2>&1 | grep -q 'ensure-cli.sh quay-registry'"
test_check "docker-registry uses ensure-cli.sh" bash -c "make -n -C mirror install-docker-registry 2>&1 | grep -q 'ensure-cli.sh docker-registry'"
test_check "docker-registry loads from ../cli/" bash -c "make -n -C mirror install-docker-registry 2>&1 | grep -q '../cli/docker-reg-image.tgz'"
test_check "Old download-registries target removed" bash -c "! grep -q '^download-registries:' mirror/Makefile"
test_check "Old mirror-registry download removed" bash -c "! grep -q '^mirror-registry-amd64.tar.gz:' mirror/Makefile"
echo

aba_info "5. Testing reg-install.sh script..."
test_check "Uses mirror-registry (not ./mirror-registry)" bash -c "! grep -q '\./mirror-registry' scripts/reg-install.sh"
test_check "Calls ensure_quay_registry" bash -c "grep -q 'ensure_quay_registry' scripts/reg-install.sh"
test_check "Uses TASK_QUAY_REG constant" bash -c "grep -q 'TASK_QUAY_REG' scripts/reg-install.sh"
test_check "Old ensure_mirror_registry removed" bash -c "! grep -q 'ensure_mirror_registry' scripts/reg-install.sh"
echo

aba_info "6. Testing reg-uninstall.sh script..."
test_check "Uses mirror-registry (not ./mirror-registry)" bash -c "! grep -q '\./mirror-registry' scripts/reg-uninstall.sh"
echo

aba_info "7. Testing aba.sh main script..."
test_check "Old mirror:reg:download removed" bash -c "! grep -q 'mirror:reg:download' scripts/aba.sh"
test_check "Registry comment updated" bash -c "grep -q 'Registry downloads.*managed in cli/' scripts/aba.sh"
echo

aba_info "8. Testing TUI script..."
test_check "Old mirror download removed from TUI" bash -c "! grep -q 'mirror:reg:download' tui/abatui_experimental.sh"
echo

# Summary
echo
if [ $TESTS_PASSED -eq $TESTS_RUN ]; then
	aba_info_ok "=== All $TESTS_RUN tests passed! ==="
	exit 0
else
	aba_abort "=== $TESTS_PASSED/$TESTS_RUN tests passed ==="
	exit 1
fi
