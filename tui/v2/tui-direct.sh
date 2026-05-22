#!/usr/bin/env bash
# =============================================================================
# TUI v2 — DIRECT Mode (connected, no mirror)
# =============================================================================
# Minimal wizard (pull secret, channel, version, platform, operators) then action menu.
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
# DIRECT Mode Wizard (pull secret, channel, version, platform, operators)
# =============================================================================

direct_wizard() {
	tui_log "Running DIRECT wizard"

	# Resume dialog: if channel+version exist, offer to continue or reconfigure (CONNO / DIRECT only)
	if [[ "$_TUI_MODE" == "CONNO" || "$_TUI_MODE" == "DIRECT" ]] && \
	   [[ -n "${ocp_channel:-}" && -n "${ocp_version:-}" ]]; then
		local _resume_summary="Current configuration:\n\n"
		_resume_summary+="  Channel:  ${ocp_channel}\n"
		_resume_summary+="  Version:  ${ocp_version}\n"
		[[ -n "${platform:-}" ]] && _resume_summary+="  Platform: ${platform}\n"
		_resume_summary+="\nContinue with this configuration?"
		dlg --backtitle "$(ui_backtitle)" \
			--title "Resume Configuration" \
			--yes-label "Continue" \
			--no-label "Reconfigure" \
			--yesno "$_resume_summary" 14 50
		local _resume_rc=$?
		if [[ $_resume_rc -eq 0 ]]; then
			if _direct_config_complete; then
				tui_log "Resuming with existing config"
				return 0
			fi
			dlg --backtitle "$(ui_backtitle)" --title "Incomplete configuration" \
				--msgbox "Continue requires a pull secret path in aba.conf and a valid secret file.\nComplete the wizard to finish setup." 0 0
		fi
		# Else: fall through to wizard steps
	fi

	local step="pull_secret"
	local _ver_short=""

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
				back) return 1 ;;  # Exit wizard (pull secret already valid — no step to go back to)
				repeat) ;;  # Stay on channel
				*) return 1 ;;
			esac
			;;
			version)
				_direct_version
				case "$DIALOG_RC" in
					next)
						dlg --backtitle "$(ui_backtitle)" \
							--title "Confirm Configuration" \
							--yesno "Channel: ${ocp_channel}\nVersion: ${ocp_version}\n\nProceed with this configuration?" \
							10 50 || { step="channel"; continue; }

						_ver_short="${ocp_version%.*}"
						# Save config early: catalog downloads need pull_secret_file from aba.conf
						_direct_save_config
					if [[ "$_TUI_MODE" != "DIRECT" ]]; then
						tui_log "Starting catalog downloads for OpenShift $_ver_short"
						download_all_catalogs "$_ver_short" >>"$_TUI_LOG_FILE" 2>&1
						# Start registry download early (shared task ID with aba.sh)
						run_once -i "mirror:reg:download" -- \
							make -sC "$ABA_ROOT/mirror" download-registries >>"$_TUI_LOG_FILE" 2>&1
					fi
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
				next)
					if [[ "$_TUI_MODE" == "DIRECT" ]]; then
						break  # DIRECT: no mirror, no operator selection needed
					fi
					step="operators"
					;;
				back) step="version" ;;
				repeat) ;;
				*) return 1 ;;
			esac
			;;
		operators)
			_direct_operators_step "$_ver_short"
			case "$DIALOG_RC" in
				next) break ;;  # Wizard done → save
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

	# Auto-skip if pull secret already present and valid JSON.
	# DIALOG_RC="next" so the wizard advances forward; when navigating back
	# to this step, the wizard's pull_secret handler calls us — we return 0
	# (success) and the wizard goes forward to channel again, which is correct
	# because the pull secret IS valid. The wizard exits via Back from pull_secret
	# only when _direct_pull_secret returns non-zero (user cancelled the dialog).
	if [[ -f "$ps_file" ]] && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$ps_file" >/dev/null 2>&1; then
		tui_log "Pull secret already valid at $ps_file, skipping"
		DIALOG_RC="next"
		return 0
	fi

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
		echo "" > "${_TUI_TMP}.edit"
		dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_PULL_SECRET_PASTE" \
			--ok-label "$TUI2_BTN_SAVE" \
			--cancel-label "$TUI2_BTN_BACK" \
			--editbox "${_TUI_TMP}.edit" 20 76 \
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
		echo "$secret" > "$ps_file"
		chmod 600 "$ps_file"
		tui_log "Pull secret saved to $ps_file"
		return 0
	done
}

# --- Channel Selection ---
_direct_channel() {
	DIALOG_RC=""
	tui_log "DIRECT wizard: channel"

	local _default_tag=s
	case "${ocp_channel:-stable}" in
	stable)    _default_tag=s ;;
	fast)      _default_tag=f ;;
	candidate) _default_tag=c ;;
	esac

	dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CHANNEL" \
		--default-item "$_default_tag" \
		--no-cancel \
		--extra-button --extra-label "$TUI2_BTN_BACK" \
		--help-button \
		--ok-label "$TUI2_BTN_NEXT" \
		--menu "$TUI2_MSG_CHANNEL_PROMPT" 0 0 3 \
		"s" "stable    — Recommended" \
		"f" "fast      — Latest GA" \
		"c" "candidate — Preview" \
		2>"$_TUI_TMP"
	local rc=$?

	case "$rc" in
		0)
			local _ch_tag
			_ch_tag=$(<"$_TUI_TMP")
			[[ -z "$_ch_tag" ]] && _ch_tag=s
			case "$_ch_tag" in
				s) ocp_channel="stable" ;;
				f) ocp_channel="fast" ;;
				c) ocp_channel="candidate" ;;
				*) ocp_channel="stable" ;;
			esac
			tui_log "Selected channel: $ocp_channel"
			DIALOG_RC="next"

			# Ensure version fetches are running (already started at TUI boot;
			# run_once -i is non-blocking and skips if task already completed)
			run_once -i "ocp:${ocp_channel}:latest_version" -- \
				bash -lc "source ./scripts/include_all.sh; fetch_latest_version $ocp_channel"
			run_once -i "ocp:${ocp_channel}:latest_version_previous" -- \
				bash -lc "source ./scripts/include_all.sh; fetch_previous_version $ocp_channel"
			run_once -i "ocp:${ocp_channel}:latest_version_older" -- \
				bash -lc "source ./scripts/include_all.sh; fetch_older_version $ocp_channel"
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
		DIALOG_RC="back"
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
				--inputbox "Enter OpenShift version (x.y or x.y.z):" 0 0 "" \
				2>"$_TUI_TMP"
			local man_rc=$?
			if [[ $man_rc -ne 0 ]]; then
				DIALOG_RC="back"
				return
			fi
			ocp_version=$(<"$_TUI_TMP")
			ocp_version="${ocp_version##[[:space:]]}"
			ocp_version="${ocp_version%%[[:space:]]}"
			if [[ "$ocp_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
				tui_log "Manual version entry: $ocp_version"
				DIALOG_RC="next"
				return
			elif [[ "$ocp_version" =~ ^[0-9]+\.[0-9]+$ ]]; then
				# x.y format — resolve to latest z-stream
				local _input_minor="$ocp_version"
				tui_log "Resolving $ocp_version to latest z-stream"
				dlg --backtitle "$(ui_backtitle)" --infobox \
					"Resolving $ocp_version to latest z-stream...\n\nPlease wait..." 0 0
				local _resolved=""
				if _resolved=$(_resolve_minor_to_patch "$_input_minor" "$ocp_channel"); then
					ocp_version="$_resolved"
					tui_log "Resolved $_input_minor to $ocp_version"
					DIALOG_RC="next"
					return
				fi
				dlg --backtitle "$(ui_backtitle)" --msgbox \
					"Version not found: $_input_minor\nChannel: $ocp_channel\n\nNo releases found for this minor version." 0 0
				ocp_version=""
			else
				dlg --backtitle "$(ui_backtitle)" --msgbox \
					"Invalid version format.\n\nExpected: x.y or x.y.z (e.g. 4.18 or 4.18.10)" 0 0
			fi
		done
		return
	fi

	# Build menu items
	local _has_current=false
	if [[ -n "${ocp_version:-}" ]] &&
	   [[ "$ocp_version" != "$latest" ]] &&
	   [[ "$ocp_version" != "${previous:-}" ]] &&
	   [[ "$ocp_version" != "${older:-}" ]]; then
		_has_current=true
	fi

	local _default_ver_tag=l
	if [[ -n "${ocp_version:-}" ]]; then
		if [[ "$_has_current" == true ]]; then
			_default_ver_tag=c
		elif [[ "$ocp_version" == "$latest" ]]; then
			_default_ver_tag=l
		elif [[ -n "$previous" && "$ocp_version" == "$previous" ]]; then
			_default_ver_tag=p
		elif [[ -n "$older" && "$ocp_version" == "$older" ]]; then
			_default_ver_tag=o
		else
			_default_ver_tag=m
		fi
	fi

	local items=()
	if [[ "$_has_current" == true ]]; then
		items+=("c" "Current   ($ocp_version)")
	fi
	items+=("l" "Latest    ($latest)")
	[[ -n "$previous" ]] && items+=("p" "Previous  ($previous)")
	[[ -n "$older" ]] && items+=("o" "Older     ($older)")
	items+=("m" "Manual entry (x.y or x.y.z)")

	dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_VERSION" \
		--default-item "$_default_ver_tag" \
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
				c) ;;
				l) ocp_version="$latest" ;;
				p) ocp_version="$previous" ;;
				o) ocp_version="$older" ;;
				m)
				while :; do
					dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_VERSION_MANUAL" \
						--inputbox "Enter OpenShift version (x.y or x.y.z):" 0 0 "${ocp_version:-$latest}" \
						2>"$_TUI_TMP"
					if [[ $? -ne 0 ]]; then
						DIALOG_RC="repeat"
						return
					fi
					ocp_version=$(<"$_TUI_TMP")
					ocp_version="${ocp_version##[[:space:]]}"
					ocp_version="${ocp_version%%[[:space:]]}"
					if [[ "$ocp_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
						break
					elif [[ "$ocp_version" =~ ^[0-9]+\.[0-9]+$ ]]; then
						# x.y format — resolve to latest z-stream
						local _input_minor="$ocp_version"
						tui_log "Resolving $ocp_version to latest z-stream"
						dlg --backtitle "$(ui_backtitle)" --infobox \
							"Resolving $ocp_version to latest z-stream...\n\nPlease wait..." 0 0
						local _resolved=""
						if _resolved=$(_resolve_minor_to_patch "$_input_minor" "$ocp_channel"); then
							ocp_version="$_resolved"
							tui_log "Resolved $_input_minor to $ocp_version"
							break
						fi
						dlg --backtitle "$(ui_backtitle)" --msgbox \
							"Version not found: $_input_minor\nChannel: $ocp_channel\n\nNo releases found for this minor version." 0 0
						ocp_version=""
					else
						dlg --backtitle "$(ui_backtitle)" --msgbox \
							"Invalid version format.\n\nExpected: x.y or x.y.z (e.g. 4.18 or 4.18.10)" 0 0
					fi
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
• Manual: enter specific version (x.y or x.y.z)"
			DIALOG_RC="repeat"
			;;
		3)
			DIALOG_RC="back"
			;;
	255)
		DIALOG_RC="back"
		;;
	esac
}

# --- Platform Selection ---
_direct_platform() {
	DIALOG_RC=""
	tui_log "DIRECT wizard: platform"

	local _default_tag="M"
	case "${platform:-bm}" in
		vmw) _default_tag="V" ;;
		kvm) _default_tag="K" ;;
	esac

	dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_PLATFORM" \
		--default-item "$_default_tag" \
		--no-cancel \
		--extra-button --extra-label "$TUI2_BTN_BACK" \
		--help-button \
		--ok-label "$TUI2_BTN_NEXT" \
		--menu "$TUI2_MSG_PLATFORM_PROMPT" 0 0 3 \
		"M"  "Bare metal (default)" \
		"V"  "VMware vSphere" \
		"K"  "KVM/libvirt" \
		2>"$_TUI_TMP"
	local rc=$?

	case "$rc" in
		0)
			local _tag
			_tag=$(<"$_TUI_TMP")
			case "$_tag" in
				V) platform="vmw" ;;
				K) platform="kvm" ;;
				*) platform="bm" ;;
			esac
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
		DIALOG_RC="back"
		;;
	esac
}

# --- Operator selection (wizard step; blocks until catalog indexes are ready) ---
_direct_operators_step() {
	DIALOG_RC=""
	local _cat_ver="${1:-}"

	if [[ -z "$_cat_ver" ]]; then
		_cat_ver="${ocp_version%.*}"
	fi
	tui_log "DIRECT wizard: operator selection ($_cat_ver)"

	# Ensure config is saved (platform may have changed since version step)
	_direct_save_config

	dlg --backtitle "$(ui_backtitle)" --infobox \
		"Downloading operator catalog indexes...\n\nPlease wait." 0 0

	if ! tui_ensure_catalogs_ready "$_cat_ver"; then
		dlg --backtitle "$(ui_backtitle)" \
			--yes-label "Retry" --no-label "Back" \
			--yesno \
			"Failed to download operator catalog indexes.\n\nCheck your network and pull secret, then try again." \
			0 0
		local _err_rc=$?
		case "$_err_rc" in
			0)
				# Reset failed catalog tasks so they re-download on retry
				local _cat
				for _cat in redhat-operator certified-operator community-operator; do
					run_once -r -i "catalog:${_cat_ver}:${_cat}" 2>/dev/null || true
				done
				download_all_catalogs "$_cat_ver" >>"$_TUI_LOG_FILE" 2>&1
				DIALOG_RC="repeat"
				;;
			*)
				DIALOG_RC="back"
				;;
		esac
		return
	fi

	local _op_rc=0
	mirror_select_operators wizard || _op_rc=$?
	case "$_op_rc" in
		0) DIALOG_RC="next" ;;
		2) DIALOG_RC="back" ;;
		*)
			DIALOG_RC="repeat"
			;;
	esac
}

# --- Operator Selection (optional — e.g. action-menu paths calling _direct_operators) ---
_direct_operators() {
	DIALOG_RC=""
	tui_log "DIRECT wizard: operator selection"

	# Save config first so mirror_select_operators can read ocp_version
	_direct_save_config

	dlg --backtitle "$(ui_backtitle)" --title "Select Operators" \
		--ok-label "$TUI2_BTN_SELECT" \
		--cancel-label "$TUI2_BTN_BACK" \
		--extra-button --extra-label "$TUI2_BTN_SKIP" \
		--menu "Select operators to include in the mirror, or skip for now.\n\nYou can always do this later from the action menu." 0 0 0 \
		"1" "Select Operator Sets (ocp, odf, virt, acm, quay...)" \
		"2" "Search Operator Names" \
		2>"$_TUI_TMP"
	local rc=$?

	case "$rc" in
		0)
			local choice
			choice=$(<"$_TUI_TMP")
			case "$choice" in
			1) mirror_select_operators ;;
			2) _operator_search "${ocp_version%.*}" ;;
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
	tui_kick_isconf_regen
}

# =============================================================================
# DIRECT Mode Action Menu
# =============================================================================

_direct_action_menu() {
	tui_log "DIRECT action menu"
	local default_item="$TUI2_DIRECT_TAG_INSTALL"

	# --- Menu state recheck optimization ---
	# IMPORTANT: _direct_need_recheck controls whether expensive state checks
	# (tui_cluster_menu_flags) run before redrawing the menu. Set to "true"
	# on first entry and after actions that can change cluster state. Actions
	# that only touch config (Settings, Rerun Wizard) set it to "false" —
	# avoiding unnecessary filesystem scans on every redraw.
	local _direct_need_recheck=true

	while :; do
		local items=()
		local inst_label
		local day2_label="Day-2 / Cluster Management"

		# Only rescan cluster directories when previous action may have changed state
		if [[ "$_direct_need_recheck" == "true" ]]; then
			tui_cluster_menu_flags DIRECT
		fi
		inst_label="${_CLUSTER_INST_LABEL}"

		if [[ "${_CLUSTER_DAY2_AVAIL}" != "true" ]]; then
			day2_label="Day-2 / Cluster Management $TUI2_GREY_INSTALL_FIRST"
		fi

		items+=(
			"" "──── Cluster ───────────────────────"
			"$TUI2_DIRECT_TAG_INSTALL"        "$inst_label"
			"$TUI2_DIRECT_TAG_DAY2"           "$day2_label"
			"" "──── Advanced ──────────────────────"
			"$TUI2_DIRECT_TAG_SETTINGS"       "\ZuC\Znonfigure...  $(_tui_settings_summary)"
			"$TUI2_DIRECT_TAG_RECONFIGURE"    "Rerun Wizard"
			"$TUI2_DIRECT_TAG_ADVANCED"       "Advanced"
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
"Fully connected mode — install OpenShift directly from the internet
without a mirror registry.

Workflow:
  1. Install Cluster — configure, review, and provision OpenShift
  2. Monitor Cluster — track install progress until completion
  3. Day-2 — post-install config (resources, NTP, update service, etc.)

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
			" ")
				continue ;;
			"$TUI2_DIRECT_TAG_INSTALL")
				cluster_install_flow
				# RECHECK: may have created/installed a cluster
				_direct_need_recheck=true
				;;
			"$TUI2_DIRECT_TAG_DAY2")
				if [[ "${_CLUSTER_DAY2_AVAIL}" != "true" ]]; then
					dlg --backtitle "$(ui_backtitle)" --msgbox "$TUI2_MSG_NO_CLUSTERS" 0 0
				else
					cluster_day2_menu
				fi
				# RECHECK: day2 sub-menu may delete clusters or change state
				_direct_need_recheck=true
				;;
			"$TUI2_DIRECT_TAG_SETTINGS")
				_tui_settings_menu
				# NO RECHECK: only changes config values (ask, reg_vendor, retry)
				_direct_need_recheck=false
				;;
			"$TUI2_DIRECT_TAG_ADVANCED")
				tui_advanced_menu
				[[ "$_TUI_MODE" != "DIRECT" ]] && return 0
				# RECHECK: advanced menu may delete clusters
				_direct_need_recheck=true
				;;
			"$TUI2_DIRECT_TAG_RECONFIGURE")
				direct_wizard || true
				source <(cd "$ABA_ROOT" && normalize-aba-conf) 2>/dev/null || true
				# NO RECHECK: wizard only changes channel/version/platform in aba.conf
				_direct_need_recheck=false
				;;
		esac
	done
}
