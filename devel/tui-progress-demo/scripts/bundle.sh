#!/bin/bash
# bundle.sh — Create an install bundle (wraps save)
#
# Demonstrates GLOBAL ID dedup: the bundle plan pre-declares shared
# IDs (rpms_ext, preflight, sv_tools, sv_save, sv_cli_wait).
# When save's plan.sh emits the same IDs, the receiver silently
# discards them — no duplicate rows in the progress dialog.
#
# Env vars:
#   SKIP_OC_MIRROR=1 — simulate oc-mirror with sleep
#   SIMULATE_FAIL=1  — fail during save step

source "$(dirname "$0")/progress.sh"

printf '\033[1;34m[ABA]\033[0m Creating install bundle ...\n'
echo

# ─── save runs as a sub-workflow ───
# save.sh emits START/DONE for shared IDs (preflight, sv_tools, sv_save,
# sv_cli_wait, sv_finalize).  The receiver already has PLANs for the shared
# ones from bundle's plan.sh — they display correctly.
# sv_finalize is NOT in the bundle plan (bundle has bnd_pack instead),
# so sv_finalize's events are silently absorbed (no PLAN = no UI row).
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
