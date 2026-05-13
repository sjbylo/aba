#!/usr/bin/env bash
# =============================================================================
# ABA TUI v2 — Complete ABA Installer (DISCO / CONNO / DIRECT)
# =============================================================================
# Entry point: mode detection, routing, CONNO action menu.
# Complete replacement for v1 (tui/abatui.sh).
#
# Design decisions:
#   - NO 'set -e': dialog returns non-zero by design (1=Cancel, 2=Help, 3=Extra).
#     Using set -e would crash the TUI on every Cancel/Back press.
#   - ERR trap disabled: include_all.sh sets 'trap show_error ERR' which would
#     also crash on dialog non-zero returns. We disable it after sourcing.
#   - Single-letter tags as keyboard shortcuts (v1 pattern): pressing a letter
#     jumps to that menu item (e.g. M=Mirror, B=Bundle, C=Configure).
#     Tags are displayed left of the label for visual shortcut hints.
#   - All pages use menu-style (select row → edit in sub-dialog) for consistent
#     UX. Form-style (--form) was abandoned because Tab key moves to buttons
#     instead of next field, confusing users into advancing accidentally.
#   - Button layout: Select/Next/Back/Help using --ok/--extra/--cancel/--help.
#     Tab order from menu: Tab→Extra(Next), Tab Tab→Cancel(Back).
#   - Fixed dialog dimensions where content changes dynamically (e.g. Basics
#     page) to prevent dialog resize flicker.

echo "Initializing ABA TUI v2..."

set -o pipefail
set +m

# Require a terminal for interactive dialog
if [[ ! -t 0 ]]; then
	echo "ERROR: TUI requires an interactive terminal (stdin is not a TTY)."
	exit 1
fi

# Progress tick helper (prints inline tick after each stage)
_tick() { echo "  [done] $1"; }

# =============================================================================
# Derive ABA_ROOT
# =============================================================================

if [[ -z "${ABA_ROOT:-}" ]]; then
	SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
	ABA_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
	export ABA_ROOT
fi

cd "$ABA_ROOT" || { echo "ERROR: Cannot cd to $ABA_ROOT"; exit 1; }

# =============================================================================
# Source dependencies
# =============================================================================

# shellcheck disable=SC1091
source scripts/include_all.sh

# include_all.sh sets 'trap show_error ERR' which treats any non-zero return as
# a fatal error. Since dialog returns 1 (Cancel/Back), 2 (Help), 3 (Extra/Next)
# by design, the ERR trap must be disabled or every Back press crashes the TUI.
trap - ERR

# Source TUI v2 modules
source "$ABA_ROOT/tui/v2/tui-strings2.sh"
source "$ABA_ROOT/tui/v2/tui-lib.sh"
source "$ABA_ROOT/tui/v2/tui-mirror.sh"
source "$ABA_ROOT/tui/v2/tui-cluster.sh"
source "$ABA_ROOT/tui/v2/tui-disco.sh"
source "$ABA_ROOT/tui/v2/tui-direct.sh"

_tick "Loading modules"

# =============================================================================
# Startup guard — verify critical functions
# =============================================================================

for fn in check_internet_connectivity get_domain get_machine_network run_once replace-value-conf; do
	type -t "$fn" >/dev/null 2>&1 || { echo "FATAL: required function '$fn' not found in include_all.sh"; exit 1; }
done

# =============================================================================
# Kick off internet check early (runs in background while we do other init)
# =============================================================================

tui_log "Kicking off background internet check"
run_once -i "aba:check:internet" -- \
	bash -lc "source ./scripts/include_all.sh; check_internet_connectivity aba"

_tick "Checking connectivity"

# Auto-install required packages if missing
"$ABA_ROOT/scripts/install-rpms.sh" external

_tick "Checking packages"

# =============================================================================
# CLI flags
# =============================================================================

_TUI_FORCE_MODE=""
_TUI_DIRECT_FROM_CONNO=false

while [[ $# -gt 0 ]]; do
	case "$1" in
		--disco)  _TUI_FORCE_MODE="DISCO" ;;
		--conno)  _TUI_FORCE_MODE="CONNO" ;;
		--direct) _TUI_FORCE_MODE="DIRECT" ;;
		--help|-h)
			echo "ABA TUI v2 — OpenShift Installer"
			echo
			echo "Usage: $(basename "$0") [--disco|--conno|--direct|--help]"
			echo
			echo "Modes:"
			echo "  --disco   Force disconnected mode"
			echo "  --conno   Force connected-with-mirror mode"
			echo "  --direct  Force direct-from-internet mode"
			echo
			echo "Without flags, mode is auto-detected."
			exit 0
			;;
		*)
			echo "Unknown option: $1 (use --help)"
			exit 1
			;;
	esac
	shift
done

# =============================================================================
# Single-instance lock (flock)
# =============================================================================
# Hold an exclusive non-blocking flock for the lifetime of this process so only one
# TUI runs per host. Do NOT use fd 9: run_once() in include_all.sh uses fd 9 for task
# directory locks (exec 9>>… / exec 9>&-) and would replace or close ours. Allocate a
# dedicated fd with {ABA_TUI_FLOCK_FD}> so nothing in ABA reuses it mid-session.
exec {ABA_TUI_FLOCK_FD}>"${HOME}/.aba/.tui.lock" || { echo "Error: Cannot open ${HOME}/.aba/.tui.lock" >&2; exit 1; }
flock -n "${ABA_TUI_FLOCK_FD}" || { echo "Error: Another TUI instance is already running on this host. Exit the other instance first." >&2; exit 1; }

# =============================================================================
# Load existing config (if any)
# =============================================================================

tui_log "=========================================="
tui_log "ABA TUI v2 started"
tui_log "ABA_ROOT: $ABA_ROOT"
tui_log "=========================================="

if [[ -f "$ABA_ROOT/aba.conf" ]]; then
	# Use normalize-aba-conf to strip trailing whitespace, comments, etc.
	# Raw 'source aba.conf' leaves trailing tabs in values (Make-style comments)
	source <(cd "$ABA_ROOT" && normalize-aba-conf) || true
fi

# Global operator basket (for CONNO mode operator selection)
declare -gA OP_BASKET
declare -gA OP_SET_ADDED
OP_BASKET=()
OP_SET_ADDED=()

# Restore basket from aba.conf (config files = single source of truth)
# Handles both ops= (comma-separated operators) and op_sets= (comma-separated set names)
# Validates each operator against the catalog index for the current OCP version
_ver_short="${ocp_version%.*}"

# Restore individual operators from ops=
if [[ -n "${ops:-}" ]]; then
	IFS=',' read -r -a _ops_arr <<<"$ops"
	for _op in "${_ops_arr[@]}"; do
		_op="${_op##[[:space:]]}"
		_op="${_op%%[[:space:]]}"
		[[ -z "$_op" ]] && continue
		if [[ -n "$_ver_short" ]] && ! grep -q "^${_op}[[:space:]]" "$ABA_ROOT"/.index/*-index-v${_ver_short} 2>/dev/null; then
			continue
		fi
		OP_BASKET["$_op"]=1
	done
fi

# Restore operator sets from op_sets=
if [[ -n "${op_sets:-}" ]]; then
	IFS=',' read -r -a _set_arr <<<"$op_sets"
	for _s in "${_set_arr[@]}"; do
		_s="${_s##[[:space:]]}"
		_s="${_s%%[[:space:]]}"
		[[ -z "$_s" ]] && continue
		_sf="$ABA_ROOT/templates/operator-set-$_s"
		[[ -f "$_sf" ]] || continue
		OP_SET_ADDED["$_s"]=1
		while IFS= read -r _line; do
			[[ "$_line" =~ ^[[:space:]]*# ]] && continue
			[[ -z "$_line" ]] && continue
			_line="${_line##[[:space:]]}"
			_line="${_line%%[[:space:]]}"
			[[ -z "$_line" ]] && continue
			if [[ -n "$_ver_short" ]] && ! grep -q "^${_line}[[:space:]]" "$ABA_ROOT"/.index/*-index-v${_ver_short} 2>/dev/null; then
				continue
			fi
			OP_BASKET["$_line"]=1
		done < "$_sf"
	done
fi
unset _ver_short _ops_arr _op _set_arr _s _sf _line

# Clean up failed run_once tasks from previous sessions
run_once -F 2>/dev/null || true

_tick "Loading config"

# Pre-fetch latest stable version (no pull secret needed, just api.openshift.com)
tui_log "Kicking off background version fetch (stable)"
run_once -i "ocp:stable:latest_version" -- \
	bash -lc "source ./scripts/include_all.sh; fetch_latest_version stable"

# Background ISC generation (so it's ready before user opens View/Edit ISC)
if [[ -f "$ABA_ROOT/aba.conf" ]]; then
	tui_log "Kicking off background ISC generation"
	run_once -i "aba:isconf:generate" -- \
		bash -lc "cd '$ABA_ROOT' && aba isconf -d mirror" >>"$_TUI_LOG_FILE" 2>&1 &
fi

# Wait for internet check to complete (this is the slow part)
run_once -q -w -i "aba:check:internet" 2>/dev/null || true

_tick "Ready"
unset -f _tick
sleep 0.3
clear

# =============================================================================
# Mode Detection
# =============================================================================
# Three modes:
#   DISCO  — Disconnected: arrived via bundle, no internet. Install registry from archives.
#   CONNO  — Connected with mirror: has a mirror registry (internet optional).
#            The mirror serves images to clusters over local network.
#   DIRECT — Direct from internet: no mirror, pull images directly from Red Hat.
#
# Detection priority:
#   1. --disco/--conno/--direct CLI flags (forced mode)
#   2. .bundle file present → DISCO (or ask if internet also available)
#   3. No .bundle + internet → ask user: mirror or direct
#   4. No .bundle + no internet + mirror ready → DISCO (post-load state)
#   5. No .bundle + no internet + no mirror → dead end (need bundle transfer)

# Validate that the repo has sufficient payload to operate offline (bundle equivalent).
# Minimum "bundle": aba.conf + CLI tools + registry install files (Quay/Docker) + ISC config.
# Additionally: EITHER mirror already installed (sync path) OR tar archives exist (save path).
_validate_payload() {
	tui_log "Validating payload for offline operation..."

	# 1. ISC config must exist and be non-empty
	if [[ ! -s "$ABA_ROOT/mirror/data/imageset-config.yaml" ]]; then
		tui_log "FAIL: ISC file missing or empty"
		return 1
	fi

	# 2. Critical CLI tools must exist and be >1MB (catches truncated/corrupt files)
	local min_size=1000000
	local cli_ok=true
	local f
	for f in openshift-client-linux openshift-install-linux oc-mirror; do
		local found
		found=$(find "$ABA_ROOT/cli/" -name "${f}*.tar.gz" -size +${min_size}c 2>/dev/null | head -1)
		if [[ -z "$found" ]]; then
			tui_log "FAIL: CLI file missing or too small: ${f}*.tar.gz"
			cli_ok=false
		fi
	done
	[[ "$cli_ok" == "false" ]] && return 1

	# 3. Registry install files: Quay (mirror-registry*.tar.gz) and/or Docker (docker-reg-image.tgz)
	local has_quay has_docker
	has_quay=$(find "$ABA_ROOT/mirror/" -maxdepth 1 -name "mirror-registry*.tar.gz" -size +${min_size}c 2>/dev/null | head -1)
	has_docker=$(find "$ABA_ROOT/mirror/" -maxdepth 1 -name "docker-reg-image.tgz" -size +${min_size}c 2>/dev/null | head -1)
	if [[ -z "$has_quay" && -z "$has_docker" ]]; then
		tui_log "FAIL: No registry install files (mirror-registry*.tar.gz or docker-reg-image.tgz)"
		return 1
	fi

	# 4. Image source: EITHER mirror already installed (sync path) OR tar archives (save path)
	local mirror_installed=false
	[[ -f "$ABA_ROOT/mirror/.available" ]] && mirror_installed=true

	local has_tar_archives=false
	if find "$ABA_ROOT/mirror/data/" -name "*.tar" -size +${min_size}c 2>/dev/null | grep -q .; then
		has_tar_archives=true
	fi

	if [[ "$mirror_installed" == "false" && "$has_tar_archives" == "false" ]]; then
		tui_log "FAIL: No image source — mirror not installed and no tar archives in mirror/data/"
		return 1
	fi

	tui_log "Payload validation passed (mirror_installed=$mirror_installed, has_tar=$has_tar_archives)"
	return 0
}

_detect_mode() {
	# Forced mode via CLI flag
	if [[ -n "$_TUI_FORCE_MODE" ]]; then
		_TUI_MODE="$_TUI_FORCE_MODE"
		tui_log "Mode forced via flag: $_TUI_MODE"
		return
	fi

	# Check .bundle flag
	if [[ -f "$ABA_ROOT/.bundle" ]]; then
		# Bundle exists — check ISC
		if [[ ! -f "$ABA_ROOT/mirror/data/imageset-config.yaml" ]]; then
			# Dead end: bundle but no ISC
			dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_DEAD_END" \
				--msgbox "$TUI2_MSG_BUNDLE_INCOMPLETE" 0 0
			clear
			exit 1
		fi

		# Bundle + ISC exists. Check internet.
		run_once -q -w -S -i "aba:check:internet" 2>/dev/null || true
		if check_internet_connectivity "aba" quiet 2>/dev/null; then
			_TUI_INET="yes"
			# Bundle + internet: ask user
			dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_BUNDLE_CONNECTED" \
				--yes-label "$TUI2_BTN_DISCO_MODE" \
				--no-label "$TUI2_BTN_CONNECTED_MODE" \
				--yesno "$TUI2_MSG_BUNDLE_CONNECTED" 0 0
			local rc=$?
			if [[ $rc -eq 0 ]]; then
				_TUI_MODE="DISCO"
			else
				# Switch to connected — remove bundle flag
				rm -f "$ABA_ROOT/.bundle"
				tui_log "User chose connected mode, removed .bundle"
				_TUI_MODE="CONNO"
				return
			fi
		else
			_TUI_MODE="DISCO"
		fi
		tui_log "Mode detected: DISCO"
		return
	fi

	# No bundle — check internet
	run_once -q -w -S -i "aba:check:internet" 2>/dev/null || true
	if check_internet_connectivity "aba" quiet 2>/dev/null; then
		_TUI_INET="yes"
		_TUI_MODE="CONNO"
		tui_log "Mode detected: CONNO (internet available, default to mirror)"
	else
		_TUI_INET="no"
		tui_log "Internet check failed: FAILED_SITES=[$FAILED_SITES]"

		# Show detailed error so user knows which sites are unreachable
		local _err_details="${ERROR_DETAILS//$'\n'/\\n  }"
		dlg --backtitle "$(ui_backtitle)" --title "Internet Access Required" \
			--no-collapse \
			--msgbox "\Z1ERROR: Internet access required\Zn\n\nCannot access: $FAILED_SITES\n\nError details:\n  $_err_details\n\nEnsure you have Internet access to download the required images.\nTo get started with ABA run it on a connected workstation/laptop\nwith Fedora, RHEL or CentOS Stream and try again.\n\nRequired sites:                    Other sites:\n  mirror.openshift.com               docker.io\n  api.openshift.com                  docker.com\n  registry.redhat.io                 hub.docker.com\n  quay.io and *.quay.io              index.docker.io\n  console.redhat.com\n  registry.access.redhat.com\n\nExiting..." 0 0

		# After showing error, check if we can fall back to DISCO
		if [[ -f "$ABA_ROOT/aba.conf" ]] && _validate_payload; then
			_TUI_MODE="DISCO"
			tui_log "Mode detected: DISCO (offline, payload ready)"
		else
			clear
			exit 1
		fi
	fi
}

## _mode_select_mirror_or_direct removed — internet available always enters CONNO.
## User switches to DIRECT from the CONNO action menu ("Switch to DIRECT mode").

# =============================================================================
# CONNO Mode Action Menu (full v1 replacement)
# =============================================================================

_conno_main() {
	tui_log "Entering CONNO mode"

	# Run initial wizard if config not complete
	if [[ -z "${ocp_channel:-}" || -z "${ocp_version:-}" ]]; then
		tui_log "CONNO: config incomplete, running wizard"
		direct_wizard || return 1
		# Reload config (normalized to avoid trailing whitespace from comments)
		source <(cd "$ABA_ROOT" && normalize-aba-conf) 2>/dev/null || true
	fi

	# CONNO action menu — single-letter tags displayed as keyboard shortcuts.
	# Items that are unavailable get "[reason]" appended to their label
	# and show a msgbox when selected (greyed-out pattern).
	# Separators (space tags) visually group mirror, transfer, and cluster ops.
	local default_item="$TUI2_CONNO_TAG_OPERATORS"
	while :; do
		# Re-check internet status each iteration (handles dynamic connectivity changes)
		if check_internet_connectivity "aba" quiet 2>/dev/null; then
			_TUI_INET="yes"
		else
			_TUI_INET="no"
		fi

		local items=()

		local mirr_label="Install Mirror (local or remote)"
		local mirr_avail=true
		local save_label="Save Images (mirror2disk)"
		local sync_label="Sync Images (mirror2mirror)"
		local visc_label="View/Edit ImageSet Config"
		local ops_label="Select Operators"
		local bndl_label="Create Install Bundle"
		local switch_label="Switch to Fully Connected"
		local disco_switch_label="Switch to Fully Disconnected"

		local save_avail=true sync_avail=true
		local ops_avail=true bndl_avail=true switch_avail=true

		# Internet-dependent items greyed out in offline mode
		if [[ "$_TUI_INET" == "no" ]]; then
			save_avail=false
			save_label="Save Images (mirror2disk) $TUI2_GREY_NO_INTERNET"
			sync_avail=false
			sync_label="Sync Images (mirror2mirror) $TUI2_GREY_NO_INTERNET"
			ops_avail=false
			ops_label="Select Operators $TUI2_GREY_NO_INTERNET"
			bndl_avail=false
			bndl_label="Create Install Bundle $TUI2_GREY_NO_INTERNET"
			switch_avail=false
			switch_label="Switch to Fully Connected $TUI2_GREY_NO_INTERNET"
		fi

		if mirror_available; then
			mirr_avail=false
			mirr_label="Install Mirror $TUI2_GREY_ALREADY_INSTALLED"
		fi

		# Cluster operations — "Install Cluster" is the unified flow (configure → review → install)
		local inst_label="Install Cluster"
		local day2_label="Day-2 / Cluster Management"
		local mon_label="Finalize Installation (wait-for)"

		local day2_avail=true mon_avail=true

		local has_installed=false
		local has_any_cluster=false
		local dir
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

		# Hint on "Install Cluster" if mirror not ready
		if ! mirror_available; then
			inst_label="Install Cluster [no mirror]"
		elif ! _mirror_has_release_image; then
			inst_label="Install Cluster [sync mirror first]"
		fi

		# Dynamic menu title with mirror state
		local _mstate
		_mstate="$(mirror_state_label)"
		local conno_menu_msg="Partially Disconnected Mode (${_mstate}):"

		# Mirror health warning
		local mirror_warn=""
		if mirror_available; then
			local verify_exit
			verify_exit=$(run_once -E -i "aba:mirror:verify" 2>/dev/null) || true
			if [[ -n "$verify_exit" && "$verify_exit" != "0" ]]; then
				mirror_warn=" \Z3Warning: mirror may be unreachable (verify failed)\Zn"
			fi
		fi

		items+=(
			"" "──── Mirror ────────────────────────"
			"$TUI2_CONNO_TAG_VIEW_ISC"       "$visc_label"
			"$TUI2_CONNO_TAG_OPERATORS"      "$ops_label"
			"$TUI2_CONNO_TAG_INSTALL_MIRROR" "$mirr_label"
			"$TUI2_CONNO_TAG_SYNC"           "$sync_label"
			"" "──── Transfer ──────────────────────"
			"$TUI2_CONNO_TAG_BUNDLE"         "$bndl_label"
			"$TUI2_CONNO_TAG_SAVE"           "$save_label"
			"" "──── Cluster ───────────────────────"
			"$TUI2_CONNO_TAG_INSTALL"        "$inst_label"
			"$TUI2_CONNO_TAG_MONITOR"        "$mon_label"
			"$TUI2_CONNO_TAG_DAY2"           "$day2_label"
			"" "──── Advanced ──────────────────────"
			"$TUI2_CONNO_TAG_ADVANCED"       "Advanced Options"
			"" "──── Mode ──────────────────────────"
			"$TUI2_CONNO_TAG_SWITCH_DIRECT"  "$switch_label"
			"$TUI2_CONNO_TAG_SWITCH_DISCO"   "$disco_switch_label"
		)

		dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CONNO_MENU" \
			--cancel-label "$TUI2_BTN_EXIT" \
			--ok-label "$TUI2_BTN_SELECT" \
			--help-button \
			--default-item "$default_item" \
			--menu "${conno_menu_msg}${mirror_warn}" 0 0 0 \
			"${items[@]}" \
			2>"$_TUI_TMP"
		local rc=$?

		case "$rc" in
			2)
				show_help "$TUI2_HELP_TITLE_CONNO" \
"Partially disconnected mode with a mirror registry. Full ABA workflow:

Mirror operations:
  • Install Mirror — set up registry (local or remote)
  • View/Edit ISC — manage the ImageSet configuration
  • Operators — select which operators to include

Transfer:
  • Save — download images to local archive
  • Sync — push images directly to registry
  • Bundle — create a portable bundle (tar) for USB transfer

Cluster operations:
  • Install Cluster — configure, review, and provision OpenShift
  • Finalize Installation — wait for install to complete (re-attach)
  • Day-2 — post-install config (resources, NTP, update service, etc.)

Mode switching:
  • Fully Connected — install from internet without a mirror
  • Fully Disconnected — work offline using this repo in-place
    Downloads CLI tools + registry installers first if missing.

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
		# Skip separator items (empty tag)
		[[ -z "$choice" ]] && continue
		default_item="$choice"

		case "$choice" in
		"$TUI2_CONNO_TAG_INSTALL_MIRROR")
			if [[ "$mirr_avail" == "false" ]]; then
				dlg --backtitle "$(ui_backtitle)" --yesno \
					"$TUI2_MSG_MIRROR_REINSTALL" 0 0
				if [[ $? -eq 0 ]]; then
					confirm_and_execute "aba -d mirror uninstall" "Uninstall Existing Mirror" && mirror_install
				fi
			else
				mirror_install
			fi
			;;
		"$TUI2_CONNO_TAG_SAVE")
			if [[ "$_TUI_INET" == "no" ]]; then
				dlg --backtitle "$(ui_backtitle)" --msgbox "$TUI2_MSG_NO_INTERNET" 0 0
			else
				mirror_save
			fi
			;;
		"$TUI2_CONNO_TAG_SYNC")
			if [[ "$_TUI_INET" == "no" ]]; then
				dlg --backtitle "$(ui_backtitle)" --msgbox "$TUI2_MSG_NO_INTERNET" 0 0
			elif ! mirror_available; then
				dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_MIRROR_REQUIRED" \
					--yesno "Mirror registry is not installed.\n\nA mirror will be installed first, then images will be synced.\n\nContinue?" 0 0
				if [[ $? -eq 0 ]]; then
					_mirror_config_review && mirror_sync
				fi
			else
				mirror_sync
			fi
			;;
			"$TUI2_CONNO_TAG_VIEW_ISC")
				mirror_view_isc "false"
				;;
			"$TUI2_CONNO_TAG_OPERATORS")
				if [[ "$ops_avail" == "false" ]]; then
					dlg --backtitle "$(ui_backtitle)" --msgbox "$TUI2_MSG_NO_INTERNET" 0 0
				else
					mirror_select_operators
				fi
				;;
			"$TUI2_CONNO_TAG_BUNDLE")
				if [[ "$bndl_avail" == "false" ]]; then
					dlg --backtitle "$(ui_backtitle)" --msgbox "$TUI2_MSG_NO_INTERNET" 0 0
				else
					mirror_create_bundle
				fi
				;;
			"$TUI2_CONNO_TAG_INSTALL")
				if ! mirror_available; then
					dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_MIRROR_REQUIRED" \
						--yes-label "Install & Sync" --no-label "$TUI2_BTN_BACK" \
						--yesno "No mirror registry installed.\n\nA mirror with synced images is required to install a cluster.\n\nInstall the mirror and sync images now?" 0 0
					if [[ $? -eq 0 ]]; then
						_mirror_config_review && mirror_sync && cluster_install_flow
					fi
				elif ! _mirror_has_release_image; then
					dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_MIRROR_NOT_SYNCED" \
						--yes-label "Sync Now" --no-label "$TUI2_BTN_BACK" \
						--yesno "The mirror is installed but has no release images.\n\nSync images to the mirror now?" 0 0
					if [[ $? -eq 0 ]]; then
						mirror_sync && cluster_install_flow
					fi
				else
					cluster_install_flow
				fi
				;;
			"$TUI2_CONNO_TAG_DAY2")
				if [[ "$day2_avail" == "false" ]]; then
					dlg --backtitle "$(ui_backtitle)" --msgbox "$TUI2_MSG_NO_CLUSTERS" 0 0
				else
					cluster_day2_menu
				fi
				;;
			"$TUI2_CONNO_TAG_MONITOR")
				if [[ "$mon_avail" == "false" ]]; then
					dlg --backtitle "$(ui_backtitle)" --msgbox "$TUI2_MSG_CLUSTER_FIRST" 0 0
				else
					cluster_monitor
				fi
				;;
			"$TUI2_CONNO_TAG_ADVANCED")
				tui_advanced_menu
				;;
	"$TUI2_CONNO_TAG_SWITCH_DIRECT")
		if [[ "$switch_avail" == "false" ]]; then
			dlg --backtitle "$(ui_backtitle)" --msgbox "$TUI2_MSG_NO_INTERNET" 0 0
		else
			_TUI_MODE="DIRECT"
			_TUI_DIRECT_FROM_CONNO=true
			tui_log "Switching to DIRECT mode"
			direct_main || true
			_TUI_MODE="CONNO"
			_TUI_DIRECT_FROM_CONNO=false
			tui_log "Returned from DIRECT, back to CONNO"
		fi
		;;
	"$TUI2_CONNO_TAG_SWITCH_DISCO")
		_ensure_offline_prereqs || continue
		_TUI_MODE="DISCO"
		tui_log "Switching to DISCO mode (in-place repo)"
		disco_main || true
		_TUI_MODE="CONNO"
		tui_log "Returned from DISCO, back to CONNO"
		;;
		" "|"  "|"   ")
				# Separator — do nothing
				;;
		esac
	done
}

# =============================================================================
# Main Flow
# =============================================================================

_detect_mode

# Pre-cache mirror verify for CONNO (task id matches run_once -E in _conno_main)
if [[ "$_TUI_MODE" == "CONNO" ]] && mirror_available; then
	tui_log "Kicking off background mirror verify (CONNO prefetch)"
	run_once -i "aba:mirror:verify" -- bash -lc "cd '$ABA_ROOT' && aba -d mirror verify"
fi

tui_log "Final mode: $_TUI_MODE"

while :; do
	case "$_TUI_MODE" in
		DISCO)
			disco_rc=0
			disco_main || disco_rc=$?
			if [[ $disco_rc -eq 2 ]]; then
				_detect_mode
				continue
			fi
			break
			;;
		CONNO)
			_conno_main
			break
			;;
		DIRECT)
			direct_main
			# If mode was changed (e.g. Switch to Mirror), loop back
			[[ "$_TUI_MODE" != "DIRECT" ]] && continue
			break
			;;
		*)
			echo "ERROR: Unknown mode: $_TUI_MODE"
			exit 1
			;;
	esac
done

clear
_show_v2_exit_summary
