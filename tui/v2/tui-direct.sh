#!/usr/bin/env bash
# =============================================================================
# TUI v2 — DIRECT Mode (connected, no mirror)
# =============================================================================
# Minimal wizard (pull secret, channel, version, platform) then action menu.
# Adapted from v1 wizard flow.
#
# Design decisions:
#   - Version pre-fetch: run_once tasks are started with "&" in _direct_channel()
#     so they run in the background while the user reads the channel dialog.
#     Results are retrieved via "run_once -o" (cached output) in _direct_version(),
#     NOT by calling fetch_*_version() directly (which would re-hit the network).
#     This makes the channel→version transition near-instant (~4s vs 2min).
#   - Wizard step navigation uses DIALOG_RC variable (set by each step function)
#     to signal: "next" (advance), "back" (go to previous step), "repeat" (re-show
#     current step, e.g. after Help). This avoids complex return code chains.
#   - _direct_config_complete() checks if wizard can be skipped (all values
#     already in aba.conf). Wizard only runs when config is incomplete.
#   - Single-letter tags as keyboard shortcuts (v1 pattern): C, I, D, N.
#
# Usage: source tui/v2/tui-direct.sh

# --- BASH_SOURCE guard ---
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	echo "This file should be sourced, not executed directly."
	exit 1
fi

# =============================================================================
# DIRECT Mode Entry Point
# =============================================================================

direct_main() {
	tui_log "Entering DIRECT mode"

	# Run wizard if config not complete
	if ! _direct_config_complete; then
		direct_wizard || return 1
	fi

	_direct_action_menu
}

# Check if minimum config exists for DIRECT mode
_direct_config_complete() {
	[[ -n "${ocp_channel:-}" ]] || return 1
	[[ -n "${ocp_version:-}" ]] || return 1
	local ps_file="${pull_secret_file:-}"
	ps_file="${ps_file/#\~/$HOME}"
	[[ -n "$ps_file" && -f "$ps_file" ]] || return 1
	return 0
}

# =============================================================================
# DIRECT Mode Wizard (pull secret, channel, version, platform)
# =============================================================================

direct_wizard() {
	tui_log "Running DIRECT wizard"
	local step="pull_secret"

	while :; do
		case "$step" in
		pull_secret)
			if _direct_pull_secret; then
				# Start redhat-operator catalog ASAP (uses core task IDs)
				"$ABA_ROOT/scripts/create-containers-auth.sh" >>"$_TUI_LOG_FILE" 2>&1 || true
				local _ps_ver=""
				if [[ -f "$ABA_ROOT/aba.conf" ]]; then
					_ps_ver=$(source <(normalize-aba-conf 2>/dev/null) && echo "${ocp_version:-}")
				fi
				if [[ ! "$_ps_ver" == *.*.* ]]; then
					# Wait for version fetch started at TUI boot (should be done by now)
					run_once -q -w -i "ocp:stable:latest_version" 2>/dev/null || true
					_ps_ver=$(run_once -o -i "ocp:stable:latest_version" 2>/dev/null)
				fi
				if [[ "$_ps_ver" == *.*.* ]]; then
					local _cat_ver="${_ps_ver%.*}"
					tui_log "Starting redhat-operator catalog for $_cat_ver"
					run_once -i "catalog:${_cat_ver}:redhat-operator" -- \
						"$ABA_ROOT/scripts/download-catalog-index.sh" redhat-operator "$_cat_ver"
				fi
				step="channel"
			else
				return 1  # User cancelled
			fi
			;;
		channel)
			_direct_channel
			case "$DIALOG_RC" in
					next) step="version" ;;
					back) step="pull_secret" ;;
					repeat) ;;  # Stay on channel
					*) return 1 ;;
				esac
				;;
			version)
				_direct_version
				case "$DIALOG_RC" in
					next)
						local _ver_short="${ocp_version%.*}"
						tui_log "Starting CLI + catalog downloads for OpenShift $_ver_short"
						"$ABA_ROOT/scripts/cli-download-all.sh" >>"$_TUI_LOG_FILE" 2>&1
						download_all_catalogs "$_ver_short" >>"$_TUI_LOG_FILE" 2>&1
						step="platform"
						;;
					back) step="channel" ;;
					repeat) ;;
					*) return 1 ;;
				esac
				;;
			platform)
				_direct_platform
				case "$DIALOG_RC" in
					next) step="operators" ;;
					back) step="version" ;;
					repeat) ;;
					*) return 1 ;;
				esac
				;;
			operators)
				_direct_operators
				case "$DIALOG_RC" in
					next) break ;;  # Wizard done
					back) step="platform" ;;
					repeat) ;;
					*) return 1 ;;
				esac
				;;
		esac
	done

	# Write config to aba.conf
	_direct_save_config
	return 0
}

# --- Pull Secret ---
_direct_pull_secret() {
	tui_log "DIRECT wizard: pull secret"

	local ps_file="${pull_secret_file:-$HOME/.pull-secret.json}"
	ps_file="${ps_file/#\~/$HOME}"

	if [[ -f "$ps_file" ]]; then
		# Already exists — confirm or re-enter
		dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_PULL_SECRET" \
			--cancel-label "$TUI2_BTN_BACK" \
			--ok-label "$TUI2_BTN_SELECT" \
			--menu "$(printf "$TUI2_MSG_PULL_SECRET_FOUND" "$ps_file")" 0 0 0 \
			"U"  "Use existing pull secret" \
			"N"  "Enter a new pull secret" \
			2>"$_TUI_TMP"
		local rc=$?
		[[ $rc -ne 0 ]] && return 1  # Back
		local choice
		choice=$(<"$_TUI_TMP")
		[[ "$choice" == "U" ]] && return 0
	fi

	# Prompt for pull secret
	dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_PULL_SECRET" \
		--ok-label "$TUI2_BTN_NEXT" \
		--cancel-label "$TUI2_BTN_BACK" \
		--msgbox "$TUI2_MSG_PULL_SECRET_INFO" 0 0

	# Loop until valid JSON entered or user presses Back
	while :; do
		dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_PULL_SECRET_PASTE" \
			--ok-label "$TUI2_BTN_SAVE" \
			--cancel-label "$TUI2_BTN_BACK" \
			--inputbox "$TUI2_MSG_PULL_SECRET_PASTE" 0 0 "" \
			2>"$_TUI_TMP"
		local rc=$?
		[[ $rc -ne 0 ]] && return 1

		local secret
		secret=$(<"$_TUI_TMP")

		if [[ -z "$secret" ]]; then
			dlg --backtitle "$(ui_backtitle)" --msgbox "$TUI2_MSG_PULL_SECRET_EMPTY" 0 0
			continue
		fi

		if ! echo "$secret" | jq . >/dev/null 2>&1; then
			dlg --backtitle "$(ui_backtitle)" --msgbox "$TUI2_MSG_PULL_SECRET_INVALID" 0 0
			continue
		fi

		# Valid JSON — save and exit loop
		echo "$secret" > "$HOME/.pull-secret.json"
		chmod 600 "$HOME/.pull-secret.json"
		tui_log "Pull secret saved to ~/.pull-secret.json"
		return 0
	done
}

# --- Channel Selection ---
_direct_channel() {
	DIALOG_RC=""
	tui_log "DIRECT wizard: channel"

	local s_state="on" f_state="off" c_state="off"
	case "${ocp_channel:-stable}" in
		candidate) c_state="on"; s_state="off" ;;
		fast) f_state="on"; s_state="off" ;;
	esac

	dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CHANNEL" \
		--no-cancel \
		--extra-button --extra-label "$TUI2_BTN_BACK" \
		--help-button \
		--ok-label "$TUI2_BTN_NEXT" \
		--radiolist "$TUI2_MSG_CHANNEL_PROMPT" 0 0 3 \
		"stable"    "Recommended for production" $s_state \
		"fast"      "Latest GA release"          $f_state \
		"candidate" "Preview/beta"               $c_state \
		2>"$_TUI_TMP"
	local rc=$?

	case "$rc" in
		0)
			ocp_channel=$(<"$_TUI_TMP")
			[[ -z "$ocp_channel" ]] && ocp_channel="stable"
			tui_log "Selected channel: $ocp_channel"
			DIALOG_RC="next"

			# Pre-fetch versions in background. The "&" is CRITICAL: without it,
			# run_once blocks until the HTTP fetch completes (~2 min), freezing the UI.
			# With "&", fetches happen while user reads the next dialog.
			# Results are later retrieved via "run_once -o -i ID" (cached output).
			run_once -i "ocp:${ocp_channel}:latest_version" -- \
				bash -lc "source ./scripts/include_all.sh; fetch_latest_version $ocp_channel" &
			run_once -i "ocp:${ocp_channel}:latest_version_previous" -- \
				bash -lc "source ./scripts/include_all.sh; fetch_previous_version $ocp_channel" &
			run_once -i "ocp:${ocp_channel}:latest_version_older" -- \
				bash -lc "source ./scripts/include_all.sh; fetch_older_version $ocp_channel" &
			;;
		2)
			show_help "$TUI2_HELP_TITLE_CHANNEL" \
"• stable — recommended for production, well-tested
• fast — latest GA release, early access to new features
• candidate — preview/beta for testing only"
			DIALOG_RC="repeat"
			;;
		3)
			DIALOG_RC="back"
			;;
		255)
			if confirm_quit; then clear; _show_v2_exit_summary; exit 0; fi
			DIALOG_RC="repeat"
			;;
	esac
}

# --- Version Selection (same look as v1) ---
_direct_version() {
	DIALOG_RC=""
	tui_log "DIRECT wizard: version"

	[[ -z "${ocp_channel:-}" ]] && ocp_channel="stable"

	# Wait for version data if needed
	local need_wait=0
	run_once -p -i "ocp:${ocp_channel}:latest_version" || need_wait=1
	run_once -p -i "ocp:${ocp_channel}:latest_version_previous" || need_wait=1

	if [[ $need_wait -eq 1 ]]; then
		dlg --backtitle "$(ui_backtitle)" --infobox \
			"$(printf "$TUI2_MSG_VERSION_FETCHING" "$ocp_channel")" 0 0
		# Wait for background tasks started from channel step (or start them if not yet running)
		run_once -q -w -S -i "ocp:${ocp_channel}:latest_version" 2>/dev/null || \
			run_once -i "ocp:${ocp_channel}:latest_version" -- \
				bash -lc "source ./scripts/include_all.sh; fetch_latest_version $ocp_channel"
		run_once -q -w -S -i "ocp:${ocp_channel}:latest_version_previous" 2>/dev/null || \
			run_once -i "ocp:${ocp_channel}:latest_version_previous" -- \
				bash -lc "source ./scripts/include_all.sh; fetch_previous_version $ocp_channel"
		run_once -q -w -S -i "ocp:${ocp_channel}:latest_version_older" 2>/dev/null || \
			run_once -i "ocp:${ocp_channel}:latest_version_older" -- \
				bash -lc "source ./scripts/include_all.sh; fetch_older_version $ocp_channel"
	fi

	local latest previous older
	latest=$(run_once -o -i "ocp:${ocp_channel}:latest_version" 2>/dev/null)
	previous=$(run_once -o -i "ocp:${ocp_channel}:latest_version_previous" 2>/dev/null)
	older=$(run_once -o -i "ocp:${ocp_channel}:latest_version_older" 2>/dev/null)

	if [[ -z "$latest" ]]; then
		# Fallback: use existing version from aba.conf or allow manual entry
		if [[ -n "${ocp_version:-}" ]]; then
			dlg --backtitle "$(ui_backtitle)" --msgbox \
				"$(printf "$TUI2_MSG_VERSION_FETCH_FAIL" "$ocp_version")" 0 0
			tui_log "Version fetch failed, using existing: $ocp_version"
			DIALOG_RC="next"
			return
		fi
		while :; do
			dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_VERSION" \
				--inputbox "$TUI2_MSG_VERSION_MANUAL_PROMPT" 0 0 "" \
				2>"$_TUI_TMP"
			local man_rc=$?
			if [[ $man_rc -ne 0 ]]; then
				DIALOG_RC="back"
				return
			fi
			ocp_version=$(<"$_TUI_TMP")
			if [[ "$ocp_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
				tui_log "Manual version entry: $ocp_version"
				DIALOG_RC="next"
				return
			fi
			dlg --backtitle "$(ui_backtitle)" --msgbox \
				"Invalid version format.\n\nExpected: x.y.z (e.g. 4.16.3)" 0 0
		done
		return
	fi

	# Build menu items
	local items=()
	items+=("1" "Latest:   $latest")
	[[ -n "$previous" ]] && items+=("2" "Previous: $previous")
	[[ -n "$older" ]] && items+=("3" "Older:    $older")
	items+=("4" "Manual entry...")

	dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_VERSION" \
		--no-cancel \
		--extra-button --extra-label "$TUI2_BTN_BACK" \
		--help-button \
		--ok-label "$TUI2_BTN_NEXT" \
		--menu "$(printf "$TUI2_MSG_VERSION_MENU" "$ocp_channel")" 0 0 0 \
		"${items[@]}" \
		2>"$_TUI_TMP"
	local rc=$?

	case "$rc" in
		0)
			local choice
			choice=$(<"$_TUI_TMP")
			case "$choice" in
				1) ocp_version="$latest" ;;
				2) ocp_version="$previous" ;;
				3) ocp_version="$older" ;;
			4)
				while :; do
					dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_VERSION_MANUAL" \
						--inputbox "$TUI2_MSG_VERSION_ENTRY" 0 0 "${ocp_version:-$latest}" \
						2>"$_TUI_TMP"
					if [[ $? -ne 0 ]]; then
						DIALOG_RC="repeat"
						return
					fi
					ocp_version=$(<"$_TUI_TMP")
					if [[ "$ocp_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
						break
					fi
					dlg --backtitle "$(ui_backtitle)" --msgbox \
						"Invalid version format.\n\nExpected: x.y.z (e.g. 4.16.3)" 0 0
				done
				;;
			esac
			tui_log "Selected version: $ocp_version"
			DIALOG_RC="next"
			;;
		2)
			show_help "$TUI2_HELP_TITLE_VERSION" \
"Choose the OpenShift version to install.

• Latest: most recent release in the channel
• Previous: one release back (good for stability)
• Older: two releases back
• Manual: enter any valid x.y.z version"
			DIALOG_RC="repeat"
			;;
		3)
			DIALOG_RC="back"
			;;
		255)
			if confirm_quit; then clear; _show_v2_exit_summary; exit 0; fi
			DIALOG_RC="repeat"
			;;
	esac
}

# --- Platform Selection ---
_direct_platform() {
	DIALOG_RC=""
	tui_log "DIRECT wizard: platform"

	local bm_state="on" vmw_state="off" kvm_state="off"
	case "${platform:-bm}" in
		vmw) vmw_state="on"; bm_state="off" ;;
		kvm) kvm_state="on"; bm_state="off" ;;
	esac

	dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_PLATFORM" \
		--no-cancel \
		--extra-button --extra-label "$TUI2_BTN_BACK" \
		--help-button \
		--ok-label "$TUI2_BTN_NEXT" \
		--radiolist "$TUI2_MSG_PLATFORM_PROMPT" 0 0 3 \
		"bm"  "Bare metal (default)"  $bm_state \
		"vmw" "VMware vSphere"        $vmw_state \
		"kvm" "KVM/libvirt"           $kvm_state \
		2>"$_TUI_TMP"
	local rc=$?

	case "$rc" in
		0)
			platform=$(<"$_TUI_TMP")
			[[ -z "$platform" ]] && platform="bm"
			tui_log "Selected platform: $platform"
			DIALOG_RC="next"
			;;
		2)
			show_help "$TUI2_HELP_TITLE_PLATFORM" \
"• Bare metal: physical servers or pre-existing VMs (you manage MAC addresses)
• VMware vSphere: ABA creates VMs on vCenter (requires ~/.vmware.conf)
• KVM/libvirt: ABA creates VMs on KVM host (requires ~/.kvm.conf)"
			DIALOG_RC="repeat"
			;;
		3)
			DIALOG_RC="back"
			;;
		255)
			if confirm_quit; then clear; _show_v2_exit_summary; exit 0; fi
			DIALOG_RC="repeat"
			;;
	esac
}

# --- Operator Selection (optional wizard step) ---
_direct_operators() {
	DIALOG_RC=""
	tui_log "DIRECT wizard: operator selection"

	# Save config first so mirror_select_operators can read ocp_version
	_direct_save_config

	dlg --backtitle "$(ui_backtitle)" --title " Select Operators " \
		--ok-label "$TUI2_BTN_SELECT" \
		--cancel-label "$TUI2_BTN_BACK" \
		--extra-button --extra-label "Skip" \
		--menu "Select operators to include in the mirror, or skip for now.\n\nYou can always do this later from the action menu." 0 0 0 \
		"1" "Select Operator Sets (day2, storage, networking...)" \
		"2" "Search Operator Names" \
		2>"$_TUI_TMP"
	local rc=$?

	case "$rc" in
		0)
			local choice
			choice=$(<"$_TUI_TMP")
			case "$choice" in
				1) mirror_select_operators ;;
				2) mirror_select_operators ;;
			esac
			DIALOG_RC="next"
			;;
		3)
			# Skip
			DIALOG_RC="next"
			;;
		1)
			DIALOG_RC="back"
			;;
		255)
			DIALOG_RC="back"
			;;
	esac
}

# --- Save Config to aba.conf ---
_direct_save_config() {
	tui_log "Saving DIRECT config to aba.conf"

	# Ensure aba.conf exists
	if [[ ! -f "$ABA_ROOT/aba.conf" ]]; then
		if [[ -f "$ABA_ROOT/templates/aba.conf.j2" ]]; then
			local domain
			domain=$(get_domain 2>/dev/null)
			export domain
			machine_network="" dns_servers="" next_hop_address="" ntp_servers="" \
				"$ABA_ROOT/scripts/j2" "$ABA_ROOT/templates/aba.conf.j2" > "$ABA_ROOT/aba.conf" 2>>"$_TUI_LOG_FILE"
		fi
	fi

	replace-value-conf -q -n ocp_channel -v "${ocp_channel}" -f "$ABA_ROOT/aba.conf"
	replace-value-conf -q -n ocp_version -v "${ocp_version}" -f "$ABA_ROOT/aba.conf"
	replace-value-conf -q -n platform -v "${platform:-bm}" -f "$ABA_ROOT/aba.conf"

	tui_log "Config saved: channel=$ocp_channel version=$ocp_version platform=${platform:-bm}"

	# Kick off ISC regeneration in background (channel/version are ISC inputs)
	run_once -r -i "aba:isconf:generate" 2>/dev/null || true
	run_once -i "aba:isconf:generate" -- \
		bash -lc "cd '$ABA_ROOT' && aba isconf -d mirror" >>"$_TUI_LOG_FILE" 2>&1 &
}

# =============================================================================
# DIRECT Mode Action Menu
# =============================================================================

_direct_action_menu() {
	tui_log "DIRECT action menu"
	local default_item="$TUI2_DIRECT_TAG_INSTALL"

	while :; do
		local items=()
		local inst_label="Install Cluster"
		local day2_label="Day-2 Operations"
		local mon_label="Monitor Cluster"
		local del_label="Delete Cluster"

		local day2_avail=true mon_avail=true del_avail=true

		local has_installed=false
		local has_any_cluster=false
		local dir
		for dir in $(list_cluster_dirs); do
			has_any_cluster=true
			cluster_installed "$dir" && has_installed=true
		done
		if [[ "$has_any_cluster" == "false" ]]; then
			del_avail=false
			del_label="Delete Cluster [no clusters]"
		fi
		if [[ "$has_installed" == "false" ]]; then
			day2_avail=false
			day2_label="Day-2 Operations $TUI2_GREY_INSTALL_FIRST"
			mon_avail=false
			mon_label="Monitor Cluster $TUI2_GREY_INSTALL_FIRST"
		fi

		items+=(
			"$TUI2_DIRECT_TAG_INSTALL"        "$inst_label"
			"$TUI2_DIRECT_TAG_DAY2"           "$day2_label"
			"$TUI2_DIRECT_TAG_MONITOR"        "$mon_label"
			"" "──── Advanced ──────────────────────"
			"$TUI2_DIRECT_TAG_DELETE"         "$del_label"
			"$TUI2_DIRECT_TAG_ADVANCED"       "Advanced Options"
			" "                               "──── Other ─────────────────────────"
			"$TUI2_DIRECT_TAG_SWITCH_MIRROR"  "Switch to MIRROR mode"
		)

		dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_DIRECT_MENU" \
			--cancel-label "$TUI2_BTN_EXIT" \
			--ok-label "$TUI2_BTN_SELECT" \
			--help-button \
			--default-item "$default_item" \
			--menu "$TUI2_MSG_DIRECT_MENU" 0 0 0 \
			"${items[@]}" \
			2>"$_TUI_TMP"
		local rc=$?

		case "$rc" in
			2)
				show_help "$TUI2_HELP_TITLE_DIRECT" \
"Install OpenShift directly from the internet without a mirror registry.

Workflow:
  1. Install Cluster — configure, review, and provision OpenShift
  2. Day-2 — post-install configuration (NTP, OSUS, etc.)
  3. Monitor — watch cluster installation status"
				continue
				;;
		1)
			# Exit button: if entered from CONNO, just return to CONNO menu
			if [[ "$_TUI_DIRECT_FROM_CONNO" == "true" ]]; then
				return 0
			fi
			if confirm_quit; then
				clear
				_show_v2_exit_summary
				exit 0
			fi
			continue
			;;
		255)
			# ESC always triggers confirm_quit (A.19)
			if confirm_quit; then clear; _show_v2_exit_summary; exit 0; fi
			continue
			;;
			0) ;;
		esac

		local choice
		choice=$(<"$_TUI_TMP")
		[[ -n "$choice" ]] && default_item="$choice"

		case "$choice" in
			" ")
				continue ;;
			"$TUI2_DIRECT_TAG_INSTALL")
				cluster_install_flow
				;;
			"$TUI2_DIRECT_TAG_DAY2")
				if [[ "$day2_avail" == "false" ]]; then
					dlg --backtitle "$(ui_backtitle)" --msgbox "$TUI2_MSG_CLUSTER_FIRST" 0 0
				else
					cluster_day2_menu
				fi
				;;
			"$TUI2_DIRECT_TAG_MONITOR")
				if [[ "$mon_avail" == "false" ]]; then
					dlg --backtitle "$(ui_backtitle)" --msgbox "$TUI2_MSG_CLUSTER_FIRST" 0 0
				else
					cluster_monitor
				fi
				;;
			"$TUI2_DIRECT_TAG_DELETE")
				if [[ "$del_avail" == "false" ]]; then
					dlg --backtitle "$(ui_backtitle)" --msgbox "No clusters to delete." 0 0
				else
					cluster_delete
				fi
				;;
			"$TUI2_DIRECT_TAG_ADVANCED")
				tui_advanced_menu
				;;
			"$TUI2_DIRECT_TAG_SWITCH_MIRROR")
				_TUI_MODE="CONNO"
				tui_log "Switching from DIRECT to CONNO mode"
				return 0
				;;
		esac
	done
}
