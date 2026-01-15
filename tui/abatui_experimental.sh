#!/usr/bin/env bash
# ABA TUI – Wizard Prototype (Bash + dialog)
#
# Wizard flow:
#   Channel  <->  Version  <->  Operators  <->  Summary / Apply

set -eo pipefail

# -----------------------------------------------------------------------------
# Validation Functions (implementations to be added to include_all.sh)
# -----------------------------------------------------------------------------
# These are placeholder functions - user will paste implementations into include_all.sh

# Validate CIDR notation (e.g., 10.0.0.0/24)
validate_cidr() {
	local cidr="$1"
	# TODO: Add to include_all.sh - validate CIDR format
	# For now, just check it's not empty
	[[ -n "$cidr" ]]
}

# Validate IP address (e.g., 192.168.1.1)
validate_ip() {
	local ip="$1"
	# TODO: Add to include_all.sh - validate IP format
	# For now, just check it's not empty
	[[ -n "$ip" ]]
}

# Validate domain name (e.g., example.com)
validate_domain() {
	local domain="$1"
	# TODO: Add to include_all.sh - validate domain format
	# For now, just check it's not empty and has a dot
	[[ "$domain" =~ \. ]]
}

# Validate comma-separated IPs (e.g., 8.8.8.8,1.1.1.1)
validate_ip_list() {
	local ip_list="$1"
	# TODO: Add to include_all.sh - validate each IP in comma-separated list
	# For now, just check it's not empty
	[[ -n "$ip_list" ]]
}

# Validate comma-separated NTP servers (IPs or hostnames)
validate_ntp_servers() {
	local server_list="$1"
	# TODO: Add to include_all.sh - validate each server as IP or hostname
	# For now, just check it's not empty
	[[ -n "$server_list" ]]
}

# -----------------------------------------------------------------------------
# Confirmation dialog for quitting
# -----------------------------------------------------------------------------
confirm_quit() {
	log "User attempting to quit, showing confirmation"
	set +e
	dialog --backtitle "ABA TUI" --title "Confirm Exit" \
		--help-button \
		--yes-label "Exit" \
		--no-label "Continue" \
		--yesno "Exit ABA TUI?\n\nProgress will not be saved unless you complete the wizard." 0 0
	rc=$?
	set -e
	
	case "$rc" in
		0)
			log "User confirmed quit"
			return 0  # Quit confirmed
			;;
		1|255)
			log "User cancelled quit"
			return 1  # Don't quit
			;;
		2)
			# Help button
			dialog --backtitle "ABA TUI" --msgbox \
"Exiting the TUI:

• Press ESC at any time to quit (with confirmation)
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
LOG_FILE="${TMPDIR:-/tmp}/aba-tui-$$.log"
# Also create a persistent log link for easier access
LOG_LINK="${TMPDIR:-/tmp}/aba-tui-latest.log"
export LOG_FILE

log() {
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

log "=========================================="
log "ABA TUI started"
log "=========================================="
log "Log file: $LOG_FILE"

# Create symlink to latest log for easier access
ln -sf "$LOG_FILE" "$LOG_LINK" 2>/dev/null || true
log "Symlink created: $LOG_LINK -> $LOG_FILE"

# -----------------------------------------------------------------------------
# Sanity checks
# -----------------------------------------------------------------------------
if ! command -v dialog >/dev/null 2>&1; then
	echo "ERROR: dialog is required (dnf install dialog)" >&2
	log "ERROR: dialog not found"
	exit 1
fi

log "dialog found: $(command -v dialog)"

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
# Aba runtime init (required for run_once)
# -----------------------------------------------------------------------------
WORK_DIR=~/.aba/runner
export WORK_DIR

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

TMP=$(mktemp)
trap 'rm -f "$TMP"; log "ABA TUI exited"' EXIT

log "Temp file: $TMP"

# Get terminal size
read -r TERM_ROWS TERM_COLS < <(stty size 2>/dev/null || echo "24 80")

ui_backtitle() {
	echo "ABA TUI  |  channel: ${OCP_CHANNEL:-?}  version: ${OCP_VERSION:-?}"
}

# Wrapper for dialog with consistent styling
dlg() {
	dialog --no-shadow --colors "$@"
}

# Calculate optimal dialog dimensions based on content
# Usage: calc_dlg_size <num_items> <max_text_width>
#   num_items: number of menu/list items (0 for msgbox/inputbox)
#   max_text_width: width of longest line of text
# Returns: sets DLG_H and DLG_W variables
calc_dlg_size() {
	local num_items=${1:-0}
	local text_width=${2:-50}
	
	# Height calculation
	if ((num_items > 0)); then
		# For lists/menus: base + items + chrome (title, buttons, borders)
		# List display area (cap at 15 visible items)
		local list_area
		if ((num_items > 15)); then
			list_area=15
		else
			list_area=$num_items
		fi
		DLG_H=$((8 + list_area))
	else
		# For msgbox/inputbox: minimal height
		DLG_H=10
	fi
	
	# Width calculation: content + padding
	DLG_W=$((text_width + 10))
	
	# Apply constraints
	# Minimum
	if ((DLG_H < 10)); then DLG_H=10; fi
	if ((DLG_W < 50)); then DLG_W=50; fi
	
	# Maximum (80% of terminal to keep some margin)
	local max_h=$((TERM_ROWS * 80 / 100))
	local max_w=$((TERM_COLS * 80 / 100))
	if ((max_h < 15)); then max_h=15; fi
	if ((max_w < 60)); then max_w=60; fi
	if ((DLG_H > max_h)); then DLG_H=$max_h; fi
	if ((DLG_W > max_w)); then DLG_W=$max_w; fi
}

# -----------------------------------------------------------------------------
# UI helpers
# -----------------------------------------------------------------------------
check_internet_access() {
	log "Checking internet access to mirror.openshift.com"
	
	if ! curl -s --connect-timeout 5 --max-time 10 https://mirror.openshift.com >/dev/null 2>&1; then
		log "ERROR: No internet access to mirror.openshift.com"
		dialog --colors --clear --title "Internet Access Required" \
			--msgbox \
"[red]ERROR: Internet access required[/red]

Cannot reach: https://mirror.openshift.com

This TUI requires internet access to:
  • Download OpenShift release information
  • Fetch operator catalog indexes
  • Download oc-mirror CLI tool

Please ensure:
  • You have an active internet connection
  • Firewall allows HTTPS access
  • Proxy settings are configured (if needed)

Exiting..." 0 0
		
		log "Exiting due to no internet access"
		exit 1
	fi
	
	log "Internet access confirmed"
}

ui_header() {
	log "Showing header screen"
	
	local rc
	while :; do
		set +e  # Disable exit on error for dialog
		dialog --colors --clear --no-collapse --backtitle "$(ui_backtitle)" --title "ABA – OpenShift Installer" \
			--help-button --help-label "Help" \
			--ok-label "Continue" \
			--msgbox \
"   __   ____   __
  / _\ (  _ \ / _\     Install & manage air-gapped OpenShift quickly
 /    \ ) _ (/    \    with the Aba utility!
 \_/\_/(____/\_/\_/

Follow the instructions below or see the README.md file
for more information.

Press <Continue> to start configuration.
Press <Help> for more information." 0 0
		rc=$?
		set -e  # Re-enable exit on error
		
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
				dialog --backtitle "$(ui_backtitle)" --title "ABA Help" --msgbox \
"ABA (Agent-Based Automation) helps install OpenShift in
disconnected environments.

This wizard configures:
  • OpenShift channel and version
  • Operators to include
  • Platform settings
  • Network configuration

Configuration is saved to aba.conf

For full documentation, see:
  $ABA_ROOT/README.md
  
For help, run: aba --help" 0 0 || true
				# Continue loop to show header again
				;;
			255)
				# ESC - confirm quit
				if confirm_quit; then
					log "User quit from header"
					exit 0
				else
					log "User cancelled quit, staying on header"
					continue
				fi
				;;
			*)
				# Unexpected return code
				log "ERROR: Unexpected header dialog return code: $rc"
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
			machine_network="" dns_servers="" next_hop_address="" ntp_servers="" \
				scripts/j2 templates/aba.conf.j2 > aba.conf
			log "Created aba.conf from templates/aba.conf.j2"
		else
			log "WARNING: No template found at $ABA_ROOT/templates/aba.conf.j2"
		fi
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
			s=${s##[[:space:]]}
			s=${s%%[[:space:]]}
			if [[ -n "$s" ]]; then
				OP_SET_ADDED["$s"]=1
				log "Restored operator set: $s"
			fi
		done
	fi
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
	
	dialog --colors --clear --backtitle "$(ui_backtitle)" --title "OpenShift Channel" \
		--extra-button --extra-label "<< Back" \
		--help-button \
		--ok-label "Next >>" \
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
  Tested and recommended for production
  
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
			return
			;;
		*)
			DIALOG_RC="back"
			return
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
	
	# Only show wait dialog if actually waiting
	if [[ $need_wait -eq 1 ]]; then
		log "Version data not ready, showing wait dialog"
		dialog --backtitle "$(ui_backtitle)" --infobox "Please wait… preparing version list for channel '$OCP_CHANNEL'" 5 80
		run_once -w -i "ocp:${OCP_CHANNEL}:latest_version"
		run_once -w -i "ocp:${OCP_CHANNEL}:latest_version_previous"
	else
		log "Version data already available, no wait needed"
	fi

	latest=$(fetch_latest_version "$OCP_CHANNEL")
	previous=$(fetch_previous_version "$OCP_CHANNEL")
	log "Versions: latest=$latest previous=$previous"

	# Check if current version is different from latest/previous AND exists in this channel
	local show_current=0
	local default_item="l"  # Default to latest
	
	if [[ -n "$OCP_VERSION" ]]; then
		if [[ "$OCP_VERSION" == "$latest" ]]; then
			default_item="l"
		elif [[ "$OCP_VERSION" == "$previous" ]]; then
			default_item="p"
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
	
	if [[ $show_current -eq 1 ]]; then
		menu_items+=("c" "Current  ($OCP_VERSION)")
	fi
	
	menu_items+=("m" "Manual entry (x.y or x.y.z)")

	dialog --colors --clear --backtitle "$(ui_backtitle)" --title "OpenShift Version" \
		--extra-button --extra-label "<< Back" \
		--help-button \
		--ok-label "Next >>" \
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

• Latest: Most recent release in the channel
• Previous: Previous stable release"
			
			if [[ $show_current -eq 1 ]]; then
				help_text="${help_text}
• Current: Version from aba.conf ($OCP_VERSION)"
			fi
			
			help_text="${help_text}
• Manual: Enter specific version (x.y or x.y.z)

Example versions: 4.18.10 or 4.18

The installer will validate and download the
selected version."
			
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
		c) 
			# Keep current version (already in OCP_VERSION)
			log "User selected current version: $OCP_VERSION"
			;;
		m)
			dialog --backtitle "$(ui_backtitle)" --inputbox "Enter OpenShift version (x.y or x.y.z):" 12 70 "$latest" 2>"$TMP" || { DIALOG_RC="back"; return; }
			OCP_VERSION=$(<"$TMP")
			OCP_VERSION=${OCP_VERSION//$'
'/}
			OCP_VERSION=${OCP_VERSION##[[:space:]]}
			OCP_VERSION=${OCP_VERSION%%[[:space:]]}

			if [[ "$OCP_VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
				# Resolve x.y -> latest x.y.z (background + wait just like aba.sh)
				run_once -i "ocp:${OCP_CHANNEL}:${OCP_VERSION}:latest_z" -- \
					bash -lc 'source ./scripts/include_all.sh; fetch_latest_z_version "'$OCP_CHANNEL'" "'$OCP_VERSION'"'
				dialog --backtitle "$(ui_backtitle)" --infobox "Please wait… resolving $OCP_VERSION to latest z-stream" 5 80
				run_once -w -i "ocp:${OCP_CHANNEL}:${OCP_VERSION}:latest_z"
				OCP_VERSION=$(fetch_latest_z_version "$OCP_CHANNEL" "$OCP_VERSION")
			fi
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
			machine_network="" dns_servers="" next_hop_address="" ntp_servers="" \
				scripts/j2 templates/aba.conf.j2 > "$ABA_ROOT/aba.conf"
			log "Created aba.conf from templates/aba.conf.j2"
		else
			log "ERROR: Template not found at $ABA_ROOT/templates/aba.conf.j2"
			dialog --backtitle "$(ui_backtitle)" --msgbox "ERROR: Template file templates/aba.conf.j2 not found!" 0 0
			return 1
		fi
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
	
	# Start catalog downloads immediately in background (now that version is known)
	# Use run_once for each catalog - proper task management and parallelization
	local version_short="${OCP_VERSION%.*}"  # 4.20.8 -> 4.20
	log "Starting catalog download tasks for OCP ${OCP_VERSION} (${version_short})"
	
	# Start all 4 catalog downloads in parallel using run_once
	# Note: download-operator-index.sh sources include_all.sh internally, and expects to be run from $ABA_ROOT
	run_once -i "catalog:${version_short}:redhat-operator" -- bash -lc "cd '$ABA_ROOT' && scripts/download-operator-index.sh redhat-operator"
	run_once -i "catalog:${version_short}:certified-operator" -- bash -lc "cd '$ABA_ROOT' && scripts/download-operator-index.sh certified-operator"
	run_once -i "catalog:${version_short}:redhat-marketplace" -- bash -lc "cd '$ABA_ROOT' && scripts/download-operator-index.sh redhat-marketplace"
	run_once -i "catalog:${version_short}:community-operator" -- bash -lc "cd '$ABA_ROOT' && scripts/download-operator-index.sh community-operator"
	
	set +e
	dialog --backtitle "$(ui_backtitle)" --title "Confirm Selection" \
		--extra-button --extra-label "<< Back" \
		--ok-label "Next >>" \
		--msgbox "Selected:

  Channel: $OCP_CHANNEL
  Version: $OCP_VERSION

Next: Configure platform and network." 0 0
	rc=$?
	set -e
	
	case "$rc" in
		0)
			# OK/Next
			DIALOG_RC="next"
			;;
		3|255)
			# Back or ESC
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
	DIALOG_RC=""
	log "Entering select_pull_secret"
	
	local pull_secret_file="$HOME/.pull-secret.json"
	local error_msg=""
	
	# Check if pull secret exists and is valid
	if [[ -f "$pull_secret_file" ]]; then
		log "Found existing pull secret at $pull_secret_file"
		
		# Validate JSON
		if jq empty "$pull_secret_file" 2>/dev/null; then
			# Check for required registry
			if grep -q "registry.redhat.io" "$pull_secret_file"; then
				log "Pull secret is valid, skipping screen"
				DIALOG_RC="next"
				return
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
	
	# Collect pull secret from user (simplified flow)
	while :; do
		# Show error message if there was a validation issue
		if [[ -n "$error_msg" ]]; then
			# Use dialog's auto-sizing (0 0 = auto height/width)
			dialog --colors --clear --backtitle "$(ui_backtitle)" --title "Validation Error" \
				--msgbox "$error_msg" 0 0 || true
			error_msg=""  # Clear for next iteration
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
		
		# Show editbox with empty file
		dialog --colors --clear --backtitle "$(ui_backtitle)" --title "Red Hat Pull Secret" \
			--extra-button --extra-label "<< Back" \
			--help-button \
			--ok-label "Next >>" \
			--editbox "$empty_file" $dlg_h $dlg_w 2>"$TMP"
		
		rc=$?
		rm -f "$empty_file"
		log "Pull secret editbox returned: $rc"
		
		# Handle ESC - confirm quit
		if [[ $rc -eq 255 ]]; then
			log "User pressed ESC"
			if confirm_quit; then
				log "User confirmed quit from pull secret screen"
				exit 0
			else
				log "User cancelled quit, staying on pull secret screen"
				continue
			fi
		fi
		
		case "$rc" in
			0)
				# Next >> - validate and save
				log "User clicked Next, validating pull secret"
				local pull_secret=$(<"$TMP")
				
				# Check if empty
			if [[ -z "$pull_secret" || "$pull_secret" =~ ^[[:space:]]*$ ]]; then
				error_msg="\Z1ERROR: Pull secret is empty\Zn

Please paste your pull secret and press <Next >>

Get it from:
  https://console.redhat.com/openshift/install/pull-secret

Press <Help> for more information."
				log "User didn't paste anything, showing error"
				continue
			fi
				
				# Validate the pasted content
				if echo "$pull_secret" | jq empty 2>/dev/null; then
					if echo "$pull_secret" | grep -q "registry.redhat.io"; then
						# Valid! Save it
						echo "$pull_secret" > "$pull_secret_file"
						chmod 600 "$pull_secret_file"
						log "Pull secret saved successfully to $pull_secret_file"
						
						DIALOG_RC="next"
						return
				else
					log "Pull secret missing registry.redhat.io"
					error_msg="\Z1ERROR: Invalid Pull Secret\Zn

The pull secret does not contain 'registry.redhat.io'.

Please ensure you copied the complete pull secret from:
  https://console.redhat.com/openshift/install/pull-secret

Press <Help> for more information."
					continue
				fi
			else
				log "Pull secret is not valid JSON"
				error_msg="\Z1ERROR: Invalid JSON Format\Zn

The pasted content is not valid JSON.

Please copy the ENTIRE pull secret from the Red Hat console.
It should start with { and end with }

Press <Help> for more information."
				continue
			fi
				;;
			2)
				# Help button
			log "Help button pressed in pull secret"
			dialog --colors --clear --backtitle "$(ui_backtitle)" --msgbox \
"[bold]Red Hat Pull Secret - Instructions[/bold]

[cyan]What is it?[/cyan]
The pull secret is a JSON file containing authentication credentials
for downloading OpenShift images from Red Hat registries.

[cyan]How to get your pull secret:[/cyan]
  1. Visit: https://console.redhat.com/openshift/install/pull-secret
  2. Log in with your Red Hat account
  3. Click 'Copy pull secret'
  4. Return to this TUI and paste into the blank field
  5. Press <Next >>

[cyan]Requirements:[/cyan]
  • Must be valid JSON format (starts with { ends with })
  • Must contain 'registry.redhat.io' credentials

[cyan]What it's used for:[/cyan]
  • Downloading OpenShift release images
  • Accessing Red Hat operator catalogs
  • Pulling certified container images

[cyan]Security:[/cyan]
  • Saved to: ~/.pull-secret.json
  • Permissions: 600 (read/write for owner only)

[cyan]Tip:[/cyan]
Copy from browser → paste directly into the blank field → Next" 0 0 || true
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

	while :; do
		# Use simpler fixed dialog size for stability
		local dlg_h=18
		local dlg_w=75
		
		log "Showing platform menu dialog..."
		log "  DLG_H=$dlg_h DLG_W=$dlg_w"
		log "  PLATFORM=${PLATFORM:-bm}"
		log "  DOMAIN=${DOMAIN:-example.com}"
		log "  MACHINE_NETWORK=${MACHINE_NETWORK:-(auto-detect)}"
		log "  DNS_SERVERS=${DNS_SERVERS:-(auto-detect)}"
		log "  NEXT_HOP_ADDRESS=${NEXT_HOP_ADDRESS:-(auto-detect)}"
		log "  NTP_SERVERS=${NTP_SERVERS:-(auto-detect)}"
		
		log "About to show platform menu dialog..."
		
		# Use explicit arguments (no array expansion issues)
		set +e  # Temporarily disable exit on error
		dialog --colors --clear --backtitle "$(ui_backtitle)" --title "Platform & Network" \
			--extra-button --extra-label "Accept & Next >>" \
			--help-button \
			--ok-label "Select" \
			--cancel-label "<< Back" \
			--menu "Configure platform and network:" $dlg_h $dlg_w 8 \
			1 "\ZbAccept\Zn" \
			2 "Platform: ${PLATFORM:-bm}" \
			3 "Base Domain: ${DOMAIN:-example.com}" \
			4 "Machine Network: ${MACHINE_NETWORK:-(auto-detect)}" \
			5 "DNS Servers: ${DNS_SERVERS:-(auto-detect)}" \
			6 "Default Route: ${NEXT_HOP_ADDRESS:-(auto-detect)}" \
			7 "NTP Servers: ${NTP_SERVERS:-(auto-detect)}" \
			2>"$TMP"
		rc=$?
		set -e  # Re-enable exit on error
		
		log "Platform menu dialog returned: $rc"
		
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
• DNS Servers: Comma-separated IPs (e.g., 8.8.8.8,1.1.1.1)
• Default Route: Gateway IP for cluster network
• NTP Servers: Time sync servers (IPs or hostnames)

Leave blank to use auto-detected values." 0 0 || true
				continue
				;;
			3)
				# Extra button = "Accept & Next"
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
			# Accept - move to next
			DIALOG_RC="next"
			log "User selected Accept, moving to next"
			return
			;;
		2)
			log "Showing platform selection menu"
			dialog --backtitle "$(ui_backtitle)" --title "Target Platform" \
				--default-item "${PLATFORM:-bm}" \
				--menu "Select target platform:" 0 0 2 \
				bm "Bare Metal" \
				vmw "VMware (vSphere/ESXi)" \
				2>"$TMP" || { log "Platform menu cancelled"; continue; }
			PLATFORM=$(<"$TMP")
			log "Platform set to: $PLATFORM"
			;;
			3)
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
				;;
			4)
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
				;;
			5)
				log "Showing DNS servers inputbox"
				while :; do
					dialog --backtitle "$(ui_backtitle)" --inputbox "DNS Servers (comma-separated IPs):" 10 70 "$DNS_SERVERS" 2>"$TMP" || { log "DNS input cancelled"; break; }
					input=$(<"$TMP")
					input=${input##[[:space:]]}
					input=${input%%[[:space:]]}
					
					# Allow empty (auto-detect) or valid IP list
					if [[ -n "$input" ]] && ! validate_ip_list "$input"; then
						dialog --backtitle "$(ui_backtitle)" --msgbox "Invalid IP address format. Please enter comma-separated IPs (e.g., 8.8.8.8,1.1.1.1)" 0 0
						continue
					fi
					DNS_SERVERS="$input"
					log "DNS servers set to: $DNS_SERVERS"
					break
				done
				;;
			6)
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
				;;
			7)
				log "Showing NTP servers inputbox"
				while :; do
					dialog --backtitle "$(ui_backtitle)" --inputbox "NTP Servers (comma-separated IPs or hostnames):" 10 70 "$NTP_SERVERS" 2>"$TMP" || { log "NTP input cancelled"; break; }
					input=$(<"$TMP")
					input=${input##[[:space:]]}
					input=${input%%[[:space:]]}
					
					# Allow empty (auto-detect) or valid NTP server list
					if [[ -n "$input" ]] && ! validate_ntp_servers "$input"; then
						dialog --backtitle "$(ui_backtitle)" --msgbox "Invalid NTP server format. Please enter comma-separated IPs or hostnames (e.g., pool.ntp.org,time.google.com,192.168.1.1)" 0 0
						continue
					fi
					NTP_SERVERS="$input"
					log "NTP servers set to: $NTP_SERVERS"
					break
				done
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

	# Start additional background tasks (catalog already started after version selection)
	log "Starting additional background tasks for operators"
	log "Starting registry download task"
	run_once -i mirror:reg:download -- make -s -C "$ABA_ROOT/mirror" download-registries
	log "Starting CLI downloads"
	run_once -i cli:download:all -- "$ABA_ROOT/scripts/cli-download-all.sh"
	
	# WAIT for catalog indexes to download (needed for operator sets AND search)
	local version_short="$(echo "$OCP_VERSION" | cut -d. -f1-2)"
	log "Checking if catalog indexes need to be downloaded..."
	
	# Peek first to see if we need to wait
	local need_wait=0
	for catalog in redhat-operator certified-operator redhat-marketplace community-operator; do
		local task_id="catalog:${version_short}:${catalog}"
		if ! run_once -p -i "$task_id"; then
			log "Catalog $catalog not yet complete"
			need_wait=1
			break
		fi
	done
	
	# Only show wait dialog if actually waiting
	if [[ $need_wait -eq 1 ]]; then
		log "Catalogs not ready, showing wait dialog..."
		dialog --backtitle "$(ui_backtitle)" --infobox "Waiting for operator catalog indexes to finish downloading for OpenShift ${version_short}

This may take 1-2 minutes on first run..." 7 80
	else
		log "All catalogs already downloaded, proceeding immediately"
	fi
	
	# Wait for all 4 catalog downloads to complete (run_once manages them in parallel)
	# Note: redhat-operator and certified-operator are REQUIRED
	#       redhat-marketplace and community-operator are OPTIONAL
	local critical_failed=0
	local optional_failed=0
	local failed_critical=""
	local failed_optional=""
	
	# Check critical catalogs (must succeed)
	for catalog in redhat-operator certified-operator; do
		local task_id="catalog:${version_short}:${catalog}"
		log "Waiting for CRITICAL catalog: $catalog"
		if ! run_once -w -i "$task_id"; then
			log "ERROR: Failed to download CRITICAL $catalog catalog"
			critical_failed=1
			failed_critical="${failed_critical}  - $catalog\n"
		fi
	done
	
	# Check optional catalogs (nice to have)
	for catalog in redhat-marketplace community-operator; do
		local task_id="catalog:${version_short}:${catalog}"
		log "Waiting for OPTIONAL catalog: $catalog"
		if ! run_once -w -i "$task_id"; then
			log "WARNING: Failed to download optional $catalog catalog"
			optional_failed=1
			failed_optional="${failed_optional}  - $catalog\n"
		fi
	done
	
	# Block only if critical catalogs failed
	if [[ $critical_failed -eq 1 ]]; then
		log "ERROR: Critical catalog downloads failed"
		dialog --colors --backtitle "$(ui_backtitle)" --msgbox \
"\Z1ERROR: Failed to download critical operator catalogs\Zn

Cannot proceed without these required catalogs.

Failed:
$failed_critical
Check logs in: ~/.aba/runner/catalog:${version_short}:*.log

Try running: make catalog" 0 0
		DIALOG_RC="back"
		return
	fi
	
	# Warn if optional catalogs failed, but allow to continue
	if [[ $optional_failed -eq 1 ]]; then
		log "WARNING: Optional catalog downloads failed, but continuing"
		dialog --colors --backtitle "$(ui_backtitle)" --msgbox \
"\Z3WARNING: Optional catalogs failed to download\Zn

These catalogs are not critical:
$failed_optional
You can continue without them. These operators won't be
available for selection:
  - Red Hat Marketplace operators
  - Community operators

Press OK to continue." 0 0 || true
	fi
	
	log "Catalog indexes ready. Starting operators menu with ${#OP_BASKET[@]} operators in basket"

	while :; do
		# Count the basket items for display
		local basket_count="${#OP_BASKET[@]}"
		log "Menu loop: basket has $basket_count operators"
		
		log "About to show operators menu dialog..."
		
		set +e  # Temporarily disable exit on error
		dialog --colors --clear --backtitle "$(ui_backtitle)" --title "Operators" \
			--extra-button --extra-label "<< Back" \
			--help-button \
			--ok-label "Select" \
			--cancel-label "Accept & Next >>" \
			--menu "Select operator actions:" 0 0 8 \
			1 "Select Operator Sets" \
			2 "Search Operator Names" \
			3 "View/Edit Basket ($basket_count operators)" \
			4 "Clear Basket" \
			5 "\ZbAccept\Zn" \
			2>"$TMP"
		rc=$?
		set -e  # Re-enable exit on error
		
		log "Operators menu dialog returned: $rc"
		
		case "$rc" in
			0)
				# OK - process the action
				: # Continue to action handler below
				;;
			1)
				# Cancel button = "Accept & Next"
				# Check if basket is empty and warn
				if [[ ${#OP_BASKET[@]} -eq 0 ]]; then
					log "Empty basket - showing warning"
					set +e
					dialog --backtitle "$(ui_backtitle)" --title "Empty Basket" \
						--extra-button --extra-label "<< Back" \
						--yes-label "Continue Anyway" \
						--no-label "Add Operators" \
						--yesno "No operators selected. Continue with empty basket?\n\nYou can add operators later as Day-2 operations." 0 0
					empty_rc=$?
					set -e
					
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
  
• View Basket: See selected operators
  
• Clear Basket: Remove all operators

Selected operators will be included in the
image synchronization process." 16 70 || true
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
				# Add operator sets to basket (sets are add-only)
				log "=== Operator Set Selection ==="
				log "Before set selection - Basket count: ${#OP_BASKET[@]}"
				
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
				dialog --clear --backtitle "$(ui_backtitle)" --title "Operator Sets" \
					--checklist "Select operator sets to add to basket:" 0 0 15 \
					"${items[@]}" 2>"$TMP" || continue

				newsel=$(<"$TMP")
				log "Raw selection: [$newsel]"
				
				# Parse dialog output and add selected sets to basket
				while read -r k; do
					k=${k//\"/}
					k=${k##[[:space:]]}
					k=${k%%[[:space:]]}
					[[ -z "$k" ]] && continue
					
					log "Adding operator set: [$k]"
					OP_SET_ADDED["$k"]=1
					add_set_to_basket "$k" || true
				done < <(echo "$newsel" | tr ' ' '\n')
					
				log "After set selection - Basket count: ${#OP_BASKET[@]}"
				log "Basket contents: ${!OP_BASKET[*]}"
				;;

			2)
			# Search operators (needs index files)
			log "User searching operators (catalog already loaded)"
		
		dialog --colors --backtitle "$(ui_backtitle)" --inputbox "Search operator names (min 2 chars, multiple terms AND'ed):" 0 0 2>"$TMP" || continue
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
			dialog --clear --backtitle "$(ui_backtitle)" --title "Select Operators" \
				--checklist "Toggle operators (already-selected are ON):" 0 0 18 \
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
				;;

			3)
				# View basket (allow multi-select adjustments)
				log "=== View Basket ==="
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
			dialog --clear --backtitle "$(ui_backtitle)" --title "Basket (${#OP_BASKET[@]} operators)" \
				--checklist "Uncheck operators to remove them from the basket." \
				0 0 18 \
					"${items[@]}" 2>"$TMP" || continue

				newsel=$(<"$TMP")
				log "View basket selection: [$newsel]"
				
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
				;;

			4)
			dialog --backtitle "$(ui_backtitle)" --yesno "Clear operator basket?" 10 55 && {
				log "Clearing operator basket"
				OP_BASKET=()
				OP_SET_ADDED=()
			}
				;;

			5)
				DIALOG_RC="next"
				return
				;;
		esac
	done
}

# -----------------------------------------------------------------------------
# Step 5: Summary / Apply
# -----------------------------------------------------------------------------
summary_apply() {
	log "Entering summary_apply"
	
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

	summary_text="
═══════════════════════════════════════════════════
               OPENSHIFT CONFIGURATION
═══════════════════════════════════════════════════

Channel:         $OCP_CHANNEL
Version:         $OCP_VERSION

Platform:        ${PLATFORM:-bm}
Domain:          ${DOMAIN:-example.com}

Network:         ${MACHINE_NETWORK:-(auto-detect)}
DNS Servers:     ${DNS_SERVERS:-(auto-detect)}
Default Route:   ${NEXT_HOP_ADDRESS:-(auto-detect)}
NTP Servers:     ${NTP_SERVERS:-(auto-detect)}

Operator Set:    ${op_sets_value:-(none)}
Operators:       $op_summary

═══════════════════════════════════════════════════"

	while :; do
		# Show summary with action buttons
		set +e
		dialog --colors --clear --backtitle "$(ui_backtitle)" --title "Configuration Summary" \
			--extra-button --extra-label "Save Draft" \
			--help-button \
			--yes-label "Apply to aba.conf" \
			--no-label "<< Back" \
			--yesno "$summary_text" 0 0
		rc=$?
		set -e
		
		case "$rc" in
			0)
				# Yes = Apply to aba.conf
				log "Applying configuration to aba.conf"
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
				log "Configuration applied successfully"
				
				# Build success message
				local success_msg="Configuration applied to aba.conf"
				if [[ -n "$custom_set_name" ]]; then
					success_msg="${success_msg}

Custom operator set created:
  templates/operator-set-${custom_set_name}
  (${#OP_BASKET[@]} operators)"
				fi
				success_msg="${success_msg}

Next steps:
  1. aba -d mirror install    (setup registry)
  2. aba -d mirror sync       (download images)
  3. aba cluster --name <name> (create cluster)

See: aba --help"
				
				dialog --backtitle "$(ui_backtitle)" --msgbox "$success_msg" 0 0 || true
				return 0
				;;
			3)
				# Extra button = Save Draft
				log "Saving draft configuration"
				cat > aba.conf.draft <<EOF
# ABA Configuration Draft
# Generated by ABA TUI on $(date)

ocp_channel=$OCP_CHANNEL
ocp_version=$OCP_VERSION
platform=${PLATFORM:-bm}
domain=${DOMAIN}
machine_network=${MACHINE_NETWORK}
dns_servers=${DNS_SERVERS}
next_hop_address=${NEXT_HOP_ADDRESS}
ntp_servers=${NTP_SERVERS}
ops=
op_sets=$op_sets_value
EOF
				# Build draft message
				local draft_msg="Draft saved to: aba.conf.draft"
				if [[ -n "$custom_set_name" ]]; then
					draft_msg="${draft_msg}

Custom operator set created:
  templates/operator-set-${custom_set_name}
  (${#OP_BASKET[@]} operators)"
				fi
				draft_msg="${draft_msg}

To apply later:
  mv aba.conf.draft aba.conf"
				
				dialog --backtitle "$(ui_backtitle)" --msgbox "$draft_msg" 0 0 || true
				
				log "Draft saved, continuing in summary"
				continue  # Stay in summary screen loop
				;;
			1)
				# No = Back
				log "User went back from summary"
				return 1
				;;
			255)
				# ESC - confirm quit
				if confirm_quit; then
					log "User confirmed quit from summary screen"
					exit 0
				else
					log "User cancelled quit, staying on summary screen"
					continue
				fi
				;;
			2)
				# Help
				dialog --backtitle "$(ui_backtitle)" --msgbox \
"Summary Actions:

• Apply to aba.conf
  Writes all configuration to aba.conf
  Ready for next steps (mirror setup, cluster install)
  
• Save Draft
  Saves to aba.conf.draft for later editing
  Does not overwrite existing aba.conf
  
• Back
  Return to operators selection

Log file: $LOG_FILE" 0 0 || true
				continue
				;;
			*)
				log "Unexpected summary dialog return code: $rc"
				return 1
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

# Start background version fetches immediately (for all channels)
log "Starting background OCP version fetches for all channels"
run_once -i "ocp:stable:latest_version"             -- bash -lc 'source ./scripts/include_all.sh; fetch_latest_version stable'
run_once -i "ocp:stable:latest_version_previous"    -- bash -lc 'source ./scripts/include_all.sh; fetch_previous_version stable'

run_once -i "ocp:fast:latest_version"               -- bash -lc 'source ./scripts/include_all.sh; fetch_latest_version fast'
run_once -i "ocp:fast:latest_version_previous"      -- bash -lc 'source ./scripts/include_all.sh; fetch_previous_version fast'

run_once -i "ocp:candidate:latest_version"          -- bash -lc 'source ./scripts/include_all.sh; fetch_latest_version candidate'
run_once -i "ocp:candidate:latest_version_previous" -- bash -lc 'source ./scripts/include_all.sh; fetch_previous_version candidate'

log "Background OCP version fetches started"

# Show header
ui_header

# Initialize configuration and global arrays
resume_from_conf

log "After resume_from_conf:"
log "  OP_BASKET type: $(declare -p OP_BASKET 2>&1)"
log "  OP_BASKET count: ${#OP_BASKET[@]}"
log "  OP_SET_ADDED count: ${#OP_SET_ADDED[@]}"
log "Starting wizard loop"

STEP="channel"
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
		select_pull_secret
		[[ "$DIALOG_RC" == "next" ]] && STEP="platform"
		[[ "$DIALOG_RC" == "back" ]] && STEP="version"
		;;
	platform)
		select_platform_network
		[[ "$DIALOG_RC" == "next" ]] && STEP="operators"
		[[ "$DIALOG_RC" == "back" ]] && STEP="pull_secret"
		;;
		operators)
			select_operators
			[[ "$DIALOG_RC" == "next" ]] && STEP="summary"
			[[ "$DIALOG_RC" == "back" ]] && STEP="platform"
			;;
		summary)
			if summary_apply; then
				break
			else
				STEP="operators"
			fi
			;;
	esac
done

clear
log "TUI completed successfully"
echo "TUI complete. Configuration saved to aba.conf"
echo
echo "Log file: $LOG_FILE"
echo
echo "Next steps:"
echo "  1. aba -d mirror install    # Setup registry"
echo "  2. aba -d mirror sync       # Download images"
echo "  3. aba cluster --name <name> # Create cluster"
