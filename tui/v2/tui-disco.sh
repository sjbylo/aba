#!/usr/bin/env bash
# =============================================================================
# TUI v2 — DISCO Mode (disconnected, bundle received)
# =============================================================================
# Action menu for disconnected hosts: install registry, load images,
# configure/install cluster, Day-2, view ISC, reset to connected.
#
# Usage: source tui/v2/tui-disco.sh

# --- BASH_SOURCE guard ---
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	echo "This file should be sourced, not executed directly."
	exit 1
fi

# =============================================================================
# DISCO Main Action Menu
# =============================================================================

disco_main() {
	tui_log "Entering DISCO mode action menu"
	local default_item="$TUI2_DISCO_TAG_VIEW_ISC"

	while :; do
		# Build menu items with dynamic status labels (matching CONNO style)
		local items=()
		local reg_label="Install Registry (local or remote)"
		local load_label="Load Images (disk2mirror)"
		local inst_label="Install Cluster"
		local day2_label="Day-2 / Cluster Management"
		local mon_label="Finalize Installation (wait-for)"
		local isc_label="View ImageSet Config"
		local reset_label="Reset to Connected Mode"

		# Determine availability
		local reg_avail=true
		local load_avail=true
		local day2_avail=true
		local mon_avail=true
		local reset_avail=true

		if mirror_available; then
			reg_label="Install Registry (installed)"
			reg_avail=false
			if _mirror_has_release_image; then
				load_label="Load Images (disk2mirror) (loaded)"
			else
				inst_label="Install Cluster [load mirror first]"
			fi
		else
			load_label="Load Images (disk2mirror) [install registry first]"
			inst_label="Install Cluster [install registry first]"
			load_avail=false
		fi

		# Check if any cluster exists / is installed
		local has_installed=false
		local has_any_cluster=false
		for dir in $(list_cluster_dirs); do
			has_any_cluster=true
			cluster_installed "$dir" && has_installed=true
		done
		if [[ "$has_any_cluster" == "false" ]]; then
			day2_avail=false
			day2_label="Day-2 / Cluster Management $TUI2_GREY_INSTALL_FIRST"
		fi
		if [[ "$has_installed" == "false" ]]; then
			mon_avail=false
			mon_label="Finalize Installation (wait-for) $TUI2_GREY_INSTALL_FIRST"
		fi

		# Internet status set once at startup (_TUI_INET). No per-loop re-check.
		if [[ "$_TUI_INET" == "no" ]]; then
			reset_avail=false
			reset_label="Reset to Connected Mode $TUI2_GREY_NO_INTERNET"
		fi

		# Wait for any in-flight mirror verify before reading state
		aba_mirror_verify_wait

		# Dynamic menu title with mirror state (matching CONNO)
		local _mstate
		_mstate="$(mirror_state_label)"
		local disco_menu_msg="Fully Disconnected — Choose an action (${_mstate}):"

		items+=(
			"" "──── Registry ──────────────────────"
			"$TUI2_DISCO_TAG_INSTALL_REG" "$reg_label"
			"$TUI2_DISCO_TAG_LOAD"        "$load_label"
			"" "──── Cluster ───────────────────────"
			"$TUI2_DISCO_TAG_INSTALL"     "$inst_label"
			"$TUI2_DISCO_TAG_MONITOR"     "$mon_label"
			"$TUI2_DISCO_TAG_DAY2"        "$day2_label"
			"" "──── Advanced ──────────────────────"
			"$TUI2_DISCO_TAG_ADVANCED"    "Advanced Options"
			"$TUI2_DISCO_TAG_VIEW_ISC"    "$isc_label"
			"$TUI2_DISCO_TAG_RESET"       "$reset_label"
		)

		dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_DISCO_MENU" \
			--cancel-label "$TUI2_BTN_EXIT" \
			--ok-label "$TUI2_BTN_SELECT" \
			--help-button \
			--default-item "$default_item" \
			--menu "$disco_menu_msg" 0 0 0 \
			"${items[@]}" \
			2>"$_TUI_TMP"
		local rc=$?

		case "$rc" in
			2)
				show_help "$TUI2_HELP_TITLE_DISCO" \
"You are in fully disconnected mode (no internet access).

Typical workflow:
  1. Install Registry — set up a local container registry
  2. Load Images — load container images into the registry
  3. Install Cluster — configure and provision OpenShift
  4. Finalize Installation — wait for install to complete
  5. Day-2 — apply cluster resources, NTP, update service, etc.

'Reset to Connected Mode' switches back if internet is restored.

Navigation:
  • Arrow keys / Tab — move between items and buttons
  • Enter — select highlighted item
  • ESC — go back (sub-menu → parent menu, main menu → exit)"
				continue
				;;
			1|255)
				if confirm_quit; then
					clear
					_show_v2_exit_summary
					exit 0
				fi
				continue
				;;
			0) ;;
		esac

		local choice
		choice=$(<"$_TUI_TMP")
		[[ -n "$choice" ]] && default_item="$choice"

		case "$choice" in
			"$TUI2_DISCO_TAG_INSTALL_REG")
				if [[ "$reg_avail" == "false" ]]; then
					dlg --backtitle "$(ui_backtitle)" --yesno \
						"$TUI2_MSG_MIRROR_REINSTALL" 0 0
					if [[ $? -eq 0 ]]; then
						confirm_and_execute "aba -d mirror uninstall" "Uninstall Existing Registry" && disco_install_reg
					fi
				else
					disco_install_reg
				fi
				;;
			"$TUI2_DISCO_TAG_LOAD")
				if [[ "$load_avail" == "false" ]]; then
					dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_MIRROR_REQUIRED" \
						--yesno "Mirror registry is not installed.\n\nA mirror will be installed first, then images will be loaded.\n\nContinue?" 0 0
					if [[ $? -eq 0 ]]; then
						_mirror_config_review && disco_load_images
					fi
				else
					disco_load_images
				fi
				;;
		"$TUI2_DISCO_TAG_INSTALL")
			if ! mirror_available; then
				dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_MIRROR_REQUIRED" \
					--yes-label "Install & Load" --no-label "$TUI2_BTN_BACK" \
					--yesno "No mirror registry installed.\n\nA mirror with loaded images is required to install a cluster.\n\nInstall the registry and load images now?" 0 0
				if [[ $? -eq 0 ]]; then
					_mirror_config_review && disco_load_images && cluster_install_flow
				fi
			elif ! _mirror_has_release_image; then
				dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_MIRROR_NOT_LOADED" \
					--yes-label "Load Now" --no-label "$TUI2_BTN_BACK" \
					--yesno "The mirror is installed but has no release images.\n\nLoad images into the mirror now?" 0 0
				if [[ $? -eq 0 ]]; then
					disco_load_images && cluster_install_flow
				fi
			else
				cluster_install_flow
			fi
			;;
			"$TUI2_DISCO_TAG_DAY2")
				if [[ "$day2_avail" == "false" ]]; then
					dlg --backtitle "$(ui_backtitle)" --msgbox \
						"$TUI2_MSG_NO_CLUSTERS" 0 0
				else
					cluster_day2_menu
				fi
				;;
			"$TUI2_DISCO_TAG_MONITOR")
				if [[ "$mon_avail" == "false" ]]; then
					dlg --backtitle "$(ui_backtitle)" --msgbox \
						"$TUI2_MSG_CLUSTER_FIRST" 0 0
				else
					cluster_monitor
				fi
				;;
			"$TUI2_DISCO_TAG_ADVANCED")
				tui_advanced_menu
				;;
			"$TUI2_DISCO_TAG_VIEW_ISC")
				mirror_view_isc "true"
				;;
		"$TUI2_DISCO_TAG_RESET")
			if [[ "$reset_avail" == "false" ]]; then
				dlg --backtitle "$(ui_backtitle)" --msgbox \
					"$TUI2_MSG_DISCO_NO_INTERNET" 0 0
			else
				disco_reset
				local rc=$?
				[[ $rc -eq 2 ]] && return 2
			fi
			;;
	esac
done
}

# =============================================================================
# Install Registry (local or remote)
# =============================================================================

disco_install_reg() {
	tui_log "DISCO: Install Registry"
	mirror_install
}

# =============================================================================
# Load Images
# =============================================================================

disco_load_images() {
	tui_log "DISCO: Load Images"

	# Check for light bundle (no tar files)
	if ! mirror_has_archives; then
		while :; do
			dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_DISCO_LIGHT" \
				--yes-label "$TUI2_BTN_CHECK_AGAIN" \
				--no-label "$TUI2_BTN_BACK" \
				--yesno "$(printf "$TUI2_MSG_DISCO_LIGHT" "$ABA_ROOT")" 0 0
			local rc=$?
			case "$rc" in
				0) ;;  # Check again
				1|255) return 1 ;;
			esac

			# Re-check
			if mirror_has_archives; then
				break
			fi
		done
	fi

	confirm_and_execute "aba -d mirror load" "Load Images (disk2mirror)" _invalidate_mirror_cache
	local rc=$?
	return $rc
}

# =============================================================================
# Reset to Connected Mode
# =============================================================================

disco_reset() {
	tui_log "DISCO: Reset to connected mode"

	while :; do
		dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_DISCO_RESET" \
			--yes-label "$TUI2_BTN_SWITCH" \
			--no-label "$TUI2_BTN_CANCEL" \
			--yesno "$TUI2_MSG_DISCO_RESET_CONFIRM" 0 0
		local rc=$?
		case "$rc" in
			0) break ;;  # Confirmed
			1|255) return 0 ;;
		esac
	done

	# Remove bundle flag
	rm -f "$ABA_ROOT/.bundle"
	tui_log "Removed .bundle flag, switching to connected mode"

	# Clear forced mode so re-detection works
	_TUI_FORCE_MODE=""
	_TUI_MODE=""
	return 2  # Special return code: re-detect mode
}
