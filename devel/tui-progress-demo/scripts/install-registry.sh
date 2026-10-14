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
if [ -n "${SIMULATE_VERBOSE:-}" ]; then
	# Simulate verbose install output (several pages for less -r testing)
	echo
	printf '\033[1;33m--- Pulling registry image ---\033[0m\n'
	for layer in sha256:a1b2c3d4 sha256:e5f6a7b8 sha256:c9d0e1f2 sha256:a3b4c5d6 sha256:e7f8a9b0; do
		printf '  Pulling layer \033[36m%s\033[0m ...\n' "$layer"
		sleep 0.05
		printf '  Layer \033[32m%s\033[0m: done (%.1f MB)\n' "$layer" "$(( RANDOM % 90 + 10 )).$(( RANDOM % 9 ))"
	done
	echo
	printf '\033[1;33m--- Configuring systemd units ---\033[0m\n'
	for unit in quay-pod.service quay-redis.service quay-postgres.service quay-app.service; do
		printf '  Creating \033[35m%s\033[0m\n' "$unit"
		sleep 0.05
		printf '  Enabling \033[35m%s\033[0m\n' "$unit"
		sleep 0.05
	done
	echo
	printf '\033[1;33m--- Starting registry pod ---\033[0m\n'
	echo "  Creating pod: quay-pod"
	echo "  Network: pasta (rootless)"
	echo "  Port mapping: 8443 -> 8443/tcp"
	sleep 0.1
	echo
	printf '\033[1;33m--- Waiting for registry health ---\033[0m\n'
	for i in $(seq 1 15); do
		printf '  Health check %2d/15: \033[33mwaiting\033[0m (HTTP 503)\n' "$i"
		sleep 0.05
	done
	for i in $(seq 16 20); do
		printf '  Health check %2d/20: \033[32mhealthy\033[0m (HTTP 200)\n' "$i"
		sleep 0.05
	done
	echo
	printf '\033[1;33m--- Generating TLS certificates ---\033[0m\n'
	echo "  Subject: CN=bastion.example.com"
	echo "  Issuer:  CN=ABA Mirror CA"
	echo "  Serial:  $(printf '%X' $(( RANDOM * RANDOM )))"
	echo "  Valid:   2026-10-14 to 2028-10-14"
	echo "  SHA256:  AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89"
	echo "  SAN:     DNS:bastion.example.com, IP:10.0.1.8"
	sleep 0.1
	echo
	printf '\033[1;33m--- Verifying registry endpoint ---\033[0m\n'
	echo "  GET https://bastion.example.com:8443/v2/"
	echo "  Response: 200 OK"
	echo "  Catalog:  0 repositories"
	echo "  Auth:     Bearer token (admin)"
	sleep 0.1
else
	sleep 1.0
fi
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
