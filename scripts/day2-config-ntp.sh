#!/bin/bash 
# Run this script for day 2 config of NTP

source scripts/include_all.sh



umask 077

source <(normalize-aba-conf)
source <(normalize-cluster-conf)

verify-aba-conf || aba_abort "$_ABA_CONF_ERR"
verify-cluster-conf || exit 1

[ ! "$ntp_servers" ] && aba_abort "Define 'ntp_servers' value in 'aba.conf' to configure NTP" 

aba_info "Ensuring CLI binaries are installed"
scripts/cli-install-all.sh --wait oc butane

ntp_servers=$(echo "$ntp_servers" | tr -d "[:space:]" | tr ',' ' ')

export ocp_ver_major=$(echo $ocp_version | cut -d. -f1-2)

#[ ! -s .99-master-chrony-conf-override.bu ] && cat > .99-master-chrony-conf-override.bu <<END
cat > .99-master-chrony-conf-override.bu <<END
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

#[ ! -s .99-worker-chrony-conf-override.bu ] && cat > .99-worker-chrony-conf-override.bu <<END
cat > .99-worker-chrony-conf-override.bu <<END
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
	if ! $SUDO dnf install butane -y; then
		if curl --connect-timeout 10 --retry 8 -s https://mirror.openshift.com/pub/openshift-v4/clients/butane/latest/butane --output butane; then
			$SUDO mv butane /usr/local/bin
		else
			aba_abort \
				"Please install 'butane' command and try again!" \
				"E.g. run: 'curl --connect-timeout 10 --retry 8 https://mirror.openshift.com/pub/openshift-v4/clients/butane/latest/butane --output butane'"
		fi
	fi
fi

butane .99-master-chrony-conf-override.bu -o 99-master-chrony-conf-override.yaml
butane .99-worker-chrony-conf-override.bu -o 99-worker-chrony-conf-override.yaml

aba_info "Accessing the cluster ..."

[ ! "$KUBECONFIG" ] && [ -s iso-agent-based/auth/kubeconfig ] && export KUBECONFIG=$PWD/iso-agent-based/auth/kubeconfig # Can also apply this script to non-aba clusters!

exec_cmd="oc whoami"
aba_debug "Running: $exec_cmd"
$exec_cmd || aba_abort "Unable to access the cluster using KUBECONFIG=$KUBECONFIG"

warn_if_cluster_unstable

exec_cmd="oc apply -f 99-master-chrony-conf-override.yaml"
aba_debug "Running: $exec_cmd"
$exec_cmd
exec_cmd="oc apply -f 99-worker-chrony-conf-override.yaml"
aba_debug "Running: $exec_cmd"
$exec_cmd

echo
aba_info "OpenShift will now configure NTP on all nodes.  Node restart may be required and will take some time to complete."
echo

#######################
# Verify NTP configuration on cluster nodes.
#
# Phase 1 (long timeout, up to 15 min):
#   chrony.conf contains all configured "server X iburst" lines.
#   Proves MachineConfig was applied by MCO.  MCO may reboot nodes, hence
#   the long timeout.
#
# Phase 2 (short timeout, up to 60s):
#   At least one NTP source is synced (^* or ^+ in chronyc sources).
#   Once chrony.conf is applied, sync should happen within seconds.
#   Unreachable sources (^?) are warned but don't fail -- pool servers
#   may be unreachable from air-gapped networks.
#
# We check the config file directly instead of resolving hostnames on bastion,
# because pool hostnames (e.g. 2.rhel.pool.ntp.org) rotate IPs and chrony on
# the node will resolve to a different address than bastion's getent.

raw_targets=($ntp_servers)

# Get list of Node IPs
aba_debug "Running: oc get nodes -owide --no-headers"
nodesIPs=$(oc get nodes -owide --no-headers | awk '{print $6}')

# Phase 1: verify chrony.conf has all configured server lines on every node.
_ntp_config_applied() {
	for host in $nodesIPs; do
		aba_debug "Checking chrony.conf on node: $host"
		node_conf=$(ssh -F ~/.aba/ssh.conf -q core@$host 'cat /etc/chrony.conf' 2>&1)
		aba_debug "Node $host chrony.conf:"
		aba_debug "\n$node_conf"

		for svr in "${raw_targets[@]}"; do
			if ! echo "$node_conf" | grep -qF "server $svr iburst"; then
				aba_debug "Server '$svr' not yet in chrony.conf on $host"
				return 1
			fi
		done
	done
	return 0
}

if ! aba_wait_show "Waiting for NTP config on all nodes (${raw_targets[*]}) (Ctrl-C to abort)" 10 900 _ntp_config_applied; then
	echo
	for host in $nodesIPs; do
		_conf=$(ssh -F ~/.aba/ssh.conf -q core@$host 'cat /etc/chrony.conf' 2>&1)
		echo "  Node $host chrony.conf servers:"
		echo "$_conf" | grep '^server ' | sed 's/^/    /'
	done
	echo
	aba_abort \
		"Timed out after 15 min waiting for chrony.conf on all nodes." \
		"MCO may still be rolling out the MachineConfig (node reboots in progress)." \
		"Check 'oc get mcp' and 'oc get nodes' for status."
fi

aba_info_ok "chrony.conf applied on all nodes."

# Phase 2: at least one NTP source synced on every node.
_ntp_source_synced() {
	for host in $nodesIPs; do
		aba_debug "Checking NTP sources on node: $host"
		node_sources=$(ssh -F ~/.aba/ssh.conf -q core@$host 'chronyc sources' 2>&1)
		aba_debug "Node $host chronyc sources:"
		aba_debug "\n$node_sources"

		if ! echo "$node_sources" | grep -qE '^\^[*+]'; then
			aba_debug "No synced NTP source on $host yet"
			return 1
		fi
	done
	return 0
}

if ! aba_wait_show "Verifying NTP source sync on all nodes (Ctrl-C to abort)" 5 60 _ntp_source_synced; then
	echo
	for host in $nodesIPs; do
		_src=$(ssh -F ~/.aba/ssh.conf -q core@$host 'chronyc sources' 2>&1)
		echo "  Node $host chronyc sources:"
		echo "$_src" | grep '^\^' | sed 's/^/    /'
	done
	echo
	aba_abort \
		"Timed out after 60s waiting for at least one synced NTP source on all nodes." \
		"chrony.conf is correctly applied, but no NTP source responded (^* or ^+)." \
		"Verify the configured NTP servers (${raw_targets[*]}) are reachable from the cluster network."
fi

# Final report: warn about unreachable sources (don't fail -- at least one is synced).
_has_warnings=""
for host in $nodesIPs; do
	_sources=$(ssh -F ~/.aba/ssh.conf -q core@$host 'chronyc sources' 2>&1)
	_unreachable=$(echo "$_sources" | grep '^\^?' | awk '{print $2}') || true
	if [ -n "$_unreachable" ]; then
		aba_warning "Node $host: unreachable NTP source(s): $_unreachable"
		_has_warnings=1
	fi
done

if [ -n "$_has_warnings" ]; then
	aba_info_ok "NTP configured (at least one source synced, some unreachable)."
else
	aba_info_ok "NTP configured and all sources synced on all nodes."
fi
