#!/bin/bash
# mirror-status.sh -- Report mirror state and run preflight checks
#
# INTENT:    Unified source of truth for all mirror status queries and
#            pre-operation validation. Follows the transfer-info.sh pattern.
# CALLED BY: make -C mirror status, make -C mirror status-preflight,
#            reg-save.sh (inline summary), reg-sync.sh (inline summary),
#            TUI (--shell mode)
# CWD:       mirror/ directory
# REQUIRES:  scripts/include_all.sh (normalize functions, ask(), ISC helpers)
# PRODUCES:  Human-readable summary (default), sourceable key=value (--shell),
#            or interactive preflight checks (--preflight)
# SIDE EFFECTS: --preflight may update aba.conf and regenerate ISC
# IDEMPOTENT: Yes (default and --shell are read-only)

set -eo pipefail

source scripts/include_all.sh

_mode="human"
for arg in "$@"; do
	case "$arg" in
		shell|--shell)       _mode="shell" ;;
		preflight|--preflight) _mode="preflight" ;;
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
	;;

preflight)
	# Interactive checks -- fix blocking issues using ask()
	if [ "$_upgrade_needs_platform" = "true" ]; then
		aba_warn "Upgrade target set (${_ver} → ${_upgrade_to}) but release images are excluded." \
			"The upgrade will fail without release images."
		if ask "Include release images"; then
			replace-value-conf -n excl_platform -v "false" -f "$ABA_ROOT/aba.conf"
			_excl_platform=false
			aba_info "Enabled release images in aba.conf (excl_platform=false)."
			aba_info "Regenerating ImageSet configuration..."
			scripts/reg-create-imageset-config.sh -f 1
		else
			aba_warn "Continuing WITHOUT release images. The upgrade may fail on the disconnected side."
		fi
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

	echo >&2
	echo "[ABA] Mirror status:" >&2
	echo "[ABA]   OCP:          ${local_ver_display}" >&2
	echo "[ABA]   Registry:     ${_reg_display}" >&2
	if [ "$_op_count" -gt 0 ]; then
		echo "[ABA]   Operators (${_op_count}): ${_ops_display}" >&2
	else
		echo "[ABA]   Operators:    none" >&2
	fi
	echo "[ABA]   ISC:          ${_isc_display}" >&2
	[ -n "$_excl_display" ] && echo "[ABA]   Excluded:     ${_excl_display}" >&2
	if [ "$_upgrade_needs_platform" = "true" ]; then
		echo "[ABA]   Warning:      upgrade requires release images but they are excluded!" >&2
	fi
	if [ -n "$_last_action" ]; then
		echo "[ABA]   Last action:  ${_last_action}${_last_action_at:+ (${_last_action_at})}" >&2
	fi
	echo >&2
	;;
esac
