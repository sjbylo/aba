#!/bin/bash
# uninstall-registry.sh — Uninstall the mirror registry
# Emits START/DONE for uninstall steps. PLANs come from plan.sh.
source "$(dirname "$0")/progress.sh"

aba_progress "START|uninst_remove"
printf '\033[1;34m[ABA]\033[0m Removing Quay registry on localhost ...\n'
sleep 1.5
echo "       Running mirror-registry uninstall ..."
sleep 1.0
echo "       Removing data directory ..."
sleep 0.5
printf '\033[1;32m[ABA]\033[0m Registry removed.\n'
aba_progress "DONE|uninst_remove"

aba_progress "START|uninst_cleanup"
printf '\033[1;34m[ABA]\033[0m Cleaning up ...\n'
sleep 0.5
echo "       Closing firewall port 8443/tcp"
echo "       Removing credentials"
echo "       Clearing state"
printf '\033[1;32m[ABA]\033[0m Cleanup complete.\n'
aba_progress "DONE|uninst_cleanup"

echo
printf '\033[1;32m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
printf '\033[1;32m  Registry uninstalled successfully!\033[0m\n'
printf '\033[1;32m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
