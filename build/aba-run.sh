#!/bin/bash
# Launch ABA inside its container image on the disconnected bastion.
#
# Usage:
#   build/aba-run.sh                        # interactive shell
#   build/aba-run.sh aba -d mirror install  # run a specific command
#
# Run this script from anywhere -- it auto-detects the ABA repo root
# from its own location and mounts mirror/data and mirror/mirror.conf
# from the host into the container.
#
# Prerequisites:
#   1. ABA container image loaded:  podman load -i aba-image.tar
#   2. Image-set archives in <aba-repo>/mirror/data/:  mirror_*.tar, aba-transfer.tar
#   3. mirror/mirror.conf edited with reg_host, reg_ssh_key, reg_ssh_user
#   4. SSH key pair exists:  ssh-keygen  (if not already present)
#   5. User can SSH to this host:  ssh $(hostname) echo ok
#
# The container uses --network host so ABA can SSH back to the host
# for registry installation (Quay runs as a host service, not inside
# the container).
#
# See docs/README-PODMAN.md for the full workflow.

set -euo pipefail

# Auto-detect the ABA repo root from this script's location (build/aba-run.sh)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ABA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ABA_IMAGE="${ABA_IMAGE:-aba:latest}"
ABA_DATA="${ABA_DATA:-$ABA_ROOT/mirror/data}"
ABA_CONF="${ABA_CONF:-$ABA_ROOT/mirror/mirror.conf}"
ABA_STATE="${ABA_STATE:-$HOME/.aba}"

# Must match ABA_USER in the Containerfile (default: aba)
C_USER="${ABA_CONTAINER_USER:-aba}"
C_HOME="/home/$C_USER"

mkdir -p "$ABA_STATE"
mkdir -p "$ABA_DATA"

if [ ! -f "$ABA_CONF" ]; then
	echo "ERROR: mirror.conf not found at $ABA_CONF" >&2
	echo "Create it first, or set ABA_CONF= to point to your mirror.conf" >&2
	exit 1
fi

# --userns keep-id maps the host UID/GID into the container so that
# bind-mounted volumes are accessible without UID mismatches.
exec podman run --rm -it \
	--name aba \
	--network host \
	--privileged \
	--userns keep-id \
	-v "$ABA_STATE:$C_HOME/.aba:Z" \
	-v "$HOME/.ssh:$C_HOME/.ssh:ro" \
	-v "$ABA_DATA:$C_HOME/aba/mirror/data:Z" \
	-v "$ABA_CONF:$C_HOME/aba/mirror/mirror.conf:ro" \
	-e "HOST_USER=$USER" \
	-e "HOST_HOME=$HOME" \
	"$ABA_IMAGE" \
	"$@"
