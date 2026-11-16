#!/bin/bash
# Load exactly one distribution file.
#
# The functions in that file are the distribution. Callers do not test
# the key. A missing or empty key, and any value other than okd, loads
# OpenShift. verify-aba-conf rejects a value that is neither ocp nor okd.
#
# Called again after --distribution, because include_all.sh is sourced
# before the flags are parsed.

dist_load() {
	local d="${distribution:-}"
	local here repo line

	here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
	repo="$(dirname "$here")"

	# The flag parser sets the variable. A fresh shell has only the file.
	if [ -z "$d" ] && [ -f "$repo/aba.conf" ]; then
		line="$(grep -E '^[[:space:]]*distribution=' "$repo/aba.conf" | tail -1 || true)"
		d="${line#*=}"
		d="${d%%#*}"
		d="${d#"${d%%[![:space:]]*}"}"
		d="${d%"${d##*[![:space:]]}"}"
		d="${d#\"}"
		d="${d%\"}"
		d="${d#\'}"
		d="${d%\'}"
	fi

	case "$d" in
		okd) source "$here/dist-okd.sh" ;;
		*) source "$here/dist-ocp.sh" ;;
	esac
}

dist_load
