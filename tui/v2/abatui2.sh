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

printf 'Initializing ABA TUI v2...\n'
printf '  [ ] Loading modules\n'
printf '  [ ] Please wait...\n'
printf '  [ ] Checking packages\n'
printf '  [ ] Loading config\n'

# Progress tick helper — moves cursor up and overwrites the step with a checkmark
_TICK_TOTAL=4
_TICK_N=0
_tick() {
	local lines_up=$(( _TICK_TOTAL - _TICK_N ))
	printf '\033[%dA\r  [✓] %s\033[K\033[%dB\r' "$lines_up" "$1" "$lines_up"
	_TICK_N=$(( _TICK_N + 1 ))
}

set -o pipefail
set +m

# Require a terminal for interactive dialog
if [[ ! -t 0 ]]; then
	echo "ERROR: TUI requires an interactive terminal (stdin is not a TTY)."
	exit 1
fi

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
# Single-instance lock (flock) — check FIRST before any heavy init
# =============================================================================
_ABA_TUI_PID_FILE="${HOME}/.aba/.tui.pid"
mkdir -p "${HOME}/.aba" 2>/dev/null || true
exec {ABA_TUI_FLOCK_FD}>"${HOME}/.aba/.tui.lock" || { echo "Error: Cannot open ${HOME}/.aba/.tui.lock" >&2; exit 1; }
if ! flock -n "${ABA_TUI_FLOCK_FD}"; then
	_other_pid=""
	[[ -f "$_ABA_TUI_PID_FILE" ]] && _other_pid=$(<"$_ABA_TUI_PID_FILE")
	if [[ -n "$_other_pid" ]] && kill -0 "$_other_pid" 2>/dev/null; then
		echo ""
		read -r -p "Another TUI is already running (PID $_other_pid). Terminate it? (Y/n) " _ans </dev/tty
		_ans="${_ans:-Y}"
		if [[ "$_ans" =~ ^[Yy]$ ]]; then
			# Kill entire process group (catches dialog and other children holding the lock FD)
			kill -- -"$_other_pid" 2>/dev/null || kill "$_other_pid" 2>/dev/null || true
			for _i in $(seq 1 20); do
				kill -0 "$_other_pid" 2>/dev/null || break
				sleep 0.25
			done
			# Force-kill if still alive
			kill -0 "$_other_pid" 2>/dev/null && kill -9 -- -"$_other_pid" 2>/dev/null || true
		else
			echo "Exiting. Stop the other TUI first." >&2
			exit 1
		fi
	fi
	# Close the old FD, remove stale lock, reopen and acquire fresh
	eval "exec ${ABA_TUI_FLOCK_FD}>&-" 2>/dev/null || true
	rm -f "${HOME}/.aba/.tui.lock"
	exec {ABA_TUI_FLOCK_FD}>"${HOME}/.aba/.tui.lock"
	if ! flock -n "${ABA_TUI_FLOCK_FD}"; then
		echo "Error: Cannot acquire TUI lock. Kill any remaining abatui processes and try again." >&2
		exit 1
	fi
fi
echo $$ > "$_ABA_TUI_PID_FILE"

# Clean exit on signals (SIGHUP = terminal closed, SIGTERM = kill)
_tui_exit_cleanup() {
	rm -f "$_ABA_TUI_PID_FILE"
	# flock FD is released automatically when process exits
}
trap '_tui_exit_cleanup; exit 0' EXIT
trap 'exit 0' HUP TERM INT

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

for fn in check_internet_connectivity get_domain get_machine_network run_once replace-value-conf \
	aba_mirror_verify_start aba_mirror_verify_refresh aba_mirror_verify_exit \
	aba_inet_check_start aba_inet_check_wait aba_inet_check_wait_status \
	aba_version_fetch_start aba_isconf_generate_start aba_prefetch_catalogs aba_bg_cleanup; do
	type -t "$fn" >/dev/null 2>&1 || { echo "FATAL: required function '$fn' not found in include_all.sh"; exit 1; }
done

# =============================================================================
# Kick off internet check early (runs in background while we do other init)
# =============================================================================

tui_log "Kicking off background internet check"
aba_inet_check_reset

# Clean up failed/stale background tasks from previous sessions
aba_bg_cleanup

aba_inet_check_start

tui_log "Kicking off background mirror verify"
aba_mirror_verify_start

_tick "Please wait..."

# Auto-install required packages if missing
"$ABA_ROOT/scripts/install-rpms.sh" external

_tick "Checking packages"

# =============================================================================
# CLI flags
# =============================================================================

_TUI_FORCE_MODE=""
_TUI_DISCO_FROM_CONNO=false

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
_ver_short=$(_ver_minor "$ocp_version")

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
			_line="${_line%%#*}"                          # Strip inline comment
			_line="${_line#"${_line%%[![:space:]]*}"}"    # Trim leading whitespace
			_line="${_line%"${_line##*[![:space:]]}"}"    # Trim trailing whitespace
			[[ -z "$_line" ]] && continue
			if [[ -n "$_ver_short" ]] && ! grep -q "^${_line}[[:space:]]" "$ABA_ROOT"/.index/*-index-v${_ver_short} 2>/dev/null; then
				continue
			fi
			OP_BASKET["$_line"]=1
		done < "$_sf"
	done
fi
unset _ver_short _ops_arr _op _set_arr _s _sf _line

_tick "Loading config"

# Stable + other channels warmed here; prefetch uses aba_prefetch_catalogs +
# Cincinnati graph cache when aba.conf has no ocp_version yet.
tui_log "Kicking off background version fetch (stable/fast/candidate)"
aba_version_fetch_start

# Ensure aba.conf exists so background catalog downloads can read pull_secret_file
# (mirrors v1's resume_from_conf — config must exist BEFORE prefetch)
if [[ ! -f "$ABA_ROOT/aba.conf" ]]; then
	if [[ -f "$ABA_ROOT/templates/aba.conf.j2" ]]; then
		_domain=$(get_domain 2>/dev/null) || true
		export domain="${_domain}"
		machine_network="" dns_servers="" next_hop_address="" ntp_servers="" \
			"$ABA_ROOT/scripts/j2" "$ABA_ROOT/templates/aba.conf.j2" > "$ABA_ROOT/aba.conf" 2>>"$_TUI_LOG_FILE"
		tui_log "Created aba.conf from template (pull_secret_file set)"
		# Wait for latest stable version and write it to aba.conf
		run_once -q -w -S -i "ocp:stable:latest_version" 2>>"$_TUI_LOG_FILE" || true
		_latest_ver=$(fetch_latest_version stable 2>>"$_TUI_LOG_FILE") || true
		if [[ -n "$_latest_ver" ]]; then
			replace-value-conf -q -n ocp_version -v "$_latest_ver" -f "$ABA_ROOT/aba.conf"
			replace-value-conf -q -n ocp_channel -v "stable"      -f "$ABA_ROOT/aba.conf"
			tui_log "Set default version=$_latest_ver channel=stable in aba.conf"
		fi
	fi
fi

# Pre-fetch catalog indexes in background (uses ocp_version/ocp_channel from aba.conf)
_ps_path="${pull_secret_file:-$HOME/.pull-secret.json}"
_ps_path="${_ps_path/#\~/$HOME}"
if [[ -f "$_ps_path" ]]; then
	tui_log "Starting background catalog pre-fetch"
	(aba_prefetch_catalogs >>"$_TUI_LOG_FILE" 2>&1) &
fi

# Background CLI tool downloads (non-blocking, uses run_once per tool)
# Start version-independent tools immediately (oc-mirror, butane, govc).
# Version-dependent tools (oc, openshift-install) are kicked after the wizard
# confirms ocp_version — see tui-direct.sh _direct_wizard().
tui_log "Kicking off background CLI tool downloads (version-independent)"
"$ABA_ROOT/scripts/cli-download-all.sh" --no-version >>"$_TUI_LOG_FILE" 2>&1

# Background ISC generation (so it's ready before user opens View/Edit ISC)
if [[ -f "$ABA_ROOT/aba.conf" ]]; then
	tui_log "Kicking off background ISC generation"
	aba_isconf_generate_start
fi

# Wait for internet check to complete (this is the slow part)
aba_inet_check_wait

printf '  Ready.\n'
unset -f _tick
sleep 0.3
clear

# =============================================================================
# Mode Detection
# =============================================================================
# Three modes:
#   DISCO  — Disconnected: no internet, payload ready (arrived via bundle or post-load state).
#            Install registry from archives or use already-running mirror.
#   CONNO  — Connected with mirror: has internet, uses a mirror registry.
#            The mirror serves images to clusters over local network.
#   DIRECT — Direct from internet: no mirror, pull images directly from Red Hat.
#            User switches to DIRECT from the CONNO action menu.
#
# Detection priority:
#   1. --disco/--conno/--direct CLI flags (forced mode)
#   2. .bundle file present → DISCO (or ask if internet also available)
#   3. No .bundle + internet → CONNO (default to mirror workflow)
#   4. No .bundle + no internet + payload valid → DISCO (post-load state)
#   5. No .bundle + no internet + no payload → dead end (error + exit)

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
		if check_internet_connectivity "aba" quiet 2>/dev/null; then
			_TUI_INET="yes"
		else
			_TUI_INET="no"
		fi
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

		# Bundle + ISC exists. Use the internet check result from startup.
		aba_inet_check_wait_status
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
			_TUI_INET="no"
			_TUI_MODE="DISCO"
		fi
		tui_log "Mode detected: DISCO"
		return
	fi

	# No bundle — check internet
	aba_inet_check_wait_status
	if check_internet_connectivity "aba" quiet 2>/dev/null; then
		_TUI_INET="yes"
		_TUI_MODE="CONNO"
		tui_log "Mode detected: CONNO (internet available, default to mirror)"
	else
		_TUI_INET="no"
		tui_log "Internet check failed: FAILED_SITES=[$FAILED_SITES]"

		# Check if we can operate in DISCO mode (no internet but payload ready)
		if [[ -f "$ABA_ROOT/aba.conf" ]] && _validate_payload; then
			_TUI_MODE="DISCO"
			tui_log "Mode detected: DISCO (offline, payload ready)"
		else
			# No fallback possible — show detailed error and exit
			local _err_details="${ERROR_DETAILS//$'\n'/\\n  }"
			dlg --backtitle "$(ui_backtitle)" --title "Internet Access Required" \
				--no-collapse \
				--msgbox "\Z1ERROR: Internet access required\Zn\n\nCannot access: $FAILED_SITES\n\nError details:\n  $_err_details\n\nEnsure you have Internet access to download the required images.\nTo get started with ABA run it on a connected workstation/laptop\nwith Fedora, RHEL or CentOS Stream and try again.\n\nRequired sites:                    Other sites:\n  mirror.openshift.com               docker.io\n  api.openshift.com                  docker.com\n  registry.redhat.io                 hub.docker.com\n  quay.io and *.quay.io              index.docker.io\n  console.redhat.com\n  registry.access.redhat.com\n\nExiting..." 0 0
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
	local default_item=""
	_TUI_ISC_UPDATED=${_TUI_ISC_UPDATED:-false}

	# --- Menu loop: no per-action flag assignments needed ---
	# _TUI_NEED_MIRROR_RECHECK is set only by _invalidate_mirror_cache()
	# (called automatically after sync, load, install, uninstall via
	# confirm_and_execute post-hook). The background check starts immediately
	# after the action, so by the time the user presses OK and the menu
	# redraws, the check is usually already complete.
	while :; do
		# Internet: runs independently on 120s TTL cache (fast when warm)
		if ! run_once -p -i "aba:check:internet" 2>/dev/null; then
			dlg --backtitle "$(ui_backtitle)" --infobox "Please wait..." 3 25
		fi
		if aba_inet_check_cached 120; then _TUI_INET="yes"; else _TUI_INET="no"; fi

		local items=()

		local mirr_label="$TUI2_LABEL_INSTALL_MIRROR"
		local mirr_avail=true
		local save_label="$TUI2_LABEL_SAVE"
		local sync_label="$TUI2_LABEL_SYNC"
		local visc_label="$TUI2_LABEL_VIEW_ISC"
		local ops_label="$TUI2_LABEL_OPERATORS"
		local bndl_label="$TUI2_LABEL_BUNDLE"
		local save_avail=true sync_avail=true
		local ops_avail=true bndl_avail=true

		# Internet-dependent items greyed out in offline mode
		local upg_label="Prepare Upgrade for Transfer"
		if [[ "$_TUI_INET" == "no" ]]; then
			save_avail=false
			save_label="$TUI2_LABEL_SAVE $TUI2_STATUS_NO_INTERNET"
			sync_avail=false
			sync_label="$TUI2_LABEL_SYNC $TUI2_STATUS_NO_INTERNET"
			ops_avail=false
			ops_label="$TUI2_LABEL_OPERATORS $TUI2_STATUS_NO_INTERNET"
			bndl_avail=false
			bndl_label="$TUI2_LABEL_BUNDLE $TUI2_STATUS_NO_INTERNET"
			upg_label="Prepare Upgrade for Transfer $TUI2_STATUS_NO_INTERNET"
		fi

		# Mirror recheck: only when _invalidate_mirror_cache fired after a
		# mirror-changing action (sync, load, install, uninstall).
		if [[ "$_TUI_NEED_MIRROR_RECHECK" == "true" ]]; then
			if ! run_once -p -i "aba:mirror:check-image" 2>/dev/null; then
				dlg --backtitle "$(ui_backtitle)" --infobox "Checking mirror..." 3 30
			fi
			aba_mirror_verify_wait
			_TUI_NEED_MIRROR_RECHECK=false
		fi

		# Refresh mirror labels from cached state (non-blocking)
		if mirror_available && _mirror_has_release_image; then
			mirr_avail=false
			mirr_label="$TUI2_LABEL_INSTALL_MIRROR $TUI2_STATUS_INSTALLED"
			if [[ "$sync_avail" == "true" ]]; then
				sync_label="$TUI2_LABEL_SYNC $TUI2_STATUS_SYNCED"
			fi
		elif mirror_available; then
			mirr_avail=false
			mirr_label="$TUI2_LABEL_INSTALL_MIRROR $TUI2_STATUS_NOT_VERIFIED"
		fi

		# Save status: tar archives exist in mirror/data/
		if [[ "$save_avail" == "true" ]] && ls "$ABA_ROOT"/mirror/data/mirror_*.tar &>/dev/null; then
			save_label="$TUI2_LABEL_SAVE $TUI2_STATUS_SAVED"
		fi

		# Cluster flags (instant — marker file checks only)
		tui_cluster_menu_flags CONNO

		local inst_label="${_CLUSTER_INST_LABEL}"
		local day2_label="$TUI2_LABEL_DAY2"
		if [[ "${_CLUSTER_DAY2_AVAIL}" != "true" ]]; then
			day2_label="$TUI2_LABEL_DAY2 $TUI2_STATUS_INSTALL_CLUSTER"
		fi

		# Smart focus: last assignment wins = highest priority (read bottom-to-top)
		if [[ -z "$default_item" ]]; then
			default_item="$TUI2_CONNO_TAG_VIEW_ISC"
			if [[ "$_CLUSTER_HAS_INSTALLED" == "true" ]];           then default_item="$TUI2_CONNO_TAG_DAY2"; fi
			if _mirror_has_release_image;                            then default_item="$TUI2_CONNO_TAG_INSTALL"; fi
			if mirror_available && ! _mirror_has_release_image;      then default_item="$TUI2_CONNO_TAG_SYNC"; fi
			if ! mirror_available;                                   then default_item="$TUI2_CONNO_TAG_INSTALL_MIRROR"; fi
			if [[ "$_TUI_ISC_UPDATED" == "true" ]];                 then default_item="$TUI2_CONNO_TAG_VIEW_ISC"; fi
		fi

		# Dynamic menu title with mirror state
		local _mstate
		_mstate="$(mirror_state_label)"
		local conno_menu_msg="Status: ${_mstate}"

		# Mirror state is already shown via color-coded label (green/yellow/red)
		local mirror_warn=""

		items+=(
			"" "──── Mirror ────────────────────────"
			"$TUI2_CONNO_TAG_VIEW_ISC"       "$visc_label"
			"$TUI2_CONNO_TAG_OPERATORS"      "$ops_label"
			"$TUI2_CONNO_TAG_INSTALL_MIRROR" "$mirr_label"
			"$TUI2_CONNO_TAG_SYNC"           "$sync_label"
			"" "──── Transfer ──────────────────────"
			"$TUI2_CONNO_TAG_BUNDLE"         "$bndl_label"
			"$TUI2_CONNO_TAG_SAVE"           "$save_label"
			"$TUI2_CONNO_TAG_PREP_UPGRADE"   "$upg_label"
			"" "──── Cluster ───────────────────────"
			"$TUI2_CONNO_TAG_INSTALL"        "$inst_label"
			"$TUI2_CONNO_TAG_DAY2"           "$day2_label"
			"" "──── Advanced ──────────────────────"
			"$TUI2_CONNO_TAG_SETTINGS"       "\ZuC\Znonfigure...  $(_tui_settings_summary)"
			"$TUI2_CONNO_TAG_RECONFIGURE"    "Rerun Wizard"
			"$TUI2_CONNO_TAG_ADVANCED"       "Advanced"
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

Mirror:
  • View/Edit ISC — manage the ImageSet configuration
  • Operators — select which operators to include
  • Install Mirror — set up registry (local or remote)
  • Sync — mirror-to-mirror (m2m): push images directly to registry

Transfer:
  • Bundle — create a portable bundle (tar) for USB transfer
  • Save — mirror-to-disk (m2d): download images to local archive
  • Prepare Upgrade — prepare upgrade images for transfer

Cluster:
  • Install Cluster — configure, review, and provision OpenShift
  • Day-2 — post-install config (resources, NTP, update service, etc.)

Advanced:
  • Configure — adjust settings (retry, editor, ask mode)
  • Rerun Wizard — re-run the initial setup wizard
  • Advanced — switch modes, uninstall, reset

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
					confirm_and_execute "aba --dir mirror uninstall" "Uninstall Existing Mirror" _invalidate_mirror_cache && mirror_install
				fi
			else
				mirror_install
			fi
			default_item=""
			;;
		"$TUI2_CONNO_TAG_SAVE")
			if [[ "$_TUI_INET" == "no" ]]; then
				dlg --backtitle "$(ui_backtitle)" --msgbox "$TUI2_MSG_NO_INTERNET" 0 0
			else
				mirror_save
				default_item=""
			fi
			;;
		"$TUI2_CONNO_TAG_PREP_UPGRADE")
			if [[ "$_TUI_INET" == "no" ]]; then
				dlg --backtitle "$(ui_backtitle)" --msgbox "$TUI2_MSG_NO_INTERNET" 0 0
			else
				mirror_prep_upgrade
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
			default_item=""
			;;
		"$TUI2_CONNO_TAG_VIEW_ISC")
			mirror_view_isc "false"
			_TUI_ISC_UPDATED=false
			;;
		"$TUI2_CONNO_TAG_OPERATORS")
			if [[ "$ops_avail" == "false" ]]; then
				dlg --backtitle "$(ui_backtitle)" --msgbox "$TUI2_MSG_NO_INTERNET" 0 0
			else
				mirror_select_operators
				default_item=""
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
			tui_install_cluster_gate CONNO
			case "$?" in
			0) cluster_install_flow; default_item="" ;;
			3) default_item="" ;;
			esac
			;;
		"$TUI2_CONNO_TAG_DAY2")
			if [[ "${_CLUSTER_DAY2_AVAIL}" != "true" ]]; then
				dlg --backtitle "$(ui_backtitle)" --msgbox "$TUI2_MSG_NO_CLUSTERS" 0 0
			else
				cluster_day2_menu
			fi
			;;
		"$TUI2_CONNO_TAG_SETTINGS")
			_tui_settings_menu
			;;
		"$TUI2_CONNO_TAG_ADVANCED")
			tui_advanced_menu
			default_item=""
			;;
		"$TUI2_CONNO_TAG_RECONFIGURE")
			direct_wizard || true
			source <(cd "$ABA_ROOT" && normalize-aba-conf) 2>/dev/null || true
			_invalidate_mirror_cache
			default_item=""
			;;
		esac
	done
}

# =============================================================================
# Main Flow
# =============================================================================

# --- Splash screen first (shown once per session, no blocking checks) ---
_aba_ver=""
[[ -f "$ABA_ROOT/VERSION" ]] && _aba_ver=$(<"$ABA_ROOT/VERSION")
_aba_ver="${_aba_ver//[[:space:]]/}"

while :; do
	dlg --backtitle "$(ui_backtitle)" \
		--title " $TUI2_TITLE_WELCOME " \
		--yes-label "Continue" \
		--no-label "Exit" \
		--help-button \
		--yesno "\

  __   ____   __
 / _\\ (  _ \\ / _\\     ABA v${_aba_ver}
/    \\ ) _ (/    \\    Install & configure
\\_/\\_/(____/\\_/\\_/    air-gapped OpenShift quickly!

Follow the setup wizard or see the README.md file for more.
Get help: https://github.com/sjbylo/aba/discussions


Navigate with <Tab>, <Enter> and arrow keys. Press <ESC> to quit.
" 0 0
	splash_rc=$?
	case "$splash_rc" in
		1|255)
			clear
			_show_v2_exit_summary
			exit 0
			;;
		2)
			show_help "$TUI2_TITLE_HELP" \
"ABA TUI — Quick Guide

The TUI wizard walks you through installing OpenShift
in connected, partially disconnected, or fully air-gapped
environments.

Workflow:
  1. Pull secret     — Configure Red Hat registry credentials
  2. Version         — Choose OCP channel and version
  3. Platform        — Select bare-metal, VMware, or KVM
  4. Operators       — Pick operators to include in the mirror
  5. Mirror registry — Set up a local Quay or Docker registry
  6. Cluster install — Create, install, and monitor your cluster

After installation, Day-2 operations are available:
  - Add/remove operators, sync registry, apply updates
  - Connect OperatorHub, configure NTP, trust registry CA

Navigation:
  Tab / Arrows  — Move between items
  Enter         — Select / confirm
  Next          — Proceed to next step
  Back          — Return to previous step
  ESC           — Exit the TUI

Tip: You can also run any step from the CLI:
     aba --help"
			;;
		*)
			break
			;;
	esac
done

# --- Detect mode (uses internet check result started during startup) ---
_detect_mode

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
