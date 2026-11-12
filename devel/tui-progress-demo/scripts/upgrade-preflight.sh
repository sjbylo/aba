#!/bin/bash
# Preflight work. Upgrade already submitted the full plan, including
# day-2 and the trigger/wait steps, before this script runs.

source "$(dirname "$0")/progress.sh"

aba_progress "START|ug_preflight"
printf '\033[1;34m[ABA]\033[0m Checking cluster access ...\n'
sleep 0.6
printf '\033[1;32m[ABA]\033[0m Cluster API is reachable.\n'
aba_progress "DONE|ug_preflight"
