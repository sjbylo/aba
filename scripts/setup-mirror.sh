#!/bin/bash -e
# Create a named mirror directory (same pattern as setup-cluster.sh).

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

make -s mirror.conf

echo
aba_info "Mirror directory created: $name"
aba_info "Next steps:"
aba_info "  Install registry:  aba -d $name install"
aba_info "  Register existing: aba -d $name --pull-secret-mirror <file> --ca-cert <file>"

exit 0
