#!/bin/bash
# Record every change in a tmux pane, including cursor moves.
# Run this on the host where the tmux session lives. It exits when the
# session ends, or when OUTDIR/stop appears.
#
#   test/func/tui-capture.sh SESSION OUTDIR
#
# Each kept frame is OUTDIR/color/frame-NNNN.txt. The last line is a
# cursor record (RS + "CURSOR x y") so the GIF step can draw the cursor.
# TUI_CAPTURE_INTERVAL is the poll period. Default 0.5 seconds.

session="${1:-}"
out="${2:-}"
if [ -z "$session" ] || [ -z "$out" ]; then
	echo "Usage: test/func/tui-capture.sh SESSION OUTDIR" >&2
	exit 2
fi

interval="${TUI_CAPTURE_INTERVAL:-0.5}"
interval="${interval%[sS]}"
case "$interval" in
	*[!0-9.]*|*.*.*|.) interval=0.5 ;;
esac

mkdir -p "$out/color"
n=0
prev=$(mktemp)
tmp=$(mktemp)
trap 'rm -f "$prev" "$tmp"' EXIT

echo "Recording $session → $out/color/ (every change, including the cursor)"

# One pane size for the whole recording. The GIF pads every frame to this.
_pw=0
_ph=0
_try=0
while [ "$_try" -lt 20 ]; do
	read -r _pw _ph <<EOF
$(tmux display-message -p -t "$session" '#{pane_width} #{pane_height}' 2>/dev/null || true)
EOF
	if [ "${_pw:-0}" -gt 0 ] && [ "${_ph:-0}" -gt 0 ]; then
		break
	fi
	_try=$(( _try + 1 ))
	sleep 0.05
done
printf '%s %s\n' "${_pw:-0}" "${_ph:-0}" > "$out/size"

while tmux has-session -t "$session" 2>/dev/null; do
	if [ -f "$out/stop" ]; then
		break
	fi
	if ! tmux capture-pane -t "$session" -e -p >"$tmp" 2>/dev/null; then
		sleep "$interval"
		continue
	fi
	cx=0
	cy=0
	read -r cx cy <<EOF
$(tmux display-message -p -t "$session" '#{cursor_x} #{cursor_y}' 2>/dev/null || true)
EOF
	printf '\036CURSOR %s %s\n' "$cx" "$cy" >>"$tmp"
	# A cleared pane is not a frame. The cursor record alone does not count.
	if ! sed $'/^\036CURSOR /d' "$tmp" | grep -q '[^[:space:]]'; then
		: >"$tmp"
		sleep "$interval"
		continue
	fi
	if [ -s "$prev" ] && cmp -s "$prev" "$tmp"; then
		sleep "$interval"
		continue
	fi
	n=$(( n + 1 ))
	cp "$tmp" "$(printf '%s/color/frame-%04d.txt' "$out" "$n")"
	cp "$tmp" "$prev"
	sleep "$interval"
done

echo "Frames: $n  ($out/color/)"
