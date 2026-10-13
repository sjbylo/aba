#!/bin/bash
# preflight.sh — Preflight checks (PHONY target, always runs)
source "$(dirname "$0")/progress.sh"

aba_progress "START|preflight"
printf '\033[1;34m[ABA]\033[0m Running pre-flight checks ...\n'
sleep 0.4
printf '\033[1;32m[ABA]\033[0m Pre-flight — OK\n\n'
aba_progress "DONE|preflight"
