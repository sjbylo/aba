#!/usr/bin/bash 
# Generate the mirror.conf file

[ -s mirror.conf ] && exit 0

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

[ "$1" = "-f" ] && force=$2 && shift 2

source <(normalize-aba-conf)

verify-aba-conf || aba_abort "$_ABA_CONF_ERR"

# $domain is used as input in below j2 command
if [ ! "$ocp_version" ] || [ ! "$domain" ]; then
	# Should never reach here due to other var verification
	aba_abort \
		"Values 'domain' and/or 'ocp_version' missing in aba/aba.conf." \
		"You must set the target version and domain of OpenShift in aba.conf. See the README.md on how to get started!"
fi

# Input is 'domain' from aba.conf, 'hostname' from this host.
# ADR-005: ocp_major is derived. Without it the template silently writes
# reg_path=/ocp/openshift (Jinja prints an empty major and exits 0).
export ocp_major="$(ocp_major_of "$ocp_version")"
if [ -z "$ocp_major" ]; then
	aba_abort "ocp_version '${ocp_version:-}' has no major number"
fi
export hostname
hostname=$(hostname -s)
if ! scripts/j2 templates/mirror.conf.j2 > mirror.conf; then
	rm -f mirror.conf
	aba_abort "Could not render mirror.conf"
fi

if [ "$force" != "yes" ]; then
	edit_file mirror.conf "Configure your private mirror registry ($(basename $PWD)/mirror.conf)" || exit 1  # if editor=none exit 0
fi

exit 0

