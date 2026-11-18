#!/bin/bash
# Load exactly one distribution file.
#
# The functions in that file are the distribution. Callers do not test
# the key. A missing or empty key, and any value other than okd, loads
# OpenShift. verify-aba-conf rejects a value that is neither ocp nor okd.
#
# aba.conf is the source of truth. An exported distribution= is ignored.
# include_all.sh calls dist_load once, after aba.sh has written the key.

dist_load() {
	local d="" here repo line

	here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
	repo="$(dirname "$here")"

	if [ -f "$repo/aba.conf" ]; then
		line="$(grep -E '^[[:space:]]*distribution=' "$repo/aba.conf" | tail -1 || true)"
		d="${line#*=}"				# value after the first =
		d="${d%%#*}"				# drop an inline comment
		d="${d#"${d%%[![:space:]]*}"}"		# trim leading whitespace
		d="${d%"${d##*[![:space:]]}"}"		# trim trailing whitespace
		d="${d#\"}"				# drop one leading double quote
		d="${d%\"}"				# drop one trailing double quote
		d="${d#\'}"				# drop one leading single quote
		d="${d%\'}"				# drop one trailing single quote
	fi

	case "$d" in
		okd) source "$here/dist-okd.sh" ;;
		*) source "$here/dist-ocp.sh" ;;
	esac
}
