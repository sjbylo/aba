#!/usr/bin/env bash
# ABA TUI – Wizard Prototype (Bash + dialog)
#
# Wizard flow:
#   Channel  <->  Version  <->  Operators  <->  Summary / Apply

set -eo pipefail

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
LOG_FILE="${TMPDIR:-/tmp}/aba-tui-$$.log"
export LOG_FILE

log() {
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

log "=========================================="
log "ABA TUI started"
log "=========================================="

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
ui_header() {
	log "Showing header screen"
	
	local rc
	while :; do
		calc_dlg_size 0 70
		dialog --clear --backtitle "$(ui_backtitle)" --title "ABA – OpenShift Installer" \
			--help-button --help-label "Help" \
			--msgbox \
"Install & manage air-gapped OpenShift quickly with Aba.

Press <OK> to continue.
Press <Help> for more information." $DLG_H $DLG_W
		
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
			calc_dlg_size 0 70
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
  
For help, run: aba --help" $DLG_H $DLG_W
			# Continue loop to show header again
			;;
			*)
				# ESC or other - exit
				log "User cancelled header (rc=$rc)"
				exit 0
				;;
		esac
	done
}

# -----------------------------------------------------------------------------
# Resume from aba.conf (best-effort)
# -----------------------------------------------------------------------------
resume_from_conf() {
	log "Resuming from aba.conf"
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

	# Prefetch versions for ALL channels (aba.sh style)
	log "Starting background version fetches"
	run_once -i "ocp:stable:latest_version"             -- bash -lc 'source ./scripts/include_all.sh; fetch_latest_version stable'
	run_once -i "ocp:stable:latest_version_previous"    -- bash -lc 'source ./scripts/include_all.sh; fetch_previous_version stable'

	run_once -i "ocp:fast:latest_version"               -- bash -lc 'source ./scripts/include_all.sh; fetch_latest_version fast'
	run_once -i "ocp:fast:latest_version_previous"      -- bash -lc 'source ./scripts/include_all.sh; fetch_previous_version fast'

	run_once -i "ocp:candidate:latest_version"          -- bash -lc 'source ./scripts/include_all.sh; fetch_latest_version candidate'
	run_once -i "ocp:candidate:latest_version_previous" -- bash -lc 'source ./scripts/include_all.sh; fetch_previous_version candidate'

	# Preselect based on resumed value
	local c_state="off" f_state="off" s_state="off"
	case "${OCP_CHANNEL:-stable}" in
		candidate) c_state="on" ;;
		fast) f_state="on" ;;
		stable|"") s_state="on" ;;
	esac

	calc_dlg_size 3 50
	dialog --clear --backtitle "$(ui_backtitle)" --title "OpenShift Channel" \
		--extra-button --extra-label "<BACK>" \
		--help-button \
		--radiolist "Choose the OpenShift update channel:" $DLG_H $DLG_W 7 \
		c "candidate  – Preview" "$c_state" \
		f "fast       – Latest GA" "$f_state" \
		s "stable     – Recommended" "$s_state" \
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
			calc_dlg_size 0 70
			dialog --backtitle "$(ui_backtitle)" --msgbox \
"OpenShift Update Channels:

• stable (Recommended)
  Tested and recommended for production
  
• fast (Latest GA)
  Latest Generally Available release
  
• candidate (Preview)
  Preview/beta releases for testing

See: https://docs.openshift.com/container-platform/latest/updating/understanding_updates/understanding-update-channels-release.html" $DLG_H $DLG_W
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

	dialog --backtitle "$(ui_backtitle)" --infobox "Please wait… preparing version list for channel '$OCP_CHANNEL'" 5 80
	log "Waiting for version data for channel: $OCP_CHANNEL"
	run_once -w -i "ocp:${OCP_CHANNEL}:latest_version"
	run_once -w -i "ocp:${OCP_CHANNEL}:latest_version_previous"

	latest=$(fetch_latest_version "$OCP_CHANNEL")
	previous=$(fetch_previous_version "$OCP_CHANNEL")
	log "Versions: latest=$latest previous=$previous"

	calc_dlg_size 3 60
	dialog --clear --backtitle "$(ui_backtitle)" --title "OpenShift Version" \
		--extra-button --extra-label "<BACK>" \
		--help-button \
		--menu "Choose the OpenShift version to install:" $DLG_H $DLG_W 7 \
		l "Latest   ($latest)" \
		p "Previous ($previous)" \
		m "Manual entry (x.y or x.y.z)" \
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
			calc_dlg_size 0 70
			dialog --backtitle "$(ui_backtitle)" --msgbox \
"OpenShift Version Selection:

• Latest: Most recent release in the channel
• Previous: Previous stable release
• Manual: Enter specific version (x.y or x.y.z)

Example versions: 4.18.10 or 4.18

The installer will validate and download the
selected version." $DLG_H $DLG_W
			DIALOG_RC="repeat"
			return
			;;
		3|1|255)
			# Back/Cancel/ESC
			DIALOG_RC="back"
			log "User went back from version (rc=$rc)"
			return
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
	log "Writing minimal aba.conf for background tasks"
	
	# Create aba.conf with minimal content if it doesn't exist
	# (replace-value-conf requires non-empty file)
	if [[ ! -s "$ABA_ROOT/aba.conf" ]]; then
		cat > "$ABA_ROOT/aba.conf" <<-'EOF'
			# ABA Configuration (generated by TUI)
			ocp_channel=
			ocp_version=
			platform=
		EOF
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
	
	# Start catalog download immediately in background (now that version is known)
	# Include version in task ID so different versions get different catalogs
	local version_short="${OCP_VERSION%.*}"  # 4.20.8 -> 4.20
	log "Starting catalog download task for OCP ${OCP_VERSION} (${version_short})"
	run_once -i "download_catalog_indexes:${version_short}" -- make -C "$ABA_ROOT" catalog
	
	calc_dlg_size 0 60
	dialog --backtitle "$(ui_backtitle)" --msgbox "Selected:

  Channel: $OCP_CHANNEL
  Version: $OCP_VERSION

Next: Configure platform and network." $DLG_H $DLG_W

	DIALOG_RC="next"
}

# -----------------------------------------------------------------------------
# Step 3: Platform and Network Configuration
# -----------------------------------------------------------------------------
select_platform_network() {
	DIALOG_RC=""
	log "Entering select_platform_network"

	while :; do
		calc_dlg_size 7 60
		dialog --colors --clear --backtitle "$(ui_backtitle)" --title "Platform & Network" \
			--extra-button --extra-label "<BACK>" \
			--help-button \
			--menu "Configure platform and network:" $DLG_H $DLG_W 8 \
			1 "Platform: ${PLATFORM:-bm}" \
			2 "Base Domain: ${DOMAIN:-example.com}" \
			3 "Machine Network: ${MACHINE_NETWORK:-(auto-detect)}" \
		4 "DNS Servers: ${DNS_SERVERS:-(auto-detect)}" \
		5 "Default Route: ${NEXT_HOP_ADDRESS:-(auto-detect)}" \
		6 "NTP Servers: ${NTP_SERVERS:-(auto-detect)}" \
		7 "\ZbAccept\Zn" \
			2>"$TMP"

		rc=$?
		if [[ $rc -eq 2 ]]; then
			# Help button
			calc_dlg_size 0 70
			dialog --backtitle "$(ui_backtitle)" --msgbox \
"Platform & Network Configuration:

• Platform: bm (bare-metal) or vmw (VMware)
• Base Domain: DNS domain for cluster (e.g., example.com)
• Machine Network: CIDR for cluster nodes (e.g., 10.0.0.0/24)
• DNS Servers: Comma-separated IPs (e.g., 8.8.8.8,1.1.1.1)
• Default Route: Gateway IP for cluster network
• NTP Servers: Time sync servers (IPs or hostnames)

Leave blank to use auto-detected values." $DLG_H $DLG_W
			continue
		fi
		
		# Handle BACK, Cancel, ESC
		if [[ "$rc" == 3 || "$rc" == 1 || "$rc" == 255 ]]; then
			DIALOG_RC="back"
			log "User went back from platform (rc=$rc)"
			return
		fi
		[[ "$rc" != 0 ]] && { DIALOG_RC="back"; return; }

		action=$(<"$TMP")
		case "$action" in
			1)
				dialog --backtitle "$(ui_backtitle)" --radiolist "Target Platform:" $DLG_H $DLG_W 3 \
					bm "Bare Metal" $([ "$PLATFORM" = "bm" ] && echo "on" || echo "off") \
					vmw "VMware (vSphere/ESXi)" $([ "$PLATFORM" = "vmw" ] && echo "on" || echo "off") \
					2>"$TMP" || continue
				PLATFORM=$(<"$TMP")
				log "Platform set to: $PLATFORM"
				;;
			2)
				dialog --backtitle "$(ui_backtitle)" --inputbox "Base Domain (e.g., example.com):" 10 70 "$DOMAIN" 2>"$TMP" || continue
				DOMAIN=$(<"$TMP")
				DOMAIN=${DOMAIN##[[:space:]]}
				DOMAIN=${DOMAIN%%[[:space:]]}
				log "Domain set to: $DOMAIN"
				;;
			3)
				dialog --backtitle "$(ui_backtitle)" --inputbox "Machine Network CIDR (e.g., 10.0.0.0/24):" 10 70 "$MACHINE_NETWORK" 2>"$TMP" || continue
				MACHINE_NETWORK=$(<"$TMP")
				MACHINE_NETWORK=${MACHINE_NETWORK##[[:space:]]}
				MACHINE_NETWORK=${MACHINE_NETWORK%%[[:space:]]}
				log "Machine network set to: $MACHINE_NETWORK"
				;;
			4)
				dialog --backtitle "$(ui_backtitle)" --inputbox "DNS Servers (comma-separated IPs):" 10 70 "$DNS_SERVERS" 2>"$TMP" || continue
				DNS_SERVERS=$(<"$TMP")
				DNS_SERVERS=${DNS_SERVERS##[[:space:]]}
				DNS_SERVERS=${DNS_SERVERS%%[[:space:]]}
				log "DNS servers set to: $DNS_SERVERS"
				;;
			5)
				dialog --backtitle "$(ui_backtitle)" --inputbox "Default Route (gateway IP):" 10 70 "$NEXT_HOP_ADDRESS" 2>"$TMP" || continue
				NEXT_HOP_ADDRESS=$(<"$TMP")
				NEXT_HOP_ADDRESS=${NEXT_HOP_ADDRESS##[[:space:]]}
				NEXT_HOP_ADDRESS=${NEXT_HOP_ADDRESS%%[[:space:]]}
				log "Default route set to: $NEXT_HOP_ADDRESS"
				;;
			6)
				dialog --backtitle "$(ui_backtitle)" --inputbox "NTP Servers (comma-separated):" 10 70 "$NTP_SERVERS" 2>"$TMP" || continue
				NTP_SERVERS=$(<"$TMP")
				NTP_SERVERS=${NTP_SERVERS##[[:space:]]}
				NTP_SERVERS=${NTP_SERVERS%%[[:space:]]}
				log "NTP servers set to: $NTP_SERVERS"
				;;
			7)
				DIALOG_RC="next"
				return
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

	while IFS= read -r op; do
		[[ "$op" =~ ^# ]] && continue
		op=${op%%#*}
		op=${op//$'
'/}
		op=${op##[[:space:]]}
		op=${op%%[[:space:]]}
		[[ -z "$op" ]] && continue

		log "Adding operator from set: $op"
		OP_BASKET["$op"]=1
	done <"$file"
	
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
	run_once -i mirror:reg:download      -- make -s -C "$ABA_ROOT/mirror" download-registries
	log "Starting CLI downloads"
	"$ABA_ROOT/scripts/cli-download-all.sh" >/dev/null 2>&1 || true
	
	log "Starting operators menu with ${#OP_BASKET[@]} operators in basket"

	while :; do
		# Count the basket items for display
		local basket_count="${#OP_BASKET[@]}"
		log "Menu loop: basket has $basket_count operators"
		
	calc_dlg_size 5 60
	dialog --colors --clear --backtitle "$(ui_backtitle)" --title "Operators" \
		--extra-button --extra-label "<BACK>" \
		--help-button \
		--menu "Select operator actions ($basket_count in basket):" $DLG_H $DLG_W 8 \
		1 "Select Operator Set" \
	2 "Search Operator Names" \
	3 "View Basket ($basket_count)" \
	4 "Clear Basket" \
	5 "\ZbAccept\Zn" \
		2>"$TMP"

		rc=$?
		log "Operators menu dialog returned: $rc"
		
		case "$rc" in
			0)
				# OK - process the action
				: # Continue
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
image synchronization process." 16 70
			continue
			;;
		3|1|255)
			# Back/Cancel/ESC
			DIALOG_RC="back"
			log "User went back from operators (rc=$rc)"
			return
			;;
			*)
				DIALOG_RC="back"
				return
				;;
		esac

		action=$(<"$TMP")
		case "$action" in
			1)
				# Add operator sets to basket (sets are add-only)
				log "=== Operator Set Selection ==="
				log "Before set selection - Basket count: ${#OP_BASKET[@]}"
				
			items=()
			for f in "$ABA_ROOT"/templates/operator-set-*; do
				[[ -f "$f" ]] || continue
				key=${f##*/operator-set-}
				display=$(head -n1 "$f" 2>/dev/null | sed 's/^# *//')
				[[ -z "$display" ]] && display="$key"

				# Always show as unselected - user picks what to add each time
				items+=("$key" "$display" "off")
			done

			[[ "${#items[@]}" -eq 0 ]] && {
				calc_dlg_size 0 70
				dialog --backtitle "$(ui_backtitle)" --msgbox "No operator-set templates found under: $ABA_ROOT/templates" $DLG_H $DLG_W
				continue
			}

		# Calculate size based on number of operator sets (items has 3 elements per set)
		local num_sets=$((${#items[@]} / 3))
		calc_dlg_size "$num_sets" 80
		dialog --clear --backtitle "$(ui_backtitle)" --title "Operator Sets" \
			--checklist "Select operator sets to add to basket:" $DLG_H $DLG_W 15 \
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
			log "User searching operators"
			
		# Always wait for catalog indexes to be ready
		# Show informative message about what's being downloaded
		log "Ensuring catalog indexes are ready..."
		local version_short="${OCP_VERSION%.*}"  # 4.20.8 -> 4.20
		dialog --backtitle "$(ui_backtitle)" --infobox "Please wait… downloading operator catalog indexes for OpenShift ${OCP_VERSION} (${version_short})

This may take 1-2 minutes on first run..." 7 80
		
		# Wait for download task to complete (returns immediately if already done)
		# IMPORTANT: Use exact same task ID and command as when starting the task!
		log "Waiting for catalog download for ${version_short}"
		if ! run_once -w -i "download_catalog_indexes:${version_short}" -- make -C "$ABA_ROOT" catalog; then
			log "Failed to download catalog indexes for ${version_short} (exit code: $?)"
			log "Check runner log: ~/.aba/runner/download_catalog_indexes:${version_short}.log"
			calc_dlg_size 0 70
			dialog --backtitle "$(ui_backtitle)" --msgbox "Failed to download operator catalogs for ${version_short}.\n\nCheck log: ~/.aba/runner/download_catalog_indexes:${version_short}.log\n\nTry running: make catalog" $DLG_H $DLG_W
			continue
		fi
		
		log "Catalog indexes for ${version_short} ready"
			calc_dlg_size 0 80
		dialog --backtitle "$(ui_backtitle)" --inputbox "Search operator names (min 2 chars, multiple terms AND'ed):" $DLG_H $DLG_W 2>"$TMP" || continue
			query=$(<"$TMP")
			query=${query//$'
'/}
			query=${query##[[:space:]]}
			query=${query%%[[:space:]]}
			
			# Require at least 2 characters
			if [[ -z "$query" ]] || [[ ${#query} -lt 2 ]]; then
				calc_dlg_size 0 50
				dialog --backtitle "$(ui_backtitle)" --msgbox "Please enter at least 2 characters to search" $DLG_H $DLG_W
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
			calc_dlg_size 0 60
			dialog --backtitle "$(ui_backtitle)" --msgbox "No matches for: $query\n\nAll search terms must match the operator name." $DLG_H $DLG_W
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
			calc_dlg_size "$num_ops" 70
			dialog --clear --backtitle "$(ui_backtitle)" --title "Select Operators" \
				--checklist "Toggle operators (already-selected are ON):" $DLG_H $DLG_W 18 \
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
				calc_dlg_size 0 40
				dialog --backtitle "$(ui_backtitle)" --msgbox "Basket is empty." $DLG_H $DLG_W
				continue
			fi

			log "Displaying ${#items[@]} items in basket view"
			# Calculate size based on number of operators in basket
			local num_ops=$((${#items[@]} / 3))
			calc_dlg_size "$num_ops" 70
			dialog --clear --backtitle "$(ui_backtitle)" --title "Basket (${#OP_BASKET[@]} operators)" \
				--checklist "Uncheck operators to remove them from the basket." \
				$DLG_H $DLG_W 18 \
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
	
	# Build comma-separated values for aba.conf
	ops_csv=$(printf "%s\n" "${!OP_BASKET[@]}" | sort | paste -sd, -)
	op_sets_csv=$(printf "%s
" "${!OP_SET_ADDED[@]}" 2>/dev/null | sort | paste -sd, -)

	# Human-friendly preview list
	op_list=$(printf "%s\n" "${!OP_BASKET[@]}" | sort | head -15)
	[[ -z "$op_list" ]] && op_list="(none)"
	[[ ${#OP_BASKET[@]} -gt 15 ]] && op_list="$op_list
... and $((${#OP_BASKET[@]} - 15)) more"

	summary_text="OpenShift Configuration:
  • Channel:  $OCP_CHANNEL
  • Version:  $OCP_VERSION

Platform & Network:
  • Platform: ${PLATFORM:-bm}
  • Domain:   ${DOMAIN:-example.com}
  • Network:  ${MACHINE_NETWORK:-(auto-detect)}
  • DNS:      ${DNS_SERVERS:-(auto-detect)}
  • Gateway:  ${NEXT_HOP_ADDRESS:-(auto-detect)}
  • NTP:      ${NTP_SERVERS:-(auto-detect)}

Operator Sets: ${op_sets_csv:-(none)}

Operators (${#OP_BASKET[@]}):
$op_list

Choose action:"

	# Calculate size based on summary content
	local num_lines=$(echo "$summary_text" | wc -l)
	local max_width=$(echo "$summary_text" | awk '{print length}' | sort -n | tail -1)
	[[ -z "$max_width" ]] && max_width=60
	((max_width < 60)) && max_width=60
	calc_dlg_size "$((num_lines + 2))" "$max_width"

	while :; do
		dialog --clear --backtitle "$(ui_backtitle)" --title "Summary" \
			--extra-button --extra-label "Save Draft" \
			--help-button \
			--yes-label "Apply to aba.conf" \
			--no-label "Back" \
			--yesno "$summary_text" $DLG_H $DLG_W

		rc=$?
		case "$rc" in
			0)
				# Apply
				log "Applying configuration to aba.conf"
				replace-value-conf -q -n ocp_channel       -v "$OCP_CHANNEL"       -f aba.conf
				replace-value-conf -q -n ocp_version       -v "$OCP_VERSION"       -f aba.conf
				replace-value-conf -q -n platform          -v "${PLATFORM:-bm}"    -f aba.conf
				replace-value-conf -q -n domain            -v "${DOMAIN}"          -f aba.conf
				replace-value-conf -q -n machine_network   -v "${MACHINE_NETWORK}" -f aba.conf
				replace-value-conf -q -n dns_servers       -v "${DNS_SERVERS}"     -f aba.conf
				replace-value-conf -q -n next_hop_address  -v "${NEXT_HOP_ADDRESS}" -f aba.conf
				replace-value-conf -q -n ntp_servers       -v "${NTP_SERVERS}"     -f aba.conf
				replace-value-conf -q -n ops               -v "$ops_csv"           -f aba.conf
				replace-value-conf -q -n op_sets           -v "$op_sets_csv"       -f aba.conf
			log "Configuration applied successfully"
			
			calc_dlg_size 0 70
			dialog --backtitle "$(ui_backtitle)" --msgbox \
"Configuration applied to aba.conf

Next steps:
  1. aba -d mirror install    (setup registry)
  2. aba -d mirror sync       (download images)
  3. aba cluster --name <name> (create cluster)

See: aba --help" $DLG_H $DLG_W
			return 0
				;;
			1)
				# Back
				log "User went back from summary"
				return 1
				;;
		2)
			# Help
			calc_dlg_size 0 70
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

Log file: $LOG_FILE" $DLG_H $DLG_W
			continue
			;;
			3)
				# Save Draft (Extra button)
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
ops=$ops_csv
op_sets=$op_sets_csv
EOF
			calc_dlg_size 0 50
			dialog --backtitle "$(ui_backtitle)" --msgbox \
"Draft saved to: aba.conf.draft

To apply later:
  mv aba.conf.draft aba.conf" $DLG_H $DLG_W
			return 1
			;;
			*)
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

# Show header first
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
				break
			fi
			;;
		version)
			select_ocp_version
			if [[ "$DIALOG_RC" == "repeat" ]]; then
				continue  # Stay on same step
			elif [[ "$DIALOG_RC" == "next" ]]; then
				STEP="platform"
			elif [[ "$DIALOG_RC" == "back" ]]; then
				STEP="channel"
			fi
			;;
		platform)
			select_platform_network
			[[ "$DIALOG_RC" == "next" ]] && STEP="operators"
			[[ "$DIALOG_RC" == "back" ]] && STEP="version"
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
