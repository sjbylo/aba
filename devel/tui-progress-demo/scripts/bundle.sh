#!/bin/bash
# bundle.sh — Create an install bundle (wraps save)
#
# Bundle asks save for its plan (see plan.sh) and submits that list
# plus Pack bundle before this script runs. save.sh does the work.
#
# Env vars:
#   SKIP_OC_MIRROR=1 — simulate oc-mirror with sleep
#   SIMULATE_FAIL=1  — fail during save step

source "$(dirname "$0")/progress.sh"

printf '\033[1;34m[ABA]\033[0m Creating install bundle ...\n'
echo

# save.sh emits START/DONE for the steps bundle already submitted.
SKIP_ASK=1 bash "$(dirname "$0")/save.sh"
_save_rc=$?
[ "$_save_rc" -ne 0 ] && exit "$_save_rc"

echo

# ─── Pack bundle (bundle-only step) ───
aba_progress "START|bnd_pack"
printf '\033[1;34m[ABA]\033[0m Packing install bundle ...\n'
sleep 1.0
echo "       Bundle: /tmp/ocp-bundle-4.17.6-x86_64.tar (14.5 GiB)"
printf '\033[1;32m[ABA]\033[0m Bundle created.\n'
aba_progress "DONE|bnd_pack"

echo
printf '\033[1;32m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
printf '\033[1;32m  Bundle ready for transfer!\033[0m\n'
printf '\033[1;32m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
