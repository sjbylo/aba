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
	local default_item="$TUI2_DISCO_TAG_INSTALL_REG"

	while :; do
		# Build menu items with greyed-out labels for unavailable items
		local items=()
		local reg_label="Install Registry (local or remote)"
		local load_label="Load Images"
		local inst_label="Install Cluster"
		local day2_label="Day-2 Operations"
		local mon_label="Monitor Cluster"
		local isc_label="View ImageSet Config"
		local reset_label="Reset to Connected Mode"

		# Determine availability
		local reg_avail=true
		local load_avail=true
		local day2_avail=true
		local mon_avail=true
		local reset_avail=true

		if mirror_available; then
			reg_label="Install Registry $TUI2_GREY_ALREADY_INSTALLED"
			reg_avail=false
		else
			load_avail=false
			load_label="Load Images $TUI2_GREY_REG_FIRST"
		fi

		# Check if any cluster is installed
		local has_installed=false
		for dir in $(list_installed_clusters); do
			has_installed=true
			break
		done
		if [[ "$has_installed" == "false" ]]; then
			day2_avail=false
			day2_label="Day-2 Operations $TUI2_GREY_INSTALL_FIRST"
			mon_avail=false
			mon_label="Monitor Cluster $TUI2_GREY_INSTALL_FIRST"
		fi

		# Internet status set once at startup (_TUI_INET). No per-loop re-check.
		if [[ "$_TUI_INET" == "no" ]]; then
			reset_avail=false
			reset_label="Reset to Connected Mode $TUI2_GREY_NO_INTERNET"
		fi

		items+=(
			"$TUI2_DISCO_TAG_INSTALL_REG" "$reg_label"
			"$TUI2_DISCO_TAG_LOAD"        "$load_label"
			"$TUI2_DISCO_TAG_INSTALL"     "$inst_label"
			"$TUI2_DISCO_TAG_DAY2"        "$day2_label"
			"$TUI2_DISCO_TAG_MONITOR"     "$mon_label"
			"$TUI2_DISCO_TAG_VIEW_ISC"    "$isc_label"
			"$TUI2_DISCO_TAG_RESET"       "$reset_label"
		)

		dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_DISCO_MENU" \
			--cancel-label "$TUI2_BTN_EXIT" \
			--ok-label "$TUI2_BTN_SELECT" \
			--help-button \
			--default-item "$default_item" \
			--menu "$TUI2_MSG_DISCO_MENU" 0 0 0 \
			"${items[@]}" \
			2>"$_TUI_TMP"
		local rc=$?

		case "$rc" in
			2)
				show_help "$TUI2_HELP_TITLE_DISCO" \
"You are in disconnected (DISCO) mode.

Typical workflow:
  1. Install Registry — set up a local container registry
  2. Load Images — load container images into the registry
  3. Install Cluster — configure and provision OpenShift
  4. Day-2 — apply NTP, OSUS, and other post-install config

'Reset to Connected Mode' switches back if internet is restored."
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
					[[ $? -eq 0 ]] && disco_install_reg
				else
					disco_install_reg
				fi
				;;
			"$TUI2_DISCO_TAG_LOAD")
				if [[ "$load_avail" == "false" ]]; then
					dlg --backtitle "$(ui_backtitle)" --msgbox \
						"$TUI2_MSG_DISCO_REG_FIRST" 0 0
				else
					disco_load_images
				fi
				;;
			"$TUI2_DISCO_TAG_INSTALL")
				cluster_install_flow
				;;
			"$TUI2_DISCO_TAG_DAY2")
				if [[ "$day2_avail" == "false" ]]; then
					dlg --backtitle "$(ui_backtitle)" --msgbox \
						"$TUI2_MSG_CLUSTER_FIRST" 0 0
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
				1) return 0 ;;  # Back
				255)
					if confirm_quit; then clear; _show_v2_exit_summary; exit 0; fi
					continue
					;;
			esac

			# Re-check
			if mirror_has_archives; then
				break
			fi
		done
	fi

	confirm_and_execute "aba -d mirror load" "Load Images into Registry"
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
			1) return 0 ;;  # Cancel
			255)
				if confirm_quit; then clear; _show_v2_exit_summary; exit 0; fi
				continue
				;;
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
