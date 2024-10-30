#!/bin/bash 
# Run this script for day 2 config of NTP

source scripts/include_all.sh

[ "$1" ] && set -x

umask 077

source <(normalize-aba-conf)

[ ! "$ntp_servers" ] && echo_red "Define 'ntp_servers' value in 'aba.conf' to configure NTP" && exit 0

ntp_servers=$(echo "$ntp_servers" | tr -d "[:space:]" | tr ',' ' ')

export ocp_ver_major=$(echo $ocp_version | cut -d. -f1-2)

[ ! -s .99-master-chrony-conf-override.bu ] && cat > .99-master-chrony-conf-override.bu <<END
variant: openshift
version: 4.12.0
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
$(for svr in $ntp_servers; do echo "          server $svr iburst"; done)

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

[ ! -s .99-worker-chrony-conf-override.bu ] && cat > .99-worker-chrony-conf-override.bu <<END
variant: openshift
version: 4.12.0
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
$(for svr in $ntp_servers; do echo "          server $svr iburst"; done)

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

make -s ~/bin/butane

# Check and install butane package
if ! which butane >/dev/null 2>&1; then
	# No rpm available for RHEL8
	if ! sudo dnf install butane -y; then
		if curl --connect-timeout 10 --retry 3 -s https://mirror.openshift.com/pub/openshift-v4/clients/butane/latest/butane --output butane; then
			sudo mv butane /usr/local/bin
		else
			echo "Please install 'butane' command and try again!"
			echo "E.g. run: 'curl --connect-timeout 10 --retry 3 https://mirror.openshift.com/pub/openshift-v4/clients/butane/latest/butane --output butane'"

			exit 1
		fi
	fi
fi

butane .99-master-chrony-conf-override.bu -o 99-master-chrony-conf-override.yaml
butane .99-worker-chrony-conf-override.bu -o 99-worker-chrony-conf-override.yaml

export KUBECONFIG=$PWD/iso-agent-based/auth/kubeconfig

oc apply -f 99-master-chrony-conf-override.yaml
oc apply -f 99-worker-chrony-conf-override.yaml

echo
echo "OpenShift will now configure NTP on all nodes.  Node restart is required and will take some time to complete."
echo
