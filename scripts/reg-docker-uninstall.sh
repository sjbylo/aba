#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Secure Docker Registry Setup Script with Verification
# Internal port 5000, external port 8443 by default
# TLS + Basic Auth + SELinux + CA trust
# Verifies docker, podman, curl, skopeo, oc-mirror
# -----------------------------------------------------------------------------

source scripts/include_all.sh
[ "$1" ] && set -x

source <(normalize-aba-conf)
source <(normalize-mirror-conf)
verify-aba-conf || exit 1
verify-mirror-conf || exit 1

DOCKER=podman 
####cd $(dirname $0)

set -e
#set -euo pipefail

#REGISTRY_DOMAIN="${1:-registry.example.com}"
#[ "$reg_host" ] && REGISTRY_DOMAIN=$reg_host   # Overrride if set
#[ "$reg_port" ] && EXTERNAL_PORT=$reg_port
#[ "$reg_user" ] && REGISTRY_USER=$reg_user
#[ "$reg_pw" ] && REGISTRY_PASS=$reg_pw

# --- Configurable defaults ---
REGISTRY_NAME="registry"
INTERNAL_PORT=5000
EXTERNAL_PORT="${EXTERNAL_PORT:-8443}"
REGISTRY_DATA_DIR="$data_dir/docker-reg/data"
REGISTRY_CERTS_DIR=".docker-certs"
REGISTRY_AUTH_DIR=".docker-auth"

REGISTRY_USER="${REGISTRY_USER:-init}"
REGISTRY_PASS="${REGISTRY_PASS:-p4ssw0rd}"

# --- Helper functions ---
echo_green() { echo -e "\033[1;32m$*\033[0m"; }
echo_yellow() { echo -e "\033[1;33m$*\033[0m"; }
echo_red() { echo -e "\033[1;31m$*\033[0m"; }

fail_checkp() {
    echo_red "❌ $1"
}

pass_check() {
    echo_green "✅ $1"
}

if $DOCKER ps -a --format '{{.Names}}' | grep -q "^${REGISTRY_NAME}$"; then
    echo_yellow "Stopping and removing old registry container..."
    $DOCKER rm -f "$REGISTRY_NAME" || true
fi

exit 0
