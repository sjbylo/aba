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
#   - For menu/radiolist/checklist: replaces menu-height=0 with the actual
#     item count so dialog sizes the box to fit all items (no scrollbar)
dlg() {
	local args=()
	local next_is_title=false
	local next_is_text=false
	local has_menu=false
	local menu_type=""
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
			if [[ "$has_menu" == "true" ]]; then
				if [[ "$arg" != "\n"* && "$arg" != $'\n'* ]]; then
					arg="\n$arg"
				fi
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
			--msgbox|--yesno|--inputbox|--infobox|--mixedform)
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
	dialog --no-shadow --colors --no-collapse --tab-correct "${args[@]}" {ABA_TUI_FLOCK_FD}>&-
}

# =============================================================================
# Backtitle (status bar at top)
# =============================================================================

_TUI_MODE=""   # Set by mode detection: DISCO, CONNO, DIRECT
_TUI_INET=""   # Set by mode detection: "yes" or "no" (internet available)

# Session-only: forwarded to oc-mirror via `aba mirror save|sync|load --retry N`
_TUI_RETRY_COUNT="${_TUI_RETRY_COUNT:-1}"

# Registry type -- in-memory state, loaded from mirror.conf at startup, persisted on toggle.
# Values: "auto", "quay", "docker"
_TUI_REG_VENDOR="auto"
if [[ -f "$ABA_ROOT/mirror/mirror.conf" ]]; then
	# Read reg_vendor directly from mirror.conf to reflect user's configured intent.
	# normalize-mirror-conf would return the resolved/installed value from state.sh.
	_raw_vendor=$(grep '^reg_vendor=' "$ABA_ROOT/mirror/mirror.conf" 2>/dev/null | head -1 | cut -d= -f2- | sed 's/[[:space:]]*#.*//')
	case "${_raw_vendor,,}" in
		quay)   _TUI_REG_VENDOR="quay" ;;
		docker) _TUI_REG_VENDOR="docker" ;;
		auto)   _TUI_REG_VENDOR="auto" ;;
		*)      _TUI_REG_VENDOR="auto" ;;
	esac
	unset _raw_vendor
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
	[ -n "$ch" ] && [ -n "$ver" ] && text="$text  |  $ch $ver"

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
	dialog --no-shadow --colors --backtitle "$(ui_backtitle)" \
		--title " $title " --cr-wrap --msgbox "\n$body" 0 0 {ABA_TUI_FLOCK_FD}>&- || true
}

# =============================================================================
# Input validation helpers
# =============================================================================

# Reject single quotes in user input destined for config files.
# Config files are sourced by bash — unescaped single quotes corrupt them.
# Usage:  _tui_reject_squote "$value" || continue
_tui_reject_squote() {
	[[ "$1" != *"'"* ]] && return 0
	dlg --backtitle "$(ui_backtitle)" --msgbox \
		"Input cannot contain single-quote (') characters.\n\nPlease re-enter without single quotes." 0 0
	return 1
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

# Session-scoped execution mode preference (empty = ask every time)
_TUI_EXEC_MODE="${_TUI_EXEC_MODE:-}"

confirm_and_execute() {
	local cmd="$1"
	local title="${2:-Confirm Execution}"
	local post_cmd_hook="${3:-}"
	tui_log "Confirming command: $cmd"

	# If user previously chose "always", skip the picker but retain retry loop
	if [[ -n "$_TUI_EXEC_MODE" ]]; then
		tui_log "Using remembered exec mode: $_TUI_EXEC_MODE"
		while :; do
			case "$_TUI_EXEC_MODE" in
				tui)      _exec_in_tui "$cmd" "$title" "$post_cmd_hook" ;;
				terminal) _exec_in_terminal "$cmd" "$title" "$post_cmd_hook" ;;
			esac
			local exec_rc=$?
			[[ $exec_rc -eq 2 ]] && continue
			return $exec_rc
		done
	fi

	local default_item="1"
	while :; do
		dlg --backtitle "$(ui_backtitle)" --title "$title" \
			--cancel-label "$TUI2_BTN_BACK" \
			--ok-label "$TUI2_BTN_SELECT" \
			--help-button \
			--extra-button --extra-label "Command" \
			--default-item "$default_item" \
			--menu "$TUI2_MSG_EXEC_MODE" 0 0 0 \
			"1" "Run in TUI" \
			"2" "Run in Terminal" \
			"3" "Always TUI (this session)" \
			"4" "Always Terminal (this session)" \
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
  - Press ENTER to return to TUI

• Always TUI / Always Terminal
  - Remembers your choice for this session
  - Skips this dialog for all subsequent commands
  - Reset via Advanced > Reset Execution Mode"
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
		[[ -n "$choice" ]] && default_item="$choice"

		case "$choice" in
			1) _exec_in_tui "$cmd" "$title" "$post_cmd_hook" ;;
			2) _exec_in_terminal "$cmd" "$title" "$post_cmd_hook" ;;
			3) _TUI_EXEC_MODE="tui"
			   tui_log "Exec mode set to: always TUI"
			   _exec_in_tui "$cmd" "$title" "$post_cmd_hook" ;;
			4) _TUI_EXEC_MODE="terminal"
			   tui_log "Exec mode set to: always Terminal"
			   _exec_in_terminal "$cmd" "$title" "$post_cmd_hook" ;;
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
	{ echo "Executing: $cmd"; echo; PLAIN_OUTPUT=1 ASK_OVERRIDE=1 bash -c "$tui_cmd" {ABA_TUI_FLOCK_FD}>&- 2>&1; } | tee "$output_file" | \
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

	# Defense-in-depth: reject commands with shell metacharacters that could indicate injection
	if [[ "$cmd" =~ [\`\$\;\|\>\<]|'&&' ]]; then
		tui_log "BLOCKED: command contains dangerous metacharacters: $cmd"
		echo "ERROR: Command blocked — contains invalid characters."
		read -rp "Press ENTER to return to TUI..."
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
		echo "  Tip: Enable auto-answer in TUI Settings to skip prompts"
	fi
	echo

	# Trap INT so Ctrl-C kills only the child command, not the TUI itself
	local _term_interrupted=false
	trap '_term_interrupted=true' INT

	# Close flock fd so child processes (e.g. conmon) don't inherit and hold the TUI lock
	bash -c "$cmd" {ABA_TUI_FLOCK_FD}>&-
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
	if [[ "$_term_interrupted" == "true" ]]; then
		echo "── Command interrupted (Ctrl-C) ──"
		echo
		read -rp "Press ENTER to continue..."
		return 1
	elif [[ $exit_code -eq 0 ]]; then
		echo "── Command completed successfully ──"
		echo
		read -rp "Press ENTER to continue..."
		return 0
	else
		echo "── Command FAILED (exit code: $exit_code) ──"
		echo
		read -rp "Press R to retry, ENTER to return to menu... " _reply
		[[ "$_reply" == [Rr] ]] && return 2
		return 1
	fi
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
	# The menu loop re-triggers automatically if >120s elapsed.
}

# Inform user about day2 after mirror load/sync.
# Shows only clusters that use this mirror (int_connection unset = mirror mode).
# Must be called AFTER confirm_and_execute returns (not from a post_cmd_hook)
# to avoid nested execution and confusing dialog ordering.
_offer_day2_after_mirror_update() {
	local _cl _list="" _int_conn

	for _cl in $(list_installed_clusters); do
		# Check if cluster uses the mirror (int_connection empty = mirror mode)
		_int_conn=$(
			int_connection=""
			# shellcheck disable=SC1090
			source <(cd "$ABA_ROOT/$_cl" && normalize-cluster-conf) 2>/dev/null || true
			echo "${int_connection:-}"
		)
		[[ -n "$_int_conn" ]] && continue
		_list="${_list}\n  - $(cluster_display_name "$_cl")"
	done

	[[ -z "$_list" ]] && return 0

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
		dir="${dir%/cluster.conf}"
		dir="${dir##*/}"
		[[ "$dir" == "mirror" || "$dir" == "templates" ]] && continue
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
		--infobox "\nDetecting installation status: ${names// /, }..." 5 55
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
				_lbl="$TUI2_LABEL_INSTALL_CLUSTER $TUI2_STATUS_SYNC_FIRST"
			fi
			;;
		DISCO)
			if ! mirror_available; then
				_lbl="$TUI2_LABEL_INSTALL_CLUSTER $TUI2_STATUS_INSTALL_REGISTRY"
			elif ! _mirror_has_release_image; then
				_lbl="$TUI2_LABEL_INSTALL_CLUSTER $TUI2_STATUS_LOAD_FIRST"
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

# Human label for Settings menu Auto-answer row
_tui_settings_ask_label() {
	local raw=""
	raw=$(_tui_abaconf_raw_ask)

	case "${raw,,}" in
		""|"true"|"1")
			echo "Ask every time"
			;;
		yes)
			echo "Auto yes"
			;;
		no)
			echo "Auto no"
			;;
		false|0)
			echo "Ask every time"
			;;
		*)
			echo "Ask every time (${raw:-unset})"
			;;
	esac
}

_tui_settings_persist_ask_mode() {
	local mode="$1"
	local conf="$ABA_ROOT/aba.conf"
	if [[ ! -f "$conf" ]]; then
		dlg --backtitle "$(ui_backtitle)" --msgbox \
			"No aba.conf found — cannot save settings.\n\nRun setup or copy templates first." 0 0
		return 1
	fi
	case "$mode" in
		always)
			replace-value-conf -q -n ask -v true -f "$conf"
			;;
		yes)
			replace-value-conf -q -n ask -v yes -f "$conf"
			;;
		no)
			replace-value-conf -q -n ask -v no -f "$conf"
			;;
		*)
			return 1
			;;
	esac
	source <(cd "$ABA_ROOT" && normalize-aba-conf) 2>/dev/null || true
	return 0
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
		auto|quay|docker)
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
		tui_log "Settings: _TUI_RETRY_COUNT=$val"
	else
		dlg --backtitle "$(ui_backtitle)" --msgbox \
			"Invalid retry count.\n\nEnter an integer between 0 and 999." 0 0
	fi
}

# Build a compact settings summary string for the menu item label.
# DIRECT mode: "(ask)" — no mirror settings shown (Bug #131).
# CONNO/DISCO:  "(ask, Docker, retry=2)" with color codes.
_tui_settings_summary() {
	local ask_short
	local raw
	raw=$(_tui_abaconf_raw_ask)
	case "${raw,,}" in
		yes) ask_short="-y" ;;
		*)   ask_short="ask" ;;
	esac

	if [[ "${_TUI_MODE:-}" == "DIRECT" ]]; then
		printf '(\Z6%s\Zn)' "$ask_short"
		return
	fi

	local rv="Auto"
	case "$_TUI_REG_VENDOR" in
		quay)   rv="Quay" ;;
		docker) rv="Docker" ;;
	esac

	printf '(\Z6%s, %s, retry=%s\Zn)' "$ask_short" "$rv" "${_TUI_RETRY_COUNT:-1}"
}

# Settings submenu -- v1-style toggle behavior.
# Each item cycles through its values on Enter (no sub-dialogs).
_tui_settings_menu() {
	local default_item="1"
	while :; do
		# Current auto-answer display (ON = skip prompts, OFF = ask user)
		local ask_display
		local raw
		raw=$(_tui_abaconf_raw_ask)
		case "${raw,,}" in
			yes)  ask_display="Auto-answer: \Z2ON\Zn (-y)" ;;
			*)    ask_display="Auto-answer: \Z1OFF\Zn" ;;
		esac

		# Mirror-related settings: only relevant when a mirror is in play
		local _menu_items=("1" "$ask_display")
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
			_menu_items+=("2" "$reg_display" "3" "$retry_display")
			_help_extra="
Registry Type:
  Auto   - Let aba choose the registry (recommended).
  Quay   - Force Quay mirror registry.
  Docker - Force Docker V2 mirror registry.

Retry Count:
  How many times to retry failed oc-mirror operations.
  0 = no retries, or set any count (default: 1)."
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
"Auto-answer (-y):
  When ON, aba commands run without confirmation prompts.
  When OFF, you will be asked to confirm each action.
${_help_extra}
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
				# Toggle: OFF ↔ ON (like v1)
				raw=$(_tui_abaconf_raw_ask)
				case "${raw,,}" in
					yes)
						_tui_settings_persist_ask_mode always
						tui_log "Settings: Auto-answer toggled OFF"
						;;
					*)
						_tui_settings_persist_ask_mode yes
						tui_log "Settings: Auto-answer toggled ON"
						;;
				esac
				;;
			2)
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
			3)
				# Toggle: 0 → 1 → 2 → 5 → 0
				case "${_TUI_RETRY_COUNT:-1}" in
					0) _TUI_RETRY_COUNT=1; tui_log "Settings: Retry count toggled to 1" ;;
					1) _TUI_RETRY_COUNT=2; tui_log "Settings: Retry count toggled to 2" ;;
					2) _TUI_RETRY_COUNT=5; tui_log "Settings: Retry count toggled to 5" ;;
					5) _TUI_RETRY_COUNT=0; tui_log "Settings: Retry count toggled to OFF" ;;
					*) _TUI_RETRY_COUNT=1; tui_log "Settings: Retry count reset to 1" ;;
				esac
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
			echo "  ${f#$ABA_ROOT/}"
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
		if [[ -n "$_resolved" && "$_resolved" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
			echo "$_resolved"
			return 0
		fi
	fi

	return 1
}

# Reset and restart ISC generation in background (non-blocking)
tui_kick_isconf_regen() {
	run_once -r -i "aba:isconf:generate" 2>/dev/null || true
	(cd "$ABA_ROOT" && aba_isconf_generate_start) {ABA_TUI_FLOCK_FD}>&- &
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
