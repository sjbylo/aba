#!/bin/bash
# install-registry.sh — Install the mirror registry
# Emits START/DONE for each install step. PLANs come from plan.sh.
source "$(dirname "$0")/progress.sh"

aba_progress "START|reg_config"
printf '\033[1;34m[ABA]\033[0m Validating mirror configuration ...\n'
sleep 0.5
printf '\033[1;32m[ABA]\033[0m Config validated.\n'
aba_progress "DONE|reg_config"

aba_progress "START|reg_env"
printf '\033[1;34m[ABA]\033[0m Checking environment ...\n'
sleep 0.3
echo "       Podman: 5.3.1"
echo "       Disk: 245 GiB free"
printf '\033[1;32m[ABA]\033[0m Environment OK.\n'
aba_progress "DONE|reg_env"

aba_progress "START|reg_firewall"
printf '\033[1;34m[ABA]\033[0m Configuring firewall ...\n'
sleep 0.3
echo "       Port 8443/tcp: opened"
printf '\033[1;32m[ABA]\033[0m Firewall configured.\n'
aba_progress "DONE|reg_firewall"

aba_progress "START|reg_download"
printf '\033[1;34m[ABA]\033[0m Downloading registry software ...\n'

if [ -n "${SIMULATE_SLOW_DOWNLOAD:-}" ]; then
	for pct in 10 25 40 55 70 85 100; do
		sleep 0.4
		echo "       Downloading: ${pct}%"
	done
else
	sleep 0.5
	echo "       docker-registry image: cached"
fi
printf '\033[1;32m[ABA]\033[0m Registry software ready.\n'
aba_progress "DONE|reg_download"

aba_progress "START|reg_install"
printf '\033[1;34m[ABA]\033[0m Installing registry ...\n'
sleep 1.0
echo "       Registry running at bastion.example.com:8443"
printf '\033[1;32m[ABA]\033[0m Registry installed.\n'
aba_progress "DONE|reg_install"

aba_progress "START|reg_trust"
printf '\033[1;34m[ABA]\033[0m Configuring trust and credentials ...\n'
sleep 0.5
echo "       CA cert added to trust store"
echo "       Pull secret updated"
printf '\033[1;32m[ABA]\033[0m Trust configured.\n'
aba_progress "DONE|reg_trust"

echo
printf '\033[1;32m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
printf '\033[1;32m  Registry installed successfully!\033[0m\n'
printf '\033[1;32m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
