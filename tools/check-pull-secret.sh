#!/bin/bash
# Check that a pull secret can pull from each image registry it names.
# cloud.openshift.com is not an image registry. A normal Red Hat pull secret
# stores the same credential there as for quay.io, so that entry is reported
# and does not fail the check.
#
# The secret is never printed.
#
# Usage: check-pull-secret.sh [pull-secret.json]
#        With no file, ~/.pull-secret.json is used.
#
#   check-pull-secret.sh ~/.pull-secret.json
#   check-pull-secret.sh /tmp/pull-secret-temp.bin

set -euo pipefail

usage() {
	sed -n '2,12p' "$0" | sed 's/^# \?//'
	exit "${1:-0}"
}

file=
while [ $# -gt 0 ]; do
	case "$1" in
		-h|--help) usage 0 ;;
		-*)
			echo "Unknown option: $1" >&2
			usage 1
			;;
		*)
			if [ -n "$file" ]; then
				echo "Only one pull secret file can be checked." >&2
				usage 1
			fi
			file=$1
			shift
			;;
	esac
done

[ -n "$file" ] || file=$HOME/.pull-secret.json

if [ ! -f "$file" ] || [ ! -r "$file" ]; then
	echo "Pull secret file not found: $file" >&2
	exit 1
fi
if ! jq -e '.auths | type == "object"' "$file" >/dev/null 2>&1; then
	echo "Pull secret is not a JSON object with an auths map: $file" >&2
	exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
	echo "curl is required." >&2
	exit 1
fi

# GNU coreutils accepts -d. macOS wants -D.
b64dec() {
	if printf '' | base64 -d >/dev/null 2>&1; then
		base64 -d
	else
		base64 -D
	fi
}

tmp=$(mktemp -d)
chmod 700 "$tmp"
trap 'rm -rf "$tmp"' EXIT

# URL is always the last argument. Prints the HTTP status. Never prints the body.
_curl() {
	local out=$1
	shift
	curl -sS --max-time 30 -o "$out" -w '%{http_code}' "$@" || true
}

_header() {
	local name=$1 file=$2
	awk -v name="$name" 'BEGIN { name = tolower(name) }
		{ line = $0; sub(/\r$/, "", line); low = tolower(line) }
		low ~ ("^" name ":") {
			sub(/^[^:]*:[[:space:]]*/, "", line)
			print line
			exit
		}' "$file"
}

# Read user and password into the named variables. Prints nothing.
# Caller names the variables that receive the username and password.
# Those names must not be locals here, or the values never leave this function.
_load_creds() {
	local host=$1 uvar=$2 pvar=$3 auth decoded _user _pass
	auth=$(jq -r --arg h "$host" '.auths[$h].auth // empty' "$file")
	if [ -n "$auth" ]; then
		decoded=$(printf '%s' "$auth" | tr -d '\n' | b64dec 2>/dev/null || true)
		_user=${decoded%%:*}
		_pass=${decoded#*:}
	else
		_user=$(jq -r --arg h "$host" '.auths[$h].username // empty' "$file")
		_pass=$(jq -r --arg h "$host" '.auths[$h].password // empty' "$file")
	fi
	if [ -z "$_user" ] || [ -z "$_pass" ]; then
		return 1
	fi
	printf -v "$uvar" '%s' "$_user"
	printf -v "$pvar" '%s' "$_pass"
}

# Ask the registry for a pull token. Prints the token, or nothing.
_token() {
	local host=$1 repo=$2 user=$3 pass=$4 realm service code
	code=$(_curl "$tmp/v2" -D "$tmp/v2.hdr" "https://$host/v2/")
	realm=$(_header www-authenticate "$tmp/v2.hdr" | sed -n 's/.*realm="\([^"]*\)".*/\1/p')
	service=$(_header www-authenticate "$tmp/v2.hdr" | sed -n 's/.*service="\([^"]*\)".*/\1/p')
	if [ -z "$realm" ]; then
		return 1
	fi
	if [ -n "$service" ]; then
		code=$(_curl "$tmp/token" -u "$user:$pass" -G \
			--data-urlencode "service=$service" \
			--data-urlencode "scope=repository:${repo}:pull" \
			"$realm")
	else
		code=$(_curl "$tmp/token" -u "$user:$pass" -G \
			--data-urlencode "scope=repository:${repo}:pull" \
			"$realm")
	fi
	[ "$code" = "200" ] || return 1
	jq -r '.token // .access_token // empty' "$tmp/token" 2>/dev/null || true
}

# 0 when the token can read the repository tag list.
_can_pull() {
	local host=$1 repo=$2 token=$3 code
	[ -n "$token" ] || return 1
	code=$(_curl "$tmp/tags" -H "Authorization: Bearer $token" \
		"https://$host/v2/${repo}/tags/list")
	[ "$code" = "200" ] || return 1
	jq -e '.tags | type == "array"' "$tmp/tags" >/dev/null 2>&1
}

# One repository on registry.connect.redhat.com. The catalog chooses a
# current image so the check does not depend on a name that was removed.
_connect_repo() {
	local code repo
	code=$(_curl "$tmp/catalog" \
		"https://catalog.redhat.com/api/containers/v1/repositories?filter=registry==registry.connect.redhat.com&page_size=5")
	[ "$code" = "200" ] || return 1
	repo=$(jq -r '.data[0].repository // empty' "$tmp/catalog" 2>/dev/null || true)
	[ -n "$repo" ] || return 1
	printf '%s\n' "$repo"
}

_known_repo() {
	case "$1" in
		registry.redhat.io) printf '%s\n' "ubi9/ubi" ;;
		quay.io) printf '%s\n' "openshift-release-dev/ocp-release" ;;
		registry.connect.redhat.com) _connect_repo ;;
		*) return 1 ;;
	esac
}

_report() {
	printf '%-6s %-32s %s\n' "$1" "$2" "$3"
}

fails=0
checked=0

while IFS= read -r host; do
	[ -n "$host" ] || continue
	checked=$(( checked + 1 ))
	if [ "$host" = "cloud.openshift.com" ]; then
		cauth=$(jq -r '.auths["cloud.openshift.com"].auth // empty' "$file")
		qauth=$(jq -r '.auths["quay.io"].auth // empty' "$file")
		if [ -n "$cauth" ] && [ "$cauth" = "$qauth" ]; then
			_report "SKIP" "$host" "not an image registry (same credential as quay.io)"
		else
			_report "SKIP" "$host" "not an image registry"
		fi
		continue
	fi

	repo=$(_known_repo "$host" || true)
	if [ -z "$repo" ]; then
		_report "FAIL" "$host" "no known image to pull from this registry"
		fails=$(( fails + 1 ))
		continue
	fi

	if ! _load_creds "$host" user pass; then
		_report "FAIL" "$host" "auth entry has no username and password"
		fails=$(( fails + 1 ))
		continue
	fi

	token=$(_token "$host" "$repo" "$user" "$pass" || true)
	if _can_pull "$host" "$repo" "$token"; then
		_report "OK" "$host" "pulled $repo"
	elif [ -z "$token" ]; then
		_report "FAIL" "$host" "credential rejected"
		fails=$(( fails + 1 ))
	else
		_report "FAIL" "$host" "credential was accepted but could not pull $repo"
		fails=$(( fails + 1 ))
	fi
done < <(jq -r '.auths | keys[]' "$file")

if [ "$checked" -eq 0 ]; then
	echo "Pull secret has no registries." >&2
	exit 1
fi

echo
if [ "$fails" -eq 0 ]; then
	echo "Pull secret can pull from every image registry it names."
	exit 0
fi
if [ "$fails" -eq 1 ]; then
	echo "Pull secret failed for 1 registry."
else
	echo "Pull secret failed for $fails registries."
fi
exit 1
