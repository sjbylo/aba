#!/bin/bash -e
# Phase 04: Create bundle tar archives + checksums

set -x

source "$(cd "$(dirname "$0")/.." && pwd)/common.sh"

cd "$WORK_DIR/aba"

echo_step "Create the install bundle files ..."

# Source include_all.sh for replace-value-conf; clear ERR trap it may set
echo "pwd=$PWD"
source scripts/include_all.sh; trap - ERR
echo
cat aba.conf
set -e

# Clear network values so the bundle is portable to any environment
cp aba.conf ~/aba.conf.bk
replace-value-conf -n domain		-v -f aba.conf
replace-value-conf -n machine_network	-v -f aba.conf
replace-value-conf -n dns_servers	-v -f aba.conf
replace-value-conf -n next_hop_address	-v -f aba.conf
replace-value-conf -n ntp_servers	-v -f aba.conf

echo
cat aba.conf
read -t 60 || true

# Use 'make tar' instead of 'aba tar' because aba re-fills the values
# --no-print-directory prevents make's "Entering directory" messages from
# corrupting the tar stream on stdout
make --no-print-directory tar out=- | split -b 10G - "$WORK_BUNDLE_DIR/ocp_${VER}_${NAME}_"

# Restore aba.conf for potential later use
cp ~/aba.conf.bk aba.conf

echo "Calculating the checksums in the background ..."

(
	cd "$WORK_BUNDLE_DIR" && cksum ocp_* > CHECKSUM.txt
) &
CKSUM_PID=$!

echo_step "Removing unneeded aba repo at $WORK_DIR/aba"

rm -rf "$WORK_DIR/aba"

# Wait for checksum to finish
wait $CKSUM_PID
