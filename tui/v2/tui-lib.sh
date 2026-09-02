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
# Global state: mirror recheck flag
# =============================================================================
# Set true on startup (initial mirror probe) and by _invalidate_mirror_cache()
# after mirror-changing actions. The menu loop waits for the background check
# only when this is true, then resets it.
_TUI_NEED_MIRROR_RECHECK=true

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
# Blanket stdout/stderr redirect — prevent stray output from corrupting TUI
# =============================================================================
# After _tui_redirect_init, ALL stdout/stderr goes to the log file.
# dlg(), show_help(), and _exec_in_terminal() temporarily restore the terminal
# for dialog rendering / interactive commands, then re-redirect afterward.
# FD 5 = saved original stdout, FD 6 = saved original stderr.

_TUI_REDIRECT_ACTIVE=""

_tui_redirect_init() {
	exec 5>&1 6>&2
	exec 1>>"$_TUI_LOG_FILE" 2>>"$_TUI_LOG_FILE"
	_TUI_REDIRECT_ACTIVE=1
}

_tui_redirect_restore() {
	if [[ "${_TUI_REDIRECT_ACTIVE:-}" == "1" ]]; then
		exec 1>&5 2>&6
	fi
}

_tui_redirect_activate() {
	if [[ "${_TUI_REDIRECT_ACTIVE:-}" == "1" ]]; then
		exec 1>>"$_TUI_LOG_FILE" 2>>"$_TUI_LOG_FILE"
	fi
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
		[[ "10#$o" -le 255 ]] || return 1
	done
	return 0
}

# Validate CIDR notation (e.g. 10.0.0.0/24)
_valid_cidr() {
	local cidr="$1"
	[[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || return 1
	local ip="${cidr%/*}" prefix="${cidr#*/}"       # split "10.0.0.0/24" → ip + prefix
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

# Validate comma-separated list of IPv4 addresses ONLY (no hostnames).
# Matches verify-cluster-conf behavior for dns_servers.
_valid_ip_list() {
	local input="$1"
	[[ -z "$input" ]] && return 0
	local IFS=',' entry
	read -ra entries <<< "$input"
	for entry in "${entries[@]}"; do
		entry=$(echo "$entry" | tr -d ' ')
		[[ -z "$entry" ]] && continue
		_valid_ip "$entry" || return 1
	done
	return 0
}

# Validate FQDN (must have at least one dot and a TLD label)
_valid_fqdn() {
	[[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || return 1
	[[ "$1" == *.* ]] || return 1
}

# Validate TCP/UDP port number (1-65535)
_valid_port() {
	[[ "$1" =~ ^[0-9]+$ ]] || return 1
	[[ "$1" -ge 1 && "$1" -le 65535 ]] || return 1
}

# Validate absolute path or ~-prefixed path
_valid_abs_path() {
	[[ "$1" =~ ^(/|~) ]] || return 1
}

# Validate MAC prefix pattern (exactly 5 octets with trailing colon, e.g. 00:50:56:xx:xx:)
_valid_mac_prefix() {
	[[ -z "$1" ]] && return 0
	[[ "$1" =~ ^([0-9A-Fa-fXx]{2}:){5}$ ]]
}

# Validate full MAC address (e.g. 00:50:56:ab:cd:ef)
_valid_mac() {
	[[ "$1" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]
}

# Validate comma-separated network port names (e.g. ens1f0,ens1f1)
_valid_port_names() {
	[[ -z "$1" ]] && return 0
	[[ "$1" =~ ^[a-zA-Z0-9_.-]+(,[a-zA-Z0-9_.-]+)*$ ]]
}

# =============================================================================
# Temp file management
# =============================================================================

_TUI_TMP=$(mktemp)

_tui_cleanup() {
	rm -f "$_TUI_TMP" "${_TUI_TMP}.edit" "${_TUI_DIALOGRC:-}" "${_ABA_TUI_PID_FILE:-}"
	tui_log "TUI v2 exited"
}
trap '_tui_cleanup' EXIT

# =============================================================================
# Dialog appearance (nmtui-like styling — same as v1)
# =============================================================================

_TUI_DIALOGRC="$ABA_TMP/dialogrc-v2.$$"
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
#   - Appends \n<space> to msgbox/yesno/inputbox text (blank line before buttons);
#     dialog ignores bare trailing \n for height, the space forces the line to render.
#     Skipped for menus and mixedform.
#   - Infobox text is NOT modified (no buttons, compact spinners with fixed sizes)
#   - For menu/radiolist/checklist: replaces menu-height=0 with the actual
#     item count so dialog sizes the box to fit all items (no scrollbar)
dlg() {
	local args=()
	local next_is_title=false
	local next_is_text=false
	local has_menu=false
	local menu_type=""
	local _add_trailing=false
	local dims_after_text=0
	local height_idx=-1
	local width_val=""
	local dims_idx=-1

	for arg in "$@"; do
		if [[ "$next_is_title" == "true" ]]; then
			args+=(" $arg ")
			next_is_title=false
			continue
		fi
		if [[ "$next_is_text" == "true" ]]; then
			# Prepend \n for consistent spacing below title (all dialog types)
			if [[ "$arg" != "\n"* && "$arg" != $'\n'* ]]; then
				arg="\n$arg"
			fi
			# Append trailing blank line before buttons.
			# dialog ignores bare trailing newlines for height; the space forces the
			# line to render.  Use the same newline style as the text: literal \n for
			# texts using literal \n sequences, real $'\n' for texts with real newlines
			# (e.g. splash screen).  Mixing styles causes dialog to misbehave.
			# Only for types with buttons — skip infobox/mixedform/menus.
			if [[ "$_add_trailing" == "true" && "$arg" != *'\n ' && "$arg" != *$'\n ' ]]; then
				if [[ "$arg" == *$'\n'* ]]; then
					arg="$arg"$'\n '
				else
					arg="$arg\n "
				fi
			fi
			if [[ "$has_menu" == "true" ]]; then
				arg="${arg}\n\n(Navigate: Arrow keys, Tab, SPACE, ESC)"
				dims_after_text=3
			fi
			args+=("$arg")
			next_is_text=false
			continue
		fi

		if [[ $dims_after_text -gt 0 ]]; then
			case $dims_after_text in
				3) height_idx=${#args[@]} ;;
				2) width_val="$arg" ;;
				1) dims_idx=${#args[@]} ;;
			esac
			dims_after_text=$(( dims_after_text - 1 ))
			args+=("$arg")
			continue
		fi

		case "$arg" in
			--title) next_is_title=true ;;
			--menu)
				next_is_text=true; has_menu=true; menu_type="menu" ;;
			--radiolist|--checklist)
				next_is_text=true; has_menu=true; menu_type="checklist" ;;
			--msgbox|--yesno|--inputbox)
				next_is_text=true; _add_trailing=true ;;
			--mixedform)
				next_is_text=true ;;
		esac
		args+=("$arg")
	done

	# If menu-height was 0, replace with actual item count and compute height
	if [[ $dims_idx -ge 0 && "${args[$dims_idx]}" == "0" ]]; then
		local items_start=$(( dims_idx + 1 ))
		local remaining=$(( ${#args[@]} - items_start ))
		local item_count
		if [[ "$menu_type" == "checklist" ]]; then
			item_count=$(( remaining / 3 ))
		else
			item_count=$(( remaining / 2 ))
		fi
		args[$dims_idx]=$item_count
		# When width is explicit (not 0), dialog's auto-height underestimates;
		# compute height from item count + overhead for borders/message/buttons
		if [[ "$width_val" != "0" && $height_idx -ge 0 && "${args[$height_idx]}" == "0" ]]; then
			args[$height_idx]=$(( item_count + 10 ))
		fi
	fi

	# Close the flock fd so dialog doesn't inherit it (prevents orphaned lock on kill)
	# Blanket redirect: save caller's stderr (may be $_TUI_TMP from `dlg ... 2>"$_TUI_TMP"`),
	# restore terminal for rendering, route dialog selection output to saved FD via --output-fd.
	if [[ "${_TUI_REDIRECT_ACTIVE:-}" == "1" ]]; then
		exec 7>&2
		_tui_redirect_restore
		dialog --no-shadow --colors --no-collapse --tab-correct --output-fd 7 "${args[@]}" {ABA_TUI_FLOCK_FD}>&-
		local _dlg_rc=$?
		_tui_redirect_activate
		exec 7>&-
		return $_dlg_rc
	fi
	dialog --no-shadow --colors --no-collapse --tab-correct "${args[@]}" {ABA_TUI_FLOCK_FD}>&-
}

# =============================================================================
# Backtitle (status bar at top)
# =============================================================================

_TUI_MODE=""   # Set by mode detection: DISCO, CONNO, DIRECT
_TUI_INET=""   # Set by mode detection: "yes" or "no" (internet available)

# Forwarded to oc-mirror via `aba mirror save|sync|load --retry N`
_TUI_RETRY_COUNT="${_TUI_RETRY_COUNT:-${TUI_OC_MIRROR_RETRY_COUNT:-1}}"

# Registry type -- in-memory state, loaded from mirror.conf at startup, persisted on toggle.
# Values: "auto", "quay", "docker", "quay-ng"
_TUI_REG_VENDOR="auto"
if [[ -f "$ABA_ROOT/mirror/mirror.conf" ]]; then
	source <(cd "$ABA_ROOT/mirror" && normalize-mirror-conf) 2>/dev/null || true
	_TUI_REG_VENDOR="${reg_vendor:-auto}"
fi

ui_backtitle() {
	local mode_display=""
	case "${_TUI_MODE:-}" in
		DISCO)  mode_display="Fully Disconnected" ;;
		CONNO)  mode_display="Partially Disconnected" ;;
		DIRECT) mode_display="Fully Connected" ;;
	esac
	local ver="${ocp_version:-}"
	local ch="${ocp_channel:-}"

	# Build title progressively — only show sections with real data
	local text="ABA TUI v2"
	[ -n "$mode_display" ] && text="$text  |  $mode_display"
	if [[ -n "$ch" && -n "$ver" ]]; then
		local _tgt="${ocp_upgrade_to:-}"
		if [[ -n "$_tgt" && "$_tgt" != "$ver" ]]; then
			text="$text  |  $ch $ver → $_tgt"
		else
			text="$text  |  $ch $ver"
		fi
	fi

	local cols=${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}
	local pad=$(( (cols - ${#text}) / 2 ))
	[[ $pad -gt 0 ]] && printf '%*s%s' "$pad" '' "$text" || echo "$text"
}

# =============================================================================
# Confirm quit
# =============================================================================

confirm_quit() {
	tui_log "User attempting to quit"
	dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CONFIRM_EXIT" \
		--yes-label "$TUI2_BTN_EXIT" \
		--no-label "$TUI2_BTN_CONTINUE" \
		--yesno "$TUI2_MSG_CONFIRM_EXIT" 0 0
	local rc=$?

	case "$rc" in
		0)
			tui_log "User confirmed quit"
			return 0
			;;
		255)
			tui_log "ESC again — quitting"
			return 0
			;;
		*)
			tui_log "User cancelled quit"
			return 1
			;;
	esac
}

# =============================================================================
# Help display helper
# =============================================================================

# show_help "Title" "Body text"
# Bypasses dlg wrapper to avoid \n prepend issues; uses --cr-wrap to preserve formatting
show_help() {
	local title="$1"
	local body="$2"
	_tui_redirect_restore
	dialog --no-shadow --colors --backtitle "$(ui_backtitle)" \
		--title " $title " --cr-wrap --msgbox "\n$body" 0 0 {ABA_TUI_FLOCK_FD}>&- || true
	_tui_redirect_activate
}

# =============================================================================
# Input validation helpers
# =============================================================================

# Reject single quotes in user input destined for config files.
# Config files are sourced by bash — unescaped single quotes corrupt them.
# Usage:  _tui_reject_squote "$value" || continue
_tui_reject_squote() {
	if [[ "$1" == *"'"* || "$1" == *'`'* || "$1" == *'$'* || "$1" == *'\\'* ]]; then
		dlg --backtitle "$(ui_backtitle)" --msgbox \
			"Input cannot contain shell metacharacters: ' \` \$ \\\\\n\nPlease re-enter without these characters." 0 0
		return 1
	fi
	return 0
}

# Generic password prompt: hidden input, double entry, match check.
# On success: writes validated password to $_TUI_TMP and returns 0.
# On cancel: returns 1. Must NOT be called in a subshell $(...) — dialog
# hangs when run inside command substitution on some terminals.
# Usage:  _tui_prompt_password "prompt" [min_len] && pw=$(<"$_TUI_TMP")
_tui_prompt_password() {
	local prompt="${1:-Enter password:}"
	local min_len="${2:-1}"
	local pw1 pw2
	while :; do
		dlg --backtitle "$(ui_backtitle)" --insecure \
			--help-button --help-label "Rules" \
			--passwordbox "$prompt" 0 70 2>"$_TUI_TMP"
		local _rc=$?
		if [[ $_rc -eq 2 ]]; then
			dlg --backtitle "$(ui_backtitle)" --title "Password Rules" --msgbox \
				"Password requirements:\n\n\
  • Minimum $min_len characters\n\
  • No whitespace (spaces or tabs)\n\
  • Not allowed: '  \"  \`  \$\n\n\
All other special characters are allowed:\n\
  ! @ # % ^ & * ( ) < > | ; ~ { } = + - _ [ ] \\\\\n\n\
Why? The upstream Quay mirror-registry installer\n\
embeds the password in a shell command and cannot\n\
handle these 4 characters." 0 0
			continue
		fi
		[[ $_rc -ne 0 ]] && return 1
		pw1=$(<"$_TUI_TMP")
		if [[ ${#pw1} -lt $min_len ]]; then
			dlg --backtitle "$(ui_backtitle)" --msgbox \
				"Password must be at least $min_len character(s)." 0 0
			continue
		fi
		if [[ "$pw1" =~ [[:space:]] ]]; then
			dlg --backtitle "$(ui_backtitle)" --msgbox \
				"Password cannot contain whitespace." 0 0
			continue
		fi
		if [[ "$pw1" == *"'"* || "$pw1" == *'"'* || "$pw1" == *'`'* || "$pw1" == *'$'* ]]; then
			dlg --backtitle "$(ui_backtitle)" --msgbox \
				"Password cannot contain: '  \"  \`  \$\n\n(The upstream Quay mirror-registry tool cannot handle these.)\nAll other special characters are allowed." 0 0
			continue
		fi
		dlg --backtitle "$(ui_backtitle)" --insecure --passwordbox \
			"Confirm password:" 0 70 2>"$_TUI_TMP"
		[[ $? -ne 0 ]] && return 1
		pw2=$(<"$_TUI_TMP")
		if [[ "$pw1" == "$pw2" ]]; then
			printf '%s' "$pw1" > "$_TUI_TMP"
			return 0
		fi
		dlg --backtitle "$(ui_backtitle)" --msgbox \
			"Passwords do not match. Try again." 0 0
	done
}

# =============================================================================
# Confirm and Execute (terminal mode / TUI mode choice)
# =============================================================================

# Format a long command for display: one flag per line with backslash continuations.
# Splits on any flag token (--foo or -x).  Short commands (<=3 flags) pass through unchanged.
_format_cmd_display() {
	local cmd="$1"
	local -a words
	read -ra words <<< "$cmd"

	# Count flags (tokens starting with -)
	local flag_count=0
	for w in "${words[@]}"; do
		[[ "$w" == -* ]] && flag_count=$(( flag_count + 1 ))
	done
	if (( flag_count <= 3 )); then
		printf '%s' "$cmd"
		return
	fi

	# First token is the base command (e.g. "aba"), collect until first flag
	local -a base=()
	local -a rest=()
	local in_base=1
	for w in "${words[@]}"; do
		if (( in_base )) && [[ "$w" != -* ]]; then
			base+=("$w")
		else
			in_base=0
			rest+=("$w")
		fi
	done

	local out="${base[*]}"
	local i=0
	while (( i < ${#rest[@]} )); do
		local token="${rest[$i]}"
		if [[ "$token" == -* ]]; then
			# Collect flag + its value args (everything until next flag)
			local chunk="$token"
			i=$(( i + 1 ))
			while (( i < ${#rest[@]} )) && [[ "${rest[$i]}" != -* ]]; do
				chunk="$chunk ${rest[$i]}"
				i=$(( i + 1 ))
			done
			printf -v out '%s \\\n    %s' "$out" "$chunk"
		else
			out="$out $token"
			i=$(( i + 1 ))
		fi
	done
	printf '%s' "$out"
}

# Persist execution mode preference to ~/.aba/config
_tui_persist_exec_mode() {
	local conf="$HOME/.aba/config"
	[[ -f "$conf" ]] && replace-value-conf -q -n TUI_EXEC_MODE -v "$1" -f "$conf"
}

# Persist oc-mirror retry count to ~/.aba/config
_tui_persist_retry_count() {
	local conf="$HOME/.aba/config"
	[[ -f "$conf" ]] && replace-value-conf -q -n TUI_OC_MIRROR_RETRY_COUNT -v "$1" -f "$conf"
}

confirm_and_execute() {
	local cmd="$1"
	local title="${2:-Confirm Execution}"
	local post_cmd_hook="${3:-}"
	tui_log "Confirming command: $cmd"

	local default_item="${_TUI_LAST_EXEC_MODE:-${TUI_EXEC_MODE:-1}}"
	while :; do
		dlg --backtitle "$(ui_backtitle)" --title "$title" \
			--cancel-label "$TUI2_BTN_BACK" \
			--ok-label "$TUI2_BTN_SELECT" \
			--help-button \
			--extra-button --extra-label "Command" \
			--default-item "$default_item" \
			--menu "$TUI2_MSG_EXEC_MODE" 0 0 0 \
			"1" "Run in Terminal (interactive)" \
			"2" "Run in Terminal (non-interactive)" \
			"3" "Run in TUI (non-interactive)" \
			2>"$_TUI_TMP"
		local rc=$?

		case "$rc" in
			2)
				show_help "$TUI2_HELP_TITLE_EXEC" \
"• Run in Terminal (interactive)
  - Command runs in real terminal
  - Full interactive mode (colors, prompts)
  - Press ENTER to return to TUI

• Run in Terminal (non-interactive)
  - Command runs in real terminal with full output
  - Prompts are answered with defaults (-y)
  - Press ENTER to return to TUI

• Run in TUI (non-interactive)
  - Command runs inside dialog interface
  - Prompts are answered with defaults (-y)
  - Output shown live in progressbox
  - Scrollable output review after completion"
				continue
				;;
			3)
				show_help "Command to execute" "$(_format_cmd_display "$cmd")"
				continue
				;;
			0) ;;  # proceed to choice
			1)
				tui_log "User cancelled execution"
				return 1
				;;
			255) return 1 ;;
		esac

		local choice
		choice=$(<"$_TUI_TMP")
		[[ -n "$choice" ]] && default_item="$choice" && _TUI_LAST_EXEC_MODE="$choice" && _tui_persist_exec_mode "$choice"

		case "$choice" in
			1) _exec_in_terminal "$cmd" "$title" "$post_cmd_hook" ;;
			2)
				local _auto_cmd="$cmd"
				[[ "$_auto_cmd" != *" --yes"* && "$_auto_cmd" != *" -y "* && "$_auto_cmd" != *" -y" ]] && _auto_cmd="$_auto_cmd --yes"
				_exec_in_terminal "$_auto_cmd" "$title" "$post_cmd_hook"
				;;
			3) _exec_in_tui "$cmd" "$title" "$post_cmd_hook" ;;
		esac
		local exec_rc=$?
		[[ $exec_rc -eq 2 ]] && continue
		return $exec_rc
	done
}

# --- Execute in TUI mode (progressbox) ---
_exec_in_tui() {
	local cmd="$1"
	local title="${2:-Executing}"
	local post_cmd_hook="${3:-}"

	# Defense-in-depth: reject commands with shell metacharacters that could indicate injection
	if [[ "$cmd" =~ [\`\$\;\|\>\<]|'&&' ]]; then
		tui_log "BLOCKED: command contains dangerous metacharacters: $cmd"
		dlg --backtitle "$(ui_backtitle)" --msgbox \
			"Command blocked: contains invalid characters.\n\nThis is a safety check to prevent command injection." 0 0
		return 1
	fi

	local tui_cmd="$cmd"
	[[ "$tui_cmd" != *" --yes"* && "$tui_cmd" != *" -y "* && "$tui_cmd" != *" -y" ]] && tui_cmd="$tui_cmd --yes"

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
	# Close flock fd so child processes (e.g. conmon) don't inherit and hold the TUI lock
	# Unset KUBECONFIG so child resolves it from the cluster dir, not stale TUI state
	{ echo "Executing: $cmd"; echo; KUBECONFIG= PLAIN_OUTPUT=1 ASK_OVERRIDE=1 bash -c "$tui_cmd" {ABA_TUI_FLOCK_FD}>&- 2>&1; } | tee "$output_file" | \
		sed -u -r 's/\x1B\[[0-9;]*[mK]//g' | \
		dlg --backtitle "$(ui_backtitle)" --title "$title" \
			--progressbox $box_height $box_width
	local exit_code=${PIPESTATUS[0]}
	# Restore global TUI INT handler (trap - INT would reset to SIG_DFL)
	trap 'exit 0' HUP TERM INT

	# Run post-command hook unconditionally — mirror state is uncertain after
	# any attempt (even failed ones), so always recheck.
	if [[ -n "$post_cmd_hook" ]]; then
		tui_log "Running post-command hook: $post_cmd_hook (exit_code=$exit_code)"
		"$post_cmd_hook"
	fi

	# Strip ANSI escape codes so dialog textbox can scroll properly
	sed -i -r 's/\x1B\[[0-9;]*[mK]//g; s/\x1B\(B//g' "$output_file"

	# Show the tail of output sized to fit the terminal without scrolling
	local review_file visible_lines
	review_file=$(mktemp)
	visible_lines=$(( $(tput lines) - 8 ))
	(( visible_lines < 10 )) && visible_lines=10
	tail -"$visible_lines" "$output_file" > "$review_file"

	# --textbox uses --exit-label for its button (not --ok-label which is ignored)
	if [[ $exit_code -eq 0 ]]; then
		dlg --backtitle "$(ui_backtitle)" --title "\Z2Success\Zn" \
			--exit-label "OK" \
			--textbox "$review_file" 0 0
		rm -f "$output_file" "$review_file"
	else
		dlg --backtitle "$(ui_backtitle)" --title "\Z1FAILED (exit $exit_code)\Zn" \
			--exit-label "$TUI2_BTN_BACK_TO_MENU" \
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
	local _title="${2:-}"
	local post_cmd_hook="${3:-}"

	_tui_redirect_restore

	# Defense-in-depth: reject commands with shell metacharacters that could indicate injection
	if [[ "$cmd" =~ [\`\$\;\|\>\<]|'&&' ]]; then
		tui_log "BLOCKED: command contains dangerous metacharacters: $cmd"
		echo "ERROR: Command blocked — contains invalid characters."
		read -rp "Press ENTER to return to TUI..."
		_tui_redirect_activate
		return 1
	fi

	# When auto-answer is ON, append --yes (same as _exec_in_tui)
	if [[ "$(_tui_abaconf_raw_ask)" == "yes" ]]; then
		[[ "$cmd" != *" --yes"* && "$cmd" != *" -y "* && "$cmd" != *" -y" ]] && cmd="$cmd --yes"
	fi

	tui_log "Executing in terminal: $cmd"
	cd "$ABA_ROOT"
	clear
	echo "═══════════════════════════════════════════════════════════════"
	echo "  Executing: $cmd"
	echo "═══════════════════════════════════════════════════════════════"
	if [[ "$cmd" != *" --yes"* && "$cmd" != *" -y "* && "$cmd" != *" -y" ]]; then
		echo "  Tip: Select non-interactive mode to skip prompts"
	fi
	echo

	# Trap INT so Ctrl-C kills only the child command, not the TUI itself
	local _term_interrupted=false
	trap '_term_interrupted=true' INT

	# Unset KUBECONFIG so child resolves it from the cluster dir, not stale TUI state
	# Close flock fd so child processes (e.g. conmon) don't inherit and hold the TUI lock
	KUBECONFIG= bash -c "$cmd" {ABA_TUI_FLOCK_FD}>&-
	local exit_code=$?

	# Restore global TUI INT handler (trap - INT would reset to SIG_DFL)
	trap 'exit 0' HUP TERM INT

	# Run post-command hook unconditionally — mirror state is uncertain after
	# any attempt (even failed ones), so always recheck.
	if [[ -n "$post_cmd_hook" ]]; then
		tui_log "Running post-command hook: $post_cmd_hook (exit_code=$exit_code)"
		"$post_cmd_hook"
	fi

	echo
	local _ret=0
	if [[ "$_term_interrupted" == "true" ]]; then
		echo "── Command interrupted (Ctrl-C) ──"
		echo
		read -rp "Press ENTER to continue..."
		_ret=1
	elif [[ $exit_code -eq 0 ]]; then
		echo "── Command completed successfully ──"
		echo
		read -rp "Press ENTER to continue..."
		_ret=0
	else
		echo "── Command FAILED (exit code: $exit_code) ──"
		echo
		read -rp "Press R to retry, ENTER to return to menu... " _reply
		[[ "$_reply" == [Rr] ]] && _ret=2 || _ret=1
	fi
	_tui_redirect_activate
	return $_ret
}

# =============================================================================
# State detection helpers
# =============================================================================

# Is a mirror registry installed and available?
mirror_available() {
	[[ -f "$ABA_ROOT/mirror/.available" ]]
}

# Check if the mirror has been verified (release image present in registry).
# Uses the background run_once task — non-blocking, returns cached result.
# Returns 0 (true) if verified, 1 (false) if not yet verified or failed.
_mirror_has_release_image() {
	local exit_code
	exit_code=$(aba_mirror_verify_exit) || true
	[[ "$exit_code" == "0" ]]
}

# Last completed mirror action from state.sh (install | load | sync | register).
# Empty if the mirror is not installed or state is missing.
_mirror_last_action() {
	source <(cd "$ABA_ROOT/mirror" && normalize-mirror-conf) 2>/dev/null && echo "${last_action:-}"
}

# Return human-readable mirror state for the menu title.
# States: "no mirror" → "mirror installed" → "mirror ready"
# "mirror ready" means the release image is actually present in the registry.
# Color-coded via dialog --colors escape codes: green=ready, yellow=installed, red=none.
mirror_state_label() {
	if ! mirror_available; then
		echo "\\Z1no mirror\\Zn"
		return
	fi
	if _mirror_has_release_image; then
		echo "\\Z2\\Zbmirror ready\\Zn"
	else
		echo "\\Z3mirror installed\\Zn"
	fi
}

# Invalidate mirror verify and kick off a fresh background check.
# Called after sync, load, install, or uninstall operations.
# Non-blocking: the check runs in background while the user reads results.
# Also sets _TUI_NEED_MIRROR_RECHECK so the menu loop re-probes on next draw.
_invalidate_mirror_cache() {
	_TUI_NEED_MIRROR_RECHECK=true
	aba_mirror_verify_refresh
	# Internet check uses TTL (aba_inet_check_cached) — no reset needed here.
	# The menu loop re-triggers automatically if >300s elapsed.
}

# After mirror load/sync, offer to run day2 on clusters using this mirror.
# Zero clusters: simple success message.
# One cluster: offer to run day2 now.
# Multiple clusters: informational dialog (user runs day2 manually).
_offer_day2_after_mirror_update() {
	local _cl _is_mirror
	local -a _clusters=()

	for _cl in $(list_installed_clusters); do
		_is_mirror=$(
			image_source=mirror
			# shellcheck disable=SC1090
			source <(cd "$ABA_ROOT/$_cl" && normalize-cluster-conf) 2>/dev/null || true
			image_source_is_mirror && echo 1 || echo 0
		)
		[[ "$_is_mirror" -ne 1 ]] && continue
		_clusters+=("$_cl")
	done

	if [[ ${#_clusters[@]} -eq 0 ]]; then
		dlg --backtitle "$(ui_backtitle)" --title "Mirror Updated" \
			--msgbox "Mirror updated successfully." 0 0
		return 0
	fi

	if [[ ${#_clusters[@]} -eq 1 ]]; then
		local _fqdn
		_fqdn=$(cluster_display_name "${_clusters[0]}")
		dlg --backtitle "$(ui_backtitle)" --title "Configure OperatorHub" \
			--yes-label "Run Day-2 now" \
			--no-label "Later" \
			--yesno "Mirror updated successfully.\n\n\
Cluster $_fqdn uses this mirror.\n\n\
Run Day-2 now to apply changes\n\
(new operators, updated release image, etc.)?" 0 0
		if [[ $? -eq 0 ]]; then
			confirm_and_execute "aba --dir ${_clusters[0]} day2" "Configure OperatorHub: $_fqdn"
		fi
		return 0
	fi

	# Multiple clusters: informational dialog
	local _list=""
	for _cl in "${_clusters[@]}"; do
		_list="${_list}\n  - $(cluster_display_name "$_cl")"
	done

	dlg --backtitle "$(ui_backtitle)" --title "Configure OperatorHub" \
		--msgbox "Mirror updated successfully.\n\n\
Installed clusters using this mirror:$_list\n\n\
Run 'aba day2' on those clusters, if you have:\n\
  - Added or changed operators\n\
  - Updated the OCP release image\n\n\
CLI:  aba --dir <cluster> day2\n\
TUI:  Cluster > Day-2 > Configure OperatorHub" 0 0
}

# Is a cluster configured? (cluster.conf exists in given dir)
cluster_configured() {
	local dir="$1"
	[[ -f "$ABA_ROOT/$dir/cluster.conf" ]]
}

# Is a cluster installed? (.install-complete is created by Makefile on success
# and removed by 'aba delete')
cluster_installed() {
	local dir="$1"
	[[ -f "$ABA_ROOT/$dir/.install-complete" ]]
}

# List cluster directories (dirs containing cluster.conf, excluding templates)
list_cluster_dirs() {
	# Sort by directory modification time (newest first) so the most
	# recently touched cluster appears at the top of selection dialogs.
	local dir
	local -a dirs=()
	for dir in "$ABA_ROOT"/*/cluster.conf; do
		[[ -f "$dir" ]] || continue
		dir="${dir%/cluster.conf}"                    # strip filename → dir path
		dir="${dir##*/}"                              # strip parent dirs → basename
		[[ "$dir" == "mirror" || "$dir" == "templates" ]] && continue
		[[ "$dir" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || continue
		dirs+=("$dir")
	done
	if [[ ${#dirs[@]} -eq 0 ]]; then
		return
	fi
	# stat -c '%Y' = mtime epoch; sort -rnk1 = newest first
	for dir in "${dirs[@]}"; do
		printf '%s %s\n' "$(stat -c '%Y' "$ABA_ROOT/$dir" 2>/dev/null || echo 0)" "$dir"
	done | sort -rnk1 | awk '{print $2}'
}

# List installed clusters (dirs with .install-complete marker).
# Pure output function -- no UI calls (safe inside command substitution).
list_installed_clusters() {
	local dir
	for dir in $(list_cluster_dirs); do
		cluster_installed "$dir" && echo "$dir" || true
	done
}

# List clusters that have kubeconfig but no .install-complete (candidates for auto-detection).
# Skips clusters that are known to be shut down (.shutdown.log exists).
list_undetected_clusters() {
	local dir
	for dir in $(list_cluster_dirs); do
		if [[ ! -f "$ABA_ROOT/$dir/.install-complete" && -f "$ABA_ROOT/$dir/iso-agent-based/auth/kubeconfig" ]]; then
			[[ -f "$ABA_ROOT/$dir/.shutdown.log" ]] && continue
			echo "$dir"
		fi
	done
}

# Probe undetected clusters and create .install-complete if ready.
# Shows "please wait" dialog only when there are candidates to probe.
# Must be called BEFORE list_installed_clusters (it updates marker files).
# If a cluster transitions to ready, offers to run day2 (mirror modes only).
_probe_undetected_clusters() {
	local -a candidates=()
	local dir

	mapfile -t candidates < <(list_undetected_clusters)
	[[ ${#candidates[@]} -eq 0 ]] && return 0

	local names="${candidates[*]}"
	dlg --backtitle "$(ui_backtitle)" \
		--infobox "\nDetecting installation status: ${names// /, }..." 5 55  # spaces → commas
	for dir in "${candidates[@]}"; do
		if [[ ! -f "$ABA_ROOT/$dir/.install-complete" ]]; then
			auto_complete_install "$dir" >/dev/null 2>&1 || true
			# Newly transitioned to ready — offer day2 in mirror modes
			if [[ -f "$ABA_ROOT/$dir/.install-complete" && "$_TUI_MODE" != "DIRECT" ]]; then
				local _fqdn
				_fqdn=$(cluster_display_name "$dir")
				dlg --backtitle "$(ui_backtitle)" --title "Cluster Ready!" \
					--yes-label "Yes, apply now" \
					--no-label "No, later" \
					--yesno "Cluster $_fqdn just completed installation!\n\n\
Run 'Configure OperatorHub' (aba day2) to set up:\n\
  • OperatorHub catalog sources\n\
  • Image content source policies\n\
  • Release signature verification\n\n\
This is needed for operators and upgrades to work\n\
from your mirror registry." 0 0
				if [[ $? -eq 0 ]]; then
					confirm_and_execute "aba --dir $dir day2" "Configure OperatorHub: $_fqdn"
				fi
			fi
		fi
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

# Feedback: show GitHub URLs, try to open in browser if available.
_tui_feedback() {
	local gh_url="https://github.com/sjbylo/aba"
	local choice

	dlg --backtitle "$(ui_backtitle)" --title "Feedback" \
		--cancel-label "$TUI2_BTN_BACK" \
		--menu "How would you like to share feedback?" 0 0 0 \
		"I" "Report an issue" \
		"D" "Start a discussion" \
		"S" "Star the project on GitHub" \
		2>"$_TUI_TMP"
	[[ $? -ne 0 ]] && return

	choice=$(<"$_TUI_TMP")

	local url=""
	case "$choice" in
		I) url="$gh_url/issues/new" ;;
		D) url="$gh_url/discussions/new?category=general" ;;
		S) url="$gh_url" ;;
	esac
	[[ -z "$url" ]] && return

	if [[ "${_TUI_INET:-no}" == "yes" ]] && command -v xdg-open &>/dev/null; then
		xdg-open "$url" &>/dev/null &
		dlg --backtitle "$(ui_backtitle)" --title "Feedback" \
			--msgbox "Opening in your browser:\n\n$url" 0 0
	elif [[ "${_TUI_INET:-no}" != "yes" ]]; then
		dlg --backtitle "$(ui_backtitle)" --title "Feedback" \
			--msgbox "No internet connection detected.\n\nOpen this URL in a browser when you have access:\n\n$url" 0 0
	else
		dlg --backtitle "$(ui_backtitle)" --title "Feedback" \
			--msgbox "Open this URL in a browser:\n\n$url" 0 0
	fi
	tui_log "Feedback: $url"
}

# Append ` --retry N` when _TUI_RETRY_COUNT > 0 (for oc-mirror operations).
_tui_oc_mirror_retry_suffix() {
	if [[ "${_TUI_RETRY_COUNT:-0}" -gt 0 ]]; then
		printf ' --retry %s' "${_TUI_RETRY_COUNT}"
	fi
}

# Compute cluster-related menu greying/state for DISCO / CONNO / DIRECT main menus.
# Sets globals (readable from any sourcing script):
#   _CLUSTER_HAS_ANY, _CLUSTER_HAS_INSTALLED,
#   _CLUSTER_DAY2_AVAIL, _CLUSTER_MON_AVAIL,
#   _CLUSTER_INST_LABEL
# Optional arg: workflow hint — CONNO | DISCO | DIRECT (default DIRECT).
tui_cluster_menu_flags() {
	local _workflow="${1:-DIRECT}"

	_CLUSTER_HAS_ANY=false
	_CLUSTER_HAS_INSTALLED=false
	local dir=""
	for dir in $(list_cluster_dirs); do
		_CLUSTER_HAS_ANY=true
		cluster_installed "$dir" && _CLUSTER_HAS_INSTALLED=true
	done

	_CLUSTER_DAY2_AVAIL=true
	_CLUSTER_MON_AVAIL=true
	if [[ "$_CLUSTER_HAS_ANY" != "true" ]]; then
		_CLUSTER_DAY2_AVAIL=false
		_CLUSTER_MON_AVAIL=false
	fi

	local _lbl="$TUI2_LABEL_INSTALL_CLUSTER"
	case "$_workflow" in
		CONNO)
			if ! mirror_available; then
				_lbl="$TUI2_LABEL_INSTALL_CLUSTER $TUI2_STATUS_NO_MIRROR"
			elif ! _mirror_has_release_image; then
				# Release image may be absent after a successful sync/load
				# (e.g. excl_platform=true / operators-only archive).
				_lbl="$TUI2_LABEL_INSTALL_CLUSTER $TUI2_STATUS_NO_RELEASE"
			fi
			;;
		DISCO)
			if ! mirror_available; then
				_lbl="$TUI2_LABEL_INSTALL_CLUSTER $TUI2_STATUS_INSTALL_REGISTRY"
			elif ! _mirror_has_release_image; then
				# Same check as CONNO: "not loaded" is wrong when the archive
				# was loaded but intentionally omitted platform/release images.
				_lbl="$TUI2_LABEL_INSTALL_CLUSTER $TUI2_STATUS_NO_RELEASE"
			fi
			;;
		DIRECT|"")
			;;
		*)
			;;
	esac
	_CLUSTER_INST_LABEL="$_lbl"
}

# -----------------------------------------------------------------------------
# Settings: ask= (aba.conf), reg_vendor (mirror.conf), oc-mirror retries (session)
# -----------------------------------------------------------------------------

# Read current ask= value via normalize-aba-conf (single source of truth)
_tui_abaconf_raw_ask() {
	if [[ ! -f "$ABA_ROOT/aba.conf" ]]; then
		echo ""
		return
	fi
	local _ask_val
	_ask_val=$(source <(cd "$ABA_ROOT" && normalize-aba-conf) 2>/dev/null && echo "$ask")
	echo "$_ask_val"
}

_tui_settings_menu_reg_vendor() {
	local vf="$ABA_ROOT/mirror/mirror.conf"
	if [[ ! -f "$vf" ]]; then
		make -sC "$ABA_ROOT/mirror" mirror.conf 2>/dev/null || true
	fi

	local cur="auto"
	if [[ -f "$vf" ]]; then
		source <(cd "$ABA_ROOT/mirror" && normalize-mirror-conf) 2>/dev/null || true
		cur="${reg_vendor:-auto}"
	fi

	dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_SETTINGS" \
		--cancel-label "$TUI2_BTN_BACK" \
		--menu "Select registry installer vendor (stored in mirror/mirror.conf).\nAuto picks Quay vs Docker based on detected architecture.\nCurrent: $cur" 0 0 3 \
		"auto"  "Auto (architecture-based)" \
		"quay"  "Quay mirror-registry" \
		"docker" "Docker registry tarball" \
		2>"$_TUI_TMP"
	local rc=$?
	[[ $rc -ne 0 ]] && return

	local pick
	pick=$(<"$_TUI_TMP")
	case "$pick" in
		auto|quay|docker|$_QUAY_NG_VENDOR)
			if [[ ! -f "$vf" ]]; then
				dlg --backtitle "$(ui_backtitle)" --msgbox "mirror.conf not available." 0 0
				return 1
			fi
			replace-value-conf -q -n reg_vendor -v "$pick" -f "$vf"
			tui_log "Settings: reg_vendor=$pick"
			;;
	esac
}

_tui_settings_menu_retry() {
	local current="${_TUI_RETRY_COUNT:-1}"
	dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_SETTINGS" \
		--inputbox "Oc-mirror retry count for this session (0 = omit --retry):" 0 0 "$current" \
		2>"$_TUI_TMP"
	[[ $? -ne 0 ]] && return

	local val
	val=$(<"$_TUI_TMP")
	val=$(echo "$val" | tr -dc '0-9')
	[[ -z "$val" ]] && val="0"

	if [[ "$val" =~ ^[0-9]+$ ]] && [[ "$val" -le 999 ]]; then
		_TUI_RETRY_COUNT="$val"
		_tui_persist_retry_count "$val"
		tui_log "Settings: _TUI_RETRY_COUNT=$val"
	else
		dlg --backtitle "$(ui_backtitle)" --msgbox \
			"Invalid retry count.\n\nEnter an integer between 0 and 999." 0 0
	fi
}

# Build a compact settings summary string for the menu item label.
_tui_settings_summary() {
	if [[ "${_TUI_MODE:-}" == "DIRECT" ]]; then
		return
	fi

	local rv="Auto"
	case "$_TUI_REG_VENDOR" in
		quay)   rv="Quay" ;;
		docker) rv="Docker" ;;
	esac

	printf '(\Z6%s, retry=%s\Zn)' "$rv" "${_TUI_RETRY_COUNT:-1}"
}

# Settings submenu -- v1-style toggle behavior.
# Each item cycles through its values on Enter (no sub-dialogs).
_tui_settings_menu() {
	local default_item="1"
	while :; do
		# Refresh reg_vendor from mirror.conf (may have changed in Mirror Config form)
		if [[ -f "$ABA_ROOT/mirror/mirror.conf" ]]; then
			source <(cd "$ABA_ROOT/mirror" && normalize-mirror-conf) 2>/dev/null || true
			_TUI_REG_VENDOR="${reg_vendor:-auto}"
		fi

		# Mirror-related settings: only relevant when a mirror is in play
		local _menu_items=()
		local _help_extra=""
		if [[ "${_TUI_MODE:-}" != "DIRECT" ]]; then
			local reg_display
			case "$_TUI_REG_VENDOR" in
				quay)   reg_display="Registry Type: \Z2Quay\Zn" ;;
				docker) reg_display="Registry Type: \Z3Docker\Zn" ;;
				*)      reg_display="Registry Type: \Z6Auto\Zn" ;;
			esac
			local retry_display
			local rc_val="${_TUI_RETRY_COUNT:-1}"
			case "$rc_val" in
				0)  retry_display="Retry Count: \Z1OFF\Zn" ;;
				*)  retry_display="Retry Count: \Z2${rc_val}\Zn" ;;
			esac
			_menu_items+=("1" "$reg_display" "2" "$retry_display")
			_help_extra="
Registry Type:
  Auto   - Let aba choose the registry (recommended).
  Quay   - Force Quay mirror registry.
  Docker - Force Docker V2 mirror registry.

Retry Count:
  How many times to retry failed oc-mirror operations.
  0 = no retries, or set any count (default: 1)."
		fi

		if [[ ${#_menu_items[@]} -eq 0 ]]; then
			dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_SETTINGS" \
				--msgbox "No settings available in this mode." 0 0
			return 0
		fi

		dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_SETTINGS" \
			--ok-label "Toggle" \
			--cancel-label "$TUI2_BTN_BACK" \
			--help-button \
			--default-item "$default_item" \
			--menu "Select a setting to toggle:" 0 0 0 \
			"${_menu_items[@]}" \
			2>"$_TUI_TMP"
		local rc=$?

		case "$rc" in
			2)
				show_help "$TUI2_TITLE_SETTINGS" \
"${_help_extra:-No settings available in this mode.}

Toggle a setting by selecting it and pressing Enter."
				continue
				;;
			1|255)
				return 0
				;;
			0) ;;
		esac

		local choice
		choice=$(<"$_TUI_TMP")
		[[ -n "$choice" ]] && default_item="$choice"

		case "$choice" in
			1)
				# Toggle in-memory: auto → quay → docker → auto
				case "$_TUI_REG_VENDOR" in
					auto)   _TUI_REG_VENDOR="quay";   tui_log "Settings: Registry type toggled to Quay" ;;
					quay)   _TUI_REG_VENDOR="docker"; tui_log "Settings: Registry type toggled to Docker" ;;
					docker) _TUI_REG_VENDOR="auto";   tui_log "Settings: Registry type toggled to Auto" ;;
					*)      _TUI_REG_VENDOR="auto";   tui_log "Settings: Registry type reset to Auto" ;;
				esac
				# Persist to file
				local vf="$ABA_ROOT/mirror/mirror.conf"
				if [[ ! -f "$vf" ]]; then
					make -sC "$ABA_ROOT/mirror" mirror.conf 2>/dev/null || true
				fi
				if [[ -f "$vf" ]]; then
					replace-value-conf -q -n reg_vendor -v "$_TUI_REG_VENDOR" -f "$vf"
				fi
				;;
			2)
				# Toggle: 0 → 1 → 2 → 5 → 0
				case "${_TUI_RETRY_COUNT:-1}" in
					0) _TUI_RETRY_COUNT=1; tui_log "Settings: Retry count toggled to 1" ;;
					1) _TUI_RETRY_COUNT=2; tui_log "Settings: Retry count toggled to 2" ;;
					2) _TUI_RETRY_COUNT=5; tui_log "Settings: Retry count toggled to 5" ;;
					5) _TUI_RETRY_COUNT=0; tui_log "Settings: Retry count toggled to OFF" ;;
					*) _TUI_RETRY_COUNT=1; tui_log "Settings: Retry count reset to 1" ;;
				esac
				_tui_persist_retry_count "$_TUI_RETRY_COUNT"
				;;
		esac
	done
}


# =============================================================================
# Cluster selector dialog
# =============================================================================

# select_cluster "title" "prompt" [filter] — sets SELECTED_CLUSTER and SELECTED_CLUSTER_DISPLAY or returns 1
# Optional filter values:
#   "installing" — only clusters with kubeconfig but no .install-complete (actively installing)
#   ""           — all clusters (default)
select_cluster() {
	local title="${1:-Select Cluster}"
	local prompt="${2:-Choose a cluster:}"
	local filter="${3:-}"
	local clusters=()
	local dir display
	local -a _cl_dirs=()
	local idx=0

	for dir in $(list_cluster_dirs); do
		# Apply filter if specified
		if [[ "$filter" == "installing" ]]; then
			# Skip clusters that are already fully installed
			[[ -f "$ABA_ROOT/$dir/.install-complete" ]] && continue
			# Skip clusters that haven't started installing (no kubeconfig)
			[[ ! -f "$ABA_ROOT/$dir/iso-agent-based/auth/kubeconfig" ]] && continue
			# Skip clusters that were shut down (can't be actively monitored)
			[[ -f "$ABA_ROOT/$dir/.shutdown.log" ]] && continue
		fi
		display=$(cluster_display_name "$dir")
		# Annotate status so the user sees cluster state at a glance
		if [[ -f "$ABA_ROOT/$dir/.shutdown.log" ]]; then
			display="$display (shut down)"
		elif [[ -f "$ABA_ROOT/$dir/.install-complete" ]]; then
			display="$display (installed)"
		elif [[ -f "$ABA_ROOT/$dir/iso-agent-based/auth/kubeconfig" ]]; then
			display="$display (installing)"
		fi
		# Show dir name only when it differs from the cluster name prefix
		if [[ "$display" != "$dir"* ]]; then
			display="$dir  $display"
		fi
		idx=$(( idx + 1 ))
		_cl_dirs+=("$dir")
		clusters+=("$idx" "$display")
	done

	if [[ ${#clusters[@]} -eq 0 ]]; then
		if [[ "$filter" == "installing" ]]; then
			dlg --backtitle "$(ui_backtitle)" --msgbox \
				"No clusters are currently installing.\n\nAll clusters are either fully installed or not yet started." 0 0
		else
			dlg --backtitle "$(ui_backtitle)" --msgbox "$TUI2_MSG_NO_CLUSTERS" 0 0
		fi
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

	local selected_idx=$(<"$_TUI_TMP")
	SELECTED_CLUSTER="${_cl_dirs[$(( selected_idx - 1 ))]}"
	if [[ ! "$SELECTED_CLUSTER" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
		dlg --backtitle "$(ui_backtitle)" --msgbox \
			"Invalid cluster name: '$SELECTED_CLUSTER'\n\nCluster directory names must be valid DNS labels." 0 0
		return 1
	fi
	SELECTED_CLUSTER_DISPLAY=$(cluster_display_name "$SELECTED_CLUSTER")
	return 0
}

# select_installed_cluster — same but only installed clusters
# Probes undetected clusters first (shows "please wait" if any need checking).
select_installed_cluster() {
	local title="${1:-Select Cluster}"
	local prompt="${2:-Choose an installed cluster:}"
	local clusters=()
	local dir display
	local -a _cl_dirs=()
	local idx=0

	# Probe clusters that might have completed installation in the background
	_probe_undetected_clusters

	for dir in $(list_installed_clusters); do
		display=$(cluster_display_name "$dir")
		# Annotate shut-down clusters so the user knows before selecting
		if [[ -f "$ABA_ROOT/$dir/.shutdown.log" ]]; then
			display="$display (shut down)"
		fi
		# Show dir name only when it differs from the cluster name prefix
		if [[ "$display" != "$dir"* ]]; then
			display="$dir  $display"
		fi
		idx=$(( idx + 1 ))
		_cl_dirs+=("$dir")
		clusters+=("$idx" "$display")
	done

	if [[ ${#clusters[@]} -eq 0 ]]; then
		dlg --backtitle "$(ui_backtitle)" --msgbox "$TUI2_MSG_NO_INSTALLED_CLUSTERS" 0 0
		return 1
	fi

	if [[ $idx -eq 1 ]]; then
		SELECTED_CLUSTER="${_cl_dirs[0]}"
		SELECTED_CLUSTER_DISPLAY=$(cluster_display_name "$SELECTED_CLUSTER")
		return 0
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

	local selected_idx=$(<"$_TUI_TMP")
	SELECTED_CLUSTER="${_cl_dirs[$(( selected_idx - 1 ))]}"
	if [[ ! "$SELECTED_CLUSTER" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
		dlg --backtitle "$(ui_backtitle)" --msgbox \
			"Invalid cluster name: '$SELECTED_CLUSTER'\n\nCluster directory names must be valid DNS labels." 0 0
		return 1
	fi
	SELECTED_CLUSTER_DISPLAY=$(cluster_display_name "$SELECTED_CLUSTER")
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
			${EDITOR:-vi} "$filepath" {ABA_TUI_FLOCK_FD}>&-
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
	_tui_redirect_restore
	clear
	echo "TUI v2 complete."
	echo
	local f mod_epoch shown=0
	for f in aba.conf mirror/mirror.conf mirror/data/imageset-config.yaml \
		vmware.conf kvm.conf; do
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
	for f in "$ABA_ROOT"/*/cluster.conf; do
		[[ -f "$f" ]] || continue
		mod_epoch=$(stat -c %Y "$f" 2>/dev/null) || continue
		if (( mod_epoch >= _TUI_START_EPOCH )); then
			if (( shown == 0 )); then
				echo "Files created/updated:"
				shown=1
			fi
			echo "  ${f#$ABA_ROOT/}"                     # strip ABA_ROOT prefix → relative path
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

# =============================================================================
# Mirror / ISC / catalog helpers shared across TUI v2 modules
# =============================================================================

# Resolve x.y to x.y.z via fetch_latest_z_version. Prints the resolved version.
# Returns 1 if resolution fails (caller should show error).
_resolve_minor_to_patch() {
	local _ver="$1"
	local _channel="${2:-stable}"

	# Already x.y.z or x.y.z-rc.N? Return as-is
	if [[ "$_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-z]+\.[0-9]+)?$ ]]; then
		echo "$_ver"
		return 0
	fi

	# x.y format — resolve to latest z (include_all expects channel then minor)
	if [[ "$_ver" =~ ^[0-9]+\.[0-9]+$ ]]; then
		local _resolved
		_resolved=$(fetch_latest_z_version "$_channel" "$_ver" 2>/dev/null)
		if [[ -n "$_resolved" && "$_resolved" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-z]+\.[0-9]+)?$ ]]; then
			echo "$_resolved"
			return 0
		fi
	fi

	return 1
}

# Reset and restart ISC generation in background (non-blocking)
tui_kick_isconf_regen() {
	run_once -r -i "aba:isconf:generate" 2>/dev/null || true
	(cd "$ABA_ROOT" && aba_isconf_generate_start) {ABA_TUI_FLOCK_FD}>&-
	_TUI_ISC_UPDATED=true
}

# Gate Install Cluster menu action: prompts for mirror/registry prep when needed.
# Returns:
#   0 — mirror ready; caller should run cluster_install_flow now
#   1 — do not proceed (cancelled / async remediation)
#   3 — DISCO only: cluster_install_flow was already invoked by this helper (success chain)
tui_install_cluster_gate() {
	if mirror_available && _mirror_has_release_image; then
		return 0
	fi

	local _rc

	case "${1:-}" in
		CONNO)
			if ! mirror_available; then
				dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_MIRROR_REQUIRED" \
					--yes-label "Install & Sync" --no-label "$TUI2_BTN_BACK" \
					--yesno "No mirror registry installed.\n\nA mirror with synced images is required to install a cluster.\n\nInstall the mirror and sync images now?" 0 0
				_rc=$?
				if [[ $_rc -eq 0 ]]; then
					if _mirror_config_review && mirror_sync; then
						cluster_install_flow
						return 3
					fi
				fi
				return 1
			fi
			dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_MIRROR_NOT_SYNCED" \
				--yes-label "Sync Now" --no-label "$TUI2_BTN_BACK" \
				--yesno "The mirror is installed but has no release images.\n\nSync images to the mirror now?" 0 0
			_rc=$?
			if [[ $_rc -eq 0 ]]; then
				if mirror_sync; then
					cluster_install_flow
					return 3
				fi
			fi
			return 1
			;;
		DISCO)
			if ! mirror_available; then
				dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_MIRROR_REQUIRED" \
					--yes-label "Install & Load" --no-label "$TUI2_BTN_BACK" \
					--yesno "No mirror registry installed.\n\nA mirror with loaded images is required to install a cluster.\n\nInstall the registry and load images now?" 0 0
				_rc=$?
				if [[ $_rc -eq 0 ]]; then
					if _mirror_config_review && disco_load_images; then
						cluster_install_flow
						return 3
					fi
				fi
				return 1
			fi
			dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_MIRROR_NOT_LOADED" \
				--yes-label "Load Now" --no-label "$TUI2_BTN_BACK" \
				--yesno "The mirror is installed but has no release images.\n\nLoad images into the mirror now?" 0 0
			_rc=$?
			if [[ $_rc -eq 0 ]]; then
				if disco_load_images; then
					cluster_install_flow
					return 3
				fi
			fi
			return 1
			;;
	esac

	return 1
}

# Advisory gate for operations that need podman (catalog index downloads).
# Waits for the background check started at mode entry.  If the previous check
# failed, retries once (user may have fixed auth/network since mode entry).
# On failure: warns the user and offers Continue/Retry/Back.
# "Continue" is remembered for the rest of the session (no repeat prompts).
# Returns 0=ok (or user chose Continue), 1=back.
# Session flag: once the user dismisses the podman warning with "Continue",
# don't prompt again (the registry may be permanently unreachable).
_PODMAN_WARN_DISMISSED=""
_require_podman() {
	[[ "$_PODMAN_WARN_DISMISSED" == "1" ]] && return 0

	# Ensure the check has been started
	aba_podman_check_start

	# If still running, show "Please wait..." until it completes
	if ! run_once -p -i "aba:preflight:podman" 2>/dev/null; then
		dlg --backtitle "$(ui_backtitle)" --infobox \
			"Verifying podman connectivity...\n\nPlease wait." 5 45
	fi

	# Block until result is available
	if ! aba_podman_check_wait; then
		# Failed — retry once (user may have fixed auth/network since mode entry)
		run_once -r -i "aba:preflight:podman" 2>/dev/null || true
		aba_podman_check_start
		if ! run_once -p -i "aba:preflight:podman" 2>/dev/null; then
			dlg --backtitle "$(ui_backtitle)" --infobox \
				"Retrying podman check...\n\nPlease wait." 5 45
		fi
	fi

	if ! aba_podman_check_wait; then
		local _err="${PODMAN_CHECK_ERROR//$'\n'/\\n}"
		dlg --backtitle "$(ui_backtitle)" --title "Podman Preflight Warning" \
			--yes-label "Continue" --no-label "Back" \
			--extra-button --extra-label "Retry" \
			--yesno "Podman preflight check failed:\n\n${_err}\n\nThis may not affect your workflow if the required\nregistries are accessible.\n\nContinue anyway?" 0 0
		local _rc=$?
		case "$_rc" in
			0) _PODMAN_WARN_DISMISSED=1; return 0 ;;
			3)
				run_once -r -i "aba:preflight:podman" 2>/dev/null || true
				aba_podman_check_start
				_require_podman
				return $?
				;;
			*) return 1 ;;
		esac
	fi
}

# Generic troubleshooting hints for catalog download failures.
_tui_catalog_error_hints() {
	local _h="To fix, check:"
	_h="${_h}\n  - Internet connectivity (can you reach registry.redhat.io?)"
	_h="${_h}\n  - Pull secret is valid and not expired"
	_h="${_h}\n  - Podman rootless setup (/etc/subuid, /etc/subgid)"
	_h="${_h}\n  - Sufficient disk space for container storage"
	_h="${_h}\n  - DNS resolution is working"
	_h="${_h}\n"
	_h="${_h}\nAfter fixing, run './install' to clear the cache and retry."
	echo "$_h"
}

# Ensure catalog indexes are available for a given OCP version.
# If shipped/downloaded files already exist in .index/, proceed immediately
# (downloads still run in background for freshness). Only blocks if no files
# exist at all (e.g. user picked a version not in catalogs/).
tui_ensure_catalogs_ready() {
	local version_short="$1"

	# Populate .index/ from shipped catalogs if missing
	_populate_shipped_indexes

	# If at least one catalog index exists for this version, proceed immediately
	local _have_files=false
	local _f
	for _f in .index/*-operator-index-v${version_short}; do
		[[ -s "$_f" ]] && { _have_files=true; break; }
	done

	if [[ "$_have_files" == true ]]; then
		# Still kick off downloads in background for freshness (no-op if already running)
		download_all_catalogs "$version_short" >>"$_TUI_LOG_FILE" 2>&1
		return 0
	fi

	# No files at all -- must download and wait
	dlg --backtitle "$(ui_backtitle)" --infobox \
		"Downloading operator catalog indexes...\n\nPlease wait." 0 0

	# Reset any cached failures from earlier prefetch attempts (e.g. startup
	# prefetch ran before pull secret was ready). run_once -i skips "done" tasks
	# even if they failed — reset clears the cached failure so they re-run.
	local _cat _exit_code
	for _cat in redhat-operator certified-operator community-operator; do
		_exit_code=$(run_once -E -i "catalog:${version_short}:${_cat}" 2>/dev/null) || continue
		if [[ "$_exit_code" != "0" ]]; then
			tui_log "Resetting failed catalog task: catalog:${version_short}:${_cat} (exit=$_exit_code)"
			run_once -r -i "catalog:${version_short}:${_cat}" 2>/dev/null || true
		fi
	done

	download_all_catalogs "$version_short" >>"$_TUI_LOG_FILE" 2>&1

	if ! wait_for_all_catalogs "$version_short" >>"$_TUI_LOG_FILE" 2>&1; then
		return 1
	fi

	return 0
}
