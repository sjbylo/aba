#!/bin/bash
# INTENT:       Check if the OCP release image exists in the mirror registry.
# CALLED BY:    make -C mirror check-image / aba -d mirror check-image
# CWD:          mirror/
# REQUIRES:     mirror.conf, aba.conf, regcreds (pull-secret-mirror.json)
# PRODUCES:     Exit 0 if release image found, exit 1 if not.
# SIDE EFFECTS: None (pure curl check, no tool install).
# IDEMPOTENT:   Yes (read-only check)

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

umask 077

source <(normalize-aba-conf)
source <(normalize-mirror-conf)
export regcreds_dir=$HOME/.aba/mirror/$(basename "$PWD")

if check_release_image; then
	aba_debug "Release image for v$_release_ver found at $reg_host:$reg_port"
	exit 0
else
	aba_debug "Release image NOT found at ${reg_host:-?}:${reg_port:-?}"
	exit 1
fi
