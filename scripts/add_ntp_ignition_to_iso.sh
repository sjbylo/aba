#!/bin/bash -e
# Use this only if your underlying platform does not support NTP.  E.g., simple servers with no baseboard management that supports NTP. 
# Platforms that do not require this script are e.g. vSphere/ESXi and server hardware with baseboard management interfaces that support NTP.
# To use this script, set the ntp param in 'aba.conf'
# This solution was created from the idea posted here: https://github.com/openshift/installer/issues/7571 

source scripts/include_all.sh

[ "$1" ] && set -x

source <(normalize-aba-conf)

[ ! "$ntp_servers" ] && echo_white "Not configuring NTP in early bootstrap node because 'ntp_servers' not defined in aba.conf." && exit 0

[ "$INFO_ABA" ] && echo_cyan "Adding NTP server to early bootstrap ignition: $ntp_servers" 

iso_dir=iso-agent-based
coreos-installer iso ignition show $iso_dir/agent.x86_64.iso > $iso_dir/tmp.ign

# Do not use tr -d "[:space:]", since that also deleted newlines which are needed for resd to work for the last line!
# Want to keep a record of chrony.conf for debugging
cat > $iso_dir/chrony.conf << EOF
$(echo "$ntp_servers" | tr -d "[ \t]" | tr ',' '\n' | while read item; do echo "server ${item} iburst"; done)
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF
###echo $CHRONY_CONF_BASE64_2 | base64 -d > $iso_dir/chrony.conf

export CHRONY_CONF_BASE64_2=$(echo "$config" | base64 -w 0)

jq '.storage.files += [{
  "group": {},
  "overwrite": true,
  "path": "/etc/chrony.conf",
  "user": {
    "name": "root"
  },
  "contents": {
    "source": "data:text/plain;charset=utf-8;base64,'$CHRONY_CONF_BASE64_2'"
  },
  "mode": 420
}]' $iso_dir/tmp.ign > $iso_dir/custom_ign.ign

coreos-installer iso ignition embed -fi $iso_dir/custom_ign.ign $iso_dir/agent.x86_64.iso

