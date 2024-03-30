#!/bin/bash -e
# Use this only if your underlying platform does not support NTP.  E.g., simple servers with no baseboard management that supports NTP. 
# Platforms that do not require this script are e.g. vSphere/ESXi and server hardware with baseboard management interfaces that support NTP.
# To use this script, run:
#   make iso
#   make ntp
#   make mon
# This solution was created from the idea posted here: https://github.com/openshift/installer/issues/7571 

source scripts/include_all.sh

[ "$1" ] && set -x

source <(normalize-aba-conf)

[ ! "$ntp_server" ] && echo "Not configuring NTP in early bootstrap node because ntp_server not defined in aba.conf." && exit 0

dir=iso-agent-based

coreos-installer iso ignition show $dir/agent.x86_64.iso > $dir/tmp.ign

export CHRONY_CONF_BASE64=$(cat << EOF | base64 -w 0
server $ntp_server iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF
)

jq '.storage.files += [{
  "group": {},
  "overwrite": true,
  "path": "/etc/chrony.conf",
  "user": {
    "name": "root"
  },
  "contents": {
    "source": "data:text/plain;charset=utf-8;base64,'$CHRONY_CONF_BASE64'"
  },
  "mode": 420
}]' $dir/tmp.ign > $dir/custom_ign.ign

coreos-installer iso ignition embed -fi $dir/custom_ign.ign $dir/agent.x86_64.iso

