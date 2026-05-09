#!/usr/bin/env bash
# =============================================================================
# TUI v2 Library — Dialog wrappers, confirm_and_execute, UI helpers
# =============================================================================
# Provides ONLY TUI-specific helpers. ABA core functions (valid_ip, run_once,
# check_internet_connectivity, etc.) come from scripts/include_all.sh.
#
# Usage: source tui/v2/tui-lib.sh

# --- BASH_SOURCE guard (standalone dev/testing) ---
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	echo "This file should be sourced, not executed directly."
	echo "Usage: source tui/v2/tui-lib.sh"
	exit 1
fi

# =============================================================================
# Logging
# =============================================================================

_TUI_LOG_DIR="${HOME}/.aba/logs"
mkdir -p "$_TUI_LOG_DIR" 2>/dev/null || true
_TUI_LOG_FILE="$_TUI_LOG_DIR/aba-tui-v2.log"

tui_log() {
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$_TUI_LOG_FILE" 2>/dev/null || true
}

# =============================================================================
# DISCO mode filters — strip public/internet values from config fields
# =============================================================================

# Filter comma-separated list, removing entries that are unreachable in DISCO mode.
# Usage: filtered=$(filter_disco_values "$ntp_servers")
filter_disco_values() {
	local input="$1"
	[[ -z "$input" ]] && return 0
	[[ "$_TUI_MODE" != "DISCO" ]] && { echo "$input"; return 0; }

	local result="" entry
	IFS=',' read -ra entries <<< "$input"
	for entry in "${entries[@]}"; do
		entry=$(echo "$entry" | tr -d ' ')
		[[ -z "$entry" ]] && continue
		# Skip known public NTP pools and time servers
		case "$entry" in
			*.pool.ntp.org|time.google.com|time.cloudflare.com|time.apple.com) continue ;;
			time.windows.com|ntp.ubuntu.com|clock.xfce.org) continue ;;
		esac
		# Skip well-known public DNS
		case "$entry" in
			8.8.8.8|8.8.4.4|1.1.1.1|1.0.0.1|9.9.9.9|208.67.222.222|208.67.220.220) continue ;;
		esac
		[[ -n "$result" ]] && result+=","
		result+="$entry"
	done
	echo "$result"
}

# =============================================================================
# Input validation helpers
# =============================================================================

# Validate a single IPv4 address (returns 0 if valid)
_valid_ip() {
	local ip="$1"
	[[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
	local IFS='.'
	read -ra octets <<< "$ip"
	for o in "${octets[@]}"; do
		[[ "$o" -le 255 ]] || return 1
	done
	return 0
}

# Validate CIDR notation (e.g. 10.0.0.0/24)
_valid_cidr() {
	local cidr="$1"
	[[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || return 1
	local ip="${cidr%/*}" prefix="${cidr#*/}"
	_valid_ip "$ip" || return 1
	[[ "$prefix" -ge 0 && "$prefix" -le 32 ]] || return 1
	return 0
}

# Validate comma-separated list of IPs or hostnames (DNS/NTP)
_valid_ip_or_host_list() {
	local input="$1"
	[[ -z "$input" ]] && return 0
	local IFS=',' entry
	read -ra entries <<< "$input"
	for entry in "${entries[@]}"; do
		entry=$(echo "$entry" | tr -d ' ')
		[[ -z "$entry" ]] && continue
		# Accept valid IPs or valid hostnames
		if ! _valid_ip "$entry"; then
			[[ "$entry" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || return 1
		fi
	done
	return 0
}

# =============================================================================
# Temp file management
# =============================================================================

_TUI_TMP=$(mktemp)

_tui_cleanup() {
	rm -f "$_TUI_TMP" "${_TUI_DIALOGRC:-}"
	tui_log "TUI v2 exited"
}
trap '_tui_cleanup' EXIT

# =============================================================================
# Dialog appearance (nmtui-like styling — same as v1)
# =============================================================================

_TUI_DIALOGRC="${TMPDIR:-/tmp}/.dialogrc-v2.$$"
export DIALOGRC="$_TUI_DIALOGRC"

cat > "$_TUI_DIALOGRC" <<'EOF'
use_colors = ON
use_shadow = OFF
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

# =============================================================================
# Core dialog wrapper
# =============================================================================

# dlg — wrapper that adds consistent styling:
#   - Pads --title with spaces: "Foo" → " Foo "
#   - Prepends \n to the prompt/message text (empty line below title)
dlg() {
	local args=()
	local next_is_title=false
	local next_is_text=false

	for arg in "$@"; do
		if [[ "$next_is_title" == "true" ]]; then
			args+=(" $arg ")
			next_is_title=false
			continue
		fi
		if [[ "$next_is_text" == "true" ]]; then
			# Prepend \n (empty line below title) unless already starts with \n
			if [[ "$arg" != "\n"* && "$arg" != $'\n'* ]]; then
				args+=("\n$arg")
			else
				args+=("$arg")
			fi
			next_is_text=false
			continue
		fi

		case "$arg" in
			--title) next_is_title=true ;;
			--menu|--msgbox|--yesno|--inputbox|--radiolist|--infobox|--checklist|--mixedform)
				next_is_text=true ;;
		esac
		args+=("$arg")
	done

	dialog --no-shadow --colors "${args[@]}"
}

# =============================================================================
# Backtitle (status bar at top)
# =============================================================================

_TUI_MODE=""   # Set by mode detection: DISCO, CONNO, DIRECT
_TUI_INET=""   # Set by mode detection: "yes" or "no" (internet available)

ui_backtitle() {
	local mode_tag="${_TUI_MODE:-?}"
	local ver="${ocp_version:-?}"
	local ch="${ocp_channel:-?}"
	echo "ABA TUI v2  |  mode: ${mode_tag}  channel: ${ch}  version: ${ver}"
}

# =============================================================================
# Confirm quit
# =============================================================================

confirm_quit() {
	tui_log "User attempting to quit"
	while :; do
		dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CONFIRM_EXIT" \
			--help-button \
			--yes-label "$TUI2_BTN_EXIT" \
			--no-label "$TUI2_BTN_CONTINUE" \
			--yesno "$TUI2_MSG_CONFIRM_EXIT" 0 0
		local rc=$?

		case "$rc" in
			0)
				tui_log "User confirmed quit"
				return 0
				;;
			1)
				tui_log "User cancelled quit"
				return 1
				;;
			255)
				tui_log "ESC again — quitting"
				return 0
				;;
			2)
				dlg --backtitle "$(ui_backtitle)" --msgbox "$TUI2_MSG_EXIT_HELP" 0 0 || true
				continue
				;;
			*)
				return 1
				;;
		esac
	done
}

# =============================================================================
# Help display helper
# =============================================================================

# show_help "Title" "Body text"
# Bypasses dlg wrapper to avoid \n prepend issues; uses --cr-wrap to preserve formatting
show_help() {
	local title="$1"
	local body="$2"
	dialog --no-shadow --colors --backtitle "$(ui_backtitle)" \
		--title " $title " --cr-wrap --msgbox "\n$body" 0 0 || true
}

# =============================================================================
# Confirm and Execute (terminal mode / TUI mode choice — same as v1)
# =============================================================================

confirm_and_execute() {
	local cmd="$1"
	local title="${2:-Confirm Execution}"
	tui_log "Confirming command: $cmd"

	while :; do
		dlg --backtitle "$(ui_backtitle)" --title "$title" \
			--cancel-label "$TUI2_BTN_BACK" \
			--ok-label "$TUI2_BTN_SELECT" \
			--help-button \
			--menu "$(printf "$TUI2_MSG_EXEC_MODE" "$cmd")" 0 0 0 \
			"1" "Run in TUI (auto-answer, dialog output)" \
			"2" "Run in Terminal (interactive, full colors)" \
			2>"$_TUI_TMP"
		local rc=$?

		case "$rc" in
			2)
				show_help "$TUI2_HELP_TITLE_EXEC" \
"• Run in TUI
  - Command runs inside dialog interface
  - Auto-answer (-y) is always enabled
  - Output shown live in progressbox
  - Scrollable output review after completion

• Run in Terminal
  - Command runs in real terminal
  - Full interactive mode (colors, prompts)
  - Press ENTER to return to TUI"
				continue
				;;
			0) ;;  # proceed to choice
			1)
				tui_log "User cancelled execution"
				return 1
				;;
			255)
				if confirm_quit; then clear; _show_v2_exit_summary; exit 0; fi
				continue
				;;
		esac

		local choice
		choice=$(<"$_TUI_TMP")

		case "$choice" in
			1) _exec_in_tui "$cmd" ;;
			2) _exec_in_terminal "$cmd" ;;
		esac
		local exec_rc=$?
		# rc=2 means "retry" — loop back to confirmation dialog
		[[ $exec_rc -eq 2 ]] && continue
		return $exec_rc
	done
}

# --- Execute in TUI mode (progressbox) ---
_exec_in_tui() {
	local cmd="$1"
	local tui_cmd="$cmd"
	[[ "$tui_cmd" != *" -y "* && "$tui_cmd" != *" -y" ]] && tui_cmd="$tui_cmd -y"

	tui_log "Executing in TUI: $tui_cmd"
	cd "$ABA_ROOT"

	local output_file
	output_file=$(mktemp)

	local term_height term_width box_height box_width
	term_height=$(tput lines)
	term_width=$(tput cols)
	box_height=$((term_height - 2))
	box_width=$((term_width - 2))

	trap : INT
	PLAIN_OUTPUT=1 ASK_OVERRIDE=1 bash -c "$tui_cmd" 2>&1 | tee "$output_file" | \
		sed -u -r 's/\x1B\[[0-9;]*[mK]//g' | \
		dlg --backtitle "$(ui_backtitle)" --title "Executing: $tui_cmd" \
			--progressbox $box_height $box_width
	local exit_code=${PIPESTATUS[0]}
	trap - INT

	# Strip ANSI escape codes so dialog textbox can scroll properly
	sed -i -r 's/\x1B\[[0-9;]*[mK]//g; s/\x1B\(B//g' "$output_file"

	# Prepend last lines to top so user sees the result immediately
	local review_file
	review_file=$(mktemp)
	{
		echo "═══ Result (last output) ═══════════════════════════════"
		echo ""
		tail -20 "$output_file"
		echo ""
		echo "═══ Full log (scroll down) ═════════════════════════════"
		echo ""
		cat "$output_file"
	} > "$review_file"

	if [[ $exit_code -eq 0 ]]; then
		dlg --backtitle "$(ui_backtitle)" --title "\Z2Success\Zn: $cmd" \
			--ok-label "$TUI2_BTN_BACK_TO_MENU" \
			--extra-button --extra-label "$TUI2_BTN_EXIT_TUI" \
			--textbox "$review_file" 0 0
		local btn=$?
		rm -f "$output_file" "$review_file"
		case $btn in
			3)
				clear
				_show_v2_exit_summary
				exit 0
				;;
		esac
	else
		dlg --backtitle "$(ui_backtitle)" --title "\Z1FAILED (exit $exit_code)\Zn: $cmd" \
			--ok-label "$TUI2_BTN_BACK_TO_MENU" \
			--extra-button --extra-label "$TUI2_BTN_RETRY" \
			--textbox "$review_file" 0 0
		local fail_btn=$?
		rm -f "$output_file" "$review_file"
		# Extra button (3) = Retry
		[[ $fail_btn -eq 3 ]] && return 2
		return 1
	fi
	return 0
}

# --- Execute in Terminal mode ---
_exec_in_terminal() {
	local cmd="$1"
	tui_log "Executing in terminal: $cmd"
	cd "$ABA_ROOT"

	clear
	echo "═══════════════════════════════════════════════════════════════"
	echo "  Executing: $cmd"
	echo "═══════════════════════════════════════════════════════════════"
	echo

	bash -c "$cmd"
	local exit_code=$?

	echo
	if [[ $exit_code -eq 0 ]]; then
		echo "── Command completed successfully ──"
	else
		echo "── Command FAILED (exit code: $exit_code) ──"
	fi
	echo
	read -rp "Press ENTER to return to TUI..."
	return 0
}

# =============================================================================
# State detection helpers
# =============================================================================

# Is a mirror registry installed and available?
mirror_available() {
	[[ -f "$ABA_ROOT/mirror/.available" ]]
}

# Is a cluster configured? (cluster.conf exists in given dir)
cluster_configured() {
	local dir="$1"
	[[ -f "$ABA_ROOT/$dir/cluster.conf" ]]
}

# Is a cluster installed? (kubeconfig exists)
cluster_installed() {
	local dir="$1"
	[[ -f "$ABA_ROOT/$dir/iso-agent-based/auth/kubeconfig" ]]
}

# List cluster directories (dirs containing cluster.conf, excluding templates)
list_cluster_dirs() {
	local dir
	for dir in "$ABA_ROOT"/*/cluster.conf; do
		[[ -f "$dir" ]] || continue
		dir="${dir%/cluster.conf}"
		dir="${dir##*/}"
		# Skip mirror and template dirs
		[[ "$dir" == "mirror" || "$dir" == "templates" ]] && continue
		echo "$dir"
	done
}

# List installed clusters (dirs with kubeconfig)
list_installed_clusters() {
	local dir
	for dir in $(list_cluster_dirs); do
		cluster_installed "$dir" && echo "$dir"
	done
}

# Get cluster display name: <name>.<base_domain>
# Uses subshell to prevent cluster.conf variables from leaking into caller
cluster_display_name() {
	local dir="$1"
	(
		cluster_name="" base_domain=""
		# shellcheck disable=SC1090
		source <(cd "$ABA_ROOT/$dir" && normalize-cluster-conf) 2>/dev/null || true
		if [[ -n "${cluster_name:-}" && -n "${base_domain:-}" ]]; then
			echo "${cluster_name}.${base_domain}"
		else
			echo "$dir"
		fi
	)
}

# Are there mirror archive tar files?
mirror_has_archives() {
	compgen -G "$ABA_ROOT/mirror/data/mirror_*.tar" >/dev/null 2>&1
}

# Is the bundle flag set?
is_bundle_mode() {
	[[ -f "$ABA_ROOT/.bundle" ]]
}

# =============================================================================
# Cluster selector dialog
# =============================================================================

# select_cluster "title" "prompt" — sets SELECTED_CLUSTER or returns 1
select_cluster() {
	local title="${1:-Select Cluster}"
	local prompt="${2:-Choose a cluster:}"
	local clusters=()
	local dir display

	for dir in $(list_cluster_dirs); do
		display=$(cluster_display_name "$dir")
		clusters+=("$dir" "$display")
	done

	if [[ ${#clusters[@]} -eq 0 ]]; then
		dlg --backtitle "$(ui_backtitle)" --msgbox "$TUI2_MSG_NO_CLUSTERS" 0 0
		return 1
	fi

	dlg --backtitle "$(ui_backtitle)" --title "$title" \
		--cancel-label "$TUI2_BTN_BACK" \
		--menu "$prompt" 0 0 0 \
		"${clusters[@]}" \
		2>"$_TUI_TMP"
	local rc=$?

	if [[ $rc -ne 0 ]]; then
		return 1
	fi

	SELECTED_CLUSTER=$(<"$_TUI_TMP")
	return 0
}

# select_installed_cluster — same but only installed clusters
select_installed_cluster() {
	local title="${1:-Select Cluster}"
	local prompt="${2:-Choose an installed cluster:}"
	local clusters=()
	local dir display

	for dir in $(list_installed_clusters); do
		display=$(cluster_display_name "$dir")
		clusters+=("$dir" "$display")
	done

	if [[ ${#clusters[@]} -eq 0 ]]; then
		dlg --backtitle "$(ui_backtitle)" --msgbox "$TUI2_MSG_NO_INSTALLED_CLUSTERS" 0 0
		return 1
	fi

	dlg --backtitle "$(ui_backtitle)" --title "$title" \
		--cancel-label "$TUI2_BTN_BACK" \
		--menu "$prompt" 0 0 0 \
		"${clusters[@]}" \
		2>"$_TUI_TMP"
	local rc=$?

	if [[ $rc -ne 0 ]]; then
		return 1
	fi

	SELECTED_CLUSTER=$(<"$_TUI_TMP")
	return 0
}

# =============================================================================
# Editor helper (offer $EDITOR or dialog editbox)
# =============================================================================

offer_editor() {
	local filepath="$1"
	local title="${2:-Edit File}"

	dlg --backtitle "$(ui_backtitle)" --title "$title" \
		--cancel-label "$TUI2_BTN_SKIP" \
		--menu "$(printf "$TUI2_MSG_EDITOR_PROMPT" "$filepath")" 0 0 0 \
		"1" "Edit in terminal (\$EDITOR)" \
		"2" "Edit in TUI dialog" \
		2>"$_TUI_TMP"
	local rc=$?

	[[ $rc -ne 0 ]] && return 1

	local choice
	choice=$(<"$_TUI_TMP")

	case "$choice" in
		1)
			clear
			${EDITOR:-vi} "$filepath"
			;;
		2)
			dlg --backtitle "$(ui_backtitle)" --title "$title" \
				--editbox "$filepath" 0 0 2>"$_TUI_TMP"
			if [[ $? -eq 0 ]]; then
				cp "$_TUI_TMP" "$filepath"
			fi
			;;
	esac
	return 0
}

# =============================================================================
# Exit summary
# =============================================================================

_TUI_START_EPOCH=$(date +%s)

_show_v2_exit_summary() {
	echo "TUI v2 complete."
	echo
	local f mod_epoch shown=0
	for f in aba.conf mirror/mirror.conf mirror/data/imageset-config.yaml; do
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
	echo
	echo "Log file: $_TUI_LOG_FILE"
	echo
	echo "Run 'aba --help' for available commands."
}
