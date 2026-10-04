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
#            compact operation summary (op=save, op=sync),
#            or interactive preflight checks (--preflight)
# SIDE EFFECTS: --preflight may update aba.conf and regenerate ISC
# IDEMPOTENT: Yes (default and --shell are read-only)

set -eo pipefail

source scripts/include_all.sh

[ -z "${INFO_ABA+x}" ] && export INFO_ABA=1

_mode="human"
_op=""
for arg in "$@"; do
	case "$arg" in
		shell|--shell)         _mode="shell" ;;
		preflight|--preflight) _mode="preflight" ;;
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
	_last_action=$(grep '^last_action=' "$HOME/.aba/mirror/$_mirror_name/state.sh" 2>/dev/null | head -1 | cut -d= -f2-)
	_last_action_at=$(grep '^last_action_at=' "$HOME/.aba/mirror/$_mirror_name/state.sh" 2>/dev/null | head -1 | cut -d= -f2- | tr -d "'\"")
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
_upgrade_needs_platform=false
if [ -n "$_upgrade_to" ] && [ "$_upgrade_to" != "$_ver" ] && [ "$_excl_platform" = "true" ]; then
	_upgrade_needs_platform=true
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
	echo "upgrade_path_exists=$_upgrade_path_exists"
	echo "upgrade_path_conditional=$_upgrade_path_conditional"
	echo "upgrade_risks=$_upgrade_risks"
	;;

preflight)
	# Interactive checks -- fix blocking issues using ask()
	if [ "$_upgrade_needs_platform" = "true" ]; then
		aba_warn "Upgrade target set (${_ver} → ${_upgrade_to}) but release images are excluded." \
			"The upgrade will fail without release images."
		if ask "Include release images"; then
			replace-value-conf -n excl_platform -v "false" -f "../aba.conf"
			_excl_platform=false
			aba_info "Enabled release images in aba.conf (excl_platform=false)."
			aba_info "Regenerating ImageSet configuration..."
			scripts/reg-create-imageset-config.sh -f 1
		else
			aba_warn "Continuing WITHOUT release images. The upgrade may fail on the disconnected side."
		fi
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
		else
			aba_info "Syncing to registry: OCP $_ver_display — $_parts"
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
		[ "$_isc_user_managed" = "true" ] && _isc_display="$_isc_display (user-managed)"
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
		aba_warn "  Warning:      upgrade requires release images but they are excluded!"
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

	# Disk space warning on data/ partition
	_data_dir="data"
	[ -d "$_data_dir" ] || _data_dir="."
	_avail_kb=$(df -k "$_data_dir" 2>/dev/null | awk 'NR==2 {print $4}')
	if [ "${_avail_kb:-0}" -gt 0 ] && [ "$_avail_kb" -lt 20971520 ]; then
		_avail_gb=$(( _avail_kb / 1048576 ))
		aba_warn "  Disk space:   ${_avail_gb}GB free (under data/) — may need more for save/load"
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
