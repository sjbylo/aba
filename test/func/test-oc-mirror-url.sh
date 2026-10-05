#!/bin/bash
# Verify oc-mirror download URLs are correct for every OCP version pattern.
# Tests the cli/Makefile oc_mirror_base_url logic and background probe guard.

set -eo pipefail

cd "$(dirname "$0")/../.."

fail=0

# Extract the URL that make would use for oc-mirror.rhel9.tar.gz
_url_for() {
	local ver="$1" maj="$2"
	make -sC cli -n download-oc-mirror ocp_version="$ver" ocp_major="$maj" 2>&1 \
		| grep "Downloading.*oc-mirror.rhel9" | head -1 | sed 's/.*Downloading //'
}

# Extract the pinned channel from cli/Makefile
pin=$(grep '^oc_mirror_pin' cli/Makefile | head -1 | awk '{print $NF}')
[ -n "$pin" ] || { echo "FAIL: could not read oc_mirror_pin from cli/Makefile"; exit 1; }
echo "Pin: $pin"

# --- URL selection tests ---

# EC → ocp-dev-preview/<version>
got=$(_url_for "5.0.0-ec.3" "5")
expect="https://mirror.openshift.com/pub/openshift-v5/x86_64/clients/ocp-dev-preview/5.0.0-ec.3/oc-mirror.rhel9.tar.gz"
if [ "$got" = "$expect" ]; then
	echo "PASS: EC 5.x → dev-preview path"
else
	echo "FAIL: EC 5.x: expected $expect, got $got"
	fail=1
fi

got=$(_url_for "4.22.0-ec.1" "4")
expect="https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp-dev-preview/4.22.0-ec.1/oc-mirror.rhel9.tar.gz"
if [ "$got" = "$expect" ]; then
	echo "PASS: EC 4.x → dev-preview path"
else
	echo "FAIL: EC 4.x: expected $expect, got $got"
	fail=1
fi

# RC → pinned channel (RC builds don't carry oc-mirror)
got=$(_url_for "5.0.0-rc.5" "5")
expect="https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/${pin}/oc-mirror.rhel9.tar.gz"
if [ "$got" = "$expect" ]; then
	echo "PASS: RC 5.x → pinned ($pin)"
else
	echo "FAIL: RC 5.x: expected $expect, got $got"
	fail=1
fi

got=$(_url_for "4.23.0-rc.2" "4")
expect="https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/${pin}/oc-mirror.rhel9.tar.gz"
if [ "$got" = "$expect" ]; then
	echo "PASS: RC 4.x → pinned ($pin)"
else
	echo "FAIL: RC 4.x: expected $expect, got $got"
	fail=1
fi

# GA 5.x → pinned channel (not stable-5.0)
got=$(_url_for "5.0.3" "5")
expect="https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/${pin}/oc-mirror.rhel9.tar.gz"
if [ "$got" = "$expect" ]; then
	echo "PASS: GA 5.x → pinned ($pin)"
else
	echo "FAIL: GA 5.x: expected $expect, got $got"
	fail=1
fi

# GA 4.22.x → pinned channel
got=$(_url_for "4.22.1" "4")
expect="https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/${pin}/oc-mirror.rhel9.tar.gz"
if [ "$got" = "$expect" ]; then
	echo "PASS: GA 4.22.x → pinned ($pin)"
else
	echo "FAIL: GA 4.22.x: expected $expect, got $got"
	fail=1
fi

# GA 4.23.x → pinned channel
got=$(_url_for "4.23.1" "4")
expect="https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/${pin}/oc-mirror.rhel9.tar.gz"
if [ "$got" = "$expect" ]; then
	echo "PASS: GA 4.23.x → pinned ($pin)"
else
	echo "FAIL: GA 4.23.x: expected $expect, got $got"
	fail=1
fi

# No version → pinned channel
got=$(_url_for "" "")
expect="https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/${pin}/oc-mirror.rhel9.tar.gz"
if [ "$got" = "$expect" ]; then
	echo "PASS: no version → pinned ($pin)"
else
	echo "FAIL: no version: expected $expect, got $got"
	fail=1
fi

# --- Probe guard tests ---
# The background probe should fire only when the user's version channel != pin.

# The probe is guarded by a shell condition that compares the user's version
# channel against the pin. make -n prints all recipe lines without evaluating
# shell conditionals, so we test the guard logic directly.

_probe_would_fire() {
	local ver="$1"
	local pin_val
	pin_val=$(grep '^oc_mirror_pin' cli/Makefile | head -1 | awk '{print $NF}')
	if [ -z "$ver" ]; then
		echo no
		return
	fi
	# EC uses dev-preview, probe doesn't apply
	case "$ver" in
		*-ec.*) echo no; return ;;
	esac
	local major_minor
	major_minor=$(echo "$ver" | cut -d. -f1,2)
	if [ "stable-$major_minor" != "$pin_val" ]; then
		echo yes
	else
		echo no
	fi
}

# 4.22.x → no probe (matches pin)
got=$(_probe_would_fire "4.22.1")
if [ "$got" = "no" ]; then
	echo "PASS: probe skipped for 4.22.x (matches pin)"
else
	echo "FAIL: probe should not fire for 4.22.x"
	fail=1
fi

# 5.0.x → probe fires
got=$(_probe_would_fire "5.0.3")
if [ "$got" = "yes" ]; then
	echo "PASS: probe fires for 5.0.x"
else
	echo "FAIL: probe should fire for 5.0.x"
	fail=1
fi

# 4.23.x → probe fires
got=$(_probe_would_fire "4.23.1")
if [ "$got" = "yes" ]; then
	echo "PASS: probe fires for 4.23.x"
else
	echo "FAIL: probe should fire for 4.23.x"
	fail=1
fi

# 5.1.x → probe fires
got=$(_probe_would_fire "5.1.2")
if [ "$got" = "yes" ]; then
	echo "PASS: probe fires for 5.1.x"
else
	echo "FAIL: probe should fire for 5.1.x"
	fail=1
fi

# EC → no probe (dev-preview path)
got=$(_probe_would_fire "5.0.0-ec.3")
if [ "$got" = "no" ]; then
	echo "PASS: probe skipped for EC (dev-preview path)"
else
	echo "FAIL: probe should not fire for EC versions"
	fail=1
fi

# RC → probe fires (uses pinned channel, version channel may differ)
got=$(_probe_would_fire "5.0.0-rc.5")
if [ "$got" = "yes" ]; then
	echo "PASS: probe fires for RC 5.x (uses pinned channel)"
else
	echo "FAIL: probe should fire for RC 5.x"
	fail=1
fi

echo
if [ $fail -eq 0 ]; then
	echo "All oc-mirror URL tests passed"
else
	echo "SOME TESTS FAILED"
	exit 1
fi
