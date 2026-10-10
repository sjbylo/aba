#!/bin/bash
# mirror-status.sh -- Report mirror state and run preflight checks
#
# INTENT:    Unified source of truth for all mirror status queries and
#            pre-operation validation. Follows the transfer-info.sh pattern.
# CALLED BY: make -C mirror status, make -C mirror status-preflight,
#            reg-save.sh, reg-sync.sh, reg-load.sh (inline summary),
#            TUI (--shell mode)
# CWD:       mirror/ directory
# REQUIRES:  scripts/include_all.sh (normalize functions, ask(), ISC helpers)
# PRODUCES:  Human-readable summary (default), sourceable key=value (--shell),
#            compact operation summary (op=save, op=sync, op=load),
#            disk verdicts with the summary (--disk),
#            or interactive preflight checks (--preflight)
# SIDE EFFECTS: --preflight may update aba.conf and regenerate ISC
# IDEMPOTENT: Yes (default and --shell are read-only)

set -eo pipefail

source scripts/include_all.sh

[ -z "${INFO_ABA+x}" ] && export INFO_ABA=1

_mode="human"
_op=""
_show_disk=false
for arg in "$@"; do
	case "$arg" in
		shell|--shell)         _mode="shell" ;;
		preflight|--preflight) _mode="preflight" ;;
		disk|--disk)           _show_disk=true ;;
		op=save)               _mode="op"; _op="save" ;;
		op=sync)               _mode="op"; _op="sync" ;;
		op=load)               _mode="op"; _op="load" ;;
	esac
done

# --- Gather state ---

source <(normalize-aba-conf)
source <(normalize-mirror-conf)

_isc="data/imageset-config.yaml"

# Registry state
_mirror_installed=false
[ -f .available ] && _mirror_installed=true

_reg_host="${reg_host:-}"
_reg_port="${reg_port:-}"
_reg_path="${reg_path:-}"

# Release image check (non-blocking -- use cached result if available)
_mirror_has_release=false
if [ "$_mirror_installed" = "true" ]; then
	export regcreds_dir=$HOME/.aba/mirror/$(basename "$PWD")
	if check_release_image 2>/dev/null; then
		_mirror_has_release=true
	fi
fi

# Mirror state from externalized state.sh
_mirror_name=$(basename "$PWD")
_last_action=""
_last_action_at=""
if [ -s "$HOME/.aba/mirror/$_mirror_name/state.sh" ]; then
	# grep exits 1 when the field is absent. That must not abort status.
	_last_action=$(grep '^last_action=' "$HOME/.aba/mirror/$_mirror_name/state.sh" 2>/dev/null | head -1 | cut -d= -f2-) || true
	_last_action_at=$(grep '^last_action_at=' "$HOME/.aba/mirror/$_mirror_name/state.sh" 2>/dev/null | head -1 | cut -d= -f2- | tr -d "'\"") || true
fi

# OCP version
_ver="${ocp_version:-}"
_chan="${ocp_channel:-}"
_upgrade_to="${ocp_upgrade_to:-}"

# Exclusions
_excl_platform="${excl_platform:-}"
_excl_operators="${excl_operators:-}"
_excl_additional="${excl_additional:-}"

# Operators from ISC
_op_count=$(_isc_operator_count "$_isc")
_operators=$(_isc_operator_list "$_isc")

# Additional images from ISC
_add_count=$(_isc_additional_count "$_isc")

# ISC state
_isc_exists=false
_isc_user_managed=false
if [ -f "$_isc" ] && [ -s "$_isc" ]; then
	_isc_exists=true
	# User-managed: ISC is strictly newer than data/.created
	if [ -f data/.created ] && [ "$_isc" -nt data/.created ]; then
		_isc_user_managed=true
	fi
fi

# Upgrade path validation (Cincinnati graph — skipped when offline or no target)
_upgrade_path_exists=""
_upgrade_path_conditional=""
_upgrade_risks=""
if [ -n "$_upgrade_to" ] && [ "$_upgrade_to" != "$_ver" ]; then
	_path_out=$(verify_upgrade_path_exists "$_ver" "$_upgrade_to" "$_chan" --shell 2>/dev/null) || true
	if echo "$_path_out" | grep -q 'REACHABLE=1'; then
		_upgrade_path_exists=true
		if echo "$_path_out" | grep -q 'CONDITIONAL=1'; then
			_upgrade_path_conditional=true
			_upgrade_risks=$(echo "$_path_out" | grep -oP 'RISKS=\K\S+')
		else
			_upgrade_path_conditional=false
		fi
	elif echo "$_path_out" | grep -q 'REACHABLE=0'; then
		_upgrade_path_exists=false
		_upgrade_path_conditional=false
	fi
fi

# Derived flags
_disk_save_summary=""
_disk_save_short=false
_disk_save_level=""
_disk_sync_summary=""
_disk_sync_short=false
_disk_sync_level=""
_disk_load_summary=""
_disk_load_short=false
_disk_load_level=""
_upgrade_needs_platform=false
if [ -n "$_upgrade_to" ] && [ "$_upgrade_to" != "$_ver" ] && [ "$_excl_platform" = "true" ]; then
	_upgrade_needs_platform=true
fi

# Transfer warning: release images excluded (bundle/save can't install a new cluster).
# Skip when ISC is user-managed — user owns the config, we don't second-guess.
_transfer_excl_release=false
if [ "$_excl_platform" = "true" ] && [ "$_isc_user_managed" != "true" ]; then
	_transfer_excl_release=true
fi

# How much more disk this ISC needs, from the one size estimate.
# save writes an archive and the oc-mirror cache. sync writes the registry
# only. load writes the registry and the cache; the archive is already here.
# Whole GB or MB, rounded up. A decimal would look like a measurement.
_fmt_disk() {
	local n=${1:-0}
	local gb=$((1024 * 1024 * 1024))
	local mb=$((1024 * 1024))
	if [ "$n" -le 0 ]; then
		echo "0 MB"
		return
	fi
	if [ "$n" -ge "$gb" ]; then
		echo "$(( (n + gb - 1) / gb )) GB"
	else
		echo "$(( (n + mb - 1) / mb )) MB"
	fi
}

_path_probe() {
	local p=$1
	while [ -n "$p" ] && [ ! -e "$p" ] && [ "$p" != "/" ]; do
		p=$(dirname "$p")
	done
	printf '%s\n' "${p:-/}"
}

_local_free() {
	df -B1 --output=avail "$(_path_probe "$1")" 2>/dev/null | awk 'NR==2 { print $1 }' || true
}

_local_dev() {
	df -P "$(_path_probe "$1")" 2>/dev/null | awk 'NR==2 { print $1 }' || true
}

_local_mount() {
	df -P "$(_path_probe "$1")" 2>/dev/null | awk 'NR==2 { print $NF }' || true
}

_cache_root() {
	local root="${OC_MIRROR_CACHE:-}"
	if [ -z "$root" ]; then
		root="${data_dir:-}"
	fi
	if [ -z "$root" ] || [ "$root" = "~" ]; then
		root=$HOME
	else
		root=$(_expand_tilde "$root")
	fi
	printf '%s\n' "$root"
}

_cache_used_bytes() {
	local dir="$1/.oc-mirror/.cache"
	if [ ! -d "$dir" ]; then
		echo 0
		return
	fi
	du -sb "$dir" 2>/dev/null | awk '{ print $1 }' || true
}

# Registry data directory. Installed state wins. Otherwise mirror.conf,
# unless the registry is external and its data directory is not known.
_registry_place() {
	_reg_disk=""
	_reg_remote=""
	_reg_ssh_target=""
	local st="$HOME/.aba/mirror/$(basename "$PWD")/state.sh"
	local vendor=""
	if [ -s "$st" ]; then
		vendor=$(grep '^reg_vendor=' "$st" 2>/dev/null | head -1 | cut -d= -f2- | tr -d "'\"") || true
	fi
	# An external registry has no ABA data directory. Do not invent one.
	if [ "$vendor" = "existing" ]; then
		return
	fi
	if [ -z "$vendor" ]; then
		vendor=$(resolved_reg_vendor)
	fi
	case "$vendor" in
		""|existing) return ;;
	esac
	local root_name=$vendor
	case "$vendor" in
		quay) root_name=quay-install ;;
		docker) root_name=docker-reg ;;
	esac
	local dd="${data_dir:-}"
	if [ -n "${reg_ssh_key:-}" ]; then
		[ -z "$dd" ] && dd='~'
		_reg_disk="$dd/$root_name"
		_reg_remote=1
		_reg_ssh_target="${reg_ssh_user:-$(whoami)}@${reg_host}"
	else
		[ -z "$dd" ] && dd=$HOME
		dd=$(_expand_tilde "$dd")
		_reg_disk="$dd/$root_name"
	fi
}

_remote_free() {
	local target=$1 path=$2 out=""
	# A leading ~ must expand on the registry host, so it is left unquoted.
	local qpath
	if [[ "$path" == "~"* ]]; then
		qpath=$path
	else
		qpath=$(printf '%q' "$path")
	fi
	out=$(ssh -F ~/.aba/ssh.conf -i "$reg_ssh_key" -o ConnectTimeout=8 -o BatchMode=yes "$target" \
		"df -B1 --output=avail -- $qpath 2>/dev/null" | awk 'NR==2 { print $1 }') || true
	printf '%s\n' "$out"
}

# ok: free is at least 30% above need. tight: free covers need, but by less.
# short: free is below need. unknown: free space could not be read.
_disk_level() {
	local need=$1 free=$2 bar
	if [ -z "$free" ]; then
		echo unknown
		return
	fi
	if [ "$free" -lt "$need" ]; then
		echo short
		return
	fi
	bar=$(( need * 13 / 10 ))
	if [ "$free" -ge "$bar" ]; then
		echo ok
	else
		echo tight
	fi
}

_disk_sentence() {
	local op=$1 how=$2 need=$3 where=$4 free=$5 from=$6
	# "may need" is an estimate. A comfortable margin prints nothing.
	if [ -z "$free" ]; then
		if [ "$from" = "@unknown" ]; then
			printf 'Estimate: this %s may need %s %s more on %s. The registry data directory is not known, so free space was not checked.' \
				"$op" "$how" "$(_fmt_disk "$need")" "$where"
		else
			# A local miss must not name this machine as if it were remote.
			[ -n "$from" ] || from="this host"
			printf 'Estimate: this %s may need %s %s more on %s. Free space could not be read from %s.' \
				"$op" "$how" "$(_fmt_disk "$need")" "$where" "$from"
		fi
	else
		printf 'Estimate: this %s may need %s %s more on %s (%s free).' \
			"$op" "$how" "$(_fmt_disk "$need")" "$where" "$(_fmt_disk "$free")"
	fi
}

# Drop places that are fine. A short place becomes DISK SPACE WARNING.
_op_reset() {
	_bad=""
	_any_short=false
}

_op_add() {
	local level=$1 sentence=$2
	[ "$level" = ok ] && return 0
	[ -z "$level" ] && return 0
	_bad="${_bad:+$_bad }$sentence"
	[ "$level" = short ] && _any_short=true
}

_op_finish() {
	local which=$1 summary short level
	if [ -z "$_bad" ]; then
		# A comfortable margin is not a promise that the copy will fit.
		summary=""
		short=false
		level=ok
	elif [ "$_any_short" = true ]; then
		summary="DISK SPACE WARNING. $_bad"
		short=true
		level=short
	else
		summary=$_bad
		short=false
		level=tight
		case "$_bad" in
			*"Free space could not be read from "*|*"data directory is not known"*) level=unknown ;;
		esac
	fi
	case "$which" in
		save)
			_disk_save_summary=$summary
			_disk_save_short=$short
			_disk_save_level=$level
			;;
		sync)
			_disk_sync_summary=$summary
			_disk_sync_short=$short
			_disk_sync_level=$level
			;;
		load)
			_disk_load_summary=$summary
			_disk_load_short=$short
			_disk_load_level=$level
			;;
	esac
}

_measure_local() {
	local path=$1
	_ml_dev=$(_local_dev "$path")
	_ml_where=$(_local_mount "$path")
	_ml_free=$(_local_free "$path")
	if [ -z "$_ml_where" ]; then
		_ml_where=$path
	elif [ "$_ml_where" = "/" ]; then
		# "/" alone is easy to miss. Name the root filesystem.
		_ml_where="/ (root)"
	fi
}

_prepare_disk_summaries() {
	[ -s "$_isc" ] || return 0
	local est=""
	est=$(scripts/estimate-isc-size.sh --shell --isc "$_isc" 2>/dev/null) || est=""
	[ -n "$est" ] || return 0
	# shellcheck disable=SC2163
	eval "$est"
	local content="${estimate_bytes:-0}"
	[ "$content" -gt 0 ] || return 0

	local cache_root archive_dir cache_have cache_need
	cache_root=$(_cache_root)
	archive_dir="$PWD/data"
	cache_have=$(_cache_used_bytes "$cache_root")
	cache_need=$content
	if [ "${cache_have:-0}" -ge "$content" ]; then
		cache_need=0
	else
		cache_need=$((content - ${cache_have:-0}))
	fi

	_measure_local "$archive_dir"
	local arch_dev=$_ml_dev arch_where=$_ml_where arch_free=$_ml_free
	_measure_local "$cache_root"
	local cache_dev=$_ml_dev cache_where=$_ml_where cache_free=$_ml_free

	_registry_place
	local reg_where="" reg_free="" reg_from=""
	if [ -n "$_reg_disk" ]; then
		if [ -n "$_reg_remote" ]; then
			reg_where="${reg_host}:${_reg_disk}"
			reg_free=$(_remote_free "$_reg_ssh_target" "$_reg_disk")
			[ -n "$reg_free" ] || reg_from="${reg_host:-unknown}"
		else
			_measure_local "$_reg_disk"
			reg_where=$_ml_where
			reg_free=$_ml_free
			[ -n "$reg_free" ] || reg_from="this host"
		fi
	else
		reg_where="the mirror registry (${reg_host:-unknown}:${reg_port:-})"
		reg_free=""
		reg_from="@unknown"
	fi

	local lvl save_need
	# save: archive plus the cache still to fill. Same volume is one number.
	_op_reset
	if [ -n "$arch_dev" ] && [ "$arch_dev" = "$cache_dev" ]; then
		save_need=$((content + cache_need))
		lvl=$(_disk_level "$save_need" "$arch_free")
		_op_add "$lvl" "$(_disk_sentence save about "$save_need" "$arch_where" "$arch_free")"
	else
		lvl=$(_disk_level "$content" "$arch_free")
		_op_add "$lvl" "$(_disk_sentence save about "$content" "$arch_where" "$arch_free")"
		if [ "$cache_need" -gt 0 ]; then
			lvl=$(_disk_level "$cache_need" "$cache_free")
			_op_add "$lvl" "$(_disk_sentence save about "$cache_need" "$cache_where" "$cache_free")"
		fi
	fi
	_op_finish save

	# sync: registry only. "up to" because blobs already stored are skipped.
	_op_reset
	lvl=$(_disk_level "$content" "$reg_free")
	_op_add "$lvl" "$(_disk_sentence sync "up to" "$content" "$reg_where" "$reg_free" "$reg_from")"
	_op_finish sync

	# load: registry plus cache. The archive is already on disk.
	_op_reset
	lvl=$(_disk_level "$content" "$reg_free")
	_op_add "$lvl" "$(_disk_sentence load "up to" "$content" "$reg_where" "$reg_free" "$reg_from")"
	if [ "$cache_need" -gt 0 ]; then
		lvl=$(_disk_level "$cache_need" "$cache_free")
		_op_add "$lvl" "$(_disk_sentence load about "$cache_need" "$cache_where" "$cache_free")"
	fi
	_op_finish load
}

if [ "$_mode" = shell ] || [ "$_mode" = op ] || [ "$_show_disk" = true ]; then
	_prepare_disk_summaries || true
fi

# --- Output ---

case "$_mode" in
shell)
	echo "mirror_installed=$_mirror_installed"
	echo "mirror_host=$_reg_host"
	echo "mirror_port=$_reg_port"
	echo "mirror_path=$_reg_path"
	echo "mirror_has_release=$_mirror_has_release"
	echo "mirror_last_action=$_last_action"
	echo "mirror_last_action_at=\"$_last_action_at\""
	echo "ocp_version=$_ver"
	echo "ocp_channel=$_chan"
	echo "ocp_upgrade_to=$_upgrade_to"
	echo "excl_platform=$_excl_platform"
	echo "excl_operators=$_excl_operators"
	echo "excl_additional=$_excl_additional"
	echo "operator_count=$_op_count"
	echo "operators=\"$_operators\""
	echo "isc_exists=$_isc_exists"
	echo "isc_user_managed=$_isc_user_managed"
	echo "upgrade_needs_platform=$_upgrade_needs_platform"
	echo "transfer_excl_release=$_transfer_excl_release"
	echo "upgrade_path_exists=$_upgrade_path_exists"
	echo "upgrade_path_conditional=$_upgrade_path_conditional"
	echo "upgrade_risks=$_upgrade_risks"
	printf 'disk_save_summary=%q\n' "$_disk_save_summary"
	echo "disk_save_short=$_disk_save_short"
	echo "disk_save_level=$_disk_save_level"
	printf 'disk_sync_summary=%q\n' "$_disk_sync_summary"
	echo "disk_sync_short=$_disk_sync_short"
	echo "disk_sync_level=$_disk_sync_level"
	printf 'disk_load_summary=%q\n' "$_disk_load_summary"
	echo "disk_load_short=$_disk_load_short"
	echo "disk_load_level=$_disk_load_level"
	;;

preflight)
	# Interactive checks -- fix blocking issues using ask()
	if [ "$_upgrade_needs_platform" = "true" ]; then
		aba_warn "Upgrade target set (${_ver} → ${_upgrade_to}) but release images are excluded." \
			"The upgrade will fail without release images on the disconnected side." \
			"To fix: set excl_platform=false in aba.conf, or clear ocp_upgrade_to in mirror.conf."
	fi
	;;

op)
	# Compact operation-specific summary (called by reg-save.sh / reg-sync.sh / reg-load.sh)
	if [ "$_op" = "load" ]; then
		# Load reads from transfer archive metadata, not config
		if _ti_out=$(scripts/transfer-info.sh --shell 2>/dev/null); then
			eval "$_ti_out"
			_ver_display="${transfer_ocp_version:-unknown}"
			if [ -n "${transfer_upgrade_to:-}" ] && [ "${transfer_upgrade_to}" != "${transfer_ocp_version:-}" ]; then
				_ver_display="${transfer_ocp_version} → ${transfer_upgrade_to}"
			fi
			[ -n "${transfer_ocp_channel:-}" ] && _ver_display="$_ver_display (${transfer_ocp_channel})"

			_parts=""
			[ "${transfer_operator_count:-0}" -gt 0 ] 2>/dev/null && _parts="${transfer_operator_count} operator(s)"
			aba_info "Loading to registry: OCP $_ver_display${_parts:+ — $_parts}"
		else
			aba_info "Loading to registry: ${_reg_host}:${_reg_port}${_reg_path}"
		fi
		if [ "$_disk_load_short" = true ]; then
			aba_warn "$_disk_load_summary"
		elif [ -n "$_disk_load_summary" ]; then
			aba_info "$_disk_load_summary"
		fi
	else
		# Save/sync read from config + ISC
		_ver_display="$_ver"
		if [ -n "$_upgrade_to" ] && [ "$_upgrade_to" != "$_ver" ] && [ "$_excl_platform" != "true" ]; then
			_ver_display="$_ver → $_upgrade_to"
		fi
		[ -n "$_chan" ] && _ver_display="$_ver_display ($_chan)"

		# Build payload description
		_parts=""
		if [ "$_excl_platform" != "true" ]; then
			_parts="release"
		fi
		if [ "$_op_count" -gt 0 ] && [ "$_excl_operators" != "true" ]; then
			_parts="${_parts:+$_parts, }$_op_count operator(s)"
		fi
		if [ "$_add_count" -gt 0 ] && [ "$_excl_additional" != "true" ]; then
			_parts="${_parts:+$_parts, }$_add_count additional image(s)"
		fi
		[ -z "$_parts" ] && _parts="(nothing — all sections excluded)"

		if [ "$_op" = "save" ]; then
			aba_info "Saving to disk: OCP $_ver_display — $_parts"
			if [ "$_disk_save_short" = true ]; then
				aba_warn "$_disk_save_summary"
			elif [ -n "$_disk_save_summary" ]; then
				aba_info "$_disk_save_summary"
			fi
		else
			aba_info "Syncing to registry: OCP $_ver_display — $_parts"
			if [ "$_disk_sync_short" = true ]; then
				aba_warn "$_disk_sync_summary"
			elif [ -n "$_disk_sync_summary" ]; then
				aba_info "$_disk_sync_summary"
			fi
		fi

		# Warn about exclusions
		_excl_list=""
		[ "$_excl_platform" = "true" ] && _excl_list="release images"
		[ "$_excl_operators" = "true" ] && _excl_list="${_excl_list:+$_excl_list, }operators"
		[ "$_excl_additional" = "true" ] && _excl_list="${_excl_list:+$_excl_list, }additional images"
		[ -n "$_excl_list" ] && aba_warn "Excluded: $_excl_list"
	fi
	;;

*)
	# Human-readable (default)
	local_ver_display="$_ver"
	[ -n "$_chan" ] && local_ver_display="$_ver ($_chan)"
	if [ -n "$_upgrade_to" ] && [ "$_upgrade_to" != "$_ver" ]; then
		local_ver_display="$_ver → $_upgrade_to ($_chan)"
	fi

	# Registry display
	_reg_display="not configured"
	if [ -n "$_reg_host" ]; then
		_reg_display="${_reg_host}:${_reg_port}${_reg_path}"
		if [ "$_mirror_installed" = "true" ]; then
			_reg_display="$_reg_display (installed)"
		else
			_reg_display="$_reg_display (not installed)"
		fi
	fi

	# Operator preview (truncate at 8)
	_ops_display="none"
	if [ "$_op_count" -gt 0 ]; then
		_ops_display=$(echo "$_operators" | sed 's/,/, /g')
		if [ "$_op_count" -gt 8 ]; then
			_ops_display=$(echo "$_operators" | cut -d, -f1-8 | sed 's/,/, /g')
			_ops_display="${_ops_display}, ... (+$(( _op_count - 8 )) more)"
		fi
	fi

	# Excluded sections
	_excl_display=""
	[ "$_excl_platform" = "true" ] && _excl_display="${_excl_display:+$_excl_display, }release images"
	[ "$_excl_operators" = "true" ] && _excl_display="${_excl_display:+$_excl_display, }operators"
	[ "$_excl_additional" = "true" ] && _excl_display="${_excl_display:+$_excl_display, }additional images"

	# ISC state
	_isc_display="not found"
	if [ "$_isc_exists" = "true" ]; then
		_isc_display="data/imageset-config.yaml"
		if [ "$_isc_user_managed" = "true" ]; then
			_isc_display="$_isc_display (user-edited, preserved on load)"
		fi
	fi

	echo
	aba_info "Mirror status:"
	aba_info "  OCP:          ${local_ver_display}"
	aba_info "  Registry:     ${_reg_display}"
	if [ "$_mirror_installed" = "true" ] && [ "$_mirror_has_release" != "true" ]; then
		aba_warn "  Release:      MISSING (v${_ver:-?} not found in registry)"
	fi
	if [ "$_op_count" -gt 0 ]; then
		aba_info "  Operators (${_op_count}): ${_ops_display}"
	else
		aba_info "  Operators:    none"
	fi
	aba_info "  ISC:          ${_isc_display}"
	[ -n "$_excl_display" ] && aba_warn "  Excluded:     ${_excl_display}"
	if [ -n "$_upgrade_to" ] && [ "$_upgrade_to" != "$_ver" ]; then
		if [ "$_upgrade_path_exists" = "true" ]; then
			if [ "$_upgrade_path_conditional" = "true" ]; then
				aba_warn "  Upgrade path: available (conditional — known risks)"
				for _r in $(echo "${_upgrade_risks:-}" | tr ',' '\n'); do
					[ -n "$_r" ] && aba_warn "                  - $_r"
				done
			else
				aba_info "  Upgrade path: available"
			fi
		elif [ "$_upgrade_path_exists" = "false" ]; then
			aba_warn "  Upgrade path: NOT available ($_ver → $_upgrade_to)"
		fi
	fi
	if [ "$_upgrade_needs_platform" = "true" ]; then
		aba_warn "  Upgrade:      requires release images but they are excluded!"
	elif [ "$_transfer_excl_release" = "true" ]; then
		aba_warn "  Release:      excluded — bundles/saves are operator-only"
	fi
	if [ -n "$_last_action" ]; then
		aba_info "  Last action:  ${_last_action}${_last_action_at:+ (${_last_action_at})}"
	fi

	# Archive size: total of mirror_*.tar + aba-transfer.tar
	_tar_total=0
	_tar_count=0
	for _tf in data/mirror_*.tar data/aba-transfer.tar; do
		[ -f "$_tf" ] || continue
		_tar_total=$(( _tar_total + $(stat -c %s "$_tf" 2>/dev/null || echo 0) ))
		_tar_count=$(( _tar_count + 1 ))
	done
	if [ "$_tar_count" -gt 0 ]; then
		if [ "$_tar_total" -ge 1073741824 ]; then
			_tar_display="$(( _tar_total / 1073741824 ))GB"
		else
			_tar_display="$(( _tar_total / 1048576 ))MB"
		fi
		aba_info "  Archives:     ${_tar_count} file(s), ${_tar_display}"
	fi

	# Transfer bundle check: warn if mirror_*.tar exists but aba-transfer.tar is missing
	if ls data/mirror_*.tar >/dev/null 2>&1 && [ ! -f data/aba-transfer.tar ]; then
		aba_warn "  Transfer:     aba-transfer.tar missing (needed on disconnected side)"
	fi

	# Disk lines stay off the default summary. status --disk prints them.
	if [ "$_show_disk" = true ]; then
		if [ -n "$_disk_save_summary" ]; then
			if [ "$_disk_save_short" = true ]; then aba_warn "  $_disk_save_summary"; else aba_info "  $_disk_save_summary"; fi
		fi
		if [ -n "$_disk_sync_summary" ]; then
			if [ "$_disk_sync_short" = true ]; then aba_warn "  $_disk_sync_summary"; else aba_info "  $_disk_sync_summary"; fi
		fi
		if [ -n "$_disk_load_summary" ]; then
			if [ "$_disk_load_short" = true ]; then aba_warn "  $_disk_load_summary"; else aba_info "  $_disk_load_summary"; fi
		fi
	fi

	# Detect unloaded archives: any mirror_*.tar newer than the last load?
	if [ "$_last_action" = "load" ] && [ -n "$_last_action_at" ]; then
		_load_epoch=$(date -d "$_last_action_at" +%s 2>/dev/null || echo 0)
		_has_new_tar=""
		for _tf in data/mirror_*.tar; do
			[ -f "$_tf" ] || continue
			_tf_epoch=$(stat -c %Y "$_tf" 2>/dev/null || echo 0)
			if [ "$_tf_epoch" -gt "$_load_epoch" ]; then
				_has_new_tar=1
				break
			fi
		done
		if [ "$_has_new_tar" ]; then
			aba_info "  New archives: detected (copied after last load)"
			aba_info "  Next step:    aba -d mirror load"
		fi
	fi

	# Day2 reminder: after a load, installed clusters may need day2
	if [ "$_last_action" = "load" ] && [ -n "$_last_action_at" ]; then
		_load_epoch=${_load_epoch:-$(date -d "$_last_action_at" +%s 2>/dev/null || echo 0)}
		_clusters_need_day2=""
		for _cd in ../*; do
			[ -d "$_cd" ] && [ -f "$_cd/.install-complete" ] || continue
			_ic_epoch=$(stat -c %Y "$_cd/.install-complete" 2>/dev/null || echo 0)
			[ "$_ic_epoch" -lt "$_load_epoch" ] && _clusters_need_day2="${_clusters_need_day2:+$_clusters_need_day2, }$(basename "$_cd")"
		done
		if [ -n "$_clusters_need_day2" ]; then
			aba_info "  Clusters:     may need day2: $_clusters_need_day2"
		fi
	fi

	echo
	;;
esac

exit 0
