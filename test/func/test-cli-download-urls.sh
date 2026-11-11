#!/bin/bash
# Test: CLI download URL validity — probe all download URLs without fetching files
#
# Uses HEAD requests (curl -sfI) to verify every download URL that the CLI
# Makefile would use is reachable (HTTP 200). Catches broken URLs before they
# become runtime errors during aba save/sync/bundle.
#
# Tests with:
#   1. Current ocp_version from aba.conf (GA/stable)
#   2. An EC (engineering candidate) version if available
#
# Usage:  bash test/func/test-cli-download-urls.sh
# Duration: ~5-10 seconds (HEAD requests only, no downloads)

set -o pipefail
cd "$(dirname "$0")/../.." || exit 1
source scripts/include_all.sh
trap - ERR

OCP_VER=$(grep '^ocp_version=' aba.conf | cut -d= -f2 | awk '{print $1}')
[ -z "$OCP_VER" ] && echo "FATAL: ocp_version not set in aba.conf" && exit 1
OCP_MAJOR=$(echo "$OCP_VER" | cut -d. -f1)
OCP_MAJOR_MINOR=$(echo "$OCP_VER" | cut -d. -f1,2)

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass_count=0
fail_count=0

test_pass() { echo -e "  ${GREEN}✓ PASS${NC}: $1"; pass_count=$(( pass_count + 1 )); }
test_fail() { echo -e "  ${RED}✗ FAIL${NC}: $1"; fail_count=$(( fail_count + 1 )); }

# Extract download URLs from the Makefile for a given ocp_version.
# Uses Make's --eval to print resolved URL variables without downloading.
extract_urls() {
	local ver="$1" dist="${2:-}"
	make -C cli --no-print-directory \
		--eval='probe-urls: ; @echo "$(rhel9_oc_url)"; echo "$(rhel8_oc_url)"; echo "$(openshift_install_url)/$(openshift_install_file)"; echo "$(oc_mirror_base_url)/oc-mirror.tar.gz"; echo "$(oc_mirror_base_url)/oc-mirror.rhel9.tar.gz"; echo "$(butane_binary_file_url)"; echo "$(govc_url)/$(govc_tar_file)"' \
		probe-urls ocp_version="$ver" platform=vmw ${dist:+distribution=$dist} 2>/dev/null | grep '^https://'
}

# HEAD-probe a URL. Returns 0 if reachable (HTTP 200), 1 otherwise.
probe_url() {
	local url="$1"
	local http_code
	http_code=$(curl -sI --connect-timeout 10 -o /dev/null -w '%{http_code}' -L "$url" 2>/dev/null)
	[ "$http_code" = "200" ]
}

# --- Test 1: Current ocp_version (GA/stable) URLs ---

echo ""
echo "=== Test 1: URL validity for current ocp_version=$OCP_VER ==="
echo ""

urls=$(extract_urls "$OCP_VER")
if [ -z "$urls" ]; then
	test_fail "No URLs extracted from Makefile for version $OCP_VER"
else
	while IFS= read -r url; do
		label=$(basename "$url")
		if probe_url "$url"; then
			test_pass "$label ($url)"
		else
			test_fail "$label ($url)"
		fi
	done <<< "$urls"
fi

# --- Test 2: EC (engineering candidate) version URLs ---
# EC versions use ocp-dev-preview/ for oc/openshift-install but should
# still use the pinned stable channel for oc-mirror.

echo ""
echo "=== Test 2: EC version oc-mirror URL resolution ==="
echo ""

# Construct a plausible EC version from the current major.minor
EC_VER="${OCP_MAJOR_MINOR}.0-ec.1"

# OKD has no engineering candidates (its tags end in -okd-scos.N)
if [ "$(dist_of)" = "okd" ]; then
	echo "  SKIP: no EC releases for distribution okd"
	EC_VER=""
fi

# For EC versions, oc-mirror should either:
#   a) Use the dev-preview path (if oc-mirror IS published there), or
#   b) Fall back to the pinned stable channel (if NOT published there).
# Either way, the resolved URL must be reachable.
ec_urls=""
[ -n "$EC_VER" ] && ec_urls=$(extract_urls "$EC_VER")
if [ -z "$EC_VER" ]; then
	:
elif [ -z "$ec_urls" ]; then
	test_fail "No URLs extracted for EC version $EC_VER"
else
	while IFS= read -r url; do
		label=$(basename "$url")
		case "$url" in
			*oc-mirror*)
				if echo "$url" | grep -q 'ocp-dev-preview'; then
					# EC oc-mirror from dev-preview — verify it's actually there
					if probe_url "$url"; then
						test_pass "EC oc-mirror: $label (dev-preview, available)"
					else
						test_fail "EC oc-mirror resolved to dev-preview but is NOT reachable: $url"
					fi
				elif probe_url "$url"; then
					test_pass "EC oc-mirror: $label (fell back to pinned channel)"
				else
					test_fail "EC oc-mirror unreachable: $url"
				fi
				;;
			*ocp-dev-preview*)
				# EC oc/openshift-install may or may not exist — skip without failing
				echo -e "  ${YELLOW}SKIP${NC}: $label (EC dev-preview, may not exist)"
				;;
			*)
				# Non-OCP URLs (govc, butane) should always work
				if probe_url "$url"; then
					test_pass "EC $label"
				else
					test_fail "EC $label unreachable: $url"
				fi
				;;
		esac
	done <<< "$ec_urls"
fi

# --- Test 3: oc-mirror pinned channel sanity ---
# Verify the pin target itself is reachable (catches stale pins).

echo ""
echo "=== Test 3: oc-mirror pinned channel reachability ==="
echo ""

pin=$(make -C cli --no-print-directory \
	--eval='show-pin: ; @echo "$(oc_mirror_pin)"' show-pin 2>/dev/null)

if [ -z "$pin" ]; then
	test_fail "Could not read oc_mirror_pin from Makefile"
else
	pin_url="https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/${pin}/oc-mirror.rhel9.tar.gz"
	if probe_url "$pin_url"; then
		test_pass "Pinned channel $pin is reachable"
	else
		test_fail "Pinned channel $pin is NOT reachable: $pin_url"
	fi
fi

# --- Test 4: OKD URL resolution (no network: the URLs are only compared as strings) ---
# The live HEAD probe of the OKD URLs is Test 1 when aba.conf has distribution=okd.

echo ""
echo "=== Test 4: OKD URLs are built from ocp_version (no network) ==="
echo ""

okd_base="https://github.com/okd-project/okd/releases/download"
for okd_ver in 4.21.0-okd-scos.11 4.20.0-okd-scos.3 5.0.0-okd-scos.5; do
	okd_urls=$(extract_urls "$okd_ver" okd)
	for want in \
		"$okd_base/$okd_ver/openshift-client-linux-amd64-rhel9-$okd_ver.tar.gz" \
		"$okd_base/$okd_ver/openshift-client-linux-amd64-rhel8-$okd_ver.tar.gz" \
		"$okd_base/$okd_ver/openshift-install-linux-$okd_ver.tar.gz"; do
		if grep -qxF "$want" <<< "$okd_urls"; then
			test_pass "OKD $okd_ver: $(basename "$want")"
		else
			test_fail "OKD $okd_ver: expected $want"
		fi
	done
	# oc-mirror keeps the OCP pin
	if grep -qE "^https://mirror\.openshift\.com/pub/openshift-v4/[^/]+/clients/ocp/stable-[0-9.]+/oc-mirror\.rhel9\.tar\.gz$" <<< "$okd_urls"; then
		test_pass "OKD $okd_ver: oc-mirror stays on the pinned OCP channel"
	else
		test_fail "OKD $okd_ver: oc-mirror URL is not the pinned OCP channel"
	fi
	# nothing else from the OCP CDN for the OKD client/installer
	if grep -E "mirror\.openshift\.com.*(openshift-client|openshift-install)" <<< "$okd_urls" | grep -q .; then
		test_fail "OKD $okd_ver: oc / openshift-install URL still points at mirror.openshift.com"
	else
		test_pass "OKD $okd_ver: oc / openshift-install no longer point at mirror.openshift.com"
	fi
done

# --- Summary ---

echo ""
echo "========================================"
echo "=== Results: $pass_count passed, $fail_count failed ==="
echo "========================================"

if [ "$fail_count" -gt 0 ]; then
	echo ""
	echo -e "${RED}FAILED${NC} — see output above"
	exit 1
fi

echo ""
echo "All download URLs are valid."
