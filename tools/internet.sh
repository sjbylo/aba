#!/bin/bash
# Bring the internet-facing network interface up or down.
# Usage: internet.sh up | down

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/test/lib.sh"

case "${1:-}" in
	up)   int_up ;;
	down) int_down ;;
	*)    echo "Usage: $(basename "$0") up|down" >&2; exit 1 ;;
esac
