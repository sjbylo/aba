#!/bin/bash
# Clean generated cluster artifacts (install-config, agent-config, ISO, markers).
# Keeps cluster.conf (and linked credentials).
#
# Refuses when the cluster is installed (.install-complete) unless force=1.
# 'aba delete' passes force=1 after VMs are destroyed so post-delete cleanup works.
#
# Usage (from cluster dir):
#   scripts/cluster-clean.sh
#   scripts/cluster-clean.sh force=1

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

force=
for _a in "$@"; do
	case "$_a" in
		force=1|force=true|--force) force=1 ;;
	esac
done

if [ -f .install-complete ] && [ -z "$force" ]; then
	_cn=$(basename "$PWD")
	aba_abort "Refusing to clean: cluster is installed (.install-complete exists)." \
		"Clean would remove install-config/agent-config while leaving VMs running." \
		"Destroy the cluster first:  aba -d $_cn delete" \
		"Then re-install, or run clean after delete if you only need artifact cleanup."
fi

rm -f install-config.yaml agent-config.yaml
rm -rf iso-agent-based*
rm -f .??*
rm -f mirror
rm -f mirror.conf
[ -L regcreds ] && rm -f regcreds || true
if [ -L clusterstate ]; then
	rm -rf "$(readlink clusterstate)"
	rm -f clusterstate
fi
# Remove any openshift-install binary extracted from the mirror registry
rm -f openshift-install-*-*

exit 0
