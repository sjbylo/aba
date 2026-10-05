#!/bin/bash
# A stopped install must not look finished, and upgrade must not rewrite
# container auth before it knows the kubeconfig exists.
# Bugs #1089, #1091, #1130. Does not run openshift-install or upgrade.

set -eo pipefail

cd "$(dirname "$0")/../.."
source scripts/include_all.sh

fail=0

_ec() {
	( exit_unless_install_finished "$1" )
	echo $?
}

got=$(_ec 0)
if [ "$got" = 0 ]; then
	echo "PASS: finished install continues"
else
	echo "FAIL: finished install returned $got"
	fail=1
fi

got=$(_ec 8)
if [ "$got" = 8 ]; then
	echo "PASS: interrupt exits 8"
else
	echo "FAIL: interrupt returned $got"
	fail=1
fi

got=$(_ec 6)
if [ "$got" = 1 ]; then
	echo "PASS: install failure returns to the caller"
else
	echo "FAIL: install failure returned $got"
	fail=1
fi

if grep -q 'exit_unless_install_finished' scripts/monitor-install.sh \
	&& ! grep -q 'ret -eq 8 ] && exit 0' scripts/monitor-install.sh; then
	echo "PASS: mon uses the interrupt exit"
else
	echo "FAIL: mon still turns interrupt into success"
	fail=1
fi

if grep -q 'exit_unless_install_finished' scripts/monitor-bootstrap.sh; then
	echo "PASS: bootstrap uses the interrupt exit"
else
	echo "FAIL: bootstrap still falls through on interrupt"
	fail=1
fi

auth=$(grep -n 'create-containers-auth.sh --load' scripts/cluster-upgrade.sh | head -1 | cut -d: -f1)
kube=$(grep -n 'kubeconfig not found' scripts/cluster-upgrade.sh | head -1 | cut -d: -f1)
if [ -n "$auth" ] && [ -n "$kube" ] && [ "$kube" -lt "$auth" ]; then
	echo "PASS: upgrade checks kubeconfig before writing container auth"
else
	echo "FAIL: upgrade writes container auth at line $auth before the kubeconfig check at line $kube"
	fail=1
fi

exit "$fail"
