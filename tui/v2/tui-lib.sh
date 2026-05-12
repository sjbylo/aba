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
	local has_menu=false

	for arg in "$@"; do
		if [[ "$next_is_title" == "true" ]]; then
			args+=(" $arg ")
			next_is_title=false
			continue
		fi
		if [[ "$next_is_text" == "true" ]]; then
			# Prepend \n (empty line below title) unless already starts with \n
			if [[ "$arg" != "\n"* && "$arg" != $'\n'* ]]; then
				arg="\n$arg"
			fi
			# Append navigation hint for list-style dialogs
			if [[ "$has_menu" == "true" ]]; then
				arg="${arg}\n(Navigate: Arrow keys, Tab, ESC)"
			fi
			args+=("$arg")
			next_is_text=false
			continue
		fi

		case "$arg" in
			--title) next_is_title=true ;;
			--menu|--radiolist|--checklist)
				next_is_text=true; has_menu=true ;;
			--msgbox|--yesno|--inputbox|--infobox|--mixedform)
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
	local mode_display
	case "${_TUI_MODE:-}" in
		DISCO)  mode_display="Fully Disconnected" ;;
		CONNO)  mode_display="Partially Disconnected" ;;
		DIRECT) mode_display="Fully Connected" ;;
		*)      mode_display="?" ;;
	esac
	local ver="${ocp_version:-?}"
	local ch="${ocp_channel:-?}"
	local text="ABA TUI v2  |  ${mode_display}  |  ${ch} ${ver}"
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
		--title " $title " --cr-wrap --msgbox "\n$body" 0 0 || true
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
	tui_log "Confirming command: $cmd"

	# If user previously chose "always", skip the picker
	if [[ -n "$_TUI_EXEC_MODE" ]]; then
		tui_log "Using remembered exec mode: $_TUI_EXEC_MODE"
		case "$_TUI_EXEC_MODE" in
			tui)      _exec_in_tui "$cmd" "$title"; return $? ;;
			terminal) _exec_in_terminal "$cmd" "$title"; return $? ;;
		esac
	fi

	while :; do
		dlg --backtitle "$(ui_backtitle)" --title "$title" \
			--cancel-label "$TUI2_BTN_BACK" \
			--ok-label "$TUI2_BTN_SELECT" \
			--help-button \
			--extra-button --extra-label "Command" \
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

		case "$choice" in
			1) _exec_in_tui "$cmd" "$title" ;;
			2) _exec_in_terminal "$cmd" "$title" ;;
			3) _TUI_EXEC_MODE="tui"
			   tui_log "Exec mode set to: always TUI"
			   _exec_in_tui "$cmd" "$title" ;;
			4) _TUI_EXEC_MODE="terminal"
			   tui_log "Exec mode set to: always Terminal"
			   _exec_in_terminal "$cmd" "$title" ;;
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

	# Defense-in-depth: reject commands with shell metacharacters that could indicate injection
	if [[ "$cmd" =~ [\`\$\;]|'&&'|'||'|'>>'|'<<' ]]; then
		tui_log "BLOCKED: command contains dangerous metacharacters: $cmd"
		dlg --backtitle "$(ui_backtitle)" --msgbox \
			"Command blocked: contains invalid characters.\n\nThis is a safety check to prevent command injection." 0 0
		return 1
	fi

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
	{ echo "Executing: $cmd"; echo; PLAIN_OUTPUT=1 ASK_OVERRIDE=1 bash -c "$tui_cmd" 2>&1; } | tee "$output_file" | \
		sed -u -r 's/\x1B\[[0-9;]*[mK]//g' | \
		dlg --backtitle "$(ui_backtitle)" --title "$title" \
			--progressbox $box_height $box_width
	local exit_code=${PIPESTATUS[0]}
	trap - INT

	# Strip ANSI escape codes so dialog textbox can scroll properly
	sed -i -r 's/\x1B\[[0-9;]*[mK]//g; s/\x1B\(B//g' "$output_file"

	# Show the tail of output sized to fit the terminal without scrolling
	local review_file visible_lines
	review_file=$(mktemp)
	visible_lines=$(( $(tput lines) - 8 ))
	(( visible_lines < 10 )) && visible_lines=10
	tail -"$visible_lines" "$output_file" > "$review_file"

	if [[ $exit_code -eq 0 ]]; then
		dlg --backtitle "$(ui_backtitle)" --title "\Z2Success\Zn" \
			--ok-label "$TUI2_BTN_BACK_TO_MENU" \
			--textbox "$review_file" 0 0
		rm -f "$output_file" "$review_file"
	else
		dlg --backtitle "$(ui_backtitle)" --title "\Z1FAILED (exit $exit_code)\Zn" \
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

	# Defense-in-depth: reject commands with shell metacharacters that could indicate injection
	if [[ "$cmd" =~ [\`\$\;]|'&&'|'||'|'>>'|'<<' ]]; then
		tui_log "BLOCKED: command contains dangerous metacharacters: $cmd"
		echo "ERROR: Command blocked — contains invalid characters."
		read -rp "Press ENTER to return to TUI..."
		return 1
	fi

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
	return $exit_code
}

# =============================================================================
# State detection helpers
# =============================================================================

# Is a mirror registry installed and available?
mirror_available() {
	[[ -f "$ABA_ROOT/mirror/.available" ]]
}

# Return human-readable mirror state for the menu title.
# States: "no mirror" → "mirror installed" → "mirror ready"
# "mirror ready" means the release image is actually present in the registry.
mirror_state_label() {
	if ! mirror_available; then
		echo "no mirror"
		return
	fi
	# Mirror is installed. Check if the release image exists via skopeo.
	if _mirror_has_release_image; then
		echo "mirror ready"
	else
		echo "mirror installed"
	fi
}

# Invalidate the mirror-ready cache (call after sync/load to force fresh check)
_invalidate_mirror_cache() {
	rm -f "$HOME/.aba/runner/tui-mirror-ready.cache"
}

# Check if the current release image exists in the mirror registry.
# Returns instantly from cache; refreshes in the background when stale.
# Only blocks on the very first call (no cache file yet).
_mirror_has_release_image() {
	local cache_file="$HOME/.aba/runner/tui-mirror-ready.cache"
	local cache_ttl=120  # seconds

	if [[ -f "$cache_file" ]]; then
		local age
		age=$(( $(date +%s) - $(stat -c %Y "$cache_file") ))
		if (( age >= cache_ttl )); then
			# Stale — reset mtime (prevents duplicate spawns), then refresh in background
			touch "$cache_file"
			_mirror_check_release_image &>/dev/null &
			disown 2>/dev/null
		fi
		[[ "$(cat "$cache_file")" == "1" ]]
		return
	fi

	# No cache at all — synchronous check (one-time cost on first TUI launch)
	_mirror_check_release_image
	[[ -f "$cache_file" ]] && [[ "$(cat "$cache_file")" == "1" ]]
}

# The slow part: runs skopeo inspect and writes result to the cache file.
# Called synchronously (first time) or in a background subshell (subsequent).
_mirror_check_release_image() {
	local cache_file="$HOME/.aba/runner/tui-mirror-ready.cache"
	mkdir -p "$(dirname "$cache_file")"

	local _oi=""
	if [[ -x "$HOME/bin/openshift-install" ]]; then
		_oi="$HOME/bin/openshift-install"
	elif command -v openshift-install >/dev/null 2>&1; then
		_oi="openshift-install"
	fi

	# Fallback: if openshift-install not available, use imageset-config-digest.yaml
	if [[ -z "$_oi" ]]; then
		if [[ -f "$ABA_ROOT/mirror/data/imageset-config-digest.yaml" ]]; then
			echo "1" > "$cache_file"
		else
			echo "0" > "$cache_file"
		fi
		return
	fi

	local _out _release_sha _reg_host _reg_port _reg_path _url
	_out=$("$_oi" version 2>/dev/null) || { echo "0" > "$cache_file"; return; }
	_release_sha=$(echo "$_out" | grep "release image" | sed "s/.*\(@sha.*$\)/\1/g")

	_reg_host=$(grep '^reg_host=' "$ABA_ROOT/mirror/mirror.conf" | cut -d= -f2 | awk '{print $1}')
	_reg_port=$(grep '^reg_port=' "$ABA_ROOT/mirror/mirror.conf" | cut -d= -f2 | awk '{print $1}')
	_reg_path=$(grep '^reg_path=' "$ABA_ROOT/mirror/mirror.conf" | cut -d= -f2 | awk '{print $1}')
	_reg_port="${_reg_port:-8443}"
	_reg_path="${_reg_path:-/ocp4/openshift4}"

	[[ -z "$_reg_host" || -z "$_release_sha" ]] && { echo "0" > "$cache_file"; return; }

	_url="docker://${_reg_host}:${_reg_port}${_reg_path}/openshift/release-images${_release_sha}"

	local _authfile="$ABA_ROOT/mirror/regcreds/pull-secret-mirror.json"
	[[ ! -f "$_authfile" ]] && _authfile="$ABA_ROOT/mirror/regcreds/pull-secret-full.json"

	if skopeo inspect ${_authfile:+--authfile "$_authfile"} "$_url" >/dev/null 2>&1; then
		echo "1" > "$cache_file"
	else
		echo "0" > "$cache_file"
	fi
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

# List installed clusters (dirs with .install-complete marker)
# Also auto-finalizes clusters that completed in the background.
list_installed_clusters() {
	local dir
	for dir in $(list_cluster_dirs); do
		if ! cluster_installed "$dir"; then
			# Probe: did this cluster finish installing in the background?
			auto_finalize_cluster "$dir" 2>/dev/null || true
		fi
		cluster_installed "$dir" && echo "$dir" || true
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

# select_cluster "title" "prompt" — sets SELECTED_CLUSTER and SELECTED_CLUSTER_DISPLAY or returns 1
select_cluster() {
	local title="${1:-Select Cluster}"
	local prompt="${2:-Choose a cluster:}"
	local clusters=()
	local dir display
	local -a _cl_dirs=()
	local idx=0

	for dir in $(list_cluster_dirs); do
		display=$(cluster_display_name "$dir")
		idx=$(( idx + 1 ))
		_cl_dirs+=("$dir")
		clusters+=("$idx" "$dir  $display")
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
select_installed_cluster() {
	local title="${1:-Select Cluster}"
	local prompt="${2:-Choose an installed cluster:}"
	local clusters=()
	local dir display
	local -a _cl_dirs=()
	local idx=0

	for dir in $(list_installed_clusters); do
		display=$(cluster_display_name "$dir")
		idx=$(( idx + 1 ))
		_cl_dirs+=("$dir")
		clusters+=("$idx" "$dir  $display")
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
