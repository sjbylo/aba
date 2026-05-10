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

# =============================================================================
# Install Mirror (local or remote)
# =============================================================================

mirror_install() {
	tui_log "Action: Install Mirror"

	while :; do
		dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CONNO_INSTALL_MIRROR" \
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
			1) return 1 ;;
			255)
				if confirm_quit; then clear; _show_v2_exit_summary; exit 0; fi
				continue
				;;
		esac

		local choice
		choice=$(<"$_TUI_TMP")

		case "$choice" in
			1) _mirror_install_local ;;
			2) _mirror_install_remote ;;
		esac
		return $?
	done
}

_mirror_install_local() {
	tui_log "Installing mirror locally"

	# Ensure mirror.conf exists (creates with defaults if missing)
	if [[ ! -f "$ABA_ROOT/mirror/mirror.conf" ]]; then
		tui_log "Creating mirror.conf with defaults"
		make -sC "$ABA_ROOT/mirror" mirror.conf 2>/dev/null || true
	fi

	# Load current values
	local m_host="" m_port="" m_user="" m_pw="" m_path="" m_vendor="" m_datadir=""
	if [[ -f "$ABA_ROOT/mirror/mirror.conf" ]]; then
		source <(cd "$ABA_ROOT/mirror" && normalize-mirror-conf) 2>/dev/null || true
	fi
	m_host="${reg_host:-$(hostname -f 2>/dev/null || hostname)}"
	m_port="${reg_port:-8443}"
	m_user="${reg_user:-init}"
	m_pw="${reg_pw:-p4ssw0rd}"
	m_path="${reg_path:-/ocp4/openshift4}"
	m_vendor="${reg_vendor:-auto}"
	m_datadir="${data_dir:-~}"

	# Menu-style config page
	local default_item="H"
	while :; do
		dlg --backtitle "$(ui_backtitle)" --title " Mirror Configuration (local) " \
			--ok-label "$TUI2_BTN_SELECT" \
			--extra-button --extra-label "$TUI2_BTN_NEXT" \
			--cancel-label "$TUI2_BTN_BACK" \
			--help-button \
			--menu "Configure local mirror registry — select a row to edit:" 18 70 7 \
			"H"  "Hostname:     $m_host" \
			"P"  "Port:         $m_port" \
			"U"  "Username:     $m_user" \
			"W"  "Password:     $m_pw" \
			"I"  "Image path:   $m_path" \
			"V"  "Vendor:       $m_vendor" \
			"D"  "Data dir:     $m_datadir" \
			2>"$_TUI_TMP"
		local rc=$?

		case "$rc" in
			2)
				show_help "Mirror Configuration" \
"Configure settings for the local mirror registry:

  • Hostname — FQDN for the registry (must resolve to this host)
  • Port — registry listen port (default 8443)
  • Username — registry login user
  • Password — registry login password
  • Image path — namespace path for mirrored images
  • Vendor — auto (detects arch), quay, or docker
  • Data dir — storage location for images"
				continue
				;;
			3) break ;;  # Next → proceed to install
			1|255) return 1 ;;  # Back/Escape
			0) ;;  # Select → edit the chosen field
		esac

		local field
		field=$(<"$_TUI_TMP")
		[[ -n "$field" ]] && default_item="$field"

		case "$field" in
			H)
				dlg --backtitle "$(ui_backtitle)" --inputbox "Registry hostname (FQDN):" 0 60 "$m_host" 2>"$_TUI_TMP"
				[[ $? -eq 0 ]] && m_host=$(<"$_TUI_TMP")
				;;
			P)
				dlg --backtitle "$(ui_backtitle)" --inputbox "Registry port:" 0 40 "$m_port" 2>"$_TUI_TMP"
				[[ $? -eq 0 ]] && m_port=$(<"$_TUI_TMP")
				;;
			U)
				dlg --backtitle "$(ui_backtitle)" --inputbox "Registry username:" 0 40 "$m_user" 2>"$_TUI_TMP"
				[[ $? -eq 0 ]] && m_user=$(<"$_TUI_TMP")
				;;
			W)
				dlg --backtitle "$(ui_backtitle)" --inputbox "Registry password:" 0 40 "$m_pw" 2>"$_TUI_TMP"
				[[ $? -eq 0 ]] && m_pw=$(<"$_TUI_TMP")
				;;
			I)
				dlg --backtitle "$(ui_backtitle)" --inputbox "Image path (e.g. /ocp4/openshift4):" 0 60 "$m_path" 2>"$_TUI_TMP"
				[[ $? -eq 0 ]] && m_path=$(<"$_TUI_TMP")
				;;
			V)
				# Toggle: auto → quay → docker → auto
				case "$m_vendor" in
					auto) m_vendor="quay" ;;
					quay) m_vendor="docker" ;;
					docker) m_vendor="auto" ;;
					*) m_vendor="auto" ;;
				esac
				tui_log "Toggled vendor to: $m_vendor"
				;;
			D)
				dlg --backtitle "$(ui_backtitle)" --inputbox "Data directory (absolute path):" 0 60 "$m_datadir" 2>"$_TUI_TMP"
				[[ $? -eq 0 ]] && m_datadir=$(<"$_TUI_TMP")
				;;
		esac
	done

	# Save to mirror.conf
	tui_log "Saving mirror config: host=$m_host port=$m_port vendor=$m_vendor"
	replace-value-conf -q -n reg_host -v "$m_host" -f "$ABA_ROOT/mirror/mirror.conf"
	replace-value-conf -q -n reg_port -v "$m_port" -f "$ABA_ROOT/mirror/mirror.conf"
	replace-value-conf -q -n reg_user -v "$m_user" -f "$ABA_ROOT/mirror/mirror.conf"
	replace-value-conf -q -n reg_pw -v "$m_pw" -f "$ABA_ROOT/mirror/mirror.conf"
	replace-value-conf -q -n reg_path -v "$m_path" -f "$ABA_ROOT/mirror/mirror.conf"
	replace-value-conf -q -n reg_vendor -v "$m_vendor" -f "$ABA_ROOT/mirror/mirror.conf"
	replace-value-conf -q -n data_dir -v "$m_datadir" -f "$ABA_ROOT/mirror/mirror.conf"
	replace-value-conf -q -n reg_ssh_user -v "" -f "$ABA_ROOT/mirror/mirror.conf"
	replace-value-conf -q -n reg_ssh_key -v "" -f "$ABA_ROOT/mirror/mirror.conf"

	confirm_and_execute "aba -d mirror install" "Install Local Mirror"
	_invalidate_mirror_cache
}

_mirror_install_remote() {
	tui_log "Installing mirror on remote host"

	# Ensure mirror.conf exists
	if [[ ! -f "$ABA_ROOT/mirror/mirror.conf" ]]; then
		tui_log "Creating mirror.conf with defaults"
		make -sC "$ABA_ROOT/mirror" mirror.conf 2>/dev/null || true
	fi

	# Load current values
	local m_host="" m_port="" m_user="" m_pw="" m_path="" m_vendor="" m_datadir=""
	local m_ssh_user="" m_ssh_key=""
	if [[ -f "$ABA_ROOT/mirror/mirror.conf" ]]; then
		source <(cd "$ABA_ROOT/mirror" && normalize-mirror-conf) 2>/dev/null || true
	fi
	m_host="${reg_host:-}"
	m_port="${reg_port:-8443}"
	m_user="${reg_user:-init}"
	m_pw="${reg_pw:-p4ssw0rd}"
	m_path="${reg_path:-/ocp4/openshift4}"
	m_vendor="${reg_vendor:-auto}"
	m_datadir="${data_dir:-~}"
	m_ssh_user="${reg_ssh_user:-root}"
	m_ssh_key="${reg_ssh_key:-$HOME/.ssh/id_rsa}"

	# Menu-style config page
	local default_item="H"
	while :; do
		dlg --backtitle "$(ui_backtitle)" --title " Mirror Configuration (remote) " \
			--ok-label "$TUI2_BTN_SELECT" \
			--extra-button --extra-label "$TUI2_BTN_NEXT" \
			--cancel-label "$TUI2_BTN_BACK" \
			--help-button \
			--menu "Configure remote mirror registry — select a row to edit:" 20 70 9 \
			"H"  "Hostname:     ${m_host:-(enter FQDN)}" \
			"S"  "SSH user:     $m_ssh_user" \
			"K"  "SSH key:      $m_ssh_key" \
			"P"  "Port:         $m_port" \
			"U"  "Username:     $m_user" \
			"W"  "Password:     $m_pw" \
			"I"  "Image path:   $m_path" \
			"V"  "Vendor:       $m_vendor" \
			"D"  "Data dir:     $m_datadir" \
			2>"$_TUI_TMP"
		local rc=$?

		case "$rc" in
			2)
				show_help "Mirror Configuration (Remote)" \
"Configure settings for the remote mirror registry:

  • Hostname — FQDN of the remote registry host
  • SSH user — SSH login user on the remote host
  • SSH key — path to SSH private key for remote access
  • Port — registry listen port (default 8443)
  • Username — registry login user
  • Password — registry login password
  • Image path — namespace path for mirrored images
  • Vendor — auto (detects arch), quay, or docker
  • Data dir — storage location on remote host"
				continue
				;;
			3)  # Next → validate and proceed
				if [[ -z "$m_host" ]]; then
					dlg --backtitle "$(ui_backtitle)" --msgbox "Hostname is required for remote install." 0 0
					default_item="H"
					continue
				fi
				break
				;;
			1|255) return 1 ;;
			0) ;;
		esac

		local field
		field=$(<"$_TUI_TMP")
		[[ -n "$field" ]] && default_item="$field"

		case "$field" in
			H)
				dlg --backtitle "$(ui_backtitle)" --inputbox "Remote registry hostname (FQDN):" 0 60 "$m_host" 2>"$_TUI_TMP"
				[[ $? -eq 0 ]] && m_host=$(<"$_TUI_TMP")
				;;
			S)
				dlg --backtitle "$(ui_backtitle)" --inputbox "SSH username:" 0 40 "$m_ssh_user" 2>"$_TUI_TMP"
				[[ $? -eq 0 ]] && m_ssh_user=$(<"$_TUI_TMP")
				;;
			K)
				dlg --backtitle "$(ui_backtitle)" --inputbox "SSH private key path:" 0 60 "$m_ssh_key" 2>"$_TUI_TMP"
				[[ $? -eq 0 ]] && m_ssh_key=$(<"$_TUI_TMP")
				;;
			P)
				dlg --backtitle "$(ui_backtitle)" --inputbox "Registry port:" 0 40 "$m_port" 2>"$_TUI_TMP"
				[[ $? -eq 0 ]] && m_port=$(<"$_TUI_TMP")
				;;
			U)
				dlg --backtitle "$(ui_backtitle)" --inputbox "Registry username:" 0 40 "$m_user" 2>"$_TUI_TMP"
				[[ $? -eq 0 ]] && m_user=$(<"$_TUI_TMP")
				;;
			W)
				dlg --backtitle "$(ui_backtitle)" --inputbox "Registry password:" 0 40 "$m_pw" 2>"$_TUI_TMP"
				[[ $? -eq 0 ]] && m_pw=$(<"$_TUI_TMP")
				;;
			I)
				dlg --backtitle "$(ui_backtitle)" --inputbox "Image path (e.g. /ocp4/openshift4):" 0 60 "$m_path" 2>"$_TUI_TMP"
				[[ $? -eq 0 ]] && m_path=$(<"$_TUI_TMP")
				;;
			V)
				case "$m_vendor" in
					auto) m_vendor="quay" ;;
					quay) m_vendor="docker" ;;
					docker) m_vendor="auto" ;;
					*) m_vendor="auto" ;;
				esac
				tui_log "Toggled vendor to: $m_vendor"
				;;
			D)
				dlg --backtitle "$(ui_backtitle)" --inputbox "Data directory on remote host:" 0 60 "$m_datadir" 2>"$_TUI_TMP"
				[[ $? -eq 0 ]] && m_datadir=$(<"$_TUI_TMP")
				;;
		esac
	done

	# Save to mirror.conf
	tui_log "Saving mirror config: host=$m_host ssh=$m_ssh_user vendor=$m_vendor"
	replace-value-conf -q -n reg_host -v "$m_host" -f "$ABA_ROOT/mirror/mirror.conf"
	replace-value-conf -q -n reg_port -v "$m_port" -f "$ABA_ROOT/mirror/mirror.conf"
	replace-value-conf -q -n reg_user -v "$m_user" -f "$ABA_ROOT/mirror/mirror.conf"
	replace-value-conf -q -n reg_pw -v "$m_pw" -f "$ABA_ROOT/mirror/mirror.conf"
	replace-value-conf -q -n reg_path -v "$m_path" -f "$ABA_ROOT/mirror/mirror.conf"
	replace-value-conf -q -n reg_vendor -v "$m_vendor" -f "$ABA_ROOT/mirror/mirror.conf"
	replace-value-conf -q -n data_dir -v "$m_datadir" -f "$ABA_ROOT/mirror/mirror.conf"
	replace-value-conf -q -n reg_ssh_user -v "$m_ssh_user" -f "$ABA_ROOT/mirror/mirror.conf"
	replace-value-conf -q -n reg_ssh_key -v "$m_ssh_key" -f "$ABA_ROOT/mirror/mirror.conf"

	confirm_and_execute "aba -d mirror install" "Install Remote Mirror"
	_invalidate_mirror_cache
}

# =============================================================================
# Save Images (to local archive)
# =============================================================================

mirror_save() {
	tui_log "Action: Save Images"
	confirm_and_execute "aba -d mirror save" "Save Images to Archive"
	_invalidate_mirror_cache
}

# =============================================================================
# Sync Images (directly to registry)
# =============================================================================

mirror_sync() {
	tui_log "Action: Sync Images"
	confirm_and_execute "aba -d mirror sync" "Sync Images to Registry"
	_invalidate_mirror_cache
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
				bash -lc "cd '$ABA_ROOT' && aba isconf -d mirror" >>"$_TUI_LOG_FILE" 2>&1 &
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
	run_once -r -i "aba:isconf:generate" 2>/dev/null || true
	run_once -i "aba:isconf:generate" -- \
		bash -lc "cd '$ABA_ROOT' && aba isconf -d mirror" >>"$_TUI_LOG_FILE" 2>&1 &

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
			bash -lc "cd '$ABA_ROOT' && aba isconf -d mirror" >>"$_TUI_LOG_FILE" 2>&1; then
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
		# Editable — offer view/edit/reset
		while :; do
		# Only show "Reset" if ISC was manually edited (newer than .created flag)
		local _isc_items=("1" "View (read-only)" "2" "Edit")
		local _created_flag="$ABA_ROOT/mirror/data/.created"
		if [[ -f "$_created_flag" && "$isconf_file" -nt "$_created_flag" ]]; then
			_isc_items+=("3" "Reset to auto-generated")
		fi

		dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CONNO_VIEW_ISC" \
			--cancel-label "$TUI2_BTN_BACK" \
			--ok-label "Select" \
			--menu "$TUI2_MSG_ISC_MENU" 0 0 0 \
				"${_isc_items[@]}" \
				2>"$_TUI_TMP"
			local rc=$?
			if [[ $rc -eq 255 ]]; then
				if confirm_quit; then clear; _show_v2_exit_summary; exit 0; fi
				continue
			fi
			[[ $rc -ne 0 ]] && return 0

			local choice
			choice=$(<"$_TUI_TMP")

			case "$choice" in
				1)
					dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CONNO_VIEW_ISC" \
						--exit-label "OK" --textbox "$isconf_file" 0 0
					;;
				2)
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
				3)
					touch "$ABA_ROOT/mirror/data/.created" 2>/dev/null
					run_once -r -i "aba:isconf:generate" 2>/dev/null || true
					dlg --backtitle "$(ui_backtitle)" --msgbox \
						"$TUI2_MSG_ISC_RESET" 0 0 || true
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
	tui_log "Action: Select Operators"

	local version_short="${ocp_version%.*}"

	# Ensure catalogs are available
	local need_wait=false
	run_once -p -i "catalog:${version_short}:redhat-operator" || need_wait=true
	run_once -p -i "catalog:${version_short}:certified-operator" || need_wait=true
	run_once -p -i "catalog:${version_short}:community-operator" || need_wait=true

	if [[ "$need_wait" == "true" ]]; then
		dlg --backtitle "$(ui_backtitle)" --infobox \
			"$(printf "$TUI2_MSG_CATALOG_DOWNLOADING" "$version_short")" 0 0
		download_all_catalogs "$version_short" >>"$_TUI_LOG_FILE" 2>&1
		for catalog in redhat-operator certified-operator community-operator; do
			if ! run_once -q -w -i "catalog:${version_short}:${catalog}"; then
				tui_log "ERROR: Catalog download failed: $catalog"
				dlg --backtitle "$(ui_backtitle)" --msgbox \
					"$(printf "$TUI2_MSG_CATALOG_FAILED" "$catalog")" 0 0
				return 1
			fi
		done
	fi

	# Delegate to the operator selection menu (same as v1 structure)
	_operator_menu "$version_short"
}

_operator_menu() {
	local version_short="$1"

	while :; do
		local basket_count="${#OP_BASKET[@]}"

		dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_OPERATORS" \
			--cancel-label "$TUI2_BTN_BACK" \
			--help-button \
			--ok-label "$TUI2_BTN_SELECT" \
			--extra-button --extra-label "$TUI2_BTN_DONE" \
			--menu "$TUI2_MSG_OPERATOR_MENU" 0 0 0 \
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

• Operator Sets: pre-defined groups (day2, storage, networking...)
• Search: find operators by name in the catalog
• View/Edit Basket: see and modify your current selection
• Clear: remove all operators from the basket

Selected operators will be included in the ImageSet config."
				continue
				;;
			3)
				# Done
				tui_log "Operator selection done with $basket_count operators"
				return 0
				;;
			1)
				return 0
				;;
			255)
				if confirm_quit; then clear; _show_v2_exit_summary; exit 0; fi
				continue
				;;
			0) ;;
		esac

		local choice
		choice=$(<"$_TUI_TMP")

		case "$choice" in
			1) _operator_sets "$version_short"
			   _OP_BASKET_DIRTY=true
			   _persist_operator_basket
			   ;;
			2) _operator_search "$version_short"
			   _OP_BASKET_DIRTY=true
			   _persist_operator_basket
			   ;;
			3) _operator_view_basket
			   _OP_BASKET_DIRTY=true
			   _persist_operator_basket
			   ;;
		4)
			if [[ ${#OP_BASKET[@]} -eq 0 ]]; then
				dlg --backtitle "$(ui_backtitle)" --msgbox "Basket is already empty." 0 0
			else
				dlg --backtitle "$(ui_backtitle)" --title "Clear Basket" \
					--yes-label "Clear" --no-label "Cancel" \
					--yesno "Remove all ${#OP_BASKET[@]} operators from basket?" 0 0
				if [[ $? -eq 0 ]]; then
					OP_BASKET=()
					OP_SET_ADDED=()
					_OP_BASKET_DIRTY=true
					_persist_operator_basket
					tui_log "Basket cleared"
					dlg --backtitle "$(ui_backtitle)" --msgbox "Basket cleared." 5 30
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
	local prev_set
	for prev_set in "${!OP_SET_ADDED[@]}"; do
		if [[ -z "${_newly_selected[$prev_set]:-}" ]]; then
			local sf="$ABA_ROOT/templates/operator-set-$prev_set"
			if [[ -f "$sf" ]]; then
				local line
				while IFS= read -r line; do
					[[ "$line" =~ ^[[:space:]]*# ]] && continue
					[[ -z "$line" ]] && continue
					line="${line##[[:space:]]}"
					line="${line%%[[:space:]]}"
					unset 'OP_BASKET[$line]'
				done < "$sf"
			fi
			unset 'OP_SET_ADDED[$prev_set]'
			tui_log "Removed operator set: $prev_set"
		fi
	done

	# Add newly selected sets
	local new_set
	for new_set in "${!_newly_selected[@]}"; do
		if [[ -z "${OP_SET_ADDED[$new_set]:-}" ]]; then
			local sf="$ABA_ROOT/templates/operator-set-$new_set"
			if [[ -f "$sf" ]]; then
				local line
				while IFS= read -r line; do
					[[ "$line" =~ ^[[:space:]]*# ]] && continue
					[[ -z "$line" ]] && continue
					line="${line##[[:space:]]}"
					line="${line%%[[:space:]]}"
					if grep -q "^$line[[:space:]]" "$ABA_ROOT"/.index/*-index-v${version_short} 2>/dev/null; then
						OP_BASKET["$line"]=1
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

	# Search across all catalog indexes (format: "op-name  Display Name  channel")
	local items=()
	local line op_name display_name state
	while IFS= read -r line; do
		line="${line##[[:space:]]}"
		line="${line%%[[:space:]]}"
		[[ -z "$line" ]] && continue
		op_name="${line%%[[:space:]]*}"
		[[ -z "$op_name" ]] && continue
		display_name=$(echo "$line" | awk '{$1=""; $NF=""; gsub(/^ +| +$/, ""); print}')
		state="off"
		[[ -n "${OP_BASKET[$op_name]:-}" ]] && state="on"
		items+=("$op_name" "${display_name:--}" "$state")
	done < <(grep -ih "$query" "$ABA_ROOT"/.index/*-index-v${version_short} 2>/dev/null | sort -u | head -50)

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
			OP_BASKET["$op"]=1
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

	local version_short="${ocp_version%.*}"
	local items=()
	local op display_name line
	for op in $(echo "${!OP_BASKET[@]}" | tr ' ' '\n' | sort); do
		display_name=""
		line=$(grep -m1 "^${op}[[:space:]]" "$ABA_ROOT"/.index/*-index-v${version_short} 2>/dev/null)
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
	run_once -p -i "mirror:reg:download" 2>/dev/null || need_download=true

	if [[ "$need_download" == "false" ]]; then
		tui_log "Offline prerequisites already ready (peek passed)."
		return 0
	fi

	dlg --backtitle "$(ui_backtitle)" --title "Preparing" \
		--infobox "Downloading offline files (CLI tools + registry installers)...\n\nPlease wait." 7 65

	# cli-download-all.sh uses per-tool run_once IDs (cli:download:<tool>[:<ver>])
	if ! bash -lc "cd '$ABA_ROOT' && scripts/cli-download-all.sh --wait" >>"$_TUI_LOG_FILE" 2>&1; then
		dlg --backtitle "$(ui_backtitle)" --title " Download Failed " \
			--msgbox "Failed to download CLI tools.\n\nCheck internet connectivity and try again." 0 0
		return 1
	fi

	if ! run_once -q -w -i "mirror:reg:download" -- \
		make -sC "$ABA_ROOT/mirror" download-registries >>"$_TUI_LOG_FILE" 2>&1; then
		dlg --backtitle "$(ui_backtitle)" --title " Download Failed " \
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
	tui_log "Action: Create Bundle"

	_ensure_offline_prereqs || return 1

	local default_bundle="/tmp/ocp-bundle"

	dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CONNO_BUNDLE" \
		--cancel-label "$TUI2_BTN_BACK" \
		--ok-label "$TUI2_BTN_NEXT" \
		--inputbox "$TUI2_MSG_BUNDLE_PATH_PROMPT" 0 0 "$default_bundle" \
		2>"$_TUI_TMP"
	local rc=$?
	[[ $rc -ne 0 ]] && return 1

	local bundle_path
	bundle_path=$(<"$_TUI_TMP")
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
		dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CONNO_BUNDLE" \
			--yes-label "$TUI2_BTN_LIGHT_BUNDLE" \
			--no-label "$TUI2_BTN_FULL_BUNDLE" \
			--yesno "$TUI2_MSG_BUNDLE_LIGHT_CONFIRM" 0 0
		[[ $? -eq 0 ]] && light_flag="--light"
	fi

	# If images already exist, offer reuse vs clean rebuild
	local force_flag=""
	if ls "$ABA_ROOT"/mirror/data/mirror_*.tar >/dev/null 2>&1; then
		local _bundle_data_choice=""
		while :; do
			dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CONNO_BUNDLE" \
				--yes-label "Reuse (fast)" \
				--no-label "Clean Rebuild" \
				--help-button \
				--yesno "Existing image data found in mirror/data/.\n\n\
Reuse: only download changed/new images (incremental, fast).\n\
Clean Rebuild: delete existing data and re-download everything.\n\n\
Reuse is recommended unless you changed OpenShift version or suspect corruption." 0 0
			local choice_rc=$?
			case $choice_rc in
				0) tui_log "Bundle: reusing existing image data (incremental)"
				   _bundle_data_choice="reuse"
				   break ;;
				1) force_flag="--force"
				   tui_log "Bundle: clean rebuild (--force)"
				   _bundle_data_choice="rebuild"
				   break ;;
				2) show_help "Bundle Image Reuse" \
"oc-mirror is incremental by design. When image data already exists,
it only downloads what has changed since the last save/sync.

Choose 'Reuse (fast)' to keep existing data and download only deltas.
Choose 'Clean Rebuild' to delete everything and start fresh.

When to use Clean Rebuild:
• You changed the OpenShift version or channel significantly
• Previous download was interrupted or data appears corrupt
• You want a guaranteed clean state

In most cases, 'Reuse' is the right choice — it is faster and
uses less bandwidth."
				   continue ;;
				255)
				   return 1 ;;
			esac
		done
		[[ -z "$_bundle_data_choice" ]] && return 1
	fi

	local cmd="aba bundle --out $bundle_path"
	[[ -n "$light_flag" ]] && cmd="$cmd $light_flag"
	[[ -n "$force_flag" ]] && cmd="$cmd $force_flag"

	confirm_and_execute "$cmd" "Create Bundle"
}
