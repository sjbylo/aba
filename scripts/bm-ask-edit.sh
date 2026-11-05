#!/bin/bash
# INTENT:      BM-only gate before ISO: review/edit agent-config / macs.conf.
#              On yes: regenerate agent-config.yaml from cluster.conf/macs.conf
#              (unless .primed). On no: abort so the user can re-run install.
# CALLED BY:   Makefile.cluster (.bm-config-reviewed)
# CWD:         Cluster directory
# IDEMPOTENT:  Yes for non-bm / .primed (immediate success)

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

# Cluster dirs symlink aba.conf → ../aba.conf
source <(normalize-aba-conf)
platform=${platform:-bm}

# VMware/KVM and primed bundles skip this gate
if [ "$platform" != "bm" ] || [ -f .primed ]; then
	aba_debug "bm-ask-edit: skip (platform=$platform primed=$([ -f .primed ] && echo yes || echo no))"
	exit 0
fi

aba_progress "START|ci_config"

aba_info "Review and edit the agent configuration before building the ISO:"
aba_info "  - $PWD/install-config.yaml"
aba_info "  - $PWD/agent-config.yaml"
aba_info "  - $PWD/macs.conf (preferred for MAC addresses)"
aba_info "    You MUST set MAC addresses to match your servers' network interfaces."
aba_info "    Optionally set disk_hint in cluster.conf (or edit YAML) for install disks."

if ! ask -y "Continue and build the agent ISO (regenerates agent-config from macs.conf if present)"; then
	aba_progress "FAIL|ci_config"
	aba_abort "Aborted. Edit configs/macs.conf, then re-run: aba -d $(basename "$PWD") install"
fi

# Apply macs.conf / cluster.conf changes into agent-config before ISO
if [ ! -f .primed ]; then
	aba_info "Regenerating agent-config.yaml from cluster.conf / macs.conf ..."
	scripts/create-agent-config.sh || {
		aba_progress "FAIL|ci_config"
		aba_abort "Failed to regenerate agent-config.yaml"
	}
fi

aba_progress "DONE|ci_config"
exit 0
