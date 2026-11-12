#!/bin/bash
# Trigger and wait. Those rows were part of the plan upgrade submitted
# before preflight, after it had asked day-2 for its steps.

source "$(dirname "$0")/progress.sh"

aba_progress "START|ug_trigger"
printf '\033[1;34m[ABA]\033[0m Triggering cluster upgrade ...\n'
sleep 0.6
echo "       Upgrade command accepted."
printf '\033[1;32m[ABA]\033[0m Upgrade requested.\n'
aba_progress "DONE|ug_trigger"

aba_progress "START|ug_progress"
printf '\033[1;34m[ABA]\033[0m Waiting for the upgrade to finish ...\n'
sleep 1.6
echo "       Cluster version is now 4.22.22."
printf '\033[1;32m[ABA]\033[0m Upgrade complete.\n'
aba_progress "DONE|ug_progress"
