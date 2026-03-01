#!/bin/bash -e
# Create a named mirror directory (like setup-cluster.sh creates cluster dirs).
# Copies mirror/Makefile, runs init + mirror.conf, optionally registers existing registry creds.

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

source <(normalize-aba-conf)
verify-aba-conf || aba_abort "Invalid or incomplete aba.conf. Check the errors above and fix aba.conf."

name=

. <(process_args $*)

[ ! "$name" ] && aba_abort "Error: mirror name missing! Usage: aba mirror --name <name>"

if [ ! -d "$name" ]; then
	mkdir "$name"
	cd "$name"
	cp ../mirror/Makefile .
	make -s init
else
	if [ -s "$name/Makefile" ]; then
		cd "$name"
		make -s init
	else
		cd "$name"
		cp ../mirror/Makefile .
		make -s init
	fi
fi

if [ -s mirror.conf ]; then
	aba_info "Using existing '$name/mirror.conf'."
else
	aba_info "Creating '$name/mirror.conf'."
fi

make -s mirror.conf force=yes

# If both pull_secret_mirror and ca_cert are provided, register the existing registry
if [ "$pull_secret_mirror" -a "$ca_cert" ]; then
	aba_info "Registering existing registry credentials ..."
	make -s register pull_secret_mirror="$pull_secret_mirror" ca_cert="$ca_cert"
fi

echo
aba_info "Mirror directory created: $name"
aba_info "Next steps:"
if [ "$pull_secret_mirror" -a "$ca_cert" ]; then
	aba_info "  Verify:  aba -d $name verify"
	aba_info "  Sync:    aba -d $name sync --retry"
	aba_info "  Load:    aba -d $name load --retry"
else
	aba_info "  Install registry:  aba -d $name install"
	aba_info "  Register existing: aba -d $name --pull-secret-mirror <file> --ca-cert <file>"
fi

exit 0
