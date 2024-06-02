#!/bin/bash 

source scripts/include_all.sh

[ "$1" ] && set -x

umask 077

source <(normalize-aba-conf)

[ ! "$ntp_server" ] && echo "Define 'ntp_server' in 'aba.conf' to configure NTP" && exit 0

export ocp_ver_major=$(echo $ocp_version | cut -d. -f1-2)

[ ! -s 99-master-chrony-conf-override.bu ] && cat > 99-master-chrony-conf-override.bu <<END
variant: openshift
version: $ocp_ver_major.0
metadata:
  name: 99-master-chrony-conf-override
  labels:
    machineconfiguration.openshift.io/role: master
storage:
  files:
    - path: /etc/chrony.conf
      mode: 0644
      overwrite: true
      contents:
        inline: |
          # Use public servers from the pool.ntp.org project.
          # Please consider joining the pool (https://www.pool.ntp.org/join.html).

          # The Machine Config Operator manages this file
          server $ntp_server iburst

          stratumweight 0
          driftfile /var/lib/chrony/drift
          rtcsync
          makestep 10 3
          bindcmdaddress 127.0.0.1
          bindcmdaddress ::1
          keyfile /etc/chrony.keys
          commandkey 1
          generatecommandkey
          noclientlog
          logchange 0.5
          logdir /var/log/chrony

          # Configure the control plane nodes to serve as local NTP servers
          # for all worker nodes, even if they are not in sync with an
          # upstream NTP server.

          # Allow NTP client access from the local network.
          allow all
          # Serve time even if not synchronized to a time source.
          local stratum 3 orphan
END

[ ! -s 99-worker-chrony-conf-override.bu ] && cat > 99-worker-chrony-conf-override.bu <<END
variant: openshift
version: $ocp_ver_major.0
metadata:
  name: 99-worker-chrony-conf-override
  labels:
    machineconfiguration.openshift.io/role: worker
storage:
  files:
    - path: /etc/chrony.conf
      mode: 0644
      overwrite: true
      contents:
        inline: |
          # Use public servers from the pool.ntp.org project.
          # Please consider joining the pool (https://www.pool.ntp.org/join.html).

          # The Machine Config Operator manages this file
          server $ntp_server iburst

          stratumweight 0
          driftfile /var/lib/chrony/drift
          rtcsync
          makestep 10 3
          bindcmdaddress 127.0.0.1
          bindcmdaddress ::1
          keyfile /etc/chrony.keys
          commandkey 1
          generatecommandkey
          noclientlog
          logchange 0.5
          logdir /var/log/chrony

          # Configure the control plane nodes to serve as local NTP servers
          # for all worker nodes, even if they are not in sync with an
          # upstream NTP server.

          # Allow NTP client access from the local network.
          allow all
          # Serve time even if not synchronized to a time source.
          local stratum 3 orphan
END

butane 99-master-chrony-conf-override.bu -o 99-master-chrony-conf-override.yaml
butane 99-worker-chrony-conf-override.bu -o 99-worker-chrony-conf-override.yaml

export KUBECONFIG=$PWD/iso-agent-based/auth/kubeconfig

oc apply -f 99-master-chrony-conf-override.yaml
oc apply -f 99-worker-chrony-conf-override.yaml

