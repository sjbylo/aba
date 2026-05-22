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
# DISCO first-run gate — bundle marker / archives / guided install + load
# =============================================================================

_disco_bundle_wizard_gate() {
	# Offline DISCO allowed without .bundle once mirror/archives exist (_validate_payload path).
	if [[ ! -f "$ABA_ROOT/.bundle" ]]; then
		if mirror_available || mirror_has_archives; then
			tui_log "DISCO: no .bundle file; proceeding (mirror or archives already present)."
			return 0
		fi
		clear
		dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_DEAD_END" --msgbox \
			"No ABA install-bundle marker (.bundle) was found, and no mirror/archives are available yet.\n\n\
You need either:\n\
  • A transferred ABA bundle (touch \".bundle\" if your transfer omitted it)\n\
  • Or mirror ISA archives under:\n\
      $ABA_ROOT/mirror/data/mirror_*.tar\n\
  • Or an installed mirror registry from a prior setup\n\n\
Then restart abatui2." 0 0
		tui_log "DISCO wizard: missing .bundle and no offline source — returning"
		return 1
	fi

	local _bv="${ocp_version:-?}"
	local _bc="${ocp_channel:-?}"
	local _isa_hint="" _payload_line=""
	if mirror_has_archives; then
		_isa_hint="ISA archives: mirror_*.tar detected in mirror/data/ (disk payload present)."
	else
		_isa_hint="ISA archives: NONE in mirror/data/ — copy mirror_*.tar from removable media\n(related paths: legacy mirror/save/ was merged into mirror/data/)."
	fi

	local min_size=1000000
	local has_quay="" has_docker=""
	has_quay=$(find "$ABA_ROOT/mirror/" -maxdepth 1 -name "mirror-registry*.tar.gz" -size +${min_size}c 2>/dev/null | head -1)
	has_docker=$(find "$ABA_ROOT/mirror/" -maxdepth 1 -name "docker-reg-image.tgz" -size +${min_size}c 2>/dev/null | head -1)
	if [[ -n "$has_quay" && -n "$has_docker" ]]; then
		_payload_line="Registry installers: Quay tarball + Docker image present."
	elif [[ -n "$has_quay" ]]; then
		_payload_line="Registry installers: Quay mirror-registry tarball present."
	elif [[ -n "$has_docker" ]]; then
		_payload_line="Registry installers: Docker registry tarball present."
	else
		_payload_line="Registry installers: (none detected yet — rerun cli/registry prep if needed)."
	fi

	dlg --backtitle "$(ui_backtitle)" --title "ABA Install Bundle" --msgbox \
		"You are operating from an install bundle (.bundle).\n\n\
Disconnected payload summary:\n\
  • OpenShift version (aba.conf): ${_bv}\n\
  • Update channel (aba.conf): ${_bc}\n\
  • ${_isa_hint}\n\
  • ${_payload_line}\n\n\
Next: ensure ISA archives exist, then the TUI installs the mirror registry\nand loads images before cluster install." \
		0 0

	if ! mirror_has_archives; then
		dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_DEAD_END" --msgbox \
			"No mirror archive files found.\n\n\
Place mirror_*.tar files in:\n\
  $ABA_ROOT/mirror/data/\n\
(Older docs referred to mirror/save/ — that layout is folded into mirror/data/.)\n\n\
Restart the TUI after copying archives." \
			0 0
		tui_log "DISCO wizard: missing ISA archives — returning"
		return 1
	fi

	if [[ "${_TUI_DISCO_FROM_CONNO:-false}" == "true" ]]; then
		tui_log "DISCO wizard: skipping auto mirror install/load (entered from CONNO menu)."
		return 0
	fi

	if mirror_available && _mirror_has_release_image; then
		tui_log "DISCO wizard: mirror already populated — skipping auto install/load."
		return 0
	fi

	if ! mirror_available; then
		tui_log "DISCO wizard: auto-running mirror_install"
		mirror_install || return 1
	fi

	if mirror_available && ! _mirror_has_release_image; then
		tui_log "DISCO wizard: auto-running disco_load_images"
		disco_load_images || return 1
	fi

	return 0
}

# =============================================================================
# DISCO Main Action Menu
# =============================================================================

disco_main() {
	tui_log "Entering DISCO mode action menu"
	_disco_bundle_wizard_gate || return 1
	local default_item="$TUI2_DISCO_TAG_VIEW_ISC"

	# --- Menu state recheck optimization ---
	# IMPORTANT: _disco_need_recheck controls whether expensive state checks
	# (aba_mirror_verify_wait, mirror_available, tui_cluster_menu_flags) run
	# before redrawing the menu. Set to "true" on first entry and after any
	# action that can change mirror/cluster state. Actions that only display
	# info (View ISC, Help) set it to "false" — avoiding a blocking pause.
	local _disco_need_recheck=true

	while :; do
		# Build menu items with dynamic status labels (matching CONNO style)
		local items=()
		local reg_label="$TUI2_LABEL_INSTALL_REGISTRY"
		local load_label="$TUI2_LABEL_LOAD"
		local isc_label="$TUI2_LABEL_VIEW_ISC_RO"

		local reg_avail=true
		local load_avail=true

		# Only run expensive state checks when a previous action may have
		# changed mirror/cluster state. Skipping these eliminates the blocking
		# pause after harmless actions like View ISC.
		if [[ "$_disco_need_recheck" == "true" ]]; then
			aba_mirror_verify_wait

			if mirror_available; then
				reg_label="$TUI2_LABEL_INSTALL_REGISTRY $TUI2_STATUS_INSTALLED"
				reg_avail=false
				if _mirror_has_release_image; then
					load_label="$TUI2_LABEL_LOAD $TUI2_STATUS_LOADED"
				fi
			else
				load_label="$TUI2_LABEL_LOAD $TUI2_STATUS_INSTALL_REGISTRY"
				load_avail=false
			fi

			tui_cluster_menu_flags DISCO
		else
			# Reuse cached state — just recompute labels from marker files (fast)
			if [[ -f "$ABA_ROOT/mirror/.available" ]]; then
				reg_label="$TUI2_LABEL_INSTALL_REGISTRY $TUI2_STATUS_INSTALLED"
				reg_avail=false
				if _mirror_has_release_image; then
					load_label="$TUI2_LABEL_LOAD $TUI2_STATUS_LOADED"
				fi
			else
				load_label="$TUI2_LABEL_LOAD $TUI2_STATUS_INSTALL_REGISTRY"
				load_avail=false
			fi
		fi

		local day2_label="$TUI2_LABEL_DAY2"
		local inst_label="${_CLUSTER_INST_LABEL}"

		if [[ "${_CLUSTER_DAY2_AVAIL}" != "true" ]]; then
			day2_label="$TUI2_LABEL_DAY2 $TUI2_STATUS_INSTALL_CLUSTER"
		fi


		# Dynamic menu title with mirror state (matching CONNO)
		local _mstate
		_mstate="$(mirror_state_label)"
		local disco_menu_msg="Status: ${_mstate}"

		items+=(
			"" "──── Registry ──────────────────────"
			"$TUI2_DISCO_TAG_INSTALL_REG" "$reg_label"
			"$TUI2_DISCO_TAG_LOAD"        "$load_label"
			"" "──── Cluster ───────────────────────"
			"$TUI2_DISCO_TAG_INSTALL"     "$inst_label"
			"$TUI2_DISCO_TAG_DAY2"        "$day2_label"
			"" "──── Advanced ──────────────────────"
			"$TUI2_DISCO_TAG_ADVANCED"    "Advanced"
			"$TUI2_DISCO_TAG_VIEW_ISC"    "$isc_label"
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
  2. Load Images — disk-to-mirror (d2m): load saved images into registry
  3. Install Cluster — configure and provision OpenShift
  4. Day-2 — apply cluster resources, NTP, update service, etc.

Image transfer uses oc-mirror (disk2mirror). The saved archives
were created on a connected host via 'Save images to disk' (mirror2disk).

Use 'Advanced' to switch modes or manage platform settings.

Navigation:
  • Arrow keys / Tab — move between items and buttons
  • Enter — select highlighted item
  • ESC — go back (sub-menu → parent menu, main menu → exit)"
				continue
				;;
		1|255)
			# ESC or Exit button: always confirm quit, regardless of how we got here
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
						confirm_and_execute "aba --dir mirror uninstall" "Uninstall Existing Registry" && disco_install_reg
					fi
				else
					disco_install_reg
				fi
				# RECHECK: may have installed/uninstalled registry
				_disco_need_recheck=true
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
				# RECHECK: load pushes images into registry (changes check-image result)
				_disco_need_recheck=true
				;;
		"$TUI2_DISCO_TAG_INSTALL")
			tui_install_cluster_gate DISCO
			case "$?" in
			0) cluster_install_flow ;;
			3) ;;
			esac
			# RECHECK: may have created/installed a cluster
			_disco_need_recheck=true
			;;
			"$TUI2_DISCO_TAG_DAY2")
				if [[ "${_CLUSTER_DAY2_AVAIL}" != "true" ]]; then
					dlg --backtitle "$(ui_backtitle)" --msgbox \
						"$TUI2_MSG_NO_CLUSTERS" 0 0
				else
					cluster_day2_menu
				fi
				# RECHECK: day2 sub-menu may delete clusters or change state
				_disco_need_recheck=true
				;;
			"$TUI2_DISCO_TAG_ADVANCED")
				tui_advanced_menu
				local _adv_rc=$?
				# RECHECK: advanced menu may uninstall registry or delete clusters
				_disco_need_recheck=true
				[[ $_adv_rc -eq 2 ]] && return 2
				;;
			"$TUI2_DISCO_TAG_VIEW_ISC")
				mirror_view_isc "true"
				# NO RECHECK: only views/edits a config file
				_disco_need_recheck=false
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

	confirm_and_execute "aba --dir mirror load$(_tui_oc_mirror_retry_suffix)" "$TUI2_LABEL_LOAD" _invalidate_mirror_cache
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
	return 2  # Special return code: re-detect mode
}
