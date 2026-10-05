#!/bin/bash
# A sha256 image digest is 64 hex digits. A tag and a real digest still match.
# Does not run aba image add, so images.conf is not changed.

set -eo pipefail

cd "$(dirname "$0")/../.."

rx=$(awk -F"'" '/grep -qE/ && /@sha256:/ { print $2; exit }' scripts/aba.sh)
[ -n "$rx" ] || { echo "FAIL: digest regex not found"; exit 1; }

example=$(awk -F'"' '/support-tools@sha256/ { print $2; exit }' scripts/aba.sh)
example=$(echo "$example" | sed 's/^[[:space:]]*//')

digest64=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
digest63=${digest64%?}
digest65=${digest64}a

fail=0
check() {
	local name=$1 ref=$2 want=$3 ok=0
	if echo "$ref" | grep -qE "$rx"; then
		ok=1
	fi
	if [ "$ok" = "$want" ]; then
		echo "PASS: $name"
	else
		echo "FAIL: $name (matched=$ok want=$want) [$ref]"
		fail=1
	fi
}

check "tag" "registry.redhat.io/ubi9/ubi:latest" 1
check "tag with digits" "quay.io/openshift/hello-openshift:1.2.0" 1
check "repo without tag" "quay.io/org/name" 1
check "64 hex digest" "registry.redhat.io/ubi9/ubi@sha256:$digest64" 1
check "error example" "$example" 1
check "one hex digit" "registry.redhat.io/ubi9/ubi@sha256:a" 0
check "63 hex digits" "registry.redhat.io/ubi9/ubi@sha256:$digest63" 0
check "65 hex digits" "registry.redhat.io/ubi9/ubi@sha256:$digest65" 0

exit "$fail"
