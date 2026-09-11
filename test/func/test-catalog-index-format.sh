#!/bin/bash
# Unit tests for catalog index format helpers (no registry access).

set -euo pipefail
cd "$(dirname "$0")/../.."

source scripts/catalog-extract-functions.sh

fail=0
check() {
	local name="$1"
	shift
	if "$@"; then
		echo "  PASS: $name"
	else
		echo "  FAIL: $name"
		fail=$((fail + 1))
	fi
}

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

echo "=== Catalog index format helpers ==="

# Unpadded record
got=$(_index_print 'kove-operator' 'Kove:SDM™ Operator' 'stable')
[[ "$got" == 'kove-operator Kove:SDM™ Operator stable' ]]
check "unpadded _index_print" true

# Quoted channel must fail syntax
printf '%s\n' 'airlock-microgateway Airlock Microgateway "5.1"' > "$tmp"
[[ -n "$(_index_syntax_bad_lines "$tmp")" ]]
check "quoted channel is a syntax error" true

# Quoted package must fail
printf '%s\n' '"airlock-microgateway" Airlock Microgateway 5.1' > "$tmp"
[[ -n "$(_index_syntax_bad_lines "$tmp")" ]]
check "quoted package is a syntax error" true

# Good line
printf '%s\n' 'airlock-microgateway Airlock Microgateway 5.1' > "$tmp"
[[ -z "$(_index_syntax_bad_lines "$tmp")" ]]
check "unquoted 5.1 channel is valid" true

# Missing display
printf '%s\n' 'rhtpa-operator - stable-v1.1' > "$tmp"
[[ -n "$(_index_missing_display_lines "$tmp")" ]]
check "lone dash is missing display" true

printf '%s\n' 'rhtpa-operator Red Hat Trusted Profile Analyzer stable-v1.1' > "$tmp"
[[ -z "$(_index_missing_display_lines "$tmp")" ]]
check "real display name is not missing" true

# Shipped indexes: no missing names, no syntax errors
for f in catalogs/*-operator-index-v*; do
	[ -f "$f" ] || continue
	if [ -n "$(_index_syntax_bad_lines "$f")" ]; then
		echo "  FAIL: syntax: $f"
		_index_syntax_bad_lines "$f" | head -3
		fail=$((fail + 1))
		continue
	fi
	if [ -n "$(_index_missing_display_lines "$f")" ]; then
		echo "  FAIL: missing display: $f"
		_index_missing_display_lines "$f" | head -3
		fail=$((fail + 1))
		continue
	fi
done
echo "  PASS: shipped catalogs/ indexes (syntax + display names)"

# Local FBC fixtures from v4.16 image, if present
if [ -d /tmp/aba-cat-416/rhtpa-operator ] && [ -d /tmp/aba-cat-416/deployment-validation-operator ]; then
	line=$(_extract_from_json /tmp/aba-cat-416/rhtpa-operator /tmp/aba-cat-416/rhtpa-operator/catalog.json)
	[[ "$line" == rhtpa-operator*"Red Hat Trusted Profile Analyzer"*stable-v1.1 ]]
	check "extract rhtpa JSON CSV blob" true
	line=$(_extract_from_yaml /tmp/aba-cat-416/deployment-validation-operator/catalog.yml)
	[[ "$line" == deployment-validation-operator*"Deployment Validation Operator"*alpha ]]
	check "extract DVO YAML CSV blob" true
else
	echo "  SKIP: /tmp/aba-cat-416 fixtures not present"
fi

echo ""
if [ "$fail" -gt 0 ]; then
	echo "FAILED: $fail check(s)"
	exit 1
fi
echo "All catalog index format checks passed"
exit 0
