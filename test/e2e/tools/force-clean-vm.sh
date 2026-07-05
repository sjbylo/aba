#!/bin/bash
# force-clean-vm.sh -- Manual last-resort cleanup for stale registry state on any E2E VM.
#
# Usage:
#   ./force-clean-vm.sh <user@host>
#   ./force-clean-vm.sh root@dis3.example.com
#   ./force-clean-vm.sh root@con1.example.com
#
# When to use:
#   When _cleanup_dis hits FATAL "Stale podman state found" and you've
#   investigated the root cause. This script force-removes all registry
#   containers, pods, secrets, and systemd units so the VM can be reused.
#
# WARNING: This is a band-aid. If you're running this, there is a bug
#   somewhere (suite didn't clean up, aba uninstall failed, snapshot
#   revert lost state). Fix the bug first, then use this to recover.

set -e

if [ -z "${1:-}" ]; then
	echo "Usage: $0 <user@host>"
	echo ""
	echo "Examples:"
	echo "  $0 root@dis3.example.com    # Clean registry state on dis3"
	echo "  $0 root@con1.example.com    # Clean registry state on con1"
	echo "  $0 steve@con2.example.com   # Clean registry state for user steve on con2"
	exit 1
fi

TARGET="$1"
SSH_CONF="${HOME}/.aba/ssh.conf"
SSH="ssh -F $SSH_CONF $TARGET"

echo ""
echo "=== Force-clean registry state on $TARGET ==="
echo ""

echo "--- Current state ---"
echo "Containers:"
$SSH "podman ps -a --format '{{.Names}} {{.Status}}'" 2>&1 || echo "  (podman not available)"
echo ""
echo "Pods:"
$SSH "podman pod ls" 2>&1 || echo "  (no pods)"
echo ""
echo "Secrets:"
$SSH "podman secret ls" 2>&1 || echo "  (no secrets)"
echo ""
echo "Systemd quay units:"
$SSH "systemctl --user list-units 'quay-*' --no-legend 2>/dev/null" || echo "  (none)"
echo ""

read -r -p "Proceed with force-cleanup? (y/N): " _answer
if [ "${_answer,,}" != "y" ]; then
	echo "Aborted."
	exit 0
fi

echo ""
echo "--- Stopping and removing pods ---"
$SSH "podman pod stop quay-pod 2>/dev/null || true; podman pod rm -f quay-pod 2>/dev/null || true" 2>&1

echo "--- Removing standalone containers ---"
$SSH "podman rm -f quay-app quay-redis quay-postgres 2>/dev/null || true" 2>&1
$SSH "podman rm -f registry 2>/dev/null || true" 2>&1

echo "--- Removing secrets ---"
$SSH "podman secret rm redis_pass 2>/dev/null || true" 2>&1

echo "--- Stopping systemd user units ---"
$SSH "systemctl --user stop 'quay-*' 2>/dev/null || true" 2>&1
$SSH "systemctl --user disable 'quay-*' 2>/dev/null || true" 2>&1
$SSH "systemctl --user reset-failed 'quay-*' 2>/dev/null || true" 2>&1

echo ""
echo "--- Post-cleanup verification ---"
_clean=1
echo "Containers:"
_containers=$($SSH "podman ps -a --format '{{.Names}}'" 2>&1 || true)
if echo "$_containers" | grep -qE 'quay-app|quay-redis|quay-postgres|^registry$'; then
	echo "  WARNING: registry containers still present!"
	echo "$_containers"
	_clean=""
else
	echo "  OK (no registry containers)"
fi

echo "Secrets:"
_secrets=$($SSH "podman secret ls --format '{{.Name}}'" 2>&1 || true)
if echo "$_secrets" | grep -q redis_pass; then
	echo "  WARNING: redis_pass secret still present!"
	_clean=""
else
	echo "  OK (no registry secrets)"
fi

echo "Systemd:"
_units=$($SSH "systemctl --user list-units 'quay-*' --no-legend 2>/dev/null | grep -v 'not-found'" || true)
if [ -n "$_units" ]; then
	echo "  WARNING: quay systemd units still active!"
	echo "$_units"
	_clean=""
else
	echo "  OK (no quay systemd units)"
fi

echo ""
if [ -n "$_clean" ]; then
	echo "Force-cleanup SUCCEEDED -- $TARGET is clean."
else
	echo "Force-cleanup INCOMPLETE -- some state remains on $TARGET."
	echo "Manual intervention may be required (podman system reset --force)."
	exit 1
fi
