#!/bin/bash
# save.sh — Save images to tar files
# Emits START/DONE for save steps. PLANs come from plan.sh.
#
# Env vars control test modes:
#   SKIP_ASK=1       — skip the interactive prompt
#   SKIP_OC_MIRROR=1 — simulate oc-mirror with sleep (fast)
#   SIMULATE_FAIL=1  — fail during save step

source "$(dirname "$0")/progress.sh"

ask() {
	aba_progress "PROMPT|$1"
	read -rp "$1" _reply
	aba_progress "PROMPT_DONE|"
	echo "$_reply"
}

# catalogs_dl — only emits if catalogs need downloading
if [ -n "${FORCE_CATALOG_DOWNLOAD:-}" ]; then
	aba_progress "START|catalogs_dl"
	printf '\033[1;34m[ABA]\033[0m Downloading operator catalogs ...\n'
	sleep 2.0
	echo "       Catalogs downloaded."
	aba_progress "DONE|catalogs_dl"
else
	printf '\033[0;90m[ABA] All operator catalogs cached\033[0m\n'
fi

# ─── Ask to continue (unless skipped) ───
if [ -z "${SKIP_ASK:-}" ]; then
	printf '\033[1;33m[ABA]\033[0m Total images to save: 47 (estimated 12.3 GiB)\n'
	_answer=$(ask "[ABA] Continue with saving? (y/N): ")
	_answer="${_answer,,}"
	if [[ "$_answer" != "y" && "$_answer" != "yes" ]]; then
		printf '\033[1;31m[ABA]\033[0m Aborted by user.\n'
		aba_progress "ABORT|Aborted by user"
		exit 0
	fi
	echo
fi

# ─── Tools step ───
aba_progress "START|sv_tools"
printf '\033[1;34m[ABA]\033[0m Preparing tools ...\n'
sleep 0.4
echo "       oc-mirror: 4.17.6"
printf '\033[1;32m[ABA]\033[0m Tools ready.\n'
aba_progress "DONE|sv_tools"

# ─── Save step ───
aba_progress "START|sv_save"
printf '\033[1;34m[ABA]\033[0m Saving images (oc-mirror) ...\n'

if [ -n "${SKIP_OC_MIRROR:-}" ]; then
	sleep 1.5
	echo "       Saved 47 images (12.3 GiB)"
else
	sleep 3.0
	echo "       Saved 47 images (12.3 GiB)"
fi

if [ -n "${SIMULATE_FAIL:-}" ]; then
	printf '\033[1;31m[ABA] Error: oc-mirror save failed\033[0m\n' >&2
	aba_progress "FAIL|sv_save"
	aba_progress "ERROR|sv_save|oc-mirror save failed: disk full"
	aba_progress "DETAIL|error: write /data/mirror_000001.tar: no space left on device"
	aba_progress "NEXT|Free disk space: df -h /data"
	aba_progress "NEXT|Retry with --retry flag: aba -d mirror save --retry 3"
	exit 1
fi

printf '\033[1;32m[ABA]\033[0m Save complete.\n'
aba_progress "DONE|sv_save"

# ─── Finalize step ───
aba_progress "START|sv_finalize"
printf '\033[1;34m[ABA]\033[0m Creating transfer archive ...\n'
sleep 0.5
echo "       Created: data/mirror_000001.tar (12.3 GiB)"
echo "       Created: data/aba-transfer.tar (2.1 MiB)"
printf '\033[1;32m[ABA]\033[0m Archive ready.\n'
aba_progress "DONE|sv_finalize"

echo
printf '\033[1;32m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
printf '\033[1;32m  Images saved! Ready for transfer.\033[0m\n'
printf '\033[1;32m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
