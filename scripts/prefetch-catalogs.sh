#!/bin/bash
# Pre-fetch operator catalog indices for the two most likely OCP versions.
# Run in background at TUI startup to reduce wait at operator screen.
#
# Core logic lives in aba_prefetch_catalogs() in scripts/include_all.sh.
# Downloads use download_all_catalogs (run_once catalog:* IDs) so the wizard
# shares the same task IDs and skips re-downloading.
# If anything fails, exit silently -- the real download handles it later.

source ./scripts/include_all.sh

# Pull secret is required for registry.redhat.io access
if [[ ! -f ~/.pull-secret.json ]]; then
	aba_debug "Pre-fetch: no pull secret found, exiting"
	exit 0
fi

# Container auth for registry.redhat.io — set regcreds_dir so mirror creds are preserved
export regcreds_dir=$HOME/.aba/mirror/mirror
scripts/create-containers-auth.sh >/dev/null 2>&1 || exit 0

if [[ -f aba.conf ]]; then
	source <(normalize-aba-conf 2>/dev/null) || true
fi

aba_prefetch_catalogs || exit 0
