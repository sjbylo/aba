#!/bin/bash
# Record a TUI test on a smaller pane, then make a GIF from its color frames.
#
#   tools/tui-record.sh drive [HOST]
#   tools/tui-record.sh stop
#   tools/tui-record.sh gif [RUN_DIR] [OUT.gif] [WIDTH]
#   tools/tui-record.sh mirror|cluster|day2 [HOST]
#
# drive starts the TUI and records every pane change, including the cursor.
# You attach from another terminal and drive it. stop ends the recording
# without exiting the TUI. gif builds a small GIF: a small dialog is a short
# pause, a large or important dialog is a longer one, a cursor move is brief.
#
# Host defaults to conno. A short name is enough: drive disco.
# TUI_TEST_HOST=disco is the same switch. local records on this machine.
# Pane size defaults to 100x30. Override with TUI_WIDTH, TUI_HEIGHT,
# TUI_CLUSTER_NAME. gif WIDTH is pixels; 900 matches a README column.

cd "$(dirname "$0")/.." || exit 1

_usage() {
	echo "Usage: tools/tui-record.sh drive [HOST]" >&2
	echo "       tools/tui-record.sh stop" >&2
	echo "       tools/tui-record.sh gif [RUN_DIR] [OUT.gif] [WIDTH]" >&2
	echo "       tools/tui-record.sh mirror|cluster|day2 [HOST]" >&2
	echo "Host defaults to conno. Example: drive disco" >&2
	exit 2
}

# The test prints the run directory on this line. Use the last one.
_run_dir_from_log() {
	sed -n 's/.*→ \(\/tmp\/tui-test\/[^ ]*\)\/.*/\1/p' "$1" | tail -1
}

_newest_run() {
	local d
	d=$(ls -dt /tmp/tui-drive/*/color /tmp/tui-test/*/color 2>/dev/null | head -1)
	[ -n "$d" ] || return 1
	dirname "$d"
}

# Argument wins, then TUI_TEST_HOST, then conno. conno and disco are SSH names.
_host() {
	local h="${1:-}"
	if [ -z "$h" ]; then
		h="${TUI_TEST_HOST:-conno}"
	fi
	printf '%s\n' "$h"
}

_local_host() {
	case "$1" in
		local|localhost) return 0 ;;
	esac
	return 1
}

_on_host() {
	local host="$1"
	if _local_host "$host"; then
		bash -c "$2"
	else
		ssh -F "$HOME/.aba/ssh.conf" -o BatchMode=yes "$host" "$2"
	fi
}

# Start abatui in tmux and record until the session ends or stop is requested.
_drive() {
	local host w h sess stamp remote local_dir
	host=$(_host "${1:-}")
	w="${TUI_WIDTH:-100}"
	h="${TUI_HEIGHT:-30}"
	sess=tui-drive
	case "$w$h" in
		*[!0-9]*) echo "TUI_WIDTH and TUI_HEIGHT must be numbers" >&2; exit 2 ;;
	esac
	stamp=$(date +%Y%m%d-%H%M%S)
	remote="/tmp/tui-drive/$stamp"
	local_dir="/tmp/tui-drive/$stamp"
	mkdir -p "$local_dir"
	printf '%s %s\n' "$host" "$remote" > /tmp/tui-drive-current

	if _on_host "$host" "tmux has-session -t $sess 2>/dev/null"; then
		echo "tmux session $sess is already running on $host" >&2
		exit 1
	fi
	_on_host "$host" "mkdir -p '$remote/color'" || exit 1
	if _local_host "$host"; then
		cp tools/tui-capture.sh "$remote/tui-capture.sh"
		chmod +x "$remote/tui-capture.sh"
	else
		ssh -F "$HOME/.aba/ssh.conf" -o BatchMode=yes "$host" "cat > '$remote/tui-capture.sh' && chmod +x '$remote/tui-capture.sh'" < tools/tui-capture.sh
	fi
	# window-size manual: attaching from a bigger or smaller terminal does not
	# change the pane. Every frame stays ${w}x${h}.
	_on_host "$host" "tmux new-session -d -s $sess -x $w -y $h 'cd ~/aba && exec abatui' && tmux set-option -w -t $sess window-size manual && tmux resize-window -t $sess -x $w -y $h" || exit 1

	echo "TUI is running on $host in tmux session $sess (${w}x${h})."
	if _local_host "$host"; then
		echo "Attach and drive it:  tmux attach -t $sess"
	else
		echo "Attach and drive it:  ssh -t $host tmux attach -t $sess"
	fi
	echo "Stop recording early:  tools/tui-record.sh stop"
	echo "Recording every change, including the cursor."

	_on_host "$host" "'$remote/tui-capture.sh' $sess '$remote'"
	if _local_host "$host"; then
		:
	else
		scp -q -F "$HOME/.aba/ssh.conf" -o BatchMode=yes -r "$host:$remote/color" "$local_dir/" || true
	fi
	echo ""
	echo "Color frames: $local_dir/color/"
	echo "GIF:          tools/tui-record.sh gif $local_dir"
}

_stop() {
	local host remote
	if [ ! -f /tmp/tui-drive-current ]; then
		echo "No drive recording is in progress." >&2
		exit 1
	fi
	read -r host remote < /tmp/tui-drive-current
	_on_host "$host" "touch '$remote/stop'"
	echo "Asked the recorder on $host to stop. Frames land when drive returns."
}

_gif() {
	local src="${1:-}" out="${2:-}" base
	if [ -z "$src" ]; then
		src=$(_newest_run) || { echo "No /tmp/tui-test run with color frames." >&2; exit 1; }
	fi
	if [ ! -d "$src" ]; then
		echo "Not a directory: $src" >&2
		exit 1
	fi
	if [ -z "$out" ]; then
		base=$(basename "$src")
		[ "$base" = color ] && base=$(basename "$(dirname "$src")")
		out="${base}.gif"
	fi
	if [ -n "${3:-}" ]; then
		python3 tools/tui-gif.py "$src" "$out" "$3"
	else
		python3 tools/tui-gif.py "$src" "$out"
	fi
}

_record() {
	local which="$1" log rc dir
	export TUI_TEST_HOST="$(_host "${2:-}")"
	export TUI_WIDTH="${TUI_WIDTH:-100}"
	export TUI_HEIGHT="${TUI_HEIGHT:-30}"
	export TUI_CLUSTER_NAME="${TUI_CLUSTER_NAME:-compact}"
	log=$(mktemp)
	echo "Recording $which on $TUI_TEST_HOST (${TUI_WIDTH}x${TUI_HEIGHT})"
	test/func/test-tui-${which}.sh | tee "$log"
	rc=${PIPESTATUS[0]}
	dir=$(_run_dir_from_log "$log")
	rm -f "$log"
	if [ -n "$dir" ]; then
		echo ""
		echo "Color frames: $dir/color/"
		echo "GIF:          tools/tui-record.sh gif $dir"
	fi
	exit "$rc"
}

case "${1:-}" in
	drive) _drive "${2:-}" ;;
	stop) _stop ;;
	mirror|cluster|day2) _record "$1" "${2:-}" ;;
	gif) _gif "${2:-}" "${3:-}" "${4:-}" ;;
	*) _usage ;;
esac
