#!/bin/bash
# sync-images.sh — Sync images to registry
# Emits START/DONE for each sync step. PLANs come from plan.sh.
source "$(dirname "$0")/progress.sh"

# ─── Background CLI download ─────────────────────────────────────
# Real run_once, the same shape ABA uses: kick off now, wait at the end.
# The dialog keeps "Download CLI tools" In Progress while the sync
# steps run, then shows "Wait for CLI tools" until run_once -w returns.
# The runner dir stays in the demo tmp so this does not touch ~/.aba/runner.
_bg_task=""
if [ -n "${SIMULATE_BG_DOWNLOAD:-}" ]; then
	_script_dir=$(cd "$(dirname "$0")" && pwd -P)
	# shellcheck disable=SC1091
	source "$_script_dir/../../../scripts/include_all.sh"
	export RUN_ONCE_DIR="${ABA_DEMO_TMP:-/tmp}/runner"
	_bg_task="demo:cli:download"
	run_once -r -i "$_bg_task" >/dev/null 2>&1 || true
	aba_progress "START|cli_dl"
	printf '\033[1;34m[ABA]\033[0m Downloading CLI tools (background) ...\n'
	# Long enough to stay In Progress beside the sync steps.
	run_once -i "$_bg_task" -- sleep 8
fi

# catalogs_dl — only emits if catalogs need downloading
if [ -n "${FORCE_CATALOG_DOWNLOAD:-}" ]; then
	aba_progress "START|catalogs_dl"
	printf '\033[1;34m[ABA]\033[0m Downloading operator catalogs ...\n'
	sleep 2.0
	echo "       redhat-operator-index v4.17: downloaded"
	echo "       certified-operator-index v4.17: downloaded"
	echo "       community-operator-index v4.17: downloaded"
	printf '\033[1;32m[ABA]\033[0m Catalogs ready.\n'
	aba_progress "DONE|catalogs_dl"
else
	printf '\033[0;90m[ABA] All operator catalogs cached\033[0m\n'
fi

aba_progress "START|versions"
printf '\033[1;34m[ABA]\033[0m Verifying release versions ...\n'
sleep 0.4
echo "       OCP 4.17.6 — available in candidate channel"
printf '\033[1;32m[ABA]\033[0m Versions verified.\n'
aba_progress "DONE|versions"

aba_progress "START|tools"
printf '\033[1;34m[ABA]\033[0m Preparing tools ...\n'
sleep 0.3
echo "       oc-mirror: 4.17.6 (/usr/local/bin/oc-mirror)"
printf '\033[1;32m[ABA]\033[0m Tools ready.\n'
aba_progress "DONE|tools"

aba_progress "START|registry"
printf '\033[1;34m[ABA]\033[0m Checking registry access ...\n'
sleep 0.3
echo "       bastion.example.com:8443 — authenticated"
printf '\033[1;32m[ABA]\033[0m Registry access OK.\n'
aba_progress "DONE|registry"

aba_progress "START|sync"
printf '\033[1;34m[ABA]\033[0m Syncing images to registry ...\n'

if [ -n "${SKIP_OC_MIRROR:-}" ]; then
	sleep 2.0
	echo "       Synced 47 images (12.3 GiB) to bastion.example.com:8443"
else
	sleep 3.0
	echo "       Synced 47 images (12.3 GiB) to bastion.example.com:8443"
fi

# Graceful failure: script emits FAIL/ERROR/NEXT events before exiting
if [ -n "${SIMULATE_FAIL:-}" ]; then
	printf '\033[1;31m[ABA] Error: oc-mirror sync failed\033[0m\n' >&2
	aba_progress "FAIL|sync"
	aba_progress "ERROR|sync|oc-mirror sync failed after 3 retries"
	aba_progress "NEXT|Check registry connectivity: curl -k https://bastion.example.com:8443/v2/"
	aba_progress "NEXT|Review oc-mirror logs in mirror/data/"
	exit 1
fi

# Unexpected crash: script dies without emitting FAIL.
if [ -n "${SIMULATE_CRASH:-}" ]; then
	printf '\033[1;31m/usr/local/bin/oc-mirror: line 1: syntax error near unexpected token\033[0m\n' >&2
	printf '\033[1;31mError: oc-mirror exited with code 2\033[0m\n' >&2
	exit 2
fi

printf '\033[1;32m[ABA]\033[0m Sync complete.\n'
aba_progress "DONE|sync"

aba_progress "START|finalize"
printf '\033[1;34m[ABA]\033[0m Finalizing ...\n'
sleep 0.3
echo "       Updated state: last_action=sync, mirror_ocp_version=4.17.6"
printf '\033[1;32m[ABA]\033[0m Finalized.\n'
aba_progress "DONE|finalize"

# ─── Wait for the background download ────────────────────────────
# run_once -p returns success when the task has already finished.
# run_once -w blocks until it has. Either way both rows are shown.
if [ -n "$_bg_task" ]; then
	aba_progress "START|cli_wait"
	if run_once -p -i "$_bg_task" >/dev/null 2>&1; then
		printf '\033[1;32m[ABA]\033[0m CLI tools already ready.\n'
	else
		printf '\033[1;34m[ABA]\033[0m Waiting for CLI tools ...\n'
		run_once -q -w -i "$_bg_task" >/dev/null 2>&1 || true
		printf '\033[1;32m[ABA]\033[0m CLI tools ready.\n'
	fi
	aba_progress "DONE|cli_dl"
	aba_progress "DONE|cli_wait"
fi

echo
printf '\033[1;32m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
printf '\033[1;32m  Images synced to bastion.example.com:8443\033[0m\n'
printf '\033[1;32m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
