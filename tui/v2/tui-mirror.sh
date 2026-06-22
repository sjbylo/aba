#!/usr/bin/env bash
# =============================================================================
# TUI v2 — Mirror Operations (save, sync, bundle, operators, ISC)
# =============================================================================
# Adapted from v1 tui/abatui.sh handle_action_* functions.
# Provides mirror-related menu actions for CONNO mode.
#
# Usage: source tui/v2/tui-mirror.sh

# --- BASH_SOURCE guard ---
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	echo "This file should be sourced, not executed directly."
	exit 1
fi

# Legacy wrapper — delegates to _tui_prompt_password in tui-lib.sh
_prompt_password() {
	_tui_prompt_password "Enter registry password (min 8 chars, no whitespace or quotes):" 8
}

# =============================================================================
# Shared mirror.conf menu editor (review / local install / remote install)
# -----------------------------------------------------------------------------
# Keeps ONE menu loop implementation; variants differ only in prompts, SSH rows,
# help text, Continue/Next semantics, validation on proceed, and post-loop actions.
# =============================================================================

_mirror_config_menu_loop() {
	local _variant="$1"
	local mcf="$ABA_ROOT/mirror/mirror.conf"
	local dlg_title dlg_prompt dlg_extra dlg_h dlg_w dlg_mh
	local dlg_help_title=""
	local dlg_help_body=""
	local m_host="" m_port="" m_user="" m_pw="" m_path="" m_vendor="" m_datadir=""
	local m_ssh_user="" m_ssh_key=""
	local -a dlg_items=()

	if [[ ! -f "$mcf" ]]; then
		make -sC "$ABA_ROOT/mirror" mirror.conf 2>/dev/null || true
	fi
	if [[ -f "$mcf" ]]; then
		source <(cd "$ABA_ROOT/mirror" && normalize-mirror-conf) 2>/dev/null || true
	fi

	m_port="${reg_port:-8443}"
	m_user="${reg_user:-init}"
	m_pw="${reg_pw:-p4ssw0rd}"
	m_path="${reg_path:-/ocp4/openshift4}"
	m_vendor="${reg_vendor:-auto}"
	m_datadir="${data_dir:-~}"

	case "$_variant" in
		review)
			m_host="${reg_host:-$(hostname -f 2>/dev/null || hostname)}"
			m_ssh_user="${reg_ssh_user:-}"
			m_ssh_key="${reg_ssh_key:-}"
			dlg_title="Mirror Configuration"
			dlg_prompt="Mirror will be installed as part of this operation.\nReview/edit settings, then press Continue:"
			dlg_extra="$TUI2_BTN_CONTINUE"
			dlg_h=18
			dlg_w=70
			dlg_mh=7
			dlg_help_title="Mirror Configuration"
			dlg_help_body="These settings will be used to install the mirror registry:

  • Hostname — FQDN for the registry (must resolve to this host)
  • Port — registry listen port (default 8443)
  • Username — registry login user
  • Password — registry login password
  • Image path — namespace path for mirrored images
  • Vendor — auto (detects arch), quay, or docker
  • Data dir — storage location for images

Press 'Continue' when ready. The mirror will be installed automatically."
			dlg_items=(
				"H"  "Hostname:     $m_host"
				"P"  "Port:         $m_port"
				"U"  "Username:     $m_user"
				"W"  "Password:     ${m_pw:+(set)}"
				"I"  "Image path:   $m_path"
				"V"  "Vendor:       $m_vendor"
				"D"  "Data dir:     $m_datadir"
			)
			;;
		local)
			m_host="${reg_host:-$(hostname -f 2>/dev/null || hostname)}"
			m_ssh_user="${reg_ssh_user:-}"
			m_ssh_key="${reg_ssh_key:-}"
			dlg_title="Mirror Configuration (local)"
			dlg_prompt="Configure local mirror registry — select a row to edit:"
			dlg_extra="$TUI2_BTN_NEXT"
			dlg_h=18
			dlg_w=70
			dlg_mh=7
			dlg_help_title="Mirror Configuration"
			dlg_help_body="Configure settings for the local mirror registry:

  • Hostname — FQDN for the registry (must resolve to this host)
  • Port — registry listen port (default 8443)
  • Username — registry login user
  • Password — registry login password
  • Image path — namespace path for mirrored images
  • Vendor — auto (detects arch), quay, or docker
  • Data dir — storage location for images"
			dlg_items=(
				"H"  "Hostname:     $m_host"
				"P"  "Port:         $m_port"
				"U"  "Username:     $m_user"
				"W"  "Password:     ${m_pw:+(set)}"
				"I"  "Image path:   $m_path"
				"V"  "Vendor:       $m_vendor"
				"D"  "Data dir:     $m_datadir"
			)
			;;
		remote)
			m_host="${reg_host:-}"
			m_ssh_user="${reg_ssh_user:-root}"
			m_ssh_key="${reg_ssh_key:-$HOME/.ssh/id_rsa}"
			dlg_title="Mirror Configuration (remote)"
			dlg_prompt="Configure remote mirror registry — select a row to edit:"
			dlg_extra="$TUI2_BTN_NEXT"
			dlg_h=20
			dlg_w=70
			dlg_mh=9
			dlg_help_title="Mirror Configuration (Remote)"
			dlg_help_body="Configure settings for the remote mirror registry:

  • Hostname — FQDN of the remote registry host
  • SSH user — SSH login user on the remote host
  • SSH key — path to SSH private key for remote access
  • Port — registry listen port (default 8443)
  • Username — registry login user
  • Password — registry login password
  • Image path — namespace path for mirrored images
  • Vendor — auto (detects arch), quay, or docker
  • Data dir — storage location on remote host"
			dlg_items=(
				"H"  "Hostname:     ${m_host:-(enter FQDN)}"
				"S"  "SSH user:     $m_ssh_user"
				"K"  "SSH key:      $m_ssh_key"
				"P"  "Port:         $m_port"
				"U"  "Username:     $m_user"
				"W"  "Password:     ${m_pw:+(set)}"
				"I"  "Image path:   $m_path"
				"V"  "Vendor:       $m_vendor"
				"D"  "Data dir:     $m_datadir"
			)
			;;
		*)
			tui_log "ERROR: unknown mirror menu variant '$_variant'"
			return 1
			;;
	esac

	local default_item="H"

	while :; do
		if [[ "$_variant" != "remote" ]]; then
			dlg_items[1]="Hostname:     ${m_host}"
			dlg_items[3]="Port:         ${m_port}"
			dlg_items[5]="Username:     ${m_user}"
			dlg_items[7]="Password:     ${m_pw:+(set)}"
			dlg_items[9]="Image path:   ${m_path}"
			dlg_items[11]="Vendor:       ${m_vendor}"
			dlg_items[13]="Data dir:     ${m_datadir}"
		else
			dlg_items[1]="Hostname:     ${m_host:-(enter FQDN)}"
			dlg_items[3]="SSH user:     ${m_ssh_user}"
			dlg_items[5]="SSH key:      ${m_ssh_key}"
			dlg_items[7]="Port:         ${m_port}"
			dlg_items[9]="Username:     ${m_user}"
			dlg_items[11]="Password:     ${m_pw:+(set)}"
			dlg_items[13]="Image path:   ${m_path}"
			dlg_items[15]="Vendor:       ${m_vendor}"
			dlg_items[17]="Data dir:     ${m_datadir}"
		fi

		dlg --backtitle "$(ui_backtitle)" --title "$dlg_title" \
			--default-item "$default_item" \
			--ok-label "$TUI2_BTN_SELECT" \
			--extra-button --extra-label "$dlg_extra" \
			--cancel-label "$TUI2_BTN_BACK" \
			--help-button \
			--menu "$dlg_prompt" "$dlg_h" "$dlg_w" "$dlg_mh" \
			"${dlg_items[@]}" \
			2>"$_TUI_TMP"
		local rc=$?

		case "$rc" in
			2)
				show_help "$dlg_help_title" "$dlg_help_body"
				continue
				;;
			3)
				if [[ "$_variant" == "remote" ]]; then
					if [[ -z "$m_host" ]]; then
						dlg --backtitle "$(ui_backtitle)" --msgbox "Hostname is required for remote install." 0 0
						default_item="H"
						continue
					fi
				fi
				break
				;;
			1|255)
				return 1
				;;
			0) ;;
		esac

		local field
		field=$(<"$_TUI_TMP")
		[[ -n "$field" ]] && default_item="$field"

		case "$field" in
			H)
				if [[ "$_variant" == "remote" ]]; then
					dlg --backtitle "$(ui_backtitle)" --inputbox "Remote registry hostname (FQDN):" 0 60 "$m_host" 2>"$_TUI_TMP"
				else
					dlg --backtitle "$(ui_backtitle)" --inputbox "Registry hostname (FQDN):" 0 60 "$m_host" 2>"$_TUI_TMP"
				fi
				if [[ $? -eq 0 ]]; then
					m_host=$(<"$_TUI_TMP")
					_tui_reject_squote "$m_host" || continue
					if [[ -n "$m_host" ]] && ! _valid_fqdn "$m_host" && ! _valid_ip "$m_host"; then
						dlg --backtitle "$(ui_backtitle)" --msgbox \
							"Invalid hostname.\n\nMust be a valid FQDN (e.g. registry.example.com) or IP address." 0 0
						continue
					fi
					replace-value-conf -q -n reg_host -v "$m_host" -f "$mcf"
				fi
				;;
			P)
				dlg --backtitle "$(ui_backtitle)" --inputbox "Registry port:" 0 40 "$m_port" 2>"$_TUI_TMP"
				if [[ $? -eq 0 ]]; then
					m_port=$(<"$_TUI_TMP")
					if [[ -n "$m_port" ]] && ! _valid_port "$m_port"; then
						dlg --backtitle "$(ui_backtitle)" --msgbox \
							"Invalid port.\n\nMust be a number between 1 and 65535." 0 0
						continue
					fi
					replace-value-conf -q -n reg_port -v "$m_port" -f "$mcf"
				fi
				;;
			U)
				dlg --backtitle "$(ui_backtitle)" --inputbox "Registry username:" 0 40 "$m_user" 2>"$_TUI_TMP"
				if [[ $? -eq 0 ]]; then
					m_user=$(<"$_TUI_TMP")
					_tui_reject_squote "$m_user" || continue
					replace-value-conf -q -n reg_user -v "$m_user" -f "$mcf"
				fi
				;;
			W)
				_tui_prompt_password "Enter registry password (min 8 chars, no whitespace or quotes/backtick/dollar):" 8
				if [[ $? -eq 0 ]]; then
					m_pw=$(<"$_TUI_TMP")
					# Pre-quote: passwords may contain $, \, `, " etc. that must stay literal
					replace-value-conf -q -n reg_pw -v "'$m_pw'" -f "$mcf"
				fi
				;;
			I)
				dlg --backtitle "$(ui_backtitle)" --inputbox "Image path (e.g. /ocp4/openshift4):" 0 60 "$m_path" 2>"$_TUI_TMP"
				if [[ $? -eq 0 ]]; then
					m_path=$(<"$_TUI_TMP")
					_tui_reject_squote "$m_path" || continue
					if [[ -n "$m_path" ]] && ! _valid_abs_path "$m_path"; then
						dlg --backtitle "$(ui_backtitle)" --msgbox \
							"Invalid image path.\n\nMust start with / (e.g. /ocp4/openshift4)." 0 0
						continue
					fi
					replace-value-conf -q -n reg_path -v "$m_path" -f "$mcf"
				fi
				;;
			V)
				case "$m_vendor" in
					auto) m_vendor="quay" ;;
					quay) m_vendor="docker" ;;
					docker) m_vendor="auto" ;;
					*) m_vendor="auto" ;;
				esac
				replace-value-conf -q -n reg_vendor -v "$m_vendor" -f "$mcf"
				if [[ "$_variant" != "review" ]]; then
					tui_log "Toggled vendor to: $m_vendor"
				fi
				;;
			D)
				if [[ "$_variant" == "remote" ]]; then
					dlg --backtitle "$(ui_backtitle)" --inputbox "Data directory on remote host:" 0 60 "$m_datadir" 2>"$_TUI_TMP"
				else
					dlg --backtitle "$(ui_backtitle)" --inputbox "Data directory (absolute path):" 0 60 "$m_datadir" 2>"$_TUI_TMP"
				fi
				if [[ $? -eq 0 ]]; then
					m_datadir=$(<"$_TUI_TMP")
					_tui_reject_squote "$m_datadir" || continue
					if [[ -n "$m_datadir" ]] && ! _valid_abs_path "$m_datadir"; then
						dlg --backtitle "$(ui_backtitle)" --msgbox \
							"Invalid directory path.\n\nMust start with / or ~ (e.g. ~/quay-mirror)." 0 0
						continue
					fi
					replace-value-conf -q -n data_dir -v "$m_datadir" -f "$mcf"
				fi
				;;
			S)
				if [[ "$_variant" != "remote" ]]; then
					continue
				fi
				dlg --backtitle "$(ui_backtitle)" --inputbox "SSH username:" 0 40 "$m_ssh_user" 2>"$_TUI_TMP"
				if [[ $? -eq 0 ]]; then
					m_ssh_user=$(<"$_TUI_TMP")
					_tui_reject_squote "$m_ssh_user" || continue
					replace-value-conf -q -n reg_ssh_user -v "$m_ssh_user" -f "$mcf"
				fi
				;;
			K)
				if [[ "$_variant" != "remote" ]]; then
					continue
				fi
				dlg --backtitle "$(ui_backtitle)" --inputbox "SSH private key path:" 0 60 "$m_ssh_key" 2>"$_TUI_TMP"
				if [[ $? -eq 0 ]]; then
					m_ssh_key=$(<"$_TUI_TMP")
					_tui_reject_squote "$m_ssh_key" || continue
					if [[ -n "$m_ssh_key" ]] && ! _valid_abs_path "$m_ssh_key"; then
						dlg --backtitle "$(ui_backtitle)" --msgbox \
							"Invalid path.\n\nMust start with / or ~ (e.g. ~/.ssh/id_rsa)." 0 0
						continue
					fi
					replace-value-conf -q -n reg_ssh_key -v "$m_ssh_key" -f "$mcf"
				fi
				;;
		esac
	done

	if [[ "$_variant" == "review" ]]; then
		return 0
	elif [[ "$_variant" == "local" ]]; then
		tui_log "Saving mirror config: host=$m_host port=$m_port vendor=$m_vendor"
		replace-value-conf -q -n reg_ssh_user -v "" -f "$mcf"
		replace-value-conf -q -n reg_ssh_key -v "" -f "$mcf"
		confirm_and_execute "aba --dir mirror install" "Install Local Mirror" _invalidate_mirror_cache
		return $?
	else
		tui_log "Saving mirror config: host=$m_host ssh=$m_ssh_user key=$m_ssh_key vendor=$m_vendor"
		replace-value-conf -q -n reg_ssh_user -v "$m_ssh_user" -f "$mcf"
		replace-value-conf -q -n reg_ssh_key -v "$m_ssh_key" -f "$mcf"
		confirm_and_execute "aba --dir mirror install" "Install Remote Mirror" _invalidate_mirror_cache
		return $?
	fi
}

# =============================================================================
# Mirror Config Review (show/edit mirror.conf values before an operation)
# Used when mirror isn't installed yet but an operation (sync/save) will trigger install via deps.
# Returns 0 if user confirms, 1 if user cancels.
# =============================================================================

_mirror_config_review() {
	tui_log "Mirror config review (pre-install)"
	_mirror_config_menu_loop review
}

# =============================================================================
# Install Mirror (local or remote)
# =============================================================================

mirror_install() {
	tui_log "Action: Install Mirror"

	local default_item="1"
	while :; do
		dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CONNO_INSTALL_MIRROR" \
			--default-item "$default_item" \
			--cancel-label "$TUI2_BTN_BACK" \
			--help-button \
			--menu "$TUI2_MSG_MIRROR_TARGET" 0 0 0 \
			"1" "Install locally (this host)" \
			"2" "Install on remote host (via SSH)" \
			2>"$_TUI_TMP"
		local rc=$?

		case "$rc" in
			2)
				show_help "$TUI2_HELP_TITLE_MIRROR" \
"A mirror registry stores OpenShift container images locally.

• Local: installs on this host (Quay or Docker registry)
• Remote: installs on another host via SSH

After installation, use 'Save' or 'Sync' to populate it with images."
				continue
				;;
			0) ;;
			1|255) return 1 ;;
		esac

		local choice
		choice=$(<"$_TUI_TMP")
		[[ -n "$choice" ]] && default_item="$choice"

		case "$choice" in
			1) _mirror_install_local ;;
			2) _mirror_install_remote ;;
		esac
		return $?
	done
}

_mirror_install_local() {
	tui_log "Installing mirror locally"
	_mirror_config_menu_loop local
}

_mirror_install_remote() {
	tui_log "Installing mirror on remote host"
	_mirror_config_menu_loop remote
}

# =============================================================================
# Pre-operation confirmation with OCP/operator summary + View ISC
# =============================================================================

# Shows a summary dialog before save/sync/load/bundle operations.
# Lets the user confirm, go back, or view the ISC file.
# Returns 0 if confirmed, 1 if cancelled.
_mirror_op_confirm() {
	local title="$1"

	source <(normalize-aba-conf) 2>/dev/null
	source <(cd "$ABA_ROOT/mirror" && normalize-mirror-conf) 2>/dev/null
	local _ver="${ocp_version:-unknown}"
	local _chan="${ocp_channel:-stable}"
	# Show upgrade range if target is set, or detect from ISC maxVersion
	local _target="${ocp_version_target:-}"
	if [[ -z "$_target" && -f "$ABA_ROOT/mirror/data/imageset-config.yaml" ]]; then
		_target=$(grep '^\s*maxVersion:' "$ABA_ROOT/mirror/data/imageset-config.yaml" 2>/dev/null | head -1 | sed 's/.*maxVersion: *//')
	fi
	if [[ -n "$_target" && "$_target" != "$_ver" ]]; then
		_ver="${_ver} → ${_target}"
	fi
	local _op_count=${#OP_BASKET[@]}
	local _op_preview=""
	if [[ $_op_count -gt 0 ]]; then
		local _shown=() _i=0
		for _op in "${!OP_BASKET[@]}"; do
			_shown+=("$_op")
			_i=$(( _i + 1 ))
			[[ $_i -ge 5 ]] && break
		done
		_op_preview=$(IFS=","; echo "${_shown[*]}" | sed 's/,/, /g')
		if [[ $_op_count -gt 5 ]]; then
			_op_preview="$_op_preview, ... (+$(( _op_count - 5 )) more)"
		fi
	fi

	local _summary="OCP: $_ver ($_chan)\n"
	if [[ $_op_count -gt 0 ]]; then
		_summary+="Operators ($_op_count): $_op_preview\n"
	else
		_summary+="Operators: none\n"
	fi
	_summary+="\nContinue?"

	while :; do
		dlg --backtitle "$(ui_backtitle)" --title "$title" \
			--yes-label "$TUI2_BTN_CONTINUE" \
			--no-label "$TUI2_BTN_BACK" \
			--help-button --help-label "View ISC" \
			--yesno "$_summary" 0 0
		local rc=$?
		if [[ $rc -eq 2 ]]; then
			local _isc="$ABA_ROOT/mirror/data/imageset-config.yaml"
			if [[ -f "$_isc" ]]; then
				dlg --backtitle "$(ui_backtitle)" --title "ImageSet Configuration" \
					--exit-label "OK" --textbox "$_isc" 0 0
			else
				dlg --backtitle "$(ui_backtitle)" --msgbox "ISC file not yet generated." 6 40
			fi
			continue
		fi
		[[ $rc -eq 0 ]] && return 0
		return 1
	done
}

# =============================================================================
# Save Images (to local archive)
# =============================================================================

mirror_save() {
	tui_log "Action: Save Images"
	_mirror_op_confirm "$TUI2_LABEL_SAVE" || return 1
	confirm_and_execute "aba --dir mirror save$(_tui_oc_mirror_retry_suffix)" "$TUI2_LABEL_SAVE"
	local rc=$?
	return $rc
}

# =============================================================================
# Prepare Upgrade for Transfer (set target version + save)
# =============================================================================

mirror_prep_upgrade() {
	tui_log "Action: Prepare Upgrade for Transfer"

	local _current_ver="${ocp_version:-unknown}"
	local _target_ver
	local _existing_target=""
	if [[ -f "$ABA_ROOT/mirror/mirror.conf" ]]; then
		_existing_target=$(grep '^ocp_version_target=' "$ABA_ROOT/mirror/mirror.conf" 2>/dev/null | head -1 | cut -d= -f2- | sed 's/[[:space:]]*#.*//')
	fi

	# Fetch available versions for the current channel (reuse cached data)
	local _channel="${ocp_channel:-fast}"
	run_once -p -i "ocp:${_channel}:latest_version" 2>/dev/null || {
		dlg --backtitle "$(ui_backtitle)" --infobox \
			"$(printf "$TUI2_MSG_VERSION_FETCHING" "$_channel")" 0 0
		run_once -q -w -S -i "ocp:${_channel}:latest_version" 2>/dev/null || \
			run_once -i "ocp:${_channel}:latest_version" -- \
				bash -lc "source ./scripts/include_all.sh; fetch_latest_version $_channel"
		run_once -q -w -S -i "ocp:${_channel}:latest_version_previous" 2>/dev/null || \
			run_once -i "ocp:${_channel}:latest_version_previous" -- \
				bash -lc "source ./scripts/include_all.sh; fetch_previous_version $_channel"
	}

	local _latest _previous
	_latest=$(run_once -o -i "ocp:${_channel}:latest_version" 2>/dev/null)
	_previous=$(run_once -o -i "ocp:${_channel}:latest_version_previous" 2>/dev/null)

	# Build menu items — show all valid upgrade versions (deduplicated)
	local items=() _default_tag="m"

	# Existing target from mirror.conf — validate against graph before showing
	if [[ -n "$_existing_target" ]]; then
		if verify_release_version_exists "$_existing_target" "$_channel" 2>/dev/null; then
			items+=("t" "Current target ($_existing_target)")
			_default_tag="t"
		else
			# Invalid target — show it marked as unavailable so user knows
			items+=("t" "Current target ($_existing_target) [NOT IN CHANNEL]")
			_default_tag="l"
		fi
	fi
	if [[ -n "$_latest" && "$_latest" != "$_existing_target" ]]; then
		items+=("l" "Latest    ($_latest)")
		[[ "$_default_tag" == "m" ]] && _default_tag="l"
	fi
	if [[ -n "$_previous" && "$_previous" != "$_existing_target" && "$_previous" != "$_latest" ]]; then
		items+=("p" "Previous  ($_previous)")
	fi
	items+=("m" "Manual entry (x.y or x.y.z)")
	if [[ -n "$_existing_target" ]]; then
		items+=("c" "Clear target (disable upgrade mode)")
	fi

	# Version picker loop
	while :; do
		dlg --backtitle "$(ui_backtitle)" --title "Prepare Upgrade for Transfer" \
			--default-item "$_default_tag" \
			--ok-label "$TUI2_BTN_NEXT" \
			--cancel-label "$TUI2_BTN_CANCEL" \
			--menu "Select target upgrade version ($_channel channel):\n\nCurrent configured: ${_current_ver}" 0 0 0 \
			"${items[@]}" \
			2>"$_TUI_TMP"
		[[ $? -ne 0 ]] && return 1

		local _choice
		_choice=$(<"$_TUI_TMP")
		case "$_choice" in
			t) _target_ver="$_existing_target" ;;
			l) _target_ver="$_latest" ;;
			p) _target_ver="$_previous" ;;
		c)
			sed -i --follow-symlinks "s|^\(ocp_version_target=\)|#\1|" "$ABA_ROOT/mirror/mirror.conf"
			tui_kick_isconf_regen
			dlg --backtitle "$(ui_backtitle)" --msgbox \
				"\nUpgrade target cleared.\n\nMirror will no longer include upgrade images." 0 0
			return 0
			;;
		m)
			while :; do
				dlg --backtitle "$(ui_backtitle)" --title "Prepare Upgrade for Transfer" \
					--inputbox "Enter target version (x.y, x.y.z, or x.y.z-rc.N):" \
					0 0 "${_existing_target}" \
					2>"$_TUI_TMP"
				[[ $? -ne 0 ]] && break
				_target_ver=$(<"$_TUI_TMP")
				_target_ver=$(echo "$_target_ver" | tr -d ' ')
				if [[ "$_target_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-z]+\.[0-9]+)?$ ]]; then
					break
				elif [[ "$_target_ver" =~ ^[0-9]+\.[0-9]+$ ]]; then
					dlg --backtitle "$(ui_backtitle)" --infobox \
						"Resolving $_target_ver to latest z-stream..." 0 0
					local _resolved=""
					if _resolved=$(_resolve_minor_to_patch "$_target_ver" "$_channel"); then
						_target_ver="$_resolved"
						break
					fi
					dlg --backtitle "$(ui_backtitle)" --msgbox \
						"Could not resolve $_target_ver in $_channel channel." 0 0
				else
					dlg --backtitle "$(ui_backtitle)" --msgbox \
						"Invalid format.\n\nExpected: x.y, x.y.z, or x.y.z-rc.N" 0 0
				fi
			done
			[[ -z "$_target_ver" ]] && continue
			;;
		esac

		# Verify version exists in Cincinnati graph (fast check before long oc-mirror run)
		dlg --backtitle "$(ui_backtitle)" --infobox "Verifying ${_target_ver} exists in ${_channel} channel..." 0 0
		if ! verify_release_version_exists "$_target_ver" "$_channel"; then
			dlg --backtitle "$(ui_backtitle)" --msgbox \
				"Version $_target_ver not found in '$_channel' channel.\n\nThis version may not have been released yet.\nCheck the channel or try a different version." 0 0
			continue
		fi

		break
	done

	# Set target version and kick off ISC regeneration in background (while user reads dialog)
	replace-value-conf -q -n ocp_version_target -v "$_target_ver" -f "$ABA_ROOT/mirror/mirror.conf"
	tui_kick_isconf_regen

	# Confirm before proceeding
	dlg --backtitle "$(ui_backtitle)" --title "Prepare Upgrade for Transfer" \
		--yes-label "Save Upgrade Images" \
		--no-label "$TUI2_BTN_CANCEL" \
		--yesno "\nThis will:\n\n\
  1. Set target version to ${_target_ver}\n\
  2. Regenerate the ImageSet Config (if not user-edited)\n\
  3. Download upgrade images (${_current_ver} → ${_target_ver})\n\n\
Proceed?" 0 0
	[[ $? -ne 0 ]] && return 1

	confirm_and_execute \
		"aba --dir mirror --target-version $_target_ver save$(_tui_oc_mirror_retry_suffix)" \
		"Prepare Upgrade: ${_current_ver} → ${_target_ver}"
	local rc=$?

	if [[ $rc -eq 0 ]]; then
		dlg --backtitle "$(ui_backtitle)" --title "Upgrade Images Ready" \
			--msgbox "\nUpgrade images saved successfully.\n\n\
To upgrade a disconnected cluster:\n\n\
  1. Copy these files to the internal host:\n\
     • mirror/data/imageset-config.yaml\n\
     • mirror/data/mirror_*.tar\n\
     • cli/openshift-*-<version>*  (matching CLI binaries for target version)\n\n\
  2. On the internal host TUI:\n\
     • Load images (L)\n\
     • Day-2 → Configure OperatorHub (D → R)\n\
     • Day-2 → Upgrade (D → U)\n" 0 0
	fi

	return $rc
}

# =============================================================================
# Sync Images (directly to registry)
# =============================================================================

mirror_sync() {
	tui_log "Action: Sync Images"
	_mirror_op_confirm "$TUI2_LABEL_SYNC" || return 1
	confirm_and_execute "aba --dir mirror sync$(_tui_oc_mirror_retry_suffix)" "$TUI2_LABEL_SYNC" _invalidate_mirror_cache
	local rc=$?
	[[ $rc -eq 0 ]] && _offer_day2_after_mirror_update
	return $rc
}

# =============================================================================
# Persist operator basket to aba.conf (so `aba isconf` picks it up)
# =============================================================================

# Tracks whether basket changed since last persist (avoids unnecessary ISC regen)
# Starts false: basket loaded from aba.conf matches what ISC was generated from
_OP_BASKET_DIRTY=false

_persist_operator_basket() {
	# If basket hasn't changed, just ensure ISC generation is running/done
	if [[ "$_OP_BASKET_DIRTY" != "true" ]]; then
		# Start ISC gen if it was never started (first View ISC call)
		if ! run_once -p -i "aba:isconf:generate" 2>/dev/null; then
			run_once -i "aba:isconf:generate" -- \
				make -sC "$ABA_ROOT/mirror" isconf >>"$_TUI_LOG_FILE" 2>&1 &
		fi
		return
	fi

	if [[ ${#OP_BASKET[@]} -eq 0 ]]; then
		replace-value-conf -q -n ops     -v "" -f aba.conf
		replace-value-conf -q -n op_sets -v "" -f aba.conf
		tui_log "Persisted empty operator basket to aba.conf"
	else
		# Generate sorted operator list for dedup comparison
		local new_op_list
		new_op_list=$(printf "%s\n" "${!OP_BASKET[@]}" | sort | paste -sd, -)

		# Check if an identical custom set already exists
		local found_duplicate="" existing_file existing_op_list
		for existing_file in "$ABA_ROOT"/templates/operator-set-custom-*; do
			[[ -f "$existing_file" ]] || continue
			existing_op_list=$(tail -n +2 "$existing_file" | sort | paste -sd, -)
			if [[ "$new_op_list" == "$existing_op_list" ]]; then
				found_duplicate=$(basename "$existing_file")
				found_duplicate=${found_duplicate#operator-set-}
				break
			fi
		done

		local custom_set_name
		if [[ -n "$found_duplicate" ]]; then
			custom_set_name="$found_duplicate"
		else
			local timestamp
			timestamp=$(date +%Y%m%d-%H%M%S)
			custom_set_name="custom-${timestamp}"
			local custom_set_file="$ABA_ROOT/templates/operator-set-${custom_set_name}"

			# Delete old custom sets
			for existing_file in "$ABA_ROOT"/templates/operator-set-custom-*; do
				[[ -f "$existing_file" ]] && rm -f "$existing_file"
			done

			{
				echo "# Name: Custom Operator Set $(date '+%Y-%m-%d %H:%M')"
				printf "%s\n" "${!OP_BASKET[@]}" | sort
			} > "$custom_set_file"
		fi

		replace-value-conf -q -n ops     -v ""               -f aba.conf
		replace-value-conf -q -n op_sets -v "$custom_set_name" -f aba.conf
		tui_log "Persisted ${#OP_BASKET[@]} operators as op_sets=$custom_set_name"
	fi

	# Kick off ISC regeneration in background (non-blocking)
	tui_kick_isconf_regen

	_OP_BASKET_DIRTY=false
}

# =============================================================================
# View ImageSet Config (read-only or editable)
# =============================================================================

mirror_view_isc() {
	local readonly="${1:-false}"
	local isconf_file="$ABA_ROOT/mirror/data/imageset-config.yaml"
	tui_log "Action: View ISC (readonly=$readonly)"

	# Ensure basket is persisted and ISC gen is running
	_persist_operator_basket

	# Only show wait message if ISC is still being generated
	if ! run_once -p -i "aba:isconf:generate" 2>/dev/null; then
		dlg --backtitle "$(ui_backtitle)" --infobox \
			"$TUI2_MSG_ISC_GENERATING" 0 0
		if ! run_once -q -w -i "aba:isconf:generate" -- \
			make -sC "$ABA_ROOT/mirror" isconf >>"$_TUI_LOG_FILE" 2>&1; then
			tui_log "ERROR: ISC generation failed"
			dlg --backtitle "$(ui_backtitle)" --msgbox \
				"Failed to generate ImageSet configuration.\nCheck log: $_TUI_LOG_FILE" 0 0
			return 0
		fi
	fi

	local wait_count=0
	while [[ ! -f "$isconf_file" ]] && [[ $wait_count -lt 10 ]]; do
		sleep 0.5
		wait_count=$((wait_count + 1))
	done

	if [[ ! -f "$isconf_file" ]]; then
		dlg --backtitle "$(ui_backtitle)" --msgbox \
			"$(printf "$TUI2_MSG_ISC_NOT_FOUND" "$isconf_file")" 0 0 || true
		return 0
	fi

	if [[ "$readonly" == "true" ]]; then
		dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_DISCO_VIEW_ISC" \
			--exit-label "OK" \
			--textbox "$isconf_file" 0 0
	else
		# Editable — offer view/edit/reset/operators-only toggle
		local default_item="V"
		while :; do
		# Read current excl_platform state from aba.conf
		local _excl_plat="false"
		source <(normalize-aba-conf) 2>/dev/null
		_excl_plat="${excl_platform:-false}"

		local _isc_items=("V" "View (read-only)" "E" "Edit")
		local _created_flag="$ABA_ROOT/mirror/data/.created"
		_isc_items+=("R" "Force regenerate (from aba settings)")
		# Toggle: process operators only (skip release images)
		local _excl_label
		if [[ "$_excl_plat" == "true" ]]; then
			_excl_label="Operators Only: \Z1ON\Zn (release images excluded)"
		else
			_excl_label="Operators Only: \Z2OFF\Zn (all images included)"
		fi
		_isc_items+=("O" "$_excl_label")

		dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CONNO_VIEW_ISC" \
			--cancel-label "$TUI2_BTN_BACK" \
			--ok-label "Select" \
			--default-item "$default_item" \
			--menu "$TUI2_MSG_ISC_MENU" 0 0 0 \
				"${_isc_items[@]}" \
				2>"$_TUI_TMP"
			local rc=$?
			[[ $rc -ne 0 ]] && return 0

			local choice
			choice=$(<"$_TUI_TMP")
			[[ -n "$choice" ]] && default_item="$choice"

			case "$choice" in
				V|E)
					# Wait for any in-flight ISC regeneration to finish
					if ! run_once -p -i "aba:isconf:generate" 2>/dev/null; then
						dlg --backtitle "$(ui_backtitle)" --infobox \
							"$TUI2_MSG_ISC_GENERATING" 0 0
						run_once -q -w -i "aba:isconf:generate" -- \
							make -sC "$ABA_ROOT/mirror" isconf >>"$_TUI_LOG_FILE" 2>&1 || true
					fi
					;;&
				V)
					dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CONNO_VIEW_ISC" \
						--exit-label "OK" --textbox "$isconf_file" 0 0
					;;
				E)
					dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CONNO_EDIT_ISC" \
						--ok-label "$TUI2_BTN_SAVE" --cancel-label "$TUI2_BTN_CANCEL" \
						--editbox "$isconf_file" 0 0 2>"$_TUI_TMP"
					if [[ $? -eq 0 ]]; then
						cp "$_TUI_TMP" "$isconf_file"
						tui_log "ISC saved by user"
						dlg --backtitle "$(ui_backtitle)" --msgbox \
							"$TUI2_MSG_ISC_SAVED" 0 0 || true
					fi
					;;
				R)
					dlg --backtitle "$(ui_backtitle)" --title "Confirm Regenerate" \
						--yes-label "Regenerate" --no-label "Cancel" \
						--yesno "\nThis will discard any manual edits and regenerate the\nImageSet Config from current aba settings\n(version, channel, operators).\n\nAre you sure?" 11 60
					if [[ $? -eq 0 ]]; then
						rm -f "$_created_flag" 2>/dev/null
						rm -f "$ABA_ROOT/mirror/imageset-config-save.yaml" 2>/dev/null
						run_once -r -i "aba:isconf:generate" 2>/dev/null || true
						dlg --backtitle "$(ui_backtitle)" --infobox "Regenerating..." 3 20
						run_once -q -w -i "aba:isconf:generate" -- \
							make -sC "$ABA_ROOT/mirror" isconf >>"$_TUI_LOG_FILE" 2>&1 || true
						tui_log "ISC force-regenerated by user"
						dlg --backtitle "$(ui_backtitle)" --title "Regenerated ImageSet Config" \
							--exit-label "OK" --textbox "$isconf_file" 0 0
					fi
					;;
				O)
				if [[ "$_excl_plat" == "true" ]]; then
					replace-value-conf -n excl_platform -v "false" -f "$ABA_ROOT/aba.conf" >>"$_TUI_LOG_FILE" 2>&1
					tui_log "Settings: excl_platform=false (all images)"
				else
					replace-value-conf -n excl_platform -v "true" -f "$ABA_ROOT/aba.conf" >>"$_TUI_LOG_FILE" 2>&1
					tui_log "Settings: excl_platform=true (operators only)"
				fi
				tui_kick_isconf_regen >>"$_TUI_LOG_FILE" 2>&1
				;;
			esac
		done
	fi
	return 0
}

# =============================================================================
# Select Operators (adapted from v1)
# =============================================================================

mirror_select_operators() {
	local wizard_mode="${1:-}"

	tui_log "Action: Select Operators"

	local version_short
	version_short=$(_ver_minor "$ocp_version")

	# Ensure catalogs are available
	if ! tui_ensure_catalogs_ready "$version_short"; then
		tui_log "ERROR: Catalog download failed (see log)"
		dlg --backtitle "$(ui_backtitle)" --msgbox \
			"Failed to download operator catalog indexes.\n\nCheck your network and pull secret, then try again from the Operators menu.\nSee log: $_TUI_LOG_FILE" 0 0
		return 1
	fi

	# Delegate to the operator selection menu (same as v1 structure)
	_operator_menu "$version_short" "${wizard_mode:-}"
	return $?
}

_operator_menu() {
	local version_short="$1"
	local wizard_mode="${2:-}"

	local default_item="1"
	while :; do
		local basket_count="${#OP_BASKET[@]}"

		# Build catalog operator counts for menu text (aligned columns)
		local _cat_stats="" _cat _count _idx _line
		for _cat in redhat-operator certified-operator community-operator; do
			_idx="$ABA_ROOT/.index/${_cat}-index-v${version_short}"
			if [[ -s "$_idx" ]]; then
				_count=$(wc -l < "$_idx")
				printf -v _line "  %-22s %s" "${_cat}s:" "$_count"
			else
				printf -v _line "  %-22s %s" "${_cat}s:" "(downloading)"
			fi
			_cat_stats="${_cat_stats}${_line}\n"
		done

		dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_OPERATORS" \
			--default-item "$default_item" \
			--cancel-label "$TUI2_BTN_BACK" \
			--help-button \
			--ok-label "$TUI2_BTN_SELECT" \
			--extra-button --extra-label "$TUI2_BTN_DONE" \
			--menu "Available catalogs:\n\n${_cat_stats}" 0 0 0 \
			1 "Select Operator Sets" \
			2 "Search Operator Names" \
			3 "View/Edit Basket ($basket_count operator$( [[ $basket_count -ne 1 ]] && echo s))" \
			4 "Clear Basket" \
			2>"$_TUI_TMP"
		local rc=$?

		case "$rc" in
			2)
				show_help "$TUI2_HELP_TITLE_OPERATORS" \
"Choose operators to include in your mirror/bundle.

• Operator Sets: pre-defined groups (ocp, odf, virt, acm, quay...)
• Search: find operators by name in the catalog
• View/Edit Basket: see and modify your current selection
• Clear: remove all operators from the basket

Selected operators will be included in the ImageSet config."
				continue
				;;
			3)
				# Done
				if [[ ${#OP_BASKET[@]} -eq 0 ]]; then
					dlg --backtitle "$(ui_backtitle)" \
						--title "Warning: No Operators Selected" \
						--yes-label "Continue" \
						--no-label "Go Back" \
						--yesno \
						"\nNo operators are selected.\n\nContinue without any operators?" \
						9 50
					local _nb_rc=$?
					[[ $_nb_rc -ne 0 ]] && continue
				fi
				tui_log "Operator selection done with $basket_count operators"
				return 0
				;;
			1|255)
				# Wizard: Back returns to platform; action menu treats Back same as Done
				if [[ "$wizard_mode" == "wizard" ]]; then
					return 2
				fi
				return 0
				;;
			0) ;;
		esac

		local choice
		choice=$(<"$_TUI_TMP")
		[[ -n "$choice" ]] && default_item="$choice"

		case "$choice" in
			1) local _pre_count=${#OP_BASKET[@]}
			   _operator_sets "$version_short"
			   if [[ ${#OP_BASKET[@]} -ne $_pre_count ]]; then
			   	_OP_BASKET_DIRTY=true
			   	_persist_operator_basket
			   fi
			   default_item=3
			   ;;
			2) local _pre_count=${#OP_BASKET[@]}
			   _operator_search "$version_short"
			   if [[ ${#OP_BASKET[@]} -ne $_pre_count ]]; then
			   	_OP_BASKET_DIRTY=true
			   	_persist_operator_basket
			   fi
			   default_item=3
			   ;;
			3) local _pre_count=${#OP_BASKET[@]}
			   _operator_view_basket
			   if [[ ${#OP_BASKET[@]} -ne $_pre_count ]]; then
			   	_OP_BASKET_DIRTY=true
			   	_persist_operator_basket
			   fi
			   ;;
			4)
				if [[ ${#OP_BASKET[@]} -eq 0 ]]; then
					dlg --backtitle "$(ui_backtitle)" --msgbox "Basket is already empty." 0 0
				else
					dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CLEAR_BASKET" \
						--yes-label "Clear" --no-label "$TUI2_BTN_CANCEL" \
						--yesno "Remove all ${#OP_BASKET[@]} operators from basket?" 0 0
					if [[ $? -eq 0 ]]; then
						OP_BASKET=()
						OP_SET_ADDED=()
						_OP_BASKET_DIRTY=true
						_persist_operator_basket
						tui_log "Basket cleared"
						dlg --backtitle "$(ui_backtitle)" --msgbox "Basket cleared." 0 0
					fi
				fi
				;;
		esac
	done
}

_operator_sets() {
	local version_short="$1"

	# Build checklist items (tag=set_key, description=display_name, state=on/off)
	local items=()
	local set_file set_key display state
	for set_file in "$ABA_ROOT"/templates/operator-set-*; do
		[[ -f "$set_file" ]] || continue
		set_key="${set_file##*operator-set-}"
		display=$(head -n1 "$set_file" 2>/dev/null | sed 's/^# *//' | sed 's/^Name: *//')
		[[ -z "$display" ]] && display="$set_key"
		state="off"
		[[ "${OP_SET_ADDED[$set_key]:-}" == "1" ]] && state="on"
		items+=("$set_key" "$display" "$state")
	done

	if [[ ${#items[@]} -eq 0 ]]; then
		dlg --backtitle "$(ui_backtitle)" --msgbox "$TUI2_MSG_NO_OPERATOR_SETS" 0 0
		return
	fi

	local num_sets=$((${#items[@]} / 3))
	local list_h=$((num_sets < 18 ? num_sets + 2 : 18))

	dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_OPERATOR_SETS" \
		--cancel-label "$TUI2_BTN_BACK" \
		--ok-label "Apply" \
		--separate-output \
		--checklist "$TUI2_MSG_OPERATOR_SET_MENU" 0 70 $list_h \
		"${items[@]}" \
		2>"$_TUI_TMP"
	local rc=$?
	[[ $rc -ne 0 ]] && return

	# Build set of what user selected
	declare -A _newly_selected=()
	local k
	while IFS= read -r k; do
		k="${k##[[:space:]]}"
		k="${k%%[[:space:]]}"
		[[ -n "$k" ]] && _newly_selected["$k"]=1
	done < "$_TUI_TMP"

	# Remove sets that were previously added but are now unchecked
	# Uses ref-counting: decrement instead of unset, so shared operators
	# remain in the basket as long as at least one set still contains them
	local prev_set
	for prev_set in "${!OP_SET_ADDED[@]}"; do
		if [[ -z "${_newly_selected[$prev_set]:-}" ]]; then
			local sf="$ABA_ROOT/templates/operator-set-$prev_set"
			if [[ -f "$sf" ]]; then
				local line
				while IFS= read -r line; do
					[[ "$line" =~ ^[[:space:]]*# ]] && continue
					[[ -z "$line" ]] && continue
					line="${line%%#*}"                          # Strip inline comment
					line="${line#"${line%%[![:space:]]*}"}"     # Trim leading whitespace
					line="${line%"${line##*[![:space:]]}"}"     # Trim trailing whitespace
					[[ -z "$line" ]] && continue
					local _count=${OP_BASKET[$line]:-0}
					_count=$(( _count - 1 ))
					if [[ $_count -le 0 ]]; then
						unset 'OP_BASKET[$line]'
					else
						OP_BASKET["$line"]=$_count
					fi
				done < "$sf"
			fi
			unset 'OP_SET_ADDED[$prev_set]'
			tui_log "Removed operator set: $prev_set"
		fi
	done

	# Add newly selected sets (increment ref-count for each operator)
	local new_set
	for new_set in "${!_newly_selected[@]}"; do
		if [[ -z "${OP_SET_ADDED[$new_set]:-}" ]]; then
			local sf="$ABA_ROOT/templates/operator-set-$new_set"
			if [[ -f "$sf" ]]; then
				local line
				while IFS= read -r line; do
					[[ "$line" =~ ^[[:space:]]*# ]] && continue
					[[ -z "$line" ]] && continue
					line="${line%%#*}"                          # Strip inline comment
					line="${line#"${line%%[![:space:]]*}"}"     # Trim leading whitespace
					line="${line%"${line##*[![:space:]]}"}"     # Trim trailing whitespace
					[[ -z "$line" ]] && continue
					if awk -v name="$line" '$1 == name {found=1; exit} END {exit !found}' "$ABA_ROOT"/.index/*-index-v${version_short} 2>/dev/null; then
						OP_BASKET["$line"]=$(( ${OP_BASKET[$line]:-0} + 1 ))
					fi
				done < "$sf"
			fi
			OP_SET_ADDED["$new_set"]=1
			tui_log "Added operator set: $new_set"
		fi
	done
	tui_log "After set selection — basket: ${#OP_BASKET[@]}, sets: ${!OP_SET_ADDED[*]}"
}

_operator_search() {
	local version_short="$1"

	dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_OPERATOR_SEARCH" \
		--cancel-label "$TUI2_BTN_BACK" \
		--inputbox "$TUI2_MSG_OPERATOR_SEARCH_PROMPT" 0 0 "" \
		2>"$_TUI_TMP"
	local rc=$?
	[[ $rc -ne 0 ]] && return

	local query
	query=$(<"$_TUI_TMP")
	[[ -z "$query" ]] && return
	if [[ ${#query} -lt 2 ]]; then
		dlg --backtitle "$(ui_backtitle)" --msgbox "Please enter at least 2 characters." 0 0
		return
	fi

	# Search across all catalog indexes (format: "op-name  Display Name  channel")
	# Priority order: redhat, certified, community — first match per operator wins
	local items=()
	local line op_name display_name state
	declare -A _seen_ops=()
	while IFS= read -r line; do
		line="${line##[[:space:]]}"
		line="${line%%[[:space:]]}"
		[[ -z "$line" ]] && continue
		op_name="${line%%[[:space:]]*}"
		[[ -z "$op_name" ]] && continue
		[[ -n "${_seen_ops[$op_name]:-}" ]] && continue
		_seen_ops["$op_name"]=1
		display_name=$(echo "$line" | awk '{$1=""; $NF=""; gsub(/^ +| +$/, ""); print}')
		state="off"
		[[ -n "${OP_BASKET[$op_name]:-}" ]] && state="on"
		items+=("$op_name" "${display_name:--}" "$state")
	# -h suppresses filename prefix; search redhat/certified before community
	done < <(grep -hiF "$query" \
		"$ABA_ROOT"/.index/redhat-operator-index-v${version_short} \
		"$ABA_ROOT"/.index/certified-operator-index-v${version_short} \
		"$ABA_ROOT"/.index/community-operator-index-v${version_short} \
		2>/dev/null | head -100)

	if [[ ${#items[@]} -eq 0 ]]; then
		dlg --backtitle "$(ui_backtitle)" --msgbox "$(printf "$TUI2_MSG_NO_SEARCH_RESULTS" "$query")" 0 0
		return
	fi

	local num_ops=$((${#items[@]} / 3))
	local list_h=$((num_ops < 18 ? num_ops + 2 : 18))

	dlg --backtitle "$(ui_backtitle)" --title "Search Results: $query" \
		--cancel-label "$TUI2_BTN_BACK" \
		--ok-label "Add to Basket" \
		--separate-output \
		--checklist "$TUI2_MSG_OPERATOR_SEARCH_MENU" 0 0 $list_h \
		"${items[@]}" \
		2>"$_TUI_TMP"
	rc=$?
	[[ $rc -ne 0 ]] && return

	# Build set of what user selected
	declare -A _SEL=()
	while IFS= read -r line; do
		line="${line##[[:space:]]}"
		line="${line%%[[:space:]]}"
		[[ -n "$line" ]] && _SEL["$line"]=1
	done < "$_TUI_TMP"

	# Add newly selected, remove unchecked
	local op
	for ((i=0; i<${#items[@]}; i+=3)); do
		op="${items[$i]}"
		if [[ -n "${_SEL[$op]:-}" ]]; then
			[[ -z "${OP_BASKET[$op]:-}" ]] && OP_BASKET["$op"]=1
		elif [[ -n "${OP_BASKET[$op]:-}" ]]; then
			unset 'OP_BASKET[$op]'
			tui_log "Removed operator: $op"
		fi
	done
	tui_log "Search complete, basket now: ${#OP_BASKET[@]} operators"
}

_operator_view_basket() {
	if [[ ${#OP_BASKET[@]} -eq 0 ]]; then
		dlg --backtitle "$(ui_backtitle)" --msgbox "$TUI2_MSG_BASKET_EMPTY" 0 0
		return
	fi

	local version_short
	version_short=$(_ver_minor "$ocp_version")
	local items=()
	local op display_name line
	for op in $(echo "${!OP_BASKET[@]}" | tr ' ' '\n' | sort); do
		display_name=""
		# Search redhat first, then certified, then community (priority order)
		line=$(grep -m1 "^${op}[[:space:]]" \
			"$ABA_ROOT"/.index/redhat-operator-index-v${version_short} \
			"$ABA_ROOT"/.index/certified-operator-index-v${version_short} \
			"$ABA_ROOT"/.index/community-operator-index-v${version_short} \
			2>/dev/null)
		if [[ -n "$line" ]]; then
			display_name=$(echo "$line" | awk '{$1=""; $NF=""; gsub(/^ +| +$/, ""); print}')
		fi
		items+=("$op" "${display_name:--}" "on")
	done

	local num_ops=$((${#items[@]} / 3))
	local list_h=$((num_ops < 18 ? num_ops + 2 : 18))

	dlg --backtitle "$(ui_backtitle)" --title "Operator Basket (${#OP_BASKET[@]})" \
		--cancel-label "$TUI2_BTN_BACK" \
		--ok-label "Apply" \
		--separate-output \
		--checklist "Uncheck to remove. Use spacebar to toggle:" 0 0 $list_h \
		"${items[@]}" \
		2>"$_TUI_TMP"
	local rc=$?
	[[ $rc -ne 0 ]] && return

	# Rebuild basket from what remains checked
	declare -A _KEPT=()
	local line
	while IFS= read -r line; do
		line="${line##[[:space:]]}"
		line="${line%%[[:space:]]}"
		[[ -n "$line" ]] && _KEPT["$line"]=1
	done < "$_TUI_TMP"

	# Remove operators that were unchecked
	for op in "${!OP_BASKET[@]}"; do
		if [[ -z "${_KEPT[$op]:-}" ]]; then
			unset 'OP_BASKET[$op]'
			tui_log "Removed from basket: $op"
		fi
	done
	tui_log "Basket after edit: ${#OP_BASKET[@]} operators"
}

# =============================================================================
# Ensure offline prerequisites (CLI tools + registry installers)
# =============================================================================

_ensure_offline_prereqs() {
	tui_log "Ensuring offline prerequisites are downloaded..."

	# Peek using the SAME per-tool IDs that ABA core uses
	local need_download=false
	run_once -p -i "cli:download:openshift-install:${ocp_version}" 2>/dev/null || need_download=true
	run_once -p -i "$TASK_DL_QUAY_REG" 2>/dev/null || need_download=true

	if [[ "$need_download" == "false" ]]; then
		tui_log "Offline prerequisites already ready (peek passed)."
		return 0
	fi

	dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_PREPARING" \
		--infobox "Downloading offline files (CLI tools + registry installers)...\n\nPlease wait." 0 0

	# cli-download-all.sh uses per-tool run_once IDs (cli:download:<tool>[:<ver>])
	# Close flock fd so child processes don't inherit and hold the TUI lock
	if ! bash -lc "cd '$ABA_ROOT' && scripts/cli-download-all.sh --wait" {ABA_TUI_FLOCK_FD}>&- >>"$_TUI_LOG_FILE" 2>&1; then
		dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_DOWNLOAD_FAILED" \
			--msgbox "Failed to download CLI tools.\n\nCheck internet connectivity and try again." 0 0
		return 1
	fi

	if ! run_once -q -w -i "$TASK_DL_QUAY_REG" -- \
		"${CMD_DL_QUAY_REG[@]}" >>"$_TUI_LOG_FILE" 2>&1; then
		dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_DOWNLOAD_FAILED" \
			--msgbox "Failed to download registry installers.\n\nCheck internet connectivity and try again." 0 0
		return 1
	fi

	tui_log "Offline prerequisites ready."
	return 0
}

# =============================================================================
# Create Bundle
# =============================================================================

mirror_create_bundle() {
	tui_log "Action: Create Install Bundle"

	_ensure_offline_prereqs || return 1

	# Build summary: OCP version/channel + operator list
	source <(normalize-aba-conf) 2>/dev/null
	local _ver="${ocp_version:-unknown}"
	local _chan="${ocp_channel:-stable}"
	local _op_count=${#OP_BASKET[@]}
	local _op_preview=""
	if [[ $_op_count -gt 0 ]]; then
		local _shown=()
		local _i=0
		for _op in "${!OP_BASKET[@]}"; do
			_shown+=("$_op")
			_i=$(( _i + 1 ))
			[[ $_i -ge 5 ]] && break
		done
		_op_preview=$(IFS=","; echo "${_shown[*]}" | sed 's/,/, /g')
		if [[ $_op_count -gt 5 ]]; then
			_op_preview="$_op_preview, ... (+$(( _op_count - 5 )) more)"
		fi
	fi

	local _summary="OCP: $_ver ($_chan)\n"
	if [[ $_op_count -gt 0 ]]; then
		_summary+="Operators ($_op_count): $_op_preview\n"
	else
		_summary+="Operators: none\n"
	fi
	_summary+="\nEnter output path (version suffix added automatically):"

	local default_bundle="/tmp/ocp-bundle"

	while :; do
		dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CONNO_BUNDLE" \
			--cancel-label "$TUI2_BTN_BACK" \
			--ok-label "$TUI2_BTN_NEXT" \
			--help-button --help-label "View ISC" \
			--inputbox "$_summary" 0 0 "$default_bundle" \
			2>"$_TUI_TMP"
		local rc=$?
		if [[ $rc -eq 2 ]]; then
			# Help button = View ISC
			local _isc="$ABA_ROOT/mirror/data/imageset-config.yaml"
			if [[ -f "$_isc" ]]; then
				dlg --backtitle "$(ui_backtitle)" --title "ImageSet Configuration" \
					--exit-label "OK" --textbox "$_isc" 0 0
			else
				dlg --backtitle "$(ui_backtitle)" --msgbox "ISC file not yet generated." 6 40
			fi
			continue
		fi
		[[ $rc -ne 0 ]] && return 1
		break
	done

	local bundle_path
	bundle_path=$(<"$_TUI_TMP")
	bundle_path="${bundle_path/#\~/$HOME}"
	[[ -z "$bundle_path" ]] && bundle_path="$default_bundle"
	[[ -d "$bundle_path" ]] && bundle_path="$bundle_path/ocp-bundle"
	bundle_path="${bundle_path%.tar}"

	# Check same-device for --light option
	local output_dir
	output_dir=$(dirname "$bundle_path")
	mkdir -p "$output_dir" 2>/dev/null

	local output_dev mirror_dev light_flag=""
	output_dev=$(stat -c %d "$output_dir" 2>/dev/null)
	mirror_dev=$(stat -c %d "$ABA_ROOT/mirror/data" 2>/dev/null)

	if [[ -n "$output_dev" && -n "$mirror_dev" && "$output_dev" == "$mirror_dev" ]]; then
		local _mount_point
		_mount_point=$(df --output=target "$output_dir" 2>/dev/null | tail -1)

		dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CONNO_BUNDLE" \
			--yes-label "$TUI2_BTN_LIGHT_BUNDLE" \
			--no-label "$TUI2_BTN_FULL_BUNDLE" \
			--yesno "$TUI2_MSG_BUNDLE_LIGHT_CONFIRM" 0 0
		if [[ $? -eq 0 ]]; then
			light_flag="--light"
		else
			# Full bundle on same device — warn about disk space
			dlg --backtitle "$(ui_backtitle)" --title "Disk Space Warning" \
				--yes-label "$TUI2_BTN_CONTINUE" \
				--no-label "$TUI2_BTN_CANCEL" \
				--yesno "\Z3Disk Space Consideration\Zn\n\n\
Bundle and mirror are on the same filesystem (${_mount_point:-unknown}).\n\n\
Creating a full bundle requires:\n\
  • Mirror image-set archives in mirror/data/\n\
  • Complete bundle copy written to: $bundle_path\n\n\
You may temporarily need roughly \Zbdouble the space\Zn.\n\n\
\ZbRecommendation:\Zn Use light bundle to avoid this.\n\n\
Continue with full bundle anyway?" 0 0
			[[ $? -ne 0 ]] && return 1
		fi
	fi

	# If images already exist, offer reuse vs clean rebuild
	local force_flag=""
	if ls "$ABA_ROOT"/mirror/data/mirror_*.tar >/dev/null 2>&1; then
		local _bundle_data_choice=""
		dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CONNO_BUNDLE" \
			--yes-label "Reuse (fast)" \
			--no-label "Clean Rebuild" \
			--yesno "Existing image data found in mirror/data/.\n\n\
Reuse: only download changed/new images (incremental, fast).\n\
Clean Rebuild: delete existing data and re-download everything.\n\n\
Reuse is recommended unless you changed OpenShift version or suspect corruption." 0 0
		local choice_rc=$?
		case $choice_rc in
			0) tui_log "Bundle: reusing existing image data (incremental)"
			   _bundle_data_choice="reuse" ;;
			1) force_flag="--force"
			   tui_log "Bundle: clean rebuild (--force)"
			   _bundle_data_choice="rebuild" ;;
			*) return 1 ;;
		esac
		[[ -z "$_bundle_data_choice" ]] && return 1
	fi

	local cmd="aba bundle --out \"$bundle_path\""
	[[ -n "$light_flag" ]] && cmd="$cmd $light_flag"
	[[ -n "$force_flag" ]] && cmd="$cmd $force_flag"

	confirm_and_execute "$cmd" "Create Install Bundle"
}
