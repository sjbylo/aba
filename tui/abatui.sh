#!/usr/bin/env bash
# ABA TUI – Wizard Prototype (Bash + dialog)
#
# Wizard flow:
#   Channel  <->  Version  <->  Operators  <->  Summary / Apply
#
# Note: We intentionally do NOT use 'set -e' because dialog commands return
# non-zero codes (1=Cancel, 2=Help, 3=Extra) by design. We handle all cases
# explicitly with case statements and if-checks.

echo Initializing ...

_TUI_START_EPOCH=$(date +%s)

set -o pipefail  # Catch pipeline errors
set +m            # Disable job control monitoring for faster exit

# Setup log directory
LOG_DIR="${HOME}/.aba/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true

# Single log file - overwrite each time
LOG_FILE="$LOG_DIR/aba-tui.log"

# Define log function early (before any function that uses it)
log() {
	# Ensure log file and directory exist before writing
	if [[ -n "${LOG_FILE:-}" ]]; then
		local log_dir=$(dirname "$LOG_FILE")
		[[ ! -d "$log_dir" ]] && mkdir -p "$log_dir" 2>/dev/null
		echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null || true
	fi
}

# -----------------------------------------------------------------------------
# Show config files created/modified during this TUI session
# -----------------------------------------------------------------------------
_show_exit_files() {
	local f mod_epoch shown=0
	for f in aba.conf mirror/mirror.conf \
	         mirror/save/imageset-config-save.yaml \
	         mirror/sync/imageset-config-sync.yaml; do
		[[ -f "$ABA_ROOT/$f" ]] || continue
		mod_epoch=$(stat -c %Y "$ABA_ROOT/$f" 2>/dev/null) || continue
		if (( mod_epoch >= _TUI_START_EPOCH )); then
			if (( shown == 0 )); then
				echo "Files created/updated:"
				shown=1
			fi
			echo "  $f"
		fi
	done
	if (( shown == 0 )); then
		echo "No files were modified."
	fi
}

_show_exit_summary() {
	# Clean up auto-created aba.conf if the user quit before completing the wizard.
	# _TUI_FRESH_CONF is set to "1" when aba.conf is first created from the template
	# (in resume_from_conf), and cleared in summary_apply() once the user finishes the
	# wizard and the full configuration is committed.  If the flag is still set at exit,
	# the user abandoned the wizard early, so the half-baked aba.conf (containing only
	# template defaults and possibly an auto-selected version) is removed to ensure a
	# clean slate on the next TUI run.
	if [[ "${_TUI_FRESH_CONF:-}" == "1" && -f "$ABA_ROOT/aba.conf" ]]; then
		rm -f "$ABA_ROOT/aba.conf"
		log "Removed auto-created aba.conf (wizard not completed)"
		echo "TUI exited before wizard completion. No configuration was saved."
		echo
		echo "Log file: $LOG_FILE"
		echo
		echo "Run 'aba --help' for available commands."
		echo "See the README.md for more."
		return
	fi

	echo "TUI complete."
	echo
	_show_exit_files
	echo
	echo "Log file: $LOG_FILE"
	echo
	echo "Run 'aba --help' for available commands."
	echo "See the README.md for more."
}

# -----------------------------------------------------------------------------
# Confirmation dialog for quitting
# -----------------------------------------------------------------------------
confirm_quit() {
	log "User attempting to quit, showing confirmation"
	dialog --backtitle "ABA TUI" --title "$TUI_TITLE_CONFIRM_EXIT" \
		--help-button \
		--yes-label "Exit" \
		--no-label "Continue" \
		--yesno "Exit ABA TUI?\n\nProgress will not be saved unless you complete the wizard." 0 0
	rc=$?
	
	case "$rc" in
		0)
			log "User confirmed quit (clicked Exit)"
			return 0  # Quit confirmed
			;;
		1)
			log "User cancelled quit (clicked Continue)"
			return 1  # Don't quit
			;;
		255)
			log "User pressed ESC again - quitting immediately"
			return 0  # ESC twice = quit
			;;
		2)
			# Help button
			dialog --backtitle "ABA TUI" --msgbox \
"Exiting the TUI:

• Press ESC at any time to quit (with confirmation)
• Press ESC again on confirmation to quit immediately
• Click 'Exit' to confirm and quit
• Click 'Continue' to return to the wizard

Note: Configuration is only saved when you
complete the wizard and apply to aba.conf

Log file: $LOG_FILE" 0 0 || true
			confirm_quit  # Recursive - show again after help
			;;
		*)
			return 1
			;;
	esac
}

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
# LOG_FILE already set at top of script
export LOG_FILE

log "=========================================="
log "ABA TUI started"
log "=========================================="
log "Log file: $LOG_FILE"

# -----------------------------------------------------------------------------
# Sanity checks & auto-install dependencies
# -----------------------------------------------------------------------------
# Derive ABA_ROOT early (needed for install-rpms.sh)
if [[ -z "${ABA_ROOT:-}" ]]; then
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	ABA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
	export ABA_ROOT
fi

# Source shared constants (dialog titles, menu IDs) — single source of truth
# shared with automated tests in test/func/
source "$ABA_ROOT/tui/tui-strings.sh"

# Auto-install required packages (dialog, jq, make, etc.) if missing
"$ABA_ROOT/scripts/install-rpms.sh" external

log "Dependencies installed/verified"

# -----------------------------------------------------------------------------
# Dialog appearance configuration (nmtui-like styling)
# -----------------------------------------------------------------------------
# Enable colors and set dialog options for a cleaner look
export DIALOGRC="${TMPDIR:-/tmp}/.dialogrc.$$"
cat > "$DIALOGRC" <<'EOF'
# Dialog color configuration for a professional nmtui-like appearance
use_colors = ON
use_shadow = OFF

# Color scheme (similar to nmtui)
screen_color = (WHITE,BLUE,ON)
dialog_color = (BLACK,WHITE,OFF)
title_color = (RED,WHITE,ON)
border_color = (BLACK,WHITE,ON)
button_active_color = (WHITE,RED,ON)
button_inactive_color = (BLACK,WHITE,OFF)
button_key_active_color = (WHITE,RED,ON)
button_key_inactive_color = (RED,WHITE,ON)
button_label_active_color = (WHITE,RED,ON)
button_label_inactive_color = (BLACK,WHITE,ON)
inputbox_color = (BLACK,WHITE,OFF)
inputbox_border_color = (BLACK,WHITE,OFF)
searchbox_color = (BLACK,WHITE,OFF)
searchbox_title_color = (RED,WHITE,ON)
searchbox_border_color = (BLACK,WHITE,OFF)
position_indicator_color = (RED,WHITE,ON)
menubox_color = (BLACK,WHITE,OFF)
menubox_border_color = (BLACK,WHITE,OFF)
item_color = (BLACK,WHITE,OFF)
item_selected_color = (WHITE,RED,ON)
tag_color = (RED,WHITE,ON)
tag_selected_color = (WHITE,RED,ON)
tag_key_color = (RED,WHITE,ON)
tag_key_selected_color = (WHITE,RED,ON)
check_color = (BLACK,WHITE,OFF)
check_selected_color = (WHITE,RED,ON)
uarrow_color = (RED,WHITE,ON)
darrow_color = (RED,WHITE,ON)
itemhelp_color = (BLACK,WHITE,OFF)
form_active_text_color = (WHITE,BLUE,ON)
form_text_color = (BLACK,WHITE,OFF)
EOF

# Cleanup dialogrc on exit
trap 'rm -f "$TMP" "$DIALOGRC"; log "ABA TUI exited"' EXIT

# Default dialog options for consistent appearance
DIALOG_OPTS="--no-shadow --colors --aspect 50"
export DIALOG_OPTS

# -----------------------------------------------------------------------------
# Aba runtime init
# -----------------------------------------------------------------------------
WORK_ID="tui-$(date +%Y%m%d%H%M%S)-$$"
export WORK_ID

# Aba repo root (best-effort). If ABA_ROOT isn't set, derive it from this script path.
# This script lives under tui/, so default ABA_ROOT to the parent dir.
if [[ -z "${ABA_ROOT:-}" ]]; then
	ABA_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
	export ABA_ROOT
fi

log "ABA_ROOT: $ABA_ROOT"

# Change to ABA_ROOT so all paths work correctly
cd "$ABA_ROOT" || { log "ERROR: Cannot cd to ABA_ROOT"; exit 1; }
log "Changed to ABA_ROOT"


# shellcheck disable=SC1091
source scripts/include_all.sh

log "Sourced include_all.sh"

# Clean up any previously failed run_once tasks to give user a fresh start
# This prevents cached failures (e.g., temporary network issues) from blocking the TUI
run_once -F 2>/dev/null || true
log "Cleaned up previously failed tasks"

TMP=$(mktemp)
trap 'rm -f "$TMP"; log "ABA TUI exited"' EXIT

log "Temp file: $TMP"

# Get terminal size
read -r TERM_ROWS TERM_COLS < <(stty size 2>/dev/null || echo "24 80")

# -----------------------------------------------------------------------------
# TUI global state variables
# -----------------------------------------------------------------------------
# Retry count for transient failures (applies to save/sync/bundle)
RETRY_COUNT="2"  # Values: "off", "2", "8"

# Registry type selection
ABA_REGISTRY_TYPE="Auto"  # Values: "Auto", "Quay", "Docker"

ui_backtitle() {
	echo "ABA TUI  |  channel: ${OCP_CHANNEL:-?}  version: ${OCP_VERSION:-?}"
}

# Resolve actual registry type based on Auto selection and architecture
get_actual_registry_type() {
	local registry_type="${ABA_REGISTRY_TYPE:-Auto}"
	
	if [[ "$registry_type" == "Auto" ]]; then
		local arch=$(uname -m)
		if [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then
			echo "Docker"
		else
			echo "Quay"
		fi
	else
		echo "$registry_type"
	fi
}

# Wrapper for dialog with consistent styling
dlg() {
	dialog --no-shadow --colors "$@"
}

# Show error from run_once task log with helpful context
# Usage: show_run_once_error "task:id" "User-friendly title"
show_run_once_error() {
	local task_id="$1"
	local title="${2:-Operation Failed}"
	
	# Use run_once API to get stderr and stdout logs
	local stderr_log stdout_log
	stderr_log=$(run_once -e -i "$task_id" 2>/dev/null) || true
	stdout_log=$(run_once -o -i "$task_id" 2>/dev/null) || true
	
	if [[ -z "$stderr_log" && -z "$stdout_log" ]]; then
		dialog --colors --backtitle "$(ui_backtitle)" --msgbox "\Z1$title\Zn

No log output found for task: $task_id

This usually means the task never started.

\Z1If errors persist:\Zn
Clear the cache by running: \Zbcd aba && ./install\ZB" 0 0
		return
	fi
	
	# Extract last meaningful errors from stderr, falling back to stdout
	local log_text="${stderr_log:-$stdout_log}"
	local error_lines=$(echo "$log_text" | tail -30 | grep -iE 'error|fail|fatal|unable|cannot|denied' | tail -8)
	
	# Fallback: just show last few lines if no errors matched
	if [[ -z "$error_lines" ]]; then
		error_lines=$(echo "$log_text" | tail -8)
	fi
	
	dialog --colors --backtitle "$(ui_backtitle)" --msgbox "\Z1$title\Zn

Recent output:
─────────────────────────────────────────
$error_lines
─────────────────────────────────────────

\Z1If errors persist:\Zn
Clear the cache: \Zbcd aba && ./install\ZB

Press OK to return" 0 0
}

# -----------------------------------------------------------------------------
# UI helpers
# -----------------------------------------------------------------------------
check_internet_access() {
	log "Checking internet access to required sites"
	
	# Use shared connectivity check function
	if ! check_internet_connectivity "tui"; then
		# Function sets FAILED_SITES and ERROR_DETAILS
		log "ERROR: No internet access to: $FAILED_SITES"
		dialog --colors --clear --no-collapse --backtitle "$(ui_backtitle)" --title "$TUI_TITLE_INTERNET_REQUIRED" \
			--msgbox \
"\Z1ERROR: Internet access required\Zn

Cannot access: $FAILED_SITES

Error details:
$ERROR_DETAILS

Ensure you have Internet access to download the required images.
To get started with Aba run it on a connected workstation/laptop
with Fedora, RHEL or Centos Stream and try again.

Required sites:                    Other sites:
  mirror.openshift.com               docker.io
  api.openshift.com                  docker.com
  registry.redhat.io                 hub.docker.com
  quay.io and *.quay.io              index.docker.io
  console.redhat.com
  registry.access.redhat.com

Exiting..." 0 0
	
		log "Exiting due to no internet access"
		clear
		exit 1
	fi
	
	log "Internet access verified to all required sites"
}

ui_header() {
	log "Showing header screen"
	
	# Get version from environment or VERSION file
	local aba_version="${ABA_VERSION:-unknown}"
	if [[ -f "$ABA_ROOT/VERSION" ]]; then
		aba_version=$(<"$ABA_ROOT/VERSION")
		aba_version=${aba_version//$'\n'/}  # Remove newlines
		aba_version=${aba_version##[[:space:]]}  # Trim leading whitespace
		aba_version=${aba_version%%[[:space:]]}  # Trim trailing whitespace
	fi
	
	local rc
	while :; do
		dialog --colors --clear --no-collapse --backtitle "$(ui_backtitle)" --title "$TUI_TITLE_WELCOME" \
			--help-button --help-label "Help" \
			--ok-label "Continue" \
			--msgbox \
"\
  __   ____   __
 / _\ (  _ \ / _\     Aba v${aba_version}
/    \ ) _ (/    \    Install & configure
\_/\_/(____/\_/\_/    air-gapped OpenShift quickly!

Follow the setup wizard or see the README.md file for more.
Get help: https://github.com/sjbylo/aba/discussions

Note: Internet access is required.

Navigate with <Tab> and arrow keys. Press <ESC> to quit.
" 0 0
		rc=$?
		
		log "Header dialog returned: $rc"
		
		case "$rc" in
			0)
				# OK pressed - continue
				log "User pressed OK on header"
				break
				;;
			2)
				# Help button pressed - show help and loop back
				log "Help button pressed in header"
				dialog --backtitle "$(ui_backtitle)" --title "$TUI_TITLE_HELP" --msgbox \
"ABA (Agent-Based Automation) helps install OpenShift in disconnected environments.

The wizard guides you through:
  1. OpenShift channel & version selection
  2. Red Hat pull secret validation
  3. Platform configuration (bare-metal/VMware)
  4. Network settings (domain, IPs, DNS, NTP)
  5. Operator selection (highly recommended!)
  6. Choose a deployment path:

     Air-Gapped:  Create a bundle or save images to transfer offline
     Connected:   Install a local or remote mirror registry and sync

Configuration is saved to:
  $ABA_ROOT/aba.conf

After completing this wizard:
  • The TUI will guide you through next steps
  • Run 'aba --help' for more commands

For full documentation:
  $ABA_ROOT/README.md
  https://github.com/sjbylo/aba/blob/main/README.md
  https://github.com/sjbylo/aba/discussions" 0 0 || true
				# Continue loop to show header again
				;;
			255)
				# ESC - confirm quit
			if confirm_quit; then
				log "User quit from header"
				clear
				_show_exit_summary
				exit 0
				else
					log "User cancelled quit, staying on header"
					continue
				fi
				;;
		*)
			# Unexpected return code
			log "ERROR: Unexpected header dialog return code: $rc"
			clear
			exit 1
			;;
	esac
	done
}

# -----------------------------------------------------------------------------
# Resume from aba.conf (best-effort)
# -----------------------------------------------------------------------------
resume_from_conf() {
	log "Resuming from aba.conf"
	
	# If aba.conf doesn't exist, create from template using j2
	if [[ ! -f aba.conf ]]; then
		log "No aba.conf found, creating from template"
		if [[ -f "$ABA_ROOT/templates/aba.conf.j2" ]]; then
			# Detect domain from local system (like aba.sh does)
			export domain=$(get_domain)
			log "Detected domain: $domain"
			
			# Set other variables to empty (will be filled by TUI)
			log "Running: scripts/j2 templates/aba.conf.j2 > aba.conf"
			if machine_network="" dns_servers="" next_hop_address="" ntp_servers="" \
				scripts/j2 templates/aba.conf.j2 > aba.conf 2>>"$LOG_FILE"; then
				log "Created aba.conf from templates/aba.conf.j2"
				log "aba.conf size: $(wc -l < aba.conf) lines"
				
				# Populate with latest stable version so aba.conf is always valid.
				# Version fetches were already started in background at startup.
				log "Waiting for stable:latest version fetch to populate aba.conf"
				run_once -q -w -S -i "ocp:stable:latest_version" 2>>"$LOG_FILE" || true
				local latest_ver
				latest_ver=$(fetch_latest_version stable 2>>"$LOG_FILE") || true
				if [[ -n "$latest_ver" ]]; then
					log "Setting default ocp_version=$latest_ver, ocp_channel=stable"
					replace-value-conf -q -n ocp_version -v "$latest_ver" -f aba.conf
					replace-value-conf -q -n ocp_channel -v "stable"      -f aba.conf
				else
					log "WARNING: Could not fetch latest stable version (no internet?)"
				fi
				# Mark that aba.conf was auto-created this session (not by the user).
				# If the user quits before completing the wizard, _show_exit_summary()
				# will remove this auto-created file to keep a clean slate.
				# The flag is cleared in summary_apply() once the wizard is completed.
				_TUI_FRESH_CONF=1
			else
				log "ERROR: Failed to create aba.conf from template (exit code: $?)"
			fi
		else
			log "WARNING: No template found at $ABA_ROOT/templates/aba.conf.j2"
		fi
	else
		log "aba.conf already exists, size: $(wc -l < aba.conf) lines"
	fi
	
	# Load existing config if present
	if [[ -f aba.conf ]]; then
		log "Found aba.conf, sourcing..."
		# shellcheck disable=SC1091
		source ./aba.conf || true
	else
		log "No aba.conf found"
	fi

	# Prefer aba.conf keys if present
	OCP_CHANNEL=${ocp_channel:-${OCP_CHANNEL:-}}
	OCP_VERSION=${ocp_version:-${OCP_VERSION:-}}
	PLATFORM=${platform:-${PLATFORM:-bm}}
	DOMAIN=${domain:-${DOMAIN:-example.com}}
	MACHINE_NETWORK=${machine_network:-${MACHINE_NETWORK:-}}
	DNS_SERVERS=${dns_servers:-${DNS_SERVERS:-}}
	NEXT_HOP_ADDRESS=${next_hop_address:-${NEXT_HOP_ADDRESS:-}}
	NTP_SERVERS=${ntp_servers:-${NTP_SERVERS:-}}
	
	log "Resumed: channel=$OCP_CHANNEL version=$OCP_VERSION platform=$PLATFORM"

	# Restore operator basket from ops (comma-separated)
	# This is the ONLY basket we maintain.
	# Initialize as GLOBAL associative arrays
	declare -gA OP_BASKET
	declare -gA OP_SET_ADDED
	
	# Clear them (important!)
	OP_BASKET=()
	OP_SET_ADDED=()
	
	log "Initializing global arrays in resume_from_conf"
	
	if [[ -n "${ops:-}" ]]; then
		log "Restoring ops from aba.conf: $ops"
		IFS=',' read -r -a _ops_arr <<<"$ops"
		for op in "${_ops_arr[@]}"; do
			op=${op##[[:space:]]}
			op=${op%%[[:space:]]}
			if [[ -n "$op" ]]; then
				OP_BASKET["$op"]=1
				log "Restored operator: $op"
			fi
		done
	fi
	log "Basket has ${#OP_BASKET[@]} operators after restore"

	if [[ -n "${op_sets:-}" ]]; then
		log "Restoring op_sets from aba.conf: $op_sets"
		IFS=',' read -r -a _set_arr <<<"$op_sets"
		for s in "${_set_arr[@]}"; do
			s=${s##[[:space:]]}  # Remove leading whitespace
			s=${s%%[[:space:]]}  # Remove trailing whitespace
			if [[ -n "$s" ]]; then
				OP_SET_ADDED["$s"]=1
				log "Restored operator set: $s"
				
				# Load operators from this set file into basket
				local set_file="$ABA_ROOT/templates/operator-set-$s"
				if [[ -f "$set_file" ]]; then
					log "Loading operators from $set_file"
					local op_count=0
					while IFS= read -r line; do
						# Skip comments and empty lines
						[[ "$line" =~ ^[[:space:]]*# ]] && continue
						[[ -z "$line" ]] && continue
						
						# Extract operator name (trim whitespace)
						line=${line##[[:space:]]}  # Remove leading whitespace
						line=${line%%[[:space:]]}  # Remove trailing whitespace
						
						if [[ -n "$line" ]]; then
							OP_BASKET["$line"]=1
							((op_count++))
							log "  Added operator from set: $line"
						fi
					done < "$set_file"
					log "Loaded $op_count operators from set '$s'"
				else
					log "WARNING: Operator set file not found: $set_file"
				fi
			fi
		done
	fi
	
	log "Final basket has ${#OP_BASKET[@]} operators after loading from op_sets"
}

# -----------------------------------------------------------------------------
# Check if configuration is complete enough to skip wizard
# Returns 0 if complete, 1 if wizard is needed
# -----------------------------------------------------------------------------
config_is_complete() {
	# Must have channel, version, and a valid pull secret
	[[ -n "${OCP_CHANNEL:-}" ]] || return 1
	[[ -n "${OCP_VERSION:-}" ]] || return 1
	[[ -f "$HOME/.pull-secret.json" ]] || return 1
	validate_pull_secret "$HOME/.pull-secret.json" >/dev/null 2>&1 || return 1
	# Must have a domain
	[[ -n "${DOMAIN:-}" ]] || return 1
	return 0
}

# -----------------------------------------------------------------------------
# Show resume dialog if config is already complete
# Sets STEP to "summary" (skip wizard) or "channel" (run wizard)
# -----------------------------------------------------------------------------
show_resume_dialog() {
	log "Checking if config is complete for resume dialog"
	
	# Skip resume dialog if aba.conf was just created in this session
	if [[ "${_TUI_FRESH_CONF:-}" == "1" ]]; then
		log "Config freshly created this session, running wizard"
		STEP="channel"
		return
	fi

	if ! config_is_complete; then
		log "Config incomplete, running full wizard"
		STEP="channel"
		return
	fi
	
	# Build summary display
	local op_count=${#OP_BASKET[@]}
	local platform_display
	case "${PLATFORM:-}" in
		bm) platform_display="Bare-metal" ;;
		vsphere) platform_display="VMware vSphere" ;;
		*) platform_display="${PLATFORM:-unknown}" ;;
	esac
	
	local _dns_display="${DNS_SERVERS//,/ }"
	local _ntp_display="${NTP_SERVERS//,/ }"
	
	dialog --colors --no-collapse --backtitle "$(ui_backtitle)" --title "$TUI_TITLE_RESUME" \
		--ok-label "Continue" \
		--extra-button --extra-label "Reconfigure" \
		--cancel-label "Exit" \
		--msgbox "\
Current configuration (from aba.conf):

  Channel:      \Zb${OCP_CHANNEL}\Zn
  Version:      \Zb${OCP_VERSION}\Zn
  Platform:     \Zb${platform_display}\Zn
  Domain:       \Zb${DOMAIN}\Zn

  Network:      \Zb${MACHINE_NETWORK:-not set}\Zn
  Default Gw:   \Zb${NEXT_HOP_ADDRESS:-not set}\Zn
  DNS:          \Zb${_dns_display:-not set}\Zn
  NTP:          \Zb${_ntp_display:-not set}\Zn

  Operators:    \Zb${op_count} selected\Zn

Press \ZbContinue\Zn to go to the action menu.
Press \ZbReconfigure\Zn to run the setup wizard again." 0 0
	local rc=$?
	
	case $rc in
		0)
			# Continue - skip to action menu
			log "User chose to continue with existing config"
			STEP="summary"
			;;
		3)
			# Extra button - Reconfigure
			log "User chose to reconfigure"
			STEP="channel"
			;;
		1|255)
			# Cancel/ESC - Exit
			log "User chose to exit from resume dialog"
			clear
			exit 0
			;;
	esac
}

# -----------------------------------------------------------------------------
# Step 1: Select OpenShift channel
# -----------------------------------------------------------------------------
select_ocp_channel() {
	DIALOG_RC=""
	log "Entering select_ocp_channel"

	# Version fetches already started in main flow (after internet check)
	# Just use the cached results here
	
	# Preselect based on resumed value
	local c_state="off" f_state="off" s_state="off"
	case "${OCP_CHANNEL:-stable}" in
		candidate) c_state="on" ;;
		fast) f_state="on" ;;
		stable|"") s_state="on" ;;
	esac

	# Set default item based on current channel
	local default_tag="${OCP_CHANNEL:0:1}"  # First letter: s, f, or c
	[[ -z "$default_tag" ]] && default_tag="s"
	
	dialog --colors --clear --backtitle "$(ui_backtitle)" --title "$TUI_TITLE_CHANNEL" \
		--extra-button --extra-label "Back" \
		--help-button \
		--ok-label "Next" \
		--default-item "$default_tag" \
		--menu "Choose the OpenShift update channel:" 0 0 3 \
		s "stable     – Recommended" \
		f "fast       – Latest GA" \
		c "candidate  – Preview" \
		2>"$TMP"

	rc=$?
	log "Channel dialog returned: $rc"
	
	case "$rc" in
		0)
			# OK/Next
			DIALOG_RC="next"
			;;
		2)
			# Help button
			log "Help button pressed in channel selection"
			dialog --backtitle "$(ui_backtitle)" --msgbox \
"OpenShift Update Channels:

• stable (Recommended)
  GA, tested and recommended for production
  
• fast (Latest GA)
  Latest Generally Available release
  
• candidate (Preview)
  Preview/beta releases for testing

See: https://docs.openshift.com/container-platform/latest/updating/understanding_updates/understanding-update-channels-release.html" 0 0 || true
			DIALOG_RC="repeat"
			return
			;;
		3|1|255)
			# Back/Cancel/ESC
			DIALOG_RC="back"
			log "User went back from channel (rc=$rc)"
			return 0
			;;
		*)
			DIALOG_RC="back"
			return 0
			;;
	esac

	choice=$(<"$TMP")
	case "$choice" in
		c) OCP_CHANNEL="candidate" ;;
		f) OCP_CHANNEL="fast" ;;
		s|"") OCP_CHANNEL="stable" ;;
		*) OCP_CHANNEL="stable" ;;
	esac
	
	log "Selected channel: $OCP_CHANNEL"

	DIALOG_RC="next"
}

# -----------------------------------------------------------------------------
# Step 2: Select OpenShift version
# -----------------------------------------------------------------------------
select_ocp_version() {
	DIALOG_RC=""
	log "Entering select_ocp_version"

	# Ensure we have a channel
	[[ -z "${OCP_CHANNEL:-}" ]] && OCP_CHANNEL="stable"

	# Check if cached version tasks exist and if they FAILED (non-zero exit code)
	# If so, reset them and retry automatically
	local need_reset=0 exit_code
	
	if exit_code=$(run_once -E -i "ocp:${OCP_CHANNEL}:latest_version" 2>/dev/null); then
		if [[ "$exit_code" != "0" ]]; then
			log "Cached task ocp:${OCP_CHANNEL}:latest_version has failed (exit $exit_code) - will reset and retry"
			need_reset=1
		fi
	fi
	if exit_code=$(run_once -E -i "ocp:${OCP_CHANNEL}:latest_version_previous" 2>/dev/null); then
		if [[ "$exit_code" != "0" ]]; then
			log "Cached task ocp:${OCP_CHANNEL}:latest_version_previous has failed (exit $exit_code) - will reset and retry"
			need_reset=1
		fi
	fi
	if exit_code=$(run_once -E -i "ocp:${OCP_CHANNEL}:latest_version_older" 2>/dev/null); then
		if [[ "$exit_code" != "0" ]]; then
			log "Cached task ocp:${OCP_CHANNEL}:latest_version_older has failed (exit $exit_code) - will reset and retry"
			need_reset=1
		fi
	fi
	
	# Reset failed caches
	if [[ $need_reset -eq 1 ]]; then
		log "Resetting failed version fetch caches for channel $OCP_CHANNEL"
		run_once -r -i "ocp:${OCP_CHANNEL}:latest_version"
		run_once -r -i "ocp:${OCP_CHANNEL}:latest_version_previous"
		run_once -r -i "ocp:${OCP_CHANNEL}:latest_version_older"
	fi

	# Peek first to see if we need to wait
	log "Checking if version data is ready for channel: $OCP_CHANNEL"
	local need_wait=0
	if ! run_once -p -i "ocp:${OCP_CHANNEL}:latest_version"; then
		log "Latest version not ready"
		need_wait=1
	fi
	if ! run_once -p -i "ocp:${OCP_CHANNEL}:latest_version_previous"; then
		log "Previous version not ready"
		need_wait=1
	fi
	if ! run_once -p -i "ocp:${OCP_CHANNEL}:latest_version_older"; then
		log "Older version not ready"
		need_wait=1
	fi
	
	# Only show wait dialog if actually waiting
	if [[ $need_wait -eq 1 ]]; then
		log "Version data not ready, showing wait dialog"
		dialog --backtitle "$(ui_backtitle)" --infobox "Fetching version data for channel '$OCP_CHANNEL'...\n\nPlease wait..." 6 55
		# Start tasks in background (if not already running), then wait.
		# Two-step start+wait avoids foreground mode which leaks stdout to terminal.
		run_once    -i "ocp:${OCP_CHANNEL}:latest_version"          -- bash -lc "source ./scripts/include_all.sh; fetch_latest_version $OCP_CHANNEL"
		run_once    -i "ocp:${OCP_CHANNEL}:latest_version_previous" -- bash -lc "source ./scripts/include_all.sh; fetch_previous_version $OCP_CHANNEL"
		run_once    -i "ocp:${OCP_CHANNEL}:latest_version_older"    -- bash -lc "source ./scripts/include_all.sh; fetch_older_version $OCP_CHANNEL"
		run_once -q -w -S -i "ocp:${OCP_CHANNEL}:latest_version"
		run_once -q -w -S -i "ocp:${OCP_CHANNEL}:latest_version_previous"
		run_once -q -w -S -i "ocp:${OCP_CHANNEL}:latest_version_older"
	else
		log "Version data already available, no wait needed"
	fi

	# Capture ONLY stderr to temp file, discard stdout
	# Note: fetch functions read from run_once cache, so don't redirect their stderr
	latest=$(fetch_latest_version "$OCP_CHANNEL")
	previous=$(fetch_previous_version "$OCP_CHANNEL")
	older=$(fetch_older_version "$OCP_CHANNEL")
	log "Versions: latest=$latest previous=$previous older=$older"
	
	# Check if version fetch failed (older is optional - N-2 may not exist)
	if [[ -z "$latest" || -z "$previous" ]]; then
		log "ERROR: Failed to fetch version data for channel $OCP_CHANNEL"
		
		# Extract error from run_once stderr (clean interface via -e flag)
		local error_detail=""
		error_detail=$(run_once -e -i "ocp:${OCP_CHANNEL}:latest_version" | head -1)
		if [[ -z "$error_detail" ]]; then
			error_detail=$(run_once -e -i "ocp:${OCP_CHANNEL}:latest_version_previous" | head -1)
		fi
		
		# Log what we found
		if [[ -n "$error_detail" ]]; then
			log "Error details: $error_detail"
		else
			log "No specific error details found"
		fi
		
		# Build error message
		local error_msg="\Z1Failed to fetch OpenShift version data!\Zn

Channel: $OCP_CHANNEL"
		
		if [[ -n "$error_detail" ]]; then
			error_msg+="

Error:
  $error_detail"
		fi
		
		error_msg+="

This may mean:
• Graph API is unreachable
• Network connectivity issue
• Invalid channel

Check log file for details:
  $LOG_FILE

What would you like to do?"
		
		dialog --colors --backtitle "$(ui_backtitle)" --title "$TUI_TITLE_VERSION_FETCH_FAILED" \
			--yes-label "Retry" \
			--no-label "Back" \
			--yesno "$error_msg" 0 0
		rc=$?
		
		case $rc in
			0)
				# Retry - clear cache, re-run, and try again
				log "User chose to retry version fetch"
				run_once -r -i "ocp:${OCP_CHANNEL}:latest_version"
				run_once -r -i "ocp:${OCP_CHANNEL}:latest_version_previous"
				run_once -r -i "ocp:${OCP_CHANNEL}:latest_version_older"
				
			# Show wait dialog and re-run the fetches
			dialog --backtitle "$(ui_backtitle)" --infobox "Retrying version fetch for channel '$OCP_CHANNEL'...\n\nPlease wait..." 6 55
			run_once -i "ocp:${OCP_CHANNEL}:latest_version" -- bash -lc "source ./scripts/include_all.sh; fetch_latest_version $OCP_CHANNEL"
			run_once -i "ocp:${OCP_CHANNEL}:latest_version_previous" -- bash -lc "source ./scripts/include_all.sh; fetch_previous_version $OCP_CHANNEL"
			run_once -i "ocp:${OCP_CHANNEL}:latest_version_older" -- bash -lc "source ./scripts/include_all.sh; fetch_older_version $OCP_CHANNEL"
			run_once -q -w -S -i "ocp:${OCP_CHANNEL}:latest_version"
			run_once -q -w -S -i "ocp:${OCP_CHANNEL}:latest_version_previous"
			run_once -q -w -S -i "ocp:${OCP_CHANNEL}:latest_version_older"
				
				DIALOG_RC="repeat"
				return
				;;
			*)
				# Back
				log "User chose to go back after version fetch failure"
				DIALOG_RC="back"
				return
				;;
		esac
	fi

	# Check if current version is different from latest/previous AND exists in this channel
	local show_current=0
	local default_item="l"  # Default to latest
	
	if [[ -n "$OCP_VERSION" ]]; then
		if [[ "$OCP_VERSION" == "$latest" ]]; then
			default_item="l"
		elif [[ "$OCP_VERSION" == "$previous" ]]; then
			default_item="p"
		elif [[ -n "$older" && "$OCP_VERSION" == "$older" ]]; then
			default_item="o"
		else
			# Current version is different - but does it exist in this channel?
			log "Checking if current version $OCP_VERSION exists in channel $OCP_CHANNEL"
			
			# Validate that the version exists in this channel by checking Cincinnati API
			# Use the same logic as aba uses: check if version is available
			local version_exists=0
			if "$ABA_ROOT/scripts/ocp-version-validate" "$OCP_CHANNEL" "$OCP_VERSION" >/dev/null 2>&1; then
				version_exists=1
				log "Version $OCP_VERSION exists in channel $OCP_CHANNEL"
			else
				log "Version $OCP_VERSION does NOT exist in channel $OCP_CHANNEL - will not show in menu"
			fi
			
			if [[ $version_exists -eq 1 ]]; then
				# Show current version - it's valid for this channel
				show_current=1
				default_item="c"
			else
				# Don't show current version - it doesn't exist in this channel
				# Default to latest instead
				show_current=0
				default_item="l"
			fi
		fi
		log "Current version: $OCP_VERSION, show_current=$show_current, default selection: $default_item"
	fi

	# Build menu items dynamically
	local menu_items=()
	menu_items+=("l" "Latest   ($latest)")
	menu_items+=("p" "Previous ($previous)")
	if [[ -n "$older" ]]; then
		menu_items+=("o" "Older    ($older)")
	fi
	
	if [[ $show_current -eq 1 ]]; then
		menu_items+=("c" "Current  ($OCP_VERSION)")
	fi
	
	menu_items+=("m" "Manual entry (x.y or x.y.z)")

	dialog --colors --clear --backtitle "$(ui_backtitle)" --title "$TUI_TITLE_VERSION" \
		--extra-button --extra-label "Back" \
		--help-button \
		--ok-label "Next" \
		--default-item "$default_item" \
		--menu "Choose the OpenShift version to install:" 0 0 7 \
		"${menu_items[@]}" \
		2>"$TMP"

	rc=$?
	log "Version dialog returned: $rc"
	
	case "$rc" in
		0)
			# OK/Next
			: # Continue to process choice
			;;
		2)
			# Help button
			log "Help button pressed in version selection"
			local help_text="OpenShift Version Selection:

• Latest: Most recent release in the channel (N)
• Previous: Previous minor release (N-1)"
			
			if [[ -n "$older" ]]; then
				help_text="${help_text}
• Older: Older minor release (N-2)"
			fi
			
			if [[ $show_current -eq 1 ]]; then
				help_text="${help_text}
• Current: Version from aba.conf ($OCP_VERSION)"
			fi
			
			help_text="${help_text}
• Manual: Enter specific version (x.y or x.y.z)

Example versions: 4.18.10 or 4.18

The installer will validate the selected version."
			
			dialog --backtitle "$(ui_backtitle)" --msgbox "$help_text" 0 0 || true
			DIALOG_RC="repeat"
			return
			;;
		3|1)
			# Back/Cancel
			DIALOG_RC="back"
			log "User went back from version (rc=$rc)"
			return
			;;
		255)
			# ESC - confirm quit
			if confirm_quit; then
				log "User confirmed quit from version screen"
				clear
				_show_exit_summary
				exit 0
			else
				log "User cancelled quit, staying on version screen"
				DIALOG_RC="repeat"
				return
			fi
			;;
		*)
			DIALOG_RC="back"
			return
			;;
	esac

	choice=$(<"$TMP")
	case "$choice" in
		l|"") OCP_VERSION="$latest" ;;
		p) OCP_VERSION="$previous" ;;
		o) OCP_VERSION="$older" ;;
		c) 
			# Keep current version (already in OCP_VERSION)
			log "User selected current version: $OCP_VERSION"
			;;
		m)
			# Loop until valid version is entered
			while true; do
				dialog --backtitle "$(ui_backtitle)" --inputbox "Enter OpenShift version (x.y or x.y.z):" 12 70 "$latest" 2>"$TMP" || { DIALOG_RC="back"; return; }
				OCP_VERSION=$(<"$TMP")
				OCP_VERSION=${OCP_VERSION//$'
'/}
				OCP_VERSION=${OCP_VERSION##[[:space:]]}
				OCP_VERSION=${OCP_VERSION%%[[:space:]]}

				if [[ "$OCP_VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
					# x.y format - resolve to latest z-stream (validates existence)
					local input_minor="$OCP_VERSION"
					log "Detected x.y format, resolving: $OCP_VERSION"
					run_once -i "ocp:${OCP_CHANNEL}:${OCP_VERSION}:latest_z" -- \
					bash -lc 'source ./scripts/include_all.sh; fetch_latest_z_version "'$OCP_CHANNEL'" "'$OCP_VERSION'"'
				dialog --backtitle "$(ui_backtitle)" --infobox "Resolving $OCP_VERSION to latest z-stream...\n\nPlease wait..." 6 55
				run_once -q -w -S -i "ocp:${OCP_CHANNEL}:${OCP_VERSION}:latest_z"
				OCP_VERSION=$(fetch_latest_z_version "$OCP_CHANNEL" "$OCP_VERSION")
					
					if [[ -n "$OCP_VERSION" ]]; then
						log "Resolved to full version: $OCP_VERSION"
						break
					else
						# Minor version doesn't exist
						dialog --colors --backtitle "$(ui_backtitle)" --msgbox "\Z1Version not found!\Zn

Version: $input_minor
Channel: $OCP_CHANNEL

This version is either invalid or does not exist.

Try:
  • Latest: $latest
  • Previous: $previous
  • Or enter a different version" 0 0 || true
						# Loop continues
					fi
				elif [[ "$OCP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
					# x.y.z format - validate using Cincinnati graph (cached)
					local minor="${OCP_VERSION%.*}"  # 4.18.10 → 4.18
					log "Detected x.y.z format, validating: $OCP_VERSION (minor: $minor)"
					dialog --backtitle "$(ui_backtitle)" --infobox "Verifying $OCP_VERSION in $OCP_CHANNEL channel..." 5 80
					
					# Fetch all versions for this channel-minor (may fail if minor doesn't exist)
					local all_versions
					if all_versions=$(fetch_all_versions "$OCP_CHANNEL" "$minor" 2>/dev/null) && [[ -n "$all_versions" ]]; then
						log "Fetched $(echo "$all_versions" | wc -l) versions for $OCP_CHANNEL/$minor"
						if echo "$all_versions" | grep -qx "$OCP_VERSION"; then
							# Version exists - validated successfully
							log "User entered valid full version: $OCP_VERSION"
							break
						else
							# Version not found in the version list
							log "Version $OCP_VERSION not found in version list"
							dialog --colors --backtitle "$(ui_backtitle)" --msgbox "\Z1Version not found!\Zn

Version: $OCP_VERSION
Channel: $OCP_CHANNEL

This version is either invalid or does not exist.

Try:
  • Latest: $latest
  • Previous: $previous
  • Or enter a different version" 0 0 || true
							# Loop continues
						fi
					else
						# Minor version doesn't exist or fetch failed
						log "Failed to fetch versions for $OCP_CHANNEL/$minor (minor doesn't exist)"
						dialog --colors --backtitle "$(ui_backtitle)" --msgbox "\Z1Version not found!\Zn

Version: $OCP_VERSION
Channel: $OCP_CHANNEL

OpenShift $minor does not exist or does not exist.

Try:
  • Latest: $latest
  • Previous: $previous
  • Or enter a different version" 0 0 || true
						# Loop continues
					fi
				else
					# Invalid format
					log "Invalid format entered: $OCP_VERSION"
					dialog --colors --backtitle "$(ui_backtitle)" --msgbox "\Z1Invalid version format!\Zn

Entered: $OCP_VERSION

Please enter:
  • x.y format (e.g., 4.18)
  • x.y.z format (e.g., 4.18.10)

Try again." 0 0 || true
					# Loop continues
				fi
			done
			;;
		*) OCP_VERSION="$latest" ;;
	esac

	# Confirmation (prevents the "blank version" confusion)
	log "Selected version: $OCP_VERSION"
	
	# Write minimal aba.conf immediately so background tasks can read it
	# (make catalog reads from aba.conf)
	log "Ensuring aba.conf exists for background tasks"
	
	# If aba.conf doesn't exist, create from template using j2
	if [[ ! -f "$ABA_ROOT/aba.conf" ]]; then
		log "aba.conf not found, creating from template"
		if [[ -f "$ABA_ROOT/templates/aba.conf.j2" ]]; then
			# Detect domain from local system (other network values auto-detected later in disconnected env)
			export domain=$(get_domain)
			log "Detected domain: $domain"
			
			# Other network values left empty (will be auto-detected in disconnected env)
			log "Running: scripts/j2 templates/aba.conf.j2 > aba.conf"
			if machine_network="" dns_servers="" next_hop_address="" ntp_servers="" \
				scripts/j2 templates/aba.conf.j2 > "$ABA_ROOT/aba.conf" 2>>"$LOG_FILE"; then
				log "Created aba.conf from templates/aba.conf.j2"
				log "aba.conf size: $(wc -l < "$ABA_ROOT/aba.conf") lines"
			else
				log "ERROR: Failed to create aba.conf from template (exit code: $?)"
				dialog --backtitle "$(ui_backtitle)" --msgbox "ERROR: Failed to create aba.conf from template!" 0 0
				return 1
			fi
		else
			log "ERROR: Template not found at $ABA_ROOT/templates/aba.conf.j2"
			dialog --backtitle "$(ui_backtitle)" --msgbox "ERROR: Template file templates/aba.conf.j2 not found!" 0 0
			return 1
		fi
	else
		log "aba.conf already exists, size: $(wc -l < "$ABA_ROOT/aba.conf") lines"
	fi
	
	# Use replace-value-conf to set values (use -q for quiet mode)
	replace-value-conf -q -n ocp_channel -v "${OCP_CHANNEL}" -f "$ABA_ROOT/aba.conf" || {
		log "ERROR: Failed to set ocp_channel"
		false
	}
	replace-value-conf -q -n ocp_version -v "${OCP_VERSION}" -f "$ABA_ROOT/aba.conf" || {
		log "ERROR: Failed to set ocp_version"
		false
	}
	replace-value-conf -q -n platform -v "${PLATFORM:-bm}" -f "$ABA_ROOT/aba.conf" || {
		log "ERROR: Failed to set platform"
		false
	}
	
	log "aba.conf updated successfully"
	
	dialog --backtitle "$(ui_backtitle)" --title "$TUI_TITLE_CONFIRM" \
		--yes-label "Next" \
		--no-label "Back" \
		--yesno "Selected:

  Channel: $OCP_CHANNEL
  Version: $OCP_VERSION" 0 0
	rc=$?
	
	case "$rc" in
		0)
		# Yes/Next - User confirmed, now start background downloads
		log "User confirmed version selection, starting background downloads"
		local version_short="${OCP_VERSION%.*}"  # 4.20.8 -> 4.20
		
		# Now that ocp_version is in aba.conf, download ALL CLIs (needs version)
		log "Starting all CLI downloads (aba.conf now has ocp_version)"
		"$ABA_ROOT/scripts/cli-download-all.sh" >>"$LOG_FILE" 2>&1
		
		# Start catalog downloads (oc-mirror already downloading from early in startup)
		log "Starting parallel catalog downloads for OCP ${OCP_VERSION} (${version_short})"
		# Use helper function with 1-day TTL (86400 seconds)
		# Suppress stdout/stderr to prevent flash (errors go to log file)
		download_all_catalogs "$version_short" 86400 >>"$LOG_FILE" 2>&1
			
			DIALOG_RC="next"
			;;
		1|255)
			# No/Back or ESC
			DIALOG_RC="back"
			;;
		*)
			# Unexpected
			DIALOG_RC="next"
			;;
	esac
}

# -----------------------------------------------------------------------------
# Step 3: Pull Secret Validation
# -----------------------------------------------------------------------------
select_pull_secret() {
	local allow_skip="${1:-}"
	DIALOG_RC=""
	log "Entering select_pull_secret (allow_skip=$allow_skip)"
	
	local pull_secret_file="$HOME/.pull-secret.json"
	local error_msg=""
	
	# Check if pull secret exists and is valid (for status display, but don't auto-skip)
	if [[ -f "$pull_secret_file" ]]; then
		log "Found existing pull secret at $pull_secret_file"
		
		# Validate JSON
		if jq empty "$pull_secret_file" 2>/dev/null; then
			# Check for required registry
			if grep -q "registry.redhat.io" "$pull_secret_file"; then
				log "Pull secret is valid"
				# Don't auto-skip - show screen so user can go back if needed
				error_msg=""  # Valid pull secret, no error
			else
				log "Pull secret missing registry.redhat.io"
				error_msg="[red]ERROR: Existing Pull Secret Invalid[/red]

Found pull secret at: $pull_secret_file

Problem: Missing 'registry.redhat.io' credentials

Please paste a valid pull secret."
			fi
		else
			log "Pull secret is not valid JSON"
			error_msg="[red]ERROR: Existing Pull Secret Invalid[/red]

Found pull secret at: $pull_secret_file

Problem: Not valid JSON format

Please paste a valid pull secret."
		fi
	else
		log "No pull secret found at $pull_secret_file"
	fi
	
	# If pull secret is already valid, skip confirmation and proceed (only when moving forward)
	if [[ -f "$pull_secret_file" ]] && [[ -z "$error_msg" ]] && [[ "$allow_skip" == "allow_skip" ]]; then
		log "Valid pull secret exists, auto-proceeding to next step"
		DIALOG_RC="next"
		return
	fi
	
	# If valid but not auto-skipping (came from Back), show info and allow Back
	if [[ -f "$pull_secret_file" ]] && [[ -z "$error_msg" ]]; then
		log "Valid pull secret exists, showing info (user can go back)"
		dialog --colors --backtitle "$(ui_backtitle)" --title "$TUI_TITLE_PULL_SECRET" \
			--yes-label "Next" \
			--no-label "Back" \
			--yesno "\Z2✓ Valid Pull Secret Found\Zn

Location: ~/.pull-secret.json

Your Red Hat pull secret is valid and ready to use." 0 0
		rc=$?
		
		case "$rc" in
			0)
				# Yes/Next
				DIALOG_RC="next"
				return
				;;
			1)
				# No/Back
				DIALOG_RC="back"
				return
				;;
			255)
				# ESC - treat as back
				DIALOG_RC="back"
				return
				;;
		esac
	fi
	
	# Collect pull secret from user (simplified flow)
	local _showed_instructions=0
	while :; do
		# Show error message if there was a validation issue
		if [[ -n "$error_msg" ]]; then
			# Use dialog's auto-sizing (0 0 = auto height/width)
			dialog --colors --clear --backtitle "$(ui_backtitle)" --title "$TUI_TITLE_VALIDATION_ERROR" \
				--msgbox "$error_msg" 0 0 || true
			error_msg=""  # Clear for next iteration
		elif [[ $_showed_instructions -eq 0 ]]; then
			# Show instructions on first visit (no error, no existing pull secret)
			_showed_instructions=1
			dialog --colors --backtitle "$(ui_backtitle)" --title "$TUI_TITLE_PULL_SECRET" \
				--ok-label "Continue" \
				--msgbox "Paste your Red Hat pull secret into the next screen.

Get your pull secret from:
  https://console.redhat.com/openshift/downloads#tool-pull-secret
  (select \ZbTokens\Zn in the pull-down)

Copy the entire JSON text and paste it into the editor." 0 0 || true
		fi
		
		# Show editbox for paste - BLANK, large size
		# Use full terminal size or max reasonable size
		local dlg_h=$((TERM_ROWS - 4))
		local dlg_w=$((TERM_COLS - 4))
		
		log "Terminal size: ${TERM_ROWS}x${TERM_COLS}, calculated dialog: ${dlg_h}x${dlg_w}"
		
		# Enforce minimums and maximums
		[[ $dlg_h -lt 25 ]] && dlg_h=25
		[[ $dlg_h -gt 50 ]] && dlg_h=50
		[[ $dlg_w -lt 80 ]] && dlg_w=80
		[[ $dlg_w -gt 120 ]] && dlg_w=120
		
		log "Final dialog size: ${dlg_h}x${dlg_w}"
		
		# Create empty temp file for editbox
		local empty_file=$(mktemp)
		echo "" > "$empty_file"
		
		# Show editbox - title tells user what to do
		dialog --colors --clear --backtitle "$(ui_backtitle)" --title "$TUI_TITLE_PULL_SECRET_PASTE" \
			--no-cancel \
			--extra-button --extra-label "Back" \
			--help-button --help-label "Clear" \
			--ok-label "Next" \
			--editbox "$empty_file" $dlg_h $dlg_w 2>"$TMP"
		
		rc=$?
		rm -f "$empty_file"
		log "Pull secret editbox returned: $rc"
		
		# Handle ESC - confirm quit
		if [[ $rc -eq 255 ]]; then
			log "User pressed ESC"
			if confirm_quit; then
				log "User confirmed quit from pull secret screen"
				clear
				_show_exit_summary
				exit 0
			else
				log "User cancelled quit, staying on pull secret screen"
				continue
			fi
		fi
		
		case "$rc" in
			0)
				# Next - validate and save
				log "User clicked Next, validating pull secret"
				local pull_secret=$(<"$TMP")
				
				# Check if empty
			if [[ -z "$pull_secret" || "$pull_secret" =~ ^[[:space:]]*$ ]]; then
				error_msg="\Z1ERROR: Pull secret is empty\Zn

Please paste your pull secret and press <Next>.

Get it from:
  https://console.redhat.com/openshift/downloads#tool-pull-secret
  (select 'Tokens' in the pull-down)"
				log "User didn't paste anything, showing error"
				continue
			fi
				
				# Validate the pasted content
				if echo "$pull_secret" | jq empty 2>/dev/null; then
					if echo "$pull_secret" | grep -q "registry.redhat.io"; then
						# Valid JSON with registry.redhat.io! Save it
						echo "$pull_secret" > "$pull_secret_file"
						chmod 600 "$pull_secret_file"
						log "Pull secret saved successfully to $pull_secret_file"
						
			# Validate pull secret by testing authentication
			dialog --backtitle "$(ui_backtitle)" --infobox "Validating pull secret...\n\nTesting authentication with registry.redhat.io" 6 60
				
				# Capture only stderr (errors), discard stdout (success messages)
				local validation_error
				validation_error=$(validate_pull_secret "$pull_secret_file" 2>&1 >/dev/null)
				local validation_rc=$?
				
				if [[ $validation_rc -eq 0 ]]; then
			log "Pull secret validation successful"
			# Show success message briefly before proceeding
			dialog --colors --backtitle "$(ui_backtitle)" --infobox "\Z2Pull secret validated!\Zn\n\nAuthentication successful." 5 60
			sleep 1
					DIALOG_RC="next"
					return
				else
					log "Pull secret validation failed: $validation_error"
					
					dialog --colors --backtitle "$(ui_backtitle)" --title "$TUI_TITLE_PULL_SECRET_VALIDATION_FAILED" \
						--yes-label "Try Again" \
						--no-label "Continue Anyway" \
						--yesno "\Z1Pull secret authentication failed!\Zn

The pull secret was saved but could not authenticate with:
  registry.redhat.io

Error:
$validation_error

This may mean:
• Pull secret is expired (download new from console.redhat.com)
• Invalid credentials  
• Network/DNS issue

\ZbWhat would you like to do?\Zn" 0 0
					rc=$?
					
					case $rc in
						0)
							# Try again - stay in loop
							log "User chose to re-enter pull secret"
							rm -f "$pull_secret_file"
							continue
							;;
						1)
							# Continue anyway
							log "User chose to continue with unvalidated pull secret"
							DIALOG_RC="next"
							return
							;;
					esac
				fi
				else
					log "Pull secret missing registry.redhat.io"
					error_msg="\Z1ERROR: Invalid Pull Secret\Zn

The pull secret does not contain 'registry.redhat.io'.

Please copy the complete pull secret from:
  https://console.redhat.com/openshift/downloads#tool-pull-secret
  (select 'Tokens' in the pull-down)"
					continue
				fi
			else
				log "Pull secret is not valid JSON"
				error_msg="\Z1ERROR: Invalid JSON Format\Zn

The pasted content is not valid JSON.

Please copy the ENTIRE pull secret from the Red Hat console.
It should start with { and end with }

Get it from:
  https://console.redhat.com/openshift/downloads#tool-pull-secret
  (select 'Tokens' in the pull-down)"
			continue
		fi
			;;
		2)
			# Clear button - just loop back to show empty editbox again
			log "Clear button pressed, restarting pull secret entry"
			error_msg=""  # Clear any error messages
			continue
			;;
		3|255)
			# Back/ESC
			DIALOG_RC="back"
				log "User went back from pull secret (rc=$rc)"
				return
				;;
			*)
				DIALOG_RC="back"
				return
				;;
		esac
	done
}

# -----------------------------------------------------------------------------
# Step 4: Platform and Network Configuration
# -----------------------------------------------------------------------------
select_platform_network() {
	DIALOG_RC=""
	log "Entering select_platform_network"

	# Track cursor position for menu navigation
	local default_item="${1:-2}"  # Start at option 2 (Base Domain) or use passed value

	while :; do
		# Use auto-sizing for better fit
		log "Showing platform menu dialog..."
		log "  DLG_H=$dlg_h DLG_W=$dlg_w"
		log "  PLATFORM=${PLATFORM:-bm}"
		log "  DOMAIN=${DOMAIN:-example.com}"
		log "  MACHINE_NETWORK=${MACHINE_NETWORK:-(auto-detect)}"
		log "  DNS_SERVERS=${DNS_SERVERS:-(auto-detect)}"
		log "  NEXT_HOP_ADDRESS=${NEXT_HOP_ADDRESS:-(auto-detect)}"
		log "  NTP_SERVERS=${NTP_SERVERS:-(auto-detect)}"
		log "  default_item=$default_item"
		
		log "About to show platform menu dialog..."
		log "TMP file: $TMP"
		
		# Display multi-value fields with spaces for readability (stored with commas)
		local _dns_display="${DNS_SERVERS:-(auto-detect)}"
		local _ntp_display="${NTP_SERVERS:-(auto-detect)}"
		[[ "$_dns_display" != "(auto-detect)" ]] && _dns_display="${_dns_display//,/ }"
		[[ "$_ntp_display" != "(auto-detect)" ]] && _ntp_display="${_ntp_display//,/ }"

		dialog --colors --backtitle "$(ui_backtitle)" --title "$TUI_TITLE_PLATFORM" \
			--cancel-label "Back" \
			--help-button \
			--ok-label "Select" \
			--extra-button --extra-label "Next" \
			--default-item "$default_item" \
			--menu "Select an item to edit, then press Next to continue." 0 0 6 \
			1 "Platform: ${PLATFORM:-bm}" \
			2 "Base Domain: ${DOMAIN:-example.com}" \
			3 "Machine Network: ${MACHINE_NETWORK:-(auto-detect)}" \
			4 "DNS Servers: ${_dns_display}" \
			5 "Default Route: ${NEXT_HOP_ADDRESS:-(auto-detect)}" \
			6 "NTP Servers: ${_ntp_display}" \
			2>"$TMP"
		rc=$?
		
		log "Platform menu dialog COMPLETED, rc=$rc"
		
		log "Platform menu dialog returned: $rc"
		log "TMP file contents: $(cat "$TMP" 2>/dev/null || echo '(empty)')"
		
		case "$rc" in
			0)
				# Item selected, handle action
				action=$(<"$TMP")
				log "Platform menu action selected: $action"
				;;
			1)
				# Cancel button (Back)
				DIALOG_RC="back"
				log "User went back from platform (rc=$rc)"
				return
				;;
			255)
				# ESC - confirm quit
				if confirm_quit; then
					log "User confirmed quit from platform screen"
					clear
					_show_exit_summary
					exit 0
				else
					log "User cancelled quit, staying on platform screen"
					continue
				fi
				;;
			2)
				# Help button
				dialog --backtitle "$(ui_backtitle)" --msgbox \
"Platform & Network Configuration:

• Platform: bm (bare-metal) or vmw (VMware)
• Base Domain: DNS domain for cluster (e.g., example.com)
• Machine Network: CIDR for cluster nodes (e.g., 10.0.0.0/24)
• DNS Servers: IPs separated by spaces (e.g., 8.8.8.8 1.1.1.1)
• Default Route: Gateway IP for cluster network
• NTP Servers: IPs or hostnames separated by spaces (e.g., pool.ntp.org 10.0.1.8)

Leave blank to use auto-detected values." 0 0 || true
				continue
				;;
			3)
				# Extra button = "Next"
				DIALOG_RC="next"
				log "User accepted platform config and moved to next (rc=$rc)"
				return
				;;
			*)
				# Unexpected return code
				log "ERROR: Unexpected dialog return code: $rc"
				DIALOG_RC="back"
				return
				;;
		esac
		
		# If we got here, rc=0 and we have an action to handle
		log "Platform menu action selected: $action"
		case "$action" in
		1)
			# Toggle platform between bm and vmw
			log "Toggling platform"
			case "${PLATFORM:-bm}" in
				bm)
					PLATFORM="vmw"
					log "Platform toggled to vmw"
					;;
				vmw)
					PLATFORM="bm"
					log "Platform toggled to bm"
					;;
			esac
			default_item="$action"  # Keep cursor on Platform
			;;
			2)
				log "Showing domain inputbox"
				while :; do
					dialog --backtitle "$(ui_backtitle)" --inputbox "Base Domain (e.g., example.com):" 10 70 "$DOMAIN" 2>"$TMP" || { log "Domain input cancelled"; break; }
					input=$(<"$TMP")
					input=${input##[[:space:]]}
					input=${input%%[[:space:]]}
					
					if [[ -n "$input" ]] && ! validate_domain "$input"; then
						dialog --backtitle "$(ui_backtitle)" --msgbox "Invalid domain format. Please enter a valid domain name (e.g., example.com)" 0 0
						continue
					fi
					DOMAIN="$input"
					log "Domain set to: $DOMAIN"
					break
				done
				default_item="$action"  # Keep cursor on Base Domain
				;;
			3)
				log "Showing machine network inputbox"
				while :; do
					dialog --backtitle "$(ui_backtitle)" --inputbox "Machine Network CIDR (e.g., 10.0.0.0/24):" 10 70 "$MACHINE_NETWORK" 2>"$TMP" || { log "Machine network input cancelled"; break; }
					input=$(<"$TMP")
					input=${input##[[:space:]]}
					input=${input%%[[:space:]]}
					
					# Allow empty (auto-detect) or valid CIDR
					if [[ -n "$input" ]] && ! validate_cidr "$input"; then
						dialog --backtitle "$(ui_backtitle)" --msgbox "Invalid CIDR format. Please enter a valid CIDR (e.g., 10.0.0.0/24)" 0 0
						continue
					fi
					MACHINE_NETWORK="$input"
					log "Machine network set to: $MACHINE_NETWORK"
					break
				done
				default_item="$action"  # Keep cursor on Machine Network
				;;
			4)
				log "Showing DNS servers inputbox"
				while :; do
					# Show space-separated in the input box for readability
					local _dns_edit="${DNS_SERVERS//,/ }"
					dialog --backtitle "$(ui_backtitle)" --inputbox "DNS Servers (space or comma-separated IPs):" 10 70 "$_dns_edit" 2>"$TMP" || { log "DNS input cancelled"; break; }
					input=$(<"$TMP")
					input=${input##[[:space:]]}
					input=${input%%[[:space:]]}
					
					# Normalize: replace spaces/commas with single commas
					if [[ -n "$input" ]]; then
						input="${input//,/ }"          # commas -> spaces
						input=$(echo "$input" | xargs) # collapse whitespace
						input="${input// /,}"          # spaces -> commas
					fi
					
					# Allow empty (auto-detect) or valid IP list
					if [[ -n "$input" ]] && ! validate_ip_list "$input"; then
						dialog --backtitle "$(ui_backtitle)" --msgbox "Invalid IP address format. Please enter IPs separated by spaces or commas (e.g., 8.8.8.8 1.1.1.1)" 0 0
						continue
					fi
					DNS_SERVERS="$input"
					log "DNS servers set to: $DNS_SERVERS"
					break
				done
				default_item="$action"  # Keep cursor on DNS Servers
				;;
			5)
				log "Showing default route inputbox"
				while :; do
					dialog --backtitle "$(ui_backtitle)" --inputbox "Default Route (gateway IP):" 10 70 "$NEXT_HOP_ADDRESS" 2>"$TMP" || { log "Default route input cancelled"; break; }
					input=$(<"$TMP")
					input=${input##[[:space:]]}
					input=${input%%[[:space:]]}
					
					# Allow empty (auto-detect) or valid IP
					if [[ -n "$input" ]] && ! validate_ip "$input"; then
						dialog --backtitle "$(ui_backtitle)" --msgbox "Invalid IP address format. Please enter a valid IP (e.g., 192.168.1.1)" 0 0
						continue
					fi
					NEXT_HOP_ADDRESS="$input"
					log "Default route set to: $NEXT_HOP_ADDRESS"
					break
				done
				default_item="$action"  # Keep cursor on Default Route
				;;
			6)
				log "Showing NTP servers inputbox"
				while :; do
					# Show space-separated in the input box for readability
					local _ntp_edit="${NTP_SERVERS//,/ }"
					dialog --backtitle "$(ui_backtitle)" --inputbox "NTP Servers (space or comma-separated IPs or hostnames):" 10 70 "$_ntp_edit" 2>"$TMP" || { log "NTP input cancelled"; break; }
					input=$(<"$TMP")
					input=${input##[[:space:]]}
					input=${input%%[[:space:]]}
					
					# Normalize: replace spaces/commas with single commas
					if [[ -n "$input" ]]; then
						input="${input//,/ }"          # commas -> spaces
						input=$(echo "$input" | xargs) # collapse whitespace
						input="${input// /,}"          # spaces -> commas
					fi
					
					# Allow empty (auto-detect) or valid NTP server list
					if [[ -n "$input" ]] && ! validate_ntp_servers "$input"; then
						dialog --backtitle "$(ui_backtitle)" --msgbox "Invalid NTP server format. Please enter IPs or hostnames separated by spaces or commas (e.g., pool.ntp.org time.google.com 192.168.1.1)" 0 0
						continue
					fi
					NTP_SERVERS="$input"
					log "NTP servers set to: $NTP_SERVERS"
					break
				done
				default_item="$action"  # Keep cursor on NTP Servers
				;;
		esac
	done
}

# -----------------------------------------------------------------------------
# Step 4: Select Operators
# -----------------------------------------------------------------------------
# Basket helpers (simple model)
# - OP_BASKET: operators in the basket
# - OP_SET_ADDED: sets that have been selected (for tracking in aba.conf)

add_set_to_basket() {
	local set_key=$1
	local file="$ABA_ROOT/templates/operator-set-$set_key"
	[[ -f "$file" ]] || return 1

	log "Adding operator set: $set_key from file: $file"
	
	local added=0
	local filtered=0

	while IFS= read -r op; do
		[[ "$op" =~ ^# ]] && continue
		op=${op%%#*}
		op=${op//$'
'/}
		op=${op##[[:space:]]}
		op=${op%%[[:space:]]}
		[[ -z "$op" ]] && continue

		# Validate operator exists in catalog index (silent filtering)
		if grep -q "^$op[[:space:]]" "$ABA_ROOT"/mirror/.index/* 2>/dev/null; then
			log "Adding operator from set: $op (validated in catalog)"
			OP_BASKET["$op"]=1
			((added++))
		else
			log "Filtered operator from set: $op (not in catalog for OCP $OCP_VERSION)"
			((filtered++))
		fi
	done <"$file"
	
	# Silent filtering - operator sets are "everything you might need"
	log "Set $set_key: added $added operators, filtered $filtered (not in catalog)"
	
	log "Basket now has ${#OP_BASKET[@]} operators after adding set $set_key"
	return 0
}

select_operators() {
	DIALOG_RC=""
	log "=== Entering select_operators ==="
	log "OP_BASKET type: $(declare -p OP_BASKET 2>&1)"
	log "OP_BASKET contents: ${!OP_BASKET[*]}"
	log "OP_BASKET count: ${#OP_BASKET[@]}"

	# Start additional background tasks (catalog and CLI downloads already started after version confirmation)
	log "Starting additional background tasks for operators"
	log "Starting registry download task"
	run_once -i "$TASK_QUAY_REG_DOWNLOAD" -- make -s -C "$ABA_ROOT/mirror" download-registries
	
	# WAIT for catalog indexes to download (needed for operator sets AND search)
	# Catalogs were started in background after version selection
	# wait_for_all_catalogs returns immediately if already complete
	local version_short="${OCP_VERSION%.*}"  # 4.20.8 -> 4.20
	log "Checking catalog indexes for version ${version_short}..."
	
	# Check if catalogs are already complete (quick check)
	local need_wait=false
	run_once -p -i "catalog:${version_short}:redhat-operator" || need_wait=true
	run_once -p -i "catalog:${version_short}:certified-operator" || need_wait=true
	run_once -p -i "catalog:${version_short}:community-operator" || need_wait=true
	
	# If catalogs are still downloading, show a waiting dialog
	if [[ "$need_wait" == "true" ]]; then
		log "Catalogs still downloading, showing wait dialog..."
		dialog --backtitle "$(ui_backtitle)" --infobox "Downloading operator catalogs...\n\nThis may take a few minutes on first run." 6 55
	fi
	
	# Ensure all 3 catalogs are running in parallel (no-op if already started)
	download_all_catalogs "$version_short" 86400 >>"$LOG_FILE" 2>&1
	
	# Now wait for all 3 — they're already running in parallel
	local failed_catalogs=()
	
	for catalog in redhat-operator certified-operator community-operator; do
		if ! run_once -q -w -i "catalog:${version_short}:${catalog}"; then
			log "ERROR: Catalog download failed: $catalog"
			failed_catalogs+=("$catalog")
		fi
	done
	
	# If any catalogs failed, show a user-friendly error
	if [[ ${#failed_catalogs[@]} -gt 0 ]]; then
		log "ERROR: ${#failed_catalogs[@]} catalog(s) failed: ${failed_catalogs[*]}"
		
		# Get error details via run_once (not direct runner access)
		local first_failed="${failed_catalogs[0]}"
		local error_msg
		error_msg=$(run_once -e -i "catalog:${version_short}:${first_failed}" 2>/dev/null | head -5)
		
		if [[ -z "$error_msg" ]]; then
			error_msg="No details available."
		fi
		
		dialog --colors --backtitle "$(ui_backtitle)" --msgbox \
"\Z1ERROR: Failed to download operator catalogs\Zn

Failed catalog(s): ${failed_catalogs[*]}

$error_msg

\ZbWhat to try:\Zn
  1. Check your internet connection
  2. Press OK and go back to retry
  3. Run 'aba doctor' for diagnostics" 0 0
		
		DIALOG_RC="back"
		return
	fi
	
	log "Catalog indexes ready for version ${version_short}"
	
	log "Catalog indexes ready. Starting operators menu with ${#OP_BASKET[@]} operators in basket"

	# Track cursor position for menu navigation
	local default_item="${1:-1}"  # Start at option 1 or use passed value

	while :; do
		# Count the basket items for display
		local basket_count="${#OP_BASKET[@]}"
		log "Menu loop: basket has $basket_count operators"
		log "  default_item=$default_item"
		
		log "About to show operators menu dialog..."
		
		dialog --colors --backtitle "$(ui_backtitle)" --title "$TUI_TITLE_OPERATORS" \
			--cancel-label "Back" \
			--help-button \
			--ok-label "Select" \
			--extra-button --extra-label "Next" \
			--default-item "$default_item" \
			--menu "$TUI_TITLE_SELECT_OPERATORS" 0 0 4 \
			1 "Select Operator Sets" \
			2 "Search Operator Names" \
			3 "View/Edit Basket ($basket_count operators)" \
			4 "Clear Basket" \
			2>"$TMP"
		rc=$?
		
		log "Operators menu dialog returned: $rc"
		log "TMP file contents: $(cat "$TMP" 2>/dev/null || echo '(empty)')"
		
		case "$rc" in
			0)
				# OK - process the action
				: # Continue to action handler below
				;;
			1)
				# Cancel button = "Back"
				log "User chose Back from operators menu"
				DIALOG_RC="back"
				return
				;;
			3)
				# Extra button = "Next"
				# Check if basket is empty and warn
				if [[ ${#OP_BASKET[@]} -eq 0 ]]; then
					log "Empty basket - showing warning"
					dialog --backtitle "$(ui_backtitle)" --title "$TUI_TITLE_EMPTY_BASKET" \
						--extra-button --extra-label "Back" \
						--yes-label "Continue Anyway" \
						--no-label "Add Operators" \
						--yesno "No operators selected. Continue with empty basket?" 0 0
					empty_rc=$?
					
					case "$empty_rc" in
						0)
							# Continue anyway
							log "User chose to continue with empty basket"
							;;
						1|255)
							# Go back to add operators
							log "User chose to add operators"
							continue
							;;
						3)
							# Extra button = Back to previous screen
							DIALOG_RC="back"
							log "User went back from empty basket warning"
							return
							;;
					esac
				fi
				
				DIALOG_RC="next"
				log "User accepted operators and moved to next (rc=$rc)"
				return
				;;
			2)
				# Help button
				log "Help button pressed in operators menu"
				dialog --backtitle "$(ui_backtitle)" --msgbox \
"Operator Selection:

• Operator Sets: Pre-defined groups of operators
  (e.g., storage, networking, observability)
  
• Search: Find operators by name or keyword
  
• View/Edit Basket: See selected operators
  
• Clear Basket: Remove all operators

Selected operators will be included in the
image synchronization process." 0 0 || true
				continue
				;;
			3)
				# Extra button = Back
				DIALOG_RC="back"
				log "User went back from operators (rc=$rc)"
				return
				;;
			255)
				# ESC - confirm quit
				if confirm_quit; then
					log "User confirmed quit from operators screen"
					clear
					_show_exit_summary
					exit 0
				else
					log "User cancelled quit, staying on operators screen"
					continue
				fi
				;;
			*)
				# Unexpected return code
				log "ERROR: Unexpected operators dialog return code: $rc"
				DIALOG_RC="back"
				return
				;;
		esac
		
		# If we got here, rc=0 and user selected an action
		action=$(<"$TMP")
		log "Operators menu action selected: $action"
		
		case "$action" in
			1)
				# Add operator sets to basket (with ability to remove)
				log "=== Operator Set Selection ==="
				log "Before set selection - Basket count: ${#OP_BASKET[@]}"
				log "Currently added sets: ${!OP_SET_ADDED[*]}"
				
				items=()
				for f in "$ABA_ROOT"/templates/operator-set-*; do
					[[ -f "$f" ]] || continue
					key=${f##*/operator-set-}
					display=$(head -n1 "$f" 2>/dev/null | sed 's/^# *//' | sed 's/^Name: *//')
					[[ -z "$display" ]] && display="$key"

					# Show as checked if already applied
					if [[ -n "${OP_SET_ADDED[$key]:-}" ]]; then
						items+=("$key" "$display ✓" "on")
					else
						items+=("$key" "$display" "off")
					fi
				done

				[[ "${#items[@]}" -eq 0 ]] && {
					dialog --backtitle "$(ui_backtitle)" --msgbox "No operator-set templates found under: $ABA_ROOT/templates" 0 0
					continue
				}

				# Calculate size based on number of operator sets (items has 3 elements per set)
				local num_sets=$((${#items[@]} / 3))
				local list_h=$((num_sets < 18 ? num_sets + 2 : 18))
				dialog --clear --backtitle "$(ui_backtitle)" --title "$TUI_TITLE_OPERATOR_SETS" \
					--ok-label "Add to Basket" \
					--checklist "Use spacebar to toggle, then press Add to Basket:" 0 70 $list_h \
					"${items[@]}" 2>"$TMP" || continue

				newsel=$(<"$TMP")
				log "Raw selection: [$newsel]"
				
				# Build array of newly selected sets
				declare -A newly_selected
				while read -r k; do
					k=${k//\"/}
					k=${k##[[:space:]]}
					k=${k%%[[:space:]]}
					[[ -z "$k" ]] && continue
					newly_selected["$k"]=1
					log "Selected set: [$k]"
				done < <(echo "$newsel" | tr ' ' '\n')
				
				# Remove sets that were previously added but are now unchecked
				for prev_set in "${!OP_SET_ADDED[@]}"; do
					if [[ -z "${newly_selected[$prev_set]:-}" ]]; then
						log "Removing unchecked operator set: $prev_set"
						unset OP_SET_ADDED["$prev_set"]
						
						# Remove all operators from this set from the basket
						local set_file="$ABA_ROOT/templates/operator-set-$prev_set"
						if [[ -f "$set_file" ]]; then
							while IFS= read -r op; do
								op=${op##[[:space:]]}
								op=${op%%[[:space:]]}
								[[ -z "$op" || "$op" =~ ^# ]] && continue
								log "  Removing operator: $op"
								unset OP_BASKET["$op"]
							done < "$set_file"
						fi
					fi
				done
				
				# Add newly selected sets
				for new_set in "${!newly_selected[@]}"; do
					if [[ -z "${OP_SET_ADDED[$new_set]:-}" ]]; then
						log "Adding new operator set: $new_set"
						OP_SET_ADDED["$new_set"]=1
						add_set_to_basket "$new_set" || true
					fi
				done
					
				log "After set selection - Basket count: ${#OP_BASKET[@]}"
				log "Basket contents: ${!OP_BASKET[*]}"
				log "Active sets: ${!OP_SET_ADDED[*]}"
				default_item="$action"  # Keep cursor on Select Operator Sets
				;;

			2)
			# Search operators (needs index files)
			log "User searching operators (catalog already loaded)"
		
		dialog --colors --backtitle "$(ui_backtitle)" --inputbox "Search operator names (min 2 chars, multiple terms AND'ed):" 10 50 2>"$TMP" || continue
			query=$(<"$TMP")
			query=${query//$'
'/}
			query=${query##[[:space:]]}
			query=${query%%[[:space:]]}
			
			# Require at least 2 characters
			if [[ -z "$query" ]] || [[ ${#query} -lt 2 ]]; then
				dialog --backtitle "$(ui_backtitle)" --msgbox "Please enter at least 2 characters to search" 0 0
				continue
			fi
			
		log "Searching for: $query"

		# Split query into multiple search terms (space-separated)
		# Progressive filtering: search for first term, then filter by second, etc.
		read -ra search_terms <<< "$query"
		log "Search terms: ${search_terms[*]}"

		# First, get all unique operators from index files
		declare -A seen_ops
		all_operators=$(
			while IFS= read -r line; do
				op_name="${line%%[[:space:]]*}"
				[[ -n "${seen_ops[$op_name]:-}" ]] && continue
				seen_ops["$op_name"]=1
				echo "$line"
			done < <(cat "$ABA_ROOT"/mirror/.index/* 2>/dev/null)
		)
		
		# Now progressively filter by each search term
		matches="$all_operators"
		for term in "${search_terms[@]}"; do
			term_lower="${term,,}"
			log "Filtering by term: [$term]"
			
			# Filter current results by this term
			matches=$(
				while IFS= read -r line; do
					[[ -z "$line" ]] && continue
					op_name="${line%%[[:space:]]*}"
					op_name_lower="${op_name,,}"
					
					# Only keep operators that contain this term
					if [[ "$op_name_lower" == *"$term_lower"* ]]; then
						echo "$line"
					fi
				done <<< "$matches"
			)
			
			# Log how many results remain after this filter
			local count=$(echo "$matches" | grep -c . || echo "0")
			log "After filtering by [$term]: $count results"
		done
		
		# Sort final results
		matches=$(echo "$matches" | sort)
		if [[ -z "$matches" ]]; then
			log "No matches for: $query"
			dialog --backtitle "$(ui_backtitle)" --msgbox "No matches for: $query\n\nAll search terms must match the operator name." 0 0
			continue
		fi
				
				match_count=$(echo "$matches" | wc -l)
				log "Found $match_count matches for: $query"

			items=()
			while IFS= read -r line; do
				line=${line//$'
'/}
				line=${line##[[:space:]]}
				line=${line%%[[:space:]]}
				[[ -z "$line" ]] && continue
				
				# Extract operator name (first field only)
				# Index file format: "operator-name<spaces>default-channel"
				# We only work with operator name for now
				op="${line%%[[:space:]]*}"  # Get everything before first space
				[[ -z "$op" ]] && continue
				
				state="off"
				[[ -n "${OP_BASKET[$op]:-}" ]] && state="on"
			# Use operator name as tag, empty description
			items+=("$op" "" "$state")
		done <<<"$matches"

			# Calculate size based on number of matching operators
			local num_ops=$((${#items[@]} / 3))
			local list_h=$((num_ops < 18 ? num_ops + 2 : 18))
			dialog --clear --backtitle "$(ui_backtitle)" --title "$TUI_TITLE_SELECT_OPERATORS" \
				--ok-label "Add to Basket" \
				--checklist "Use spacebar to toggle, then press Add to Basket:" 0 60 $list_h \
					"${items[@]}" 2>"$TMP" || continue

			newsel=$(<"$TMP")
			log "Raw user selection from search: [$newsel]"
			
			# Build a set of what was selected in the dialog
			# Dialog returns operator names, possibly with quotes or brackets
			declare -A SEL
			SEL=()
			
			log "Starting to parse selections..."
			# Parse the dialog output - remove quotes, brackets and split on spaces
			sel_count=0
			for op in $newsel; do
				log "  Processing token: [$op]"
				# Remove quotes
				op="${op//\"/}"
				log "  After removing quotes: [$op]"
				# Remove brackets (dialog may add these)
				op="${op//\[/}"
				op="${op//\]/}"
				log "  After removing brackets: [$op]"
				# Skip empty
				if [[ -z "$op" ]]; then
					log "  Token is empty, skipping"
					continue
				fi
				
				log "  Adding to SEL array: [$op]"
				SEL["$op"]=1 || { log "ERROR: Failed to add [$op] to SEL array"; exit 1; }
				((sel_count++)) || true
				log "  Selection #$sel_count: [$op]"
			done
			
			log "Finished parsing loop"
			log "Total selections parsed from dialog: ${#SEL[@]}"
			log "Selected keys: ${!SEL[*]}"

				# BUG FIX: Only process operators that were ACTUALLY SELECTED
				# NOT all the search results!
				# Old code looped through ALL matches and added them all
				
				# Add all selected operators (and ONLY selected operators!)
			log "Now adding ${#SEL[@]} selected operators to basket..."
			for op in "${!SEL[@]}"; do
				log "  -> Adding to basket: [$op]"
				OP_BASKET["$op"]=1
			done
				log "Finished adding. Basket now has: ${#OP_BASKET[@]} operators"
				
			# Remove operators that were in the search results AND in the basket
			# but NOT selected (i.e., user unchecked them)
			while IFS= read -r line; do
				line=${line//$'
'/}
				line=${line##[[:space:]]}
				line=${line%%[[:space:]]}
				[[ -z "$line" ]] && continue
				
				# Extract just the operator name (first field)
				op="${line%%[[:space:]]*}"
				[[ -z "$op" ]] && continue

				# If this operator was in the search results
				# AND is currently in the basket
				# BUT was not selected in the dialog
				# Then user unchecked it - remove it
			if [[ -n "${OP_BASKET[$op]:-}" && -z "${SEL[$op]:-}" ]]; then
				log "User unchecked operator, removing from basket: [$op]"
				unset 'OP_BASKET[$op]'
			fi
			done <<<"$matches"
				
				log "After search update, basket has ${#OP_BASKET[@]} operators"
				log "Basket contents: ${!OP_BASKET[*]}"
				default_item="$action"  # Keep cursor on Search Operator Names
				;;

			3)
				# View/Edit basket (allow multi-select adjustments)
				log "=== View/Edit Basket ==="
				log "Basket count: ${#OP_BASKET[@]}"
				log "Basket keys: ${!OP_BASKET[*]}"
				
				items=()
				for op in $(printf "%s\n" "${!OP_BASKET[@]}" | sort); do
					log "Adding to view: [$op]"
					items+=("$op" "" "on")
				done
				
			if [[ "${#items[@]}" -eq 0 ]]; then
				log "Basket is empty"
				dialog --backtitle "$(ui_backtitle)" --msgbox "Basket is empty." 0 0
				continue
			fi

			log "Displaying ${#items[@]} items in basket view"
			# Calculate size based on number of operators in basket
			local num_ops=$((${#items[@]} / 3))
			local list_h=$((num_ops < 18 ? num_ops + 2 : 18))
			dialog --clear --backtitle "$(ui_backtitle)" --title "Basket (${#OP_BASKET[@]} operators)" \
				--ok-label "Apply" \
				--checklist "Uncheck to remove. Use spacebar to toggle:" \
				0 60 $list_h \
					"${items[@]}" 2>"$TMP" || continue

				newsel=$(<"$TMP")
				log "View/Edit basket selection: [$newsel]"
				
				declare -A KEEP
				KEEP=()
				while read -r op; do
					op=${op//\"/}
					op=${op##[[:space:]]}
					op=${op%%[[:space:]]}
					[[ -n "$op" ]] && KEEP["$op"]=1 && log "Keeping: $op"
				done < <(echo "$newsel" | tr ' ' '\n')

				for op in "${!OP_BASKET[@]}"; do
					if [[ -n "${KEEP[$op]:-}" ]]; then
				log "Operator $op kept in basket"
			else
				log "Removing operator $op from basket"
				unset 'OP_BASKET[$op]'
			fi
				done
				
				log "After view basket - count: ${#OP_BASKET[@]}"
				default_item="$action"  # Keep cursor on View/Edit Basket
				;;

			4)
			dialog --backtitle "$(ui_backtitle)" --yesno "Clear operator basket?" 0 0 && {
				log "Clearing operator basket"
				OP_BASKET=()
				OP_SET_ADDED=()
			}
				default_item="$action"  # Keep cursor on Clear Basket
				;;
		esac
	done
}

# -----------------------------------------------------------------------------
# Action Handlers
# -----------------------------------------------------------------------------
handle_action_view_isconf() {
	log "Handling action: View ImageSet Config"
	
	local isconf_file="$ABA_ROOT/mirror/save/imageset-config-save.yaml"
	
	# Wait for background isconf generation to complete AND file to exist
	if ! run_once -p -i "tui:isconf:generate"; then
	log "Waiting for ImageSet config generation to complete"
	dialog --backtitle "$(ui_backtitle)" --infobox "Generating ImageSet configuration...\n\nThis may take a moment." 6 50
	
	if ! run_once -q -w -i "tui:isconf:generate"; then
			log "ERROR: ImageSet config generation failed"
			show_run_once_error "tui:isconf:generate" "ImageSet Config Generation Failed"
			return 0
		fi
		
		# Wait for file to actually exist (task might have just finished)
		local wait_count=0
		while [[ ! -f "$isconf_file" ]] && [[ $wait_count -lt 10 ]]; do
			log "Waiting for file to be written... ($wait_count)"
			sleep 0.5
			wait_count=$((wait_count + 1))
		done
	else
		log "ImageSet config is ready (cached)"
	fi
	
	# Check if file exists
	if [[ ! -f "$isconf_file" ]]; then
		dialog --backtitle "$(ui_backtitle)" --msgbox \
"ImageSet configuration file not found.

File: $isconf_file

This file should have been generated automatically." 0 0 || true
		return 0
	fi
	
	# Show file in scrollable textbox
	dialog --colors --clear --backtitle "$(ui_backtitle)" --title "$TUI_TITLE_IMAGESET" \
		--exit-label "OK" \
		--textbox "$isconf_file" 0 0
	
	return 0
}

handle_action_bundle() {
	log "Handling action: Create Bundle"
	
	# Get output path from user
	local default_bundle="/tmp/ocp-bundle"
	
	dialog --colors --clear --backtitle "$(ui_backtitle)" --title "$TUI_TITLE_CREATE_BUNDLE" \
		--ok-label "Next" \
		--cancel-label "Back" \
		--inputbox "Enter output path for install bundle:\n\n(Version suffix will be added automatically)" 10 70 "$default_bundle" \
		2>"$TMP"
	rc=$?
	
	if [[ $rc -ne 0 ]]; then
		log "User cancelled bundle path input"
		return 1
	fi
	
	# Parse output
	bundle_path=$(<"$TMP")
	[[ -z "$bundle_path" ]] && bundle_path="$default_bundle"
	
	# If directory, append default filename (like aba.sh does)
	if [[ -d "$bundle_path" ]]; then
		log "Path is directory, appending default filename"
		bundle_path="$bundle_path/ocp-bundle"
	fi
	
	# Strip .tar extension if present - make-bundle.sh will add version and .tar
	bundle_path="${bundle_path%.tar}"
	log "Bundle path (version will be added by make-bundle.sh): $bundle_path"
	
	# Check filesystem compatibility using device numbers (more reliable than filesystem type)
	local output_dir=$(dirname "$bundle_path")
	
	# Ensure output directory exists for stat to work
	mkdir -p "$output_dir" 2>/dev/null
	
	# Get device numbers (like files_on_same_device() in include_all.sh)
	local output_dev=$(stat -c %d "$output_dir" 2>/dev/null)
	local mirror_dev=$(stat -c %d "$ABA_ROOT/mirror/save" 2>/dev/null)
	
	log "Device check: output=[$output_dev], mirror=[$mirror_dev]"
	
	local light_flag=""
	local same_device=false
	
	# Check if on same device
	if [[ -n "$output_dev" && -n "$mirror_dev" && "$output_dev" == "$mirror_dev" ]]; then
		same_device=true
		log "Output and mirror on same device"
		
		# Ask user if they want --light option
		dialog --colors --clear --backtitle "$(ui_backtitle)" --title "$TUI_TITLE_CREATE_BUNDLE" \
			--yes-label "Yes" \
			--no-label "No" \
			--yesno "Enable light bundle option?\n\n(Excludes large image-set archives from bundle to save disk space)\n\nBundle output: $bundle_path" 0 0
		rc=$?
		
		if [[ $rc -eq 0 ]]; then
			light_flag="--light"
			log "Light option enabled by user"
		else
			log "Light option disabled by user - will create full bundle"
			
			# Warn about disk space (like aba.sh does for full bundles on same device)
			dialog --colors --backtitle "$(ui_backtitle)" --title "$TUI_TITLE_DISK_SPACE_WARNING" \
				--yes-label "Continue" \
				--no-label "Cancel" \
				--yesno "\Z3Disk Space Consideration\Zn

Bundle and mirror are on the same filesystem.

Creating a full bundle requires:
  • Mirror image-set archives written to mirror/save/
  • Complete bundle copy written to: $bundle_path

You may temporarily need roughly \Zbdouble the space\Zn.

\ZbRecommendation:\Zn Use --light option to avoid this.

Continue with full bundle anyway?" 0 0
			rc=$?
			if [[ $rc -ne 0 ]]; then
				log "User cancelled due to disk space concern"
				return 1
			fi
		fi
	else
		# Different devices - no light option available
		log "Light option not available (different devices: output=$output_dev, mirror=$mirror_dev)"
	fi
	
	# Use global auto-answer setting
	local y_flag=""
	if [[ "$ABA_AUTO_ANSWER" == "yes" ]]; then
		y_flag="-y"
		log "Using global auto-answer: -y flag enabled"
	else
		log "Using global auto-answer: -y flag disabled"
	fi
	
	# Use global retry count
	local retry_flag=""
	if [[ "$RETRY_COUNT" != "off" ]]; then
		retry_flag="--retry $RETRY_COUNT"
		log "Using retry count: $RETRY_COUNT"
	fi
	
	log "Bundle output path: $bundle_path, light: $light_flag, y_flag: $y_flag, retry: $RETRY_COUNT"
	
	# Show command and confirm
	local cmd="aba bundle -o '$bundle_path' $light_flag $retry_flag $y_flag"
	if ! confirm_and_execute "$cmd"; then
		return 1
	fi
	
	return 0
}

handle_action_local_quay() {
	log "Handling action: Local Quay Registry"
	
	# Load existing values from mirror.conf
	if [[ -f "$ABA_ROOT/mirror/mirror.conf" ]]; then
		source "$ABA_ROOT/mirror/mirror.conf" 2>/dev/null || true
	fi
	
	# Set defaults (prefer existing config, fall back to sensible defaults)
	local default_host="${reg_host:-$(hostname -f 2>/dev/null || hostname)}"
	local default_user="${reg_user:-init}"
	local default_pw="${reg_pw:-p4ssw0rd}"
	local default_path="${reg_path:-ocp4/openshift4}"
	local default_data_dir="${data_dir:-~}"
	
	# Collect inputs using form
	dialog --colors --clear --backtitle "$(ui_backtitle)" --title "$TUI_TITLE_LOCAL_QUAY" \
		--ok-label "Next" \
		--cancel-label "Back" \
		--form "Configure local Quay registry:" 0 0 0 \
		"Registry Host (FQDN):"  1 1 "$default_host"       1 25 40 0 \
		"Registry Username:"     2 1 "$default_user"       2 25 40 0 \
		"Registry Password:"     3 1 "$default_pw"         3 25 40 0 \
		"Registry Path:"         4 1 "$default_path"       4 25 40 0 \
		"Data Directory:"        5 1 "$default_data_dir"   5 25 40 0 \
		2>"$TMP"
	rc=$?
	
	if [[ $rc -ne 0 ]]; then
		log "User cancelled local Quay form"
		return 1
	fi
	
	# Parse form output
	local reg_host=$(sed -n '1p' "$TMP")
	local reg_user=$(sed -n '2p' "$TMP")
	local reg_pw=$(sed -n '3p' "$TMP")
	local reg_path=$(sed -n '4p' "$TMP")
	local data_dir=$(sed -n '5p' "$TMP")
	
	# Use global auto-answer setting
	local y_flag=""
	if [[ "$ABA_AUTO_ANSWER" == "yes" ]]; then
		y_flag="-y"
		log "Using global auto-answer: -y flag enabled"
	else
		log "Using global auto-answer: -y flag disabled"
	fi
	
	# Use global retry count
	local retry_flag=""
	if [[ "$RETRY_COUNT" != "off" ]]; then
		retry_flag="--retry $RETRY_COUNT"
		log "Using retry count: $RETRY_COUNT"
	fi
	
	log "Local Quay config: host=$reg_host, user=$reg_user, path=$reg_path, data_dir=$data_dir, y_flag=$y_flag, retry=$RETRY_COUNT"
	
	# Save to mirror.conf
	replace-value-conf -q -n reg_host -v "$reg_host" -f mirror/mirror.conf
	replace-value-conf -q -n reg_port -v "8443" -f mirror/mirror.conf
	replace-value-conf -q -n reg_user -v "$reg_user" -f mirror/mirror.conf
	replace-value-conf -q -n reg_pw -v "$reg_pw" -f mirror/mirror.conf
	replace-value-conf -q -n reg_path -v "$reg_path" -f mirror/mirror.conf
	replace-value-conf -q -n data_dir -v "$data_dir" -f mirror/mirror.conf
	
	# Clear SSH parameters for local installation (empty = localhost)
	replace-value-conf -q -n reg_ssh_user -v "" -f mirror/mirror.conf
	replace-value-conf -q -n reg_ssh_key -v "" -f mirror/mirror.conf
	log "Cleared SSH parameters for local registry installation"
	
	# Determine actual registry type and build appropriate command
	local actual_type=$(get_actual_registry_type)
	log "Actual registry type: $actual_type"
	
	local cmd
	if [[ "$actual_type" == "Docker" ]]; then
		# Docker: install-docker-registry + sync in one command
		cmd="aba -d mirror install-docker-registry $retry_flag sync -H '$reg_host' $y_flag"
	else
		# Quay: just sync (install is make dependency)
		cmd="aba -d mirror $retry_flag sync -H '$reg_host' $y_flag"
	fi
	
	if ! confirm_and_execute "$cmd"; then
		return 1
	fi
	
	return 0
}

handle_action_local_docker() {
	log "Handling action: Local Docker Registry"
	
	# Load existing values from mirror.conf
	if [[ -f "$ABA_ROOT/mirror/mirror.conf" ]]; then
		source "$ABA_ROOT/mirror/mirror.conf" 2>/dev/null || true
	fi
	
	# Set defaults (prefer existing config, fall back to sensible defaults)
	local default_host="${reg_host:-$(hostname -f 2>/dev/null || hostname)}"
	local default_user="${reg_user:-init}"
	local default_pw="${reg_pw:-p4ssw0rd}"
	local default_path="${reg_path:-ocp4/openshift4}"
	local default_data_dir="${data_dir:-~}"
	
	# Collect inputs using form
	dialog --colors --clear --backtitle "$(ui_backtitle)" --title "$TUI_TITLE_LOCAL_DOCKER" \
		--ok-label "Next" \
		--cancel-label "Back" \
		--form "Configure local Docker registry:" 0 0 0 \
		"Registry Host (FQDN):"  1 1 "$default_host"       1 25 40 0 \
		"Registry Username:"     2 1 "$default_user"       2 25 40 0 \
		"Registry Password:"     3 1 "$default_pw"         3 25 40 0 \
		"Registry Path:"         4 1 "$default_path"       4 25 40 0 \
		"Data Directory:"        5 1 "$default_data_dir"   5 25 40 0 \
		2>"$TMP"
	rc=$?
	
	if [[ $rc -ne 0 ]]; then
		log "User cancelled local Docker form"
		return 1
	fi
	
	# Parse form output
	local reg_host=$(sed -n '1p' "$TMP")
	local reg_user=$(sed -n '2p' "$TMP")
	local reg_pw=$(sed -n '3p' "$TMP")
	local reg_path=$(sed -n '4p' "$TMP")
	local data_dir=$(sed -n '5p' "$TMP")
	
	# Use global auto-answer setting
	local y_flag=""
	if [[ "$ABA_AUTO_ANSWER" == "yes" ]]; then
		y_flag="-y"
		log "Using global auto-answer: -y flag enabled"
	else
		log "Using global auto-answer: -y flag disabled"
	fi
	
	log "Local Docker config: host=$reg_host, user=$reg_user, path=$reg_path, data_dir=$data_dir, y_flag=$y_flag"
	
	# Save to mirror.conf
	replace-value-conf -q -n reg_host -v "$reg_host" -f mirror/mirror.conf
	replace-value-conf -q -n reg_port -v "8443" -f mirror/mirror.conf
	replace-value-conf -q -n reg_user -v "$reg_user" -f mirror/mirror.conf
	replace-value-conf -q -n reg_pw -v "$reg_pw" -f mirror/mirror.conf
	replace-value-conf -q -n reg_path -v "$reg_path" -f mirror/mirror.conf
	replace-value-conf -q -n data_dir -v "$data_dir" -f mirror/mirror.conf
	
	# Clear SSH parameters for local installation (empty = localhost)
	replace-value-conf -q -n reg_ssh_user -v "" -f mirror/mirror.conf
	replace-value-conf -q -n reg_ssh_key -v "" -f mirror/mirror.conf
	log "Cleared SSH parameters for local registry installation"
	
	# Build command (install-docker-registry + sync in one)
	local cmd="aba -d mirror install-docker-registry -H '$reg_host' sync $y_flag"
	if ! confirm_and_execute "$cmd"; then
		return 1
	fi
	
	return 0
}

handle_action_remote_quay() {
	log "Handling action: Remote Quay Registry"
	
	# Load existing values from mirror.conf
	if [[ -f "$ABA_ROOT/mirror/mirror.conf" ]]; then
		source "$ABA_ROOT/mirror/mirror.conf" 2>/dev/null || true
	fi
	
	# Set defaults (prefer existing config, fall back to sensible defaults)
	local default_host="${reg_host:-}"
	local default_ssh_user="${reg_ssh_user:-root}"
	local default_ssh_key="${reg_ssh_key:-$HOME/.ssh/id_rsa}"
	local default_user="${reg_user:-init}"
	local default_pw="${reg_pw:-p4ssw0rd}"
	local default_path="${reg_path:-ocp4/openshift4}"
	local default_data_dir="${data_dir:-~}"
	
	# Collect inputs using form
	dialog --colors --clear --backtitle "$(ui_backtitle)" --title "$TUI_TITLE_REMOTE_QUAY" \
		--ok-label "Next" \
		--cancel-label "Back" \
		--form "Configure remote Quay registry:" 0 0 0 \
		"Remote Host (FQDN):"    1 1 "$default_host"       1 25 40 0 \
		"SSH Username:"          2 1 "$default_ssh_user"   2 25 40 0 \
		"SSH Key Path:"          3 1 "$default_ssh_key"    3 25 40 0 \
		"Registry Username:"     4 1 "$default_user"       4 25 40 0 \
		"Registry Password:"     5 1 "$default_pw"         5 25 40 0 \
		"Registry Path:"         6 1 "$default_path"       6 25 40 0 \
		"Data Directory:"        7 1 "$default_data_dir"   7 25 40 0 \
		2>"$TMP"
	rc=$?
	
	if [[ $rc -ne 0 ]]; then
		log "User cancelled remote Quay form"
		return 1
	fi
	
	# Parse form output
	local reg_host=$(sed -n '1p' "$TMP")
	local reg_ssh_user=$(sed -n '2p' "$TMP")
	local reg_ssh_key=$(sed -n '3p' "$TMP")
	local reg_user=$(sed -n '4p' "$TMP")
	local reg_pw=$(sed -n '5p' "$TMP")
	local reg_path=$(sed -n '6p' "$TMP")
	local data_dir=$(sed -n '7p' "$TMP")
	
	# Use global auto-answer setting
	local y_flag=""
	if [[ "$ABA_AUTO_ANSWER" == "yes" ]]; then
		y_flag="-y"
		log "Using global auto-answer: -y flag enabled"
	else
		log "Using global auto-answer: -y flag disabled"
	fi
	
	# Use global retry count
	local retry_flag=""
	if [[ "$RETRY_COUNT" != "off" ]]; then
		retry_flag="--retry $RETRY_COUNT"
		log "Using retry count: $RETRY_COUNT"
	fi
	
	log "Remote Quay config: host=$reg_host, ssh_user=$reg_ssh_user, ssh_key=$reg_ssh_key, y_flag=$y_flag, retry=$RETRY_COUNT"
	
	# Save to mirror.conf
	replace-value-conf -q -n reg_host -v "$reg_host" -f mirror/mirror.conf
	replace-value-conf -q -n reg_port -v "8443" -f mirror/mirror.conf
	replace-value-conf -q -n reg_user -v "$reg_user" -f mirror/mirror.conf
	replace-value-conf -q -n reg_pw -v "$reg_pw" -f mirror/mirror.conf
	replace-value-conf -q -n reg_path -v "$reg_path" -f mirror/mirror.conf
	replace-value-conf -q -n data_dir -v "$data_dir" -f mirror/mirror.conf
	replace-value-conf -q -n reg_ssh_key -v "$reg_ssh_key" -f mirror/mirror.conf
	replace-value-conf -q -n reg_ssh_user -v "$reg_ssh_user" -f mirror/mirror.conf
	
	# Determine actual registry type and build appropriate command
	local actual_type=$(get_actual_registry_type)
	log "Actual registry type: $actual_type"
	
	local cmd
	if [[ "$actual_type" == "Docker" ]]; then
		# Docker: install-docker-registry + sync in one command
		cmd="aba -d mirror install-docker-registry $retry_flag sync -H '$reg_host' -k '$reg_ssh_key' $y_flag"
	else
		# Quay: just sync (install is make dependency)
		cmd="aba -d mirror $retry_flag sync -H '$reg_host' -k '$reg_ssh_key' $y_flag"
	fi
	
	if ! confirm_and_execute "$cmd"; then
		return 1
	fi
	
	return 0
}

handle_action_save() {
	log "Handling action: Save Images"
	
	# No form needed - just confirm and execute using global auto-answer setting
	local y_flag=""
	if [[ "$ABA_AUTO_ANSWER" == "yes" ]]; then
		y_flag="-y"
		log "Using global auto-answer: -y flag enabled"
	else
		log "Using global auto-answer: -y flag disabled"
	fi
	
	# Use global retry count
	local retry_flag=""
	if [[ "$RETRY_COUNT" != "off" ]]; then
		retry_flag="--retry $RETRY_COUNT"
		log "Using retry count: $RETRY_COUNT"
	fi
	
	# Confirm and execute
	local cmd="aba -d mirror $retry_flag save $y_flag"
	if ! confirm_and_execute "$cmd"; then
		return 1
	fi
	
	return 0
}

handle_action_isconf() {
	log "Handling action: Generate ImageSet Config"
	
	# Fast command -- run directly without confirmation dialog
	dialog --backtitle "$(ui_backtitle)" --infobox "Generating ImageSet configuration..." 4 50
	
	local output rc
	output=$(aba -d mirror isconf -y 2>&1) || true
	rc=$?
	log "aba -d mirror isconf -y returned rc=$rc"
	
	if [[ $rc -eq 0 ]]; then
		dialog --colors --backtitle "$(ui_backtitle)" --title "\Z2ImageSet Config Generated\Zn" \
			--msgbox "ImageSet configuration generated successfully.\n\nFiles:\n  mirror/save/imageset-config-save.yaml\n  mirror/sync/imageset-config-sync.yaml" 0 0 || true
	else
		dialog --colors --backtitle "$(ui_backtitle)" --title "\Z1ImageSet Config Failed\Zn" \
			--msgbox "Failed to generate ImageSet configuration.\n\n$output" 0 0 || true
		return 1
	fi
	
	return 0
}

confirm_and_execute() {
	local cmd="$1"
	log "Confirming command: $cmd"
	
	while :; do
		dialog --colors --clear --backtitle "$(ui_backtitle)" --title "$TUI_TITLE_CONFIRM_EXEC" \
			--cancel-label "Back" \
			--ok-label "Select" \
			--help-button \
			--menu "Ready to execute:\n\n\Zb$cmd\Zn\n\nChoose execution mode:" 0 0 0 \
			"1" "Run in TUI (auto-answer, dialog output)" \
			"2" "Run in Terminal (interactive, full colors)" \
			2>"$TMP"
		rc=$?
		
		if [[ $rc -eq 2 ]]; then
			# Help button
			log "Help button pressed in confirm execution"
			dialog --backtitle "$(ui_backtitle)" --msgbox \
"Execution Options:

• Run in TUI
  - Command runs inside dialog interface
  - Auto-answer (-y) is ALWAYS enabled (non-interactive)
  - Output shown live in progressbox
  - Scrollable output review after completion

• Run in Terminal  
  - Command runs in real terminal (exits dialog temporarily)
  - Respects your Auto-answer toggle setting from action menu
  - Full interactive mode (can answer prompts, see colors)
  - Press ENTER to return to TUI after completion

For most operations, 'Run in TUI' is recommended.
Use 'Run in Terminal' if you need to interact with the command." 0 0 || true
			continue
		fi
		
		if [[ $rc -ne 0 ]]; then
			# Cancel/Back
			log "User cancelled execution"
			return 1
		fi
		
		choice=$(<"$TMP")
		
		case "$choice" in
			1)
				# Run in TUI
				# ALWAYS force -y for TUI execution (non-interactive)
				local tui_cmd="$cmd"
				if [[ ! "$tui_cmd" =~ -y ]]; then
					tui_cmd="$tui_cmd -y"
				fi
				log "Executing command in TUI (with -y): $tui_cmd"
				
				# Execute command and show live output in progressbox
				cd "$ABA_ROOT"
				
				# Create temp file to capture output for later review
				local output_file=$(mktemp)
				
				# Run command with progressbox showing live output
			# progressbox reads from stdin and displays line by line
		# Get terminal dimensions and use maximum available space
		local term_height=$(tput lines)
		local term_width=$(tput cols)
		# Minimal margins - just 1 char on each side for dialog borders
		local box_height=$((term_height - 2))
		local box_width=$((term_width - 2))
		
		# Strip ANSI color codes (sed -u for unbuffered/line-by-line output) before showing in dialog
		# This prevents control characters from displaying literally
		# Set ASK_OVERRIDE=1 to skip interactive prompts (TUI is non-interactive)
		ASK_OVERRIDE=1 bash -c "$tui_cmd" 2>&1 | tee "$output_file" | \
			sed -u -r 's/\x1B\[[0-9;]*[mK]//g' | \
			dialog --backtitle "$(ui_backtitle)" --title "Executing: $tui_cmd" \
				--progressbox $box_height $box_width
				
			# Get exit code from the command (via PIPESTATUS before pipe)
			local exit_code=${PIPESTATUS[0]}
			
		# Always show full output in scrollable textbox for review (success or failure)
		# textbox provides full scrolling support (arrows, page up/down, home/end)
		
		if [[ $exit_code -eq 0 ]]; then
			# Success - show output with success indicator and choice buttons
			dialog --colors --backtitle "$(ui_backtitle)" --title "\Z2Command Output (Success)\Zn: $tui_cmd" \
				--ok-label "Back to Menu" \
				--extra-button --extra-label "Exit TUI" \
				--textbox "$output_file" 0 0
			local choice=$?
			
			rm -f "$output_file"
			
			case $choice in
				0)
					# OK = Back to menu
					log "User chose to return to menu after successful command"
					return 1
					;;
				3)
					# Extra button = Exit TUI
					log "User chose to exit TUI after successful command"
					clear
					_show_exit_summary
					exit 0
					;;
				255)
					# ESC = Back to menu
					log "User pressed ESC, returning to menu"
					return 1
					;;
			esac
		else
		# Failure - show output with error indicator and action buttons
		dialog --colors --backtitle "$(ui_backtitle)" --title "\Z1Command Output (Failed - exit code: $exit_code)\Zn: $tui_cmd" \
			--ok-label "Back to Menu" \
			--extra-button --extra-label "Retry" \
			--textbox "$output_file" 0 0
		local choice=$?
		
		rm -f "$output_file"
		
		case $choice in
			0|255)
				# OK/ESC = Back to menu
				log "User chose to return to menu after failed command"
				return 1
				;;
			3)
				# Extra button = Retry - loop back to confirmation
				log "User chose to retry after failed command"
				continue
				;;
		esac
		fi
				;;
			2)
				# Run in Terminal
				log "User chose to execute in terminal: $cmd"
				
				# For terminal execution, respect user's auto-answer setting from action menu
				local terminal_cmd="$cmd"
				# First remove any existing -y flag
				terminal_cmd="${terminal_cmd// -y/}"
				terminal_cmd="${terminal_cmd//  / }"  # Clean up any double spaces
				
				# Then add -y back if user has auto-answer enabled
				if [[ "$ABA_AUTO_ANSWER" == "yes" ]]; then
					terminal_cmd="$terminal_cmd -y"
					log "Terminal execution with auto-answer enabled (-y)"
				else
					log "Terminal execution with auto-answer disabled (interactive)"
				fi
				
				clear
				echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
				echo "Executing command in terminal:"
				echo "  $terminal_cmd"
				echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
				echo ""
				
				cd "$ABA_ROOT"
				bash -c "$terminal_cmd"
				local exit_code=$?
				
				echo ""
				echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
				echo "Command completed with exit code: $exit_code"
				echo ""
				read -p "Press ENTER to return to TUI menu... " 
				
				# If command succeeded, return success (don't loop back to confirmation)
				if [[ $exit_code -eq 0 ]]; then
					log "Terminal execution succeeded, returning to menu"
					return 0
				else
					log "Terminal execution failed with exit code $exit_code, returning to menu"
					return 1
				fi
				;;
			*)
				log "ERROR: Unexpected menu choice: $choice"
				return 1
				;;
		esac
	done
}

# -----------------------------------------------------------------------------
# Step 5: Summary / Apply
# -----------------------------------------------------------------------------
summary_apply() {
	log "Entering summary_apply"
	# DEBUG: Write directly to file to bypass log() function
	echo "[DEBUG $(date '+%Y-%m-%d %H:%M:%S')] Entering summary_apply, LOG_FILE=$LOG_FILE" >> /tmp/aba-tui-debug.log
	
	# Create custom operator-set file if basket is not empty
	local custom_set_name=""
	if [[ ${#OP_BASKET[@]} -gt 0 ]]; then
		# Generate sorted list of operators for comparison
		local new_op_list=$(printf "%s\n" "${!OP_BASKET[@]}" | sort | paste -sd, -)
		log "New operator list: $new_op_list"
		
		# Check if an identical custom set already exists
		local found_duplicate=""
		for existing_file in "$ABA_ROOT"/templates/operator-set-custom-*; do
			[[ -f "$existing_file" ]] || continue
			
			# Skip the first line (comment/title) and get sorted operator list
			local existing_op_list=$(tail -n +2 "$existing_file" | sort | paste -sd, -)
			
			if [[ "$new_op_list" == "$existing_op_list" ]]; then
				# Found an identical set!
				found_duplicate=$(basename "$existing_file")
				found_duplicate=${found_duplicate#operator-set-}
				log "Found duplicate custom set: $found_duplicate"
				break
			fi
		done
		
		if [[ -n "$found_duplicate" ]]; then
			# Reuse existing set
			custom_set_name="$found_duplicate"
			log "Reusing existing custom operator set: $custom_set_name"
		else
			# Create new set and delete old custom sets (they're outdated)
			local timestamp=$(date +%Y%m%d-%H%M%S)
			local readable_date=$(date '+%Y-%m-%d %H:%M')
			custom_set_name="custom-${timestamp}"
			local custom_set_file="$ABA_ROOT/templates/operator-set-${custom_set_name}"
			
			log "Creating NEW custom operator set file: $custom_set_file"
			
			# Delete old custom operator sets (they're outdated now)
			local deleted_count=0
			for old_file in "$ABA_ROOT"/templates/operator-set-custom-*; do
				[[ -f "$old_file" ]] || continue
				log "Deleting old custom set: $old_file"
				rm -f "$old_file"
				((deleted_count++))
			done
			[[ $deleted_count -gt 0 ]] && log "Deleted $deleted_count old custom operator sets"
			
			# Create the new custom operator set file with title and operators
			{
				echo "# Name: Custom Operator Set ${readable_date}"
				printf "%s\n" "${!OP_BASKET[@]}" | sort
			} > "$custom_set_file"
			
			log "Created NEW custom operator set with ${#OP_BASKET[@]} operators"
		fi
	fi
	
	# For aba.conf: use custom set name only, leave ops empty
	local op_sets_value=""
	if [[ -n "$custom_set_name" ]]; then
		op_sets_value="$custom_set_name"
	fi
	
	# Human-friendly preview list for summary dialog
	local op_summary
	if [[ ${#OP_BASKET[@]} -eq 0 ]]; then
		op_summary="(none)"
	else
		op_summary="${#OP_BASKET[@]} operators selected"
		if [[ ${#OP_BASKET[@]} -le 5 ]]; then
			# Show operator names if 5 or fewer
			op_summary="${op_summary}: $(printf "%s\n" "${!OP_BASKET[@]}" | sort | paste -sd, -)"
		fi
	fi

	# First, save configuration to aba.conf automatically
	log "Auto-saving configuration to aba.conf"
	replace-value-conf -q -n ocp_channel       -v "$OCP_CHANNEL"       -f aba.conf
	replace-value-conf -q -n ocp_version       -v "$OCP_VERSION"       -f aba.conf
	replace-value-conf -q -n platform          -v "${PLATFORM:-bm}"    -f aba.conf
	replace-value-conf -q -n domain            -v "${DOMAIN}"          -f aba.conf
	replace-value-conf -q -n machine_network   -v "${MACHINE_NETWORK}" -f aba.conf
	replace-value-conf -q -n dns_servers       -v "${DNS_SERVERS}"     -f aba.conf
	replace-value-conf -q -n next_hop_address  -v "${NEXT_HOP_ADDRESS}" -f aba.conf
	replace-value-conf -q -n ntp_servers       -v "${NTP_SERVERS}"     -f aba.conf
	replace-value-conf -q -n ops               -v ""                   -f aba.conf
	replace-value-conf -q -n op_sets           -v "$op_sets_value"     -f aba.conf
	log "Configuration saved to aba.conf"

	# Clear the fresh-config flag now that the user has completed the wizard.
	# This prevents _show_exit_summary() from deleting aba.conf on exit.
	# See _show_exit_summary() for the full explanation of this mechanism.
	_TUI_FRESH_CONF=
	
	# ALWAYS pre-generate ImageSet config in background before showing action menu
	# This ensures it's ready for any action (with or without operators)
	log "Pre-generating ImageSet configuration for OCP $OCP_VERSION"
	cd "$ABA_ROOT"
	
	# Wait for oc-mirror to be installed (needed for isconf generation)
	log "Ensuring oc-mirror is installed before generating ImageSet config"
	# Show waiting dialog if oc-mirror is still downloading
	if ! run_once -p -i "$TASK_OC_MIRROR"; then
		dialog --backtitle "$(ui_backtitle)" --infobox "Installing oc-mirror...\n\nThis is needed before proceeding." 6 50
	fi
	# Let errors flow to logs, suppress stdout (informational messages only)
	if ! run_once -w -i "$TASK_OC_MIRROR" -- make -sC "$ABA_ROOT/cli" oc-mirror >/dev/null; then
		log "ERROR: Failed to install oc-mirror"
		show_run_once_error "$TASK_OC_MIRROR" "Failed to Install oc-mirror"
		DIALOG_RC="back"
		return
	fi
	
	# Remove old ImageSet config files to force regeneration with current version
	rm -f "$ABA_ROOT/mirror/save/imageset-config-save.yaml" 2>/dev/null || true
	
	# Reset and start isconf generation in background (non-blocking)
	# Reset ensures regeneration if user changes operators and comes back
	log "Resetting and starting background task: aba -d mirror isconf"
	# DEBUG: Write directly to file
	echo "[DEBUG $(date '+%Y-%m-%d %H:%M:%S')] About to reset isconf task" >> /tmp/aba-tui-debug.log
	run_once -r -i "tui:isconf:generate"
	# Small delay to ensure reset completes
	sleep 0.2
	echo "[DEBUG $(date '+%Y-%m-%d %H:%M:%S')] About to start isconf task" >> /tmp/aba-tui-debug.log
	run_once -i "tui:isconf:generate" -- bash -lc "cd '$ABA_ROOT' && aba -d mirror isconf" >/dev/null 2>&1
	echo "[DEBUG $(date '+%Y-%m-%d %H:%M:%S')] isconf task started, checking directory..." >> /tmp/aba-tui-debug.log
	ls -la ~/.aba/runner/tui:isconf:generate/ >> /tmp/aba-tui-debug.log 2>&1
	log "ImageSet config generation started in background"
	
	# Now show action menu - what to do next?
	# Initialize auto-answer setting if not set
	: "${ABA_AUTO_ANSWER:=yes}"
	# Initialize registry type setting if not set
	: "${ABA_REGISTRY_TYPE:=Auto}"
	
	# Track which item has focus (start at item 1 for first display)
	local default_item="1"
	
	# --- Settings sub-dialog ---
	_show_settings() {
		local settings_default="1"
		while :; do
			# Determine toggle displays
			local toggle_answer_display
			if [[ "$ABA_AUTO_ANSWER" == "yes" ]]; then
				toggle_answer_display="Auto-answer: \Z2ON\Zn (-y)"
			else
				toggle_answer_display="Auto-answer: \Z1OFF\Zn"
			fi
			
			local toggle_registry_display
			case "$ABA_REGISTRY_TYPE" in
				Auto)  toggle_registry_display="Registry Type: \Z6Auto\Zn" ;;
				Quay)  toggle_registry_display="Registry Type: \Z2Quay\Zn" ;;
				Docker) toggle_registry_display="Registry Type: \Z3Docker\Zn" ;;
			esac
			
			local toggle_retry_display
			case "$RETRY_COUNT" in
				off) toggle_retry_display="Retry Count: \Z1OFF\Zn" ;;
				2)   toggle_retry_display="Retry Count: \Z22\Zn" ;;
				8)   toggle_retry_display="Retry Count: \Z38\Zn" ;;
			esac
			
		dialog --colors --backtitle "$(ui_backtitle)" --title "$TUI_TITLE_SETTINGS" \
			--ok-label "Toggle" \
			--cancel-label "Back" \
			--help-button \
			--default-item "$settings_default" \
			--menu "Select a setting to toggle:" 0 0 3 \
				$TUI_SETTINGS_AUTO_ANSWER "$toggle_answer_display" \
				$TUI_SETTINGS_REGISTRY_TYPE "$toggle_registry_display" \
				$TUI_SETTINGS_RETRY_COUNT "$toggle_retry_display" \
				2>"$TMP"
			local src=$?
			
			if [[ $src -eq 2 ]]; then
				# Help button
				dialog --backtitle "$(ui_backtitle)" --title "Settings Help" --msgbox \
"Auto-answer (-y):
  When ON, aba commands run without confirmation prompts.
  When OFF, you will be asked to confirm each action.

Registry Type:
  Auto   - Let aba choose the registry (recommended).
  Quay   - Force Quay mirror registry.
  Docker - Force Docker V2 mirror registry.

Retry Count:
  How many times to retry failed oc-mirror operations.
  OFF = no retries, 2 or 8 = retry that many times.

Toggle a setting by selecting it and pressing Enter." 0 0 || true
				continue
			fi
			
			[[ $src -ne 0 ]] && return  # Done/Cancel
			
			local saction=$(<"$TMP")
			case "$saction" in
				$TUI_SETTINGS_AUTO_ANSWER)
					if [[ "$ABA_AUTO_ANSWER" == "yes" ]]; then
						ABA_AUTO_ANSWER="no"; log "Auto-answer toggled OFF"
					else
						ABA_AUTO_ANSWER="yes"; log "Auto-answer toggled ON"
					fi
					settings_default="$TUI_SETTINGS_AUTO_ANSWER"
					;;
				$TUI_SETTINGS_REGISTRY_TYPE)
					case "$ABA_REGISTRY_TYPE" in
						Auto)   ABA_REGISTRY_TYPE="Quay"; log "Registry type toggled to Quay" ;;
						Quay)   ABA_REGISTRY_TYPE="Docker"; log "Registry type toggled to Docker" ;;
						Docker) ABA_REGISTRY_TYPE="Auto"; log "Registry type toggled to Auto" ;;
					esac
					settings_default="$TUI_SETTINGS_REGISTRY_TYPE"
					;;
				$TUI_SETTINGS_RETRY_COUNT)
					case "$RETRY_COUNT" in
						off) RETRY_COUNT="2"; log "Retry count toggled to 2" ;;
						2)   RETRY_COUNT="8"; log "Retry count toggled to 8" ;;
						8)   RETRY_COUNT="off"; log "Retry count toggled to OFF" ;;
					esac
					settings_default="$TUI_SETTINGS_RETRY_COUNT"
					;;
			esac
		done
	}
	
	# --- Advanced sub-dialog ---
	_show_advanced() {
		local adv_default="1"
		while :; do
			dialog --colors --backtitle "$(ui_backtitle)" --title "$TUI_TITLE_ADVANCED" \
				--cancel-label "Back" \
				--ok-label "Select" \
				--default-item "$adv_default" \
				--menu "Advanced actions:" 0 0 4 \
				1 "Generate ImageSet Config & Exit" \
				2 "Delete Registry (Quay)" \
				3 "Delete Registry (Docker)" \
				4 "Exit (run commands manually)" \
				2>"$TMP"
			local arc=$?
			
			[[ $arc -ne 0 ]] && return  # Back/Cancel
			
			local aaction=$(<"$TMP")
			case "$aaction" in
				1)
					if handle_action_isconf; then
						ADVANCED_EXIT=0; return
					fi
					adv_default="1"; continue
					;;
				2)
					log "User chose to delete Quay registry"
					if [[ ! -f "$ABA_ROOT/mirror/mirror.conf" ]]; then
						dialog --colors --title "$TUI_TITLE_ERROR" --msgbox \
							"\Zb\Z1Error:\Zn\n\nmirror/mirror.conf not found.\n\nRegistry must be installed first." 0 0
						adv_default="2"; continue
					fi
					if ! confirm_and_execute "aba -d mirror uninstall -y"; then
						adv_default="2"; continue
					fi
					;;
				3)
					log "User chose to delete Docker registry"
					if [[ ! -f "$ABA_ROOT/mirror/mirror.conf" ]]; then
						dialog --colors --title "$TUI_TITLE_ERROR" --msgbox \
							"\Zb\Z1Error:\Zn\n\nmirror/mirror.conf not found.\n\nRegistry must be installed first." 0 0
						adv_default="3"; continue
					fi
					if ! confirm_and_execute "aba -d mirror uninstall-docker-registry -y"; then
						adv_default="3"; continue
					fi
					;;
				4)
					log "User chose to exit and run commands manually"
					clear
					_show_exit_summary
					ADVANCED_EXIT=0; return
					;;
			esac
		done
	}
	
	while :; do
		local ADVANCED_EXIT=""
		
		dialog --colors --backtitle "$(ui_backtitle)" --title "$TUI_TITLE_ACTION_MENU" \
		--cancel-label "Exit" \
		--help-button \
		--ok-label "Select" \
		--extra-button --extra-label "Back" \
		--default-item "$default_item" \
		--menu "Configuration saved to aba.conf. Choose what to do next:" 0 0 0 \
		"" "──── Review ─────────────────────────────" \
		$TUI_ACTION_VIEW_IMAGESET "$TUI_ACTION_LABEL_VIEW_IMAGESET" \
		"" " " \
		"" "──── Air-Gapped (Fully Disconnected) ────" \
		$TUI_ACTION_CREATE_BUNDLE "$TUI_ACTION_LABEL_CREATE_BUNDLE" \
		$TUI_ACTION_SAVE_IMAGES "$TUI_ACTION_LABEL_SAVE_IMAGES" \
		"" " " \
		"" "──── Connected / Partially Connected ────" \
		$TUI_ACTION_LOCAL_REGISTRY "$TUI_ACTION_LABEL_LOCAL_REGISTRY" \
		$TUI_ACTION_REMOTE_REGISTRY "$TUI_ACTION_LABEL_REMOTE_REGISTRY" \
		"" " " \
		"" "──── Other ──────────────────────────────" \
		$TUI_ACTION_RERUN_WIZARD "$TUI_ACTION_LABEL_RERUN_WIZARD" \
		$TUI_ACTION_SETTINGS "$TUI_ACTION_LABEL_SETTINGS" \
		$TUI_ACTION_ADVANCED "$TUI_ACTION_LABEL_ADVANCED" \
		$TUI_ACTION_EXIT "$TUI_ACTION_LABEL_EXIT" \
		2>"$TMP"
		rc=$?
		
		case "$rc" in
			0)
			# OK - process the selected action
			action=$(<"$TMP")
			log "User selected action: $action"
			
			case "$action" in
				"")
					# Separator selected - redisplay menu
					log "Separator selected, redisplaying menu"
					continue
					;;
				$TUI_ACTION_VIEW_IMAGESET)
					# View ImageSet Config
					handle_action_view_isconf
					default_item="$TUI_ACTION_VIEW_IMAGESET"
					continue
					;;
				$TUI_ACTION_CREATE_BUNDLE)
					# Create Bundle
					if handle_action_bundle; then
						return 0
					else
						default_item="$TUI_ACTION_CREATE_BUNDLE"
						continue
					fi
					;;
				$TUI_ACTION_SAVE_IMAGES)
					# Save Images
					if handle_action_save; then
						return 0
					else
						default_item="$TUI_ACTION_SAVE_IMAGES"
						continue
					fi
					;;
				$TUI_ACTION_LOCAL_REGISTRY)
					# Local Registry (Auto/Quay/Docker based on setting)
					case "$ABA_REGISTRY_TYPE" in
						Auto)
							if [[ "$(uname -m)" == "aarch64" ]] || [[ "$(uname -m)" == "arm64" ]]; then
								log "Auto-selected Docker for ARM64 architecture"
								if handle_action_local_docker; then
									return 0
								else
									default_item="$TUI_ACTION_LOCAL_REGISTRY"
									continue
								fi
							else
								log "Auto-selected Quay for non-ARM64 architecture"
								if handle_action_local_quay; then
									return 0
								else
									default_item="$TUI_ACTION_LOCAL_REGISTRY"
									continue
								fi
							fi
							;;
						Quay)
							if handle_action_local_quay; then
								return 0
							else
								default_item="$TUI_ACTION_LOCAL_REGISTRY"
								continue
							fi
							;;
						Docker)
							if handle_action_local_docker; then
								return 0
							else
								default_item="$TUI_ACTION_LOCAL_REGISTRY"
								continue
							fi
							;;
					esac
					;;
				$TUI_ACTION_REMOTE_REGISTRY)
					# Remote Registry
					if handle_action_remote_quay; then
						return 0
					else
						default_item="$TUI_ACTION_REMOTE_REGISTRY"
						continue
					fi
					;;
			$TUI_ACTION_RERUN_WIZARD)
				# Rerun Wizard
				log "User chose to rerun wizard"
				RERUN_WIZARD=true
				return 0
				;;
			$TUI_ACTION_SETTINGS)
				# Settings sub-menu
				_show_settings
				default_item="$TUI_ACTION_SETTINGS"
				continue
				;;
			$TUI_ACTION_ADVANCED)
				# Advanced sub-menu
				_show_advanced
				if [[ "$ADVANCED_EXIT" == "0" ]]; then
					return 0
				fi
				default_item="$TUI_ACTION_ADVANCED"
				continue
				;;
			$TUI_ACTION_EXIT)
				# Exit
				log "User chose to exit"
				clear
				_show_exit_summary
				return 0
				;;
			esac
				;;
			1)
				# Cancel = Exit
				log "User cancelled from action menu"
				clear
				_show_exit_summary
				return 0
				;;
			3)
				# Extra button = Back to operators
				log "User went back from action menu to operators"
				return 1
				;;
			2)
			# Help
			log "Help button pressed in action menu"
			dialog --backtitle "$(ui_backtitle)" --msgbox \
"Choose Next Action - Help

VIEW:
• View ImageSet Config - Preview the generated YAML for oc-mirror

AIR-GAPPED (Fully Disconnected) - uses mirror-to-disk:
  For environments with no internet access.
• Create Air-Gapped Install Bundle - Package images, binaries & configs
                              Transfer this bundle to the air-gapped site
• Save Images to Archive - Save images to aba/mirror/save/

CONNECTED / PARTIALLY CONNECTED - uses mirror-to-mirror:
  For environments with direct or proxied internet.
• Local Registry  - Install a registry here and sync images
• Remote Registry - Install a registry on a remote host via SSH

RERUN WIZARD:
• Go back to channel/version/operator selection to change config

SETTINGS (sub-menu):
• Auto-answer (-y) - Skip confirmation prompts
• Registry Type    - Toggle between Auto / Quay / Docker
• Retry Count      - oc-mirror retry attempts (off / 3 / 8)

ADVANCED (sub-menu):
• Generate ISConf & Exit  - Create YAML only (for manual oc-mirror)
• Delete Registry (Quay)  - Uninstall Quay mirror registry
• Delete Registry (Docker) - Uninstall Docker mirror registry
• Exit (manual)           - Exit TUI to run 'aba' commands yourself

Log file: $LOG_FILE" 0 0 || true
				continue
				;;
			255)
				# ESC - confirm quit
				if confirm_quit; then
					log "User confirmed quit from action menu"
					clear
					_show_exit_summary
					exit 0
				else
					log "User cancelled quit, staying on action menu"
					continue
				fi
				;;
			*)
				log "ERROR: Unexpected action menu return code: $rc"
				clear
				exit 1
				;;
		esac
	done
}

# -----------------------------------------------------------------------------
# Main wizard loop
# -----------------------------------------------------------------------------
log "=== STARTING TUI ==="

# Check internet access first
check_internet_access

# Start background version fetches for ALL channels (latest + previous + older)
log "Starting background OCP version fetches for all channels"
# Let errors flow to logs (stderr), suppress stdout (version output)
run_once -i "ocp:stable:latest_version"             -- bash -lc 'source ./scripts/include_all.sh; fetch_latest_version stable' >/dev/null
run_once -i "ocp:stable:latest_version_previous"    -- bash -lc 'source ./scripts/include_all.sh; fetch_previous_version stable' >/dev/null
run_once -i "ocp:stable:latest_version_older"       -- bash -lc 'source ./scripts/include_all.sh; fetch_older_version stable' >/dev/null

run_once -i "ocp:fast:latest_version"               -- bash -lc 'source ./scripts/include_all.sh; fetch_latest_version fast' >/dev/null
run_once -i "ocp:fast:latest_version_previous"      -- bash -lc 'source ./scripts/include_all.sh; fetch_previous_version fast' >/dev/null
run_once -i "ocp:fast:latest_version_older"         -- bash -lc 'source ./scripts/include_all.sh; fetch_older_version fast' >/dev/null

run_once -i "ocp:candidate:latest_version"          -- bash -lc 'source ./scripts/include_all.sh; fetch_latest_version candidate' >/dev/null
run_once -i "ocp:candidate:latest_version_previous" -- bash -lc 'source ./scripts/include_all.sh; fetch_previous_version candidate' >/dev/null
run_once -i "ocp:candidate:latest_version_older"    -- bash -lc 'source ./scripts/include_all.sh; fetch_older_version candidate' >/dev/null

# Download oc-mirror early (needed for catalog downloads later)
log "Starting oc-mirror download in background"
PLAIN_OUTPUT=1 run_once -i "$TASK_OC_MIRROR" -- make -sC "$ABA_ROOT/cli" oc-mirror
log "oc-mirror download started"

# Initialize configuration and global arrays (must happen BEFORE prefetch
# so that aba.conf exists when background catalog scripts try to read it)
resume_from_conf

# Pre-fetch catalogs for stable:latest in background
log "Starting background catalog pre-fetch"
run_once -S -i "tui:prefetch:catalogs" -- "$ABA_ROOT/scripts/prefetch-catalogs.sh"
log "Background catalog pre-fetch started"

# Show header
ui_header

log "After resume_from_conf:"
log "  OP_BASKET type: $(declare -p OP_BASKET 2>&1)"
log "  OP_BASKET count: ${#OP_BASKET[@]}"
log "  OP_SET_ADDED count: ${#OP_SET_ADDED[@]}"
log "Starting wizard loop"

# Check if we can skip wizard (config already complete)
show_resume_dialog
while :; do
	log "Current step: $STEP"
	case "$STEP" in
		channel)
			select_ocp_channel
			if [[ "$DIALOG_RC" == "repeat" ]]; then
				continue  # Stay on same step, show again
			elif [[ "$DIALOG_RC" == "next" ]]; then
				STEP="version"
			elif [[ "$DIALOG_RC" == "back" ]]; then
				# First screen, confirm quit
			if confirm_quit; then
				log "User quit from channel selection"
				clear
				_show_exit_summary
				break
				else
					log "User cancelled quit, staying on channel"
					continue
				fi
			fi
			;;
	version)
		select_ocp_version
		if [[ "$DIALOG_RC" == "repeat" ]]; then
			continue  # Stay on same step
		elif [[ "$DIALOG_RC" == "next" ]]; then
			STEP="pull_secret"
		elif [[ "$DIALOG_RC" == "back" ]]; then
			STEP="channel"
		fi
		;;
	pull_secret)
		log "=== STEP: pull_secret, CALLING select_pull_secret() ==="
		# Don't auto-skip if we got here from a back action
		if [[ "${CAME_FROM_BACK:-}" == "1" ]]; then
			select_pull_secret "no_skip"
			CAME_FROM_BACK=""
		else
			select_pull_secret "allow_skip"
		fi
		log "=== RETURNED FROM select_pull_secret, DIALOG_RC=$DIALOG_RC ==="
		if [[ "$DIALOG_RC" == "next" ]]; then
			log "=== MOVING TO STEP: platform ==="
			STEP="platform"
		elif [[ "$DIALOG_RC" == "back" ]]; then
			log "=== MOVING TO STEP: version ==="
			STEP="version"
		else
			log "=== WARNING: UNEXPECTED DIALOG_RC=$DIALOG_RC ==="
		fi
		;;
	platform)
		select_platform_network
		log "After select_platform_network: DIALOG_RC=$DIALOG_RC"
		if [[ "$DIALOG_RC" == "next" ]]; then
			STEP="operators"
			log "Moving to operators"
		elif [[ "$DIALOG_RC" == "back" ]]; then
			# Check if pull secret is valid - if so, skip directly to version
			if [[ -f ~/.pull-secret.json ]] && validate_pull_secret ~/.pull-secret.json >/dev/null 2>&1; then
				STEP="version"
				log "Moving back to version (skipping pull secret - already valid)"
			else
				# Pull secret missing or invalid - go to entry screen
				CAME_FROM_BACK="1"
				STEP="pull_secret"
				log "Moving back to pull_secret (needs entry/fix)"
			fi
		else
			log "WARNING: Unexpected DIALOG_RC value: $DIALOG_RC"
		fi
		;;
		operators)
			select_operators
			[[ "$DIALOG_RC" == "next" ]] && STEP="summary"
			[[ "$DIALOG_RC" == "back" ]] && STEP="platform"
			;;
	summary)
		RERUN_WIZARD=false
		if summary_apply; then
			if [[ "$RERUN_WIZARD" == "true" ]]; then
				log "Rerunning wizard from channel selection"
				STEP="channel"
			else
				break
			fi
		else
			STEP="operators"
		fi
			;;
	esac
done

clear
log "TUI completed successfully"
_show_exit_summary
