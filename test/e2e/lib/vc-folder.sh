#!/usr/bin/env bash
# Pool VMs must use /Datacenter/vm/aba-e2e/poolN.
# abatesting is the production folder. E2E must not create or keep clusters there.

# $1 is a VC_FOLDER value. 0 when it is exactly one e2e pool folder.
_e2e_vc_folder_allowed() {
	case "$1" in
		/Datacenter/vm/aba-e2e/pool[1-6]) return 0 ;;
		*) return 1 ;;
	esac
}

# $1 is a govc VM path, $2 is the pool number. 0 when the cluster folder
# directly under abatesting belongs to that pool (e2e-standard1 is pool 1).
# Another pool's folder, and a longer number that only ends with the same
# digit (e2e-sno12 versus pool 2), do not match.
_e2e_abatesting_path_is_pool() {
	local path="$1"
	local pool="$2"
	local name stem

	[[ "$pool" =~ ^[1-6]$ ]] || return 1
	name=${path#/Datacenter/vm/abatesting/}
	[ "$name" != "$path" ] || return 1
	name=${name%%/*}
	case "$name" in
		e2e-*"$pool") ;;
		*) return 1 ;;
	esac
	stem=${name%"$pool"}
	case "$stem" in
		*[!0-9]) return 0 ;;
	esac
	return 1
}

# Rewrite VC_FOLDER in one vmware.conf. $1 file, $2 folder, $3 datastore (optional).
# A missing or empty file is left alone: aba copies ~/.vmware.conf when the
# repo file is empty, so the home file is the one that must be right.
# Returns 1 when the file still names another folder after the edit.
_e2e_rewrite_vc_file() {
	local file="$1"
	local folder="$2"
	local ds="${3:-}"
	local bad

	[ -e "$file" ] || return 0
	[ -s "$file" ] || return 0
	grep -q 'VC_FOLDER=' "$file" || return 0

	sed -i -E "s#^[#[:space:]]*(export[[:space:]]+)?VC_FOLDER=.*#VC_FOLDER=${folder}#" "$file" || return 1
	if [ -n "$ds" ]; then
		sed -i -E "s#^[#[:space:]]*(export[[:space:]]+)?GOVC_DATASTORE=.*#GOVC_DATASTORE=${ds}#" "$file" || return 1
	fi

	if grep -q 'abatesting' "$file"; then
		echo "  FATAL: $file still contains abatesting" >&2
		return 1
	fi
	bad=$(grep -E '^VC_FOLDER=' "$file" | grep -vx "VC_FOLDER=${folder}" || true)
	if [ -n "$bad" ]; then
		echo "  FATAL: $file has VC_FOLDER other than ${folder}: $bad" >&2
		return 1
	fi
	grep -qx "VC_FOLDER=${folder}" "$file"
}
