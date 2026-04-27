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
# Phase 1a: Wait for MCO to START processing the new MachineConfig.
#   Right after oc apply, the MCO hasn't noticed yet -- MCP still shows
#   Updated=True from the previous state.  We must wait for Updating=True
#   before we can meaningfully wait for it to finish.
#   If it never starts (60s), the MC content is likely identical (no reboot).
#
# Phase 1b: Wait for all MachineConfigPools to finish updating.
#   MCO renders the new MachineConfig, drains and reboots nodes.
#   On SNO the master pool reboot takes the API offline temporarily.
#   We must wait for MCP stability before checking anything on nodes.
#
# Phase 2: chrony.conf contains all configured "server X iburst" lines.
#   Quick sanity check that the MachineConfig content is correct.
#
# Phase 3: At least one NTP source is synced (^* or ^+ in chronyc sources).
#   Once chrony.conf is applied, sync should happen within seconds.
#   Unreachable sources (^?) are warned but don't fail -- pool servers
#   may be unreachable from air-gapped networks.
#
# Phase 4: Wait for API server to be available after MCO reboot.
#   On SNO the API goes down during the reboot -- callers expect it back.
#
# We check the config file directly instead of resolving hostnames on bastion,
# because pool hostnames (e.g. 2.rhel.pool.ntp.org) rotate IPs and chrony on
# the node will resolve to a different address than bastion's getent.

# Phase 1a: wait for MCO to start processing (Updating=True on any pool).
_any_mcp_updating() {
	local updating
	updating=$(oc get mcp -o jsonpath='{.items[*].status.conditions[?(@.type=="Updating")].status}' 2>/dev/null) || return 1
	echo "$updating" | grep -q True
}

_mco_started=1
_wait_rc=0
aba_wait_show "Waiting for MCO to start processing NTP MachineConfig (Ctrl-C to skip)" 2 60 _any_mcp_updating || _wait_rc=$?
if [ "$_wait_rc" -eq 130 ] || [ "$_wait_rc" -eq 143 ]; then
	echo
	aba_info "Aborted by user."
	exit 0
elif [ "$_wait_rc" -ne 0 ]; then
	_mco_started=0
	aba_info "MCO did not start updating -- MachineConfig may match current config (no reboot needed)."
fi

raw_targets=($ntp_servers)

# Get list of Node IPs before potential reboot.
aba_debug "Running: oc get nodes -owide --no-headers"
nodesIPs=$(oc get nodes -owide --no-headers | awk '{print $6}')

# Phase 2: verify chrony.conf has all configured server lines on every node.
# Polls through the MCO reboot -- no need to wait for MCP to finish first.
_ntp_config_applied() {
	for host in $nodesIPs; do
		aba_debug "Checking chrony.conf on node: $host"
		node_conf=$(ssh -F ~/.aba/ssh.conf -q core@$host 'cat /etc/chrony.conf' 2>/dev/null) || return 1

		for svr in "${raw_targets[@]}"; do
			if ! echo "$node_conf" | grep -qF "server $svr iburst"; then
				aba_debug "Server '$svr' not yet in chrony.conf on $host"
				return 1
			fi
		done
	done
	return 0
}

_wait_rc=0
aba_wait_show "Waiting for chrony.conf update on all nodes (${raw_targets[*]}) (Ctrl-C to skip)" 10 900 _ntp_config_applied || _wait_rc=$?
if [ "$_wait_rc" -eq 130 ] || [ "$_wait_rc" -eq 143 ]; then
	echo
	aba_info "Aborted by user."
	exit 0
elif [ "$_wait_rc" -ne 0 ]; then
	echo
	for host in $nodesIPs; do
		_conf=$(ssh -F ~/.aba/ssh.conf -q core@$host 'cat /etc/chrony.conf' 2>/dev/null) || true
		echo "  Node $host chrony.conf servers:"
		echo "$_conf" | grep '^server ' | sed 's/^/    /'
	done
	echo
	aba_abort \
		"Timed out after 15 min waiting for chrony.conf on all nodes." \
		"Check 'oc get mcp' and 'oc get nodes' for status."
fi

aba_info_ok "chrony.conf applied on all nodes."

# Phase 3: at least one NTP source synced on every node.
# Uses chronyc -N to show original configured names (avoids hostname resolution issues
# when both a hostname and its IP are configured as separate NTP sources).
_ntp_source_synced() {
	for host in $nodesIPs; do
		aba_debug "Checking NTP sources on node: $host"
		node_sources=$(ssh -F ~/.aba/ssh.conf -q core@$host 'chronyc -N sources' 2>/dev/null) || return 1

		if ! echo "$node_sources" | grep -qE '^\^[*+]'; then
			aba_debug "No synced NTP source on $host yet"
			return 1
		fi
	done
	return 0
}

_wait_rc=0
aba_wait_show "Waiting for NTP source sync on all nodes (Ctrl-C to skip)" 5 300 _ntp_source_synced || _wait_rc=$?
if [ "$_wait_rc" -eq 130 ] || [ "$_wait_rc" -eq 143 ]; then
	echo
	aba_info "Aborted by user."
	exit 0
elif [ "$_wait_rc" -ne 0 ]; then
	echo
	for host in $nodesIPs; do
		_src=$(ssh -F ~/.aba/ssh.conf -q core@$host 'chronyc -N sources' 2>/dev/null) || true
		echo "  Node $host chronyc sources:"
		echo "$_src" | grep '^\^' | sed 's/^/    /' || true
	done
	echo
	aba_abort \
		"Timed out after 5 min waiting for at least one synced NTP source on all nodes." \
		"chrony.conf is correctly applied, but no NTP source responded (^* or ^+)." \
		"Verify the configured NTP servers (${raw_targets[*]}) are reachable from the cluster network."
fi

# Final report: warn about unreachable sources (don't fail -- at least one is synced).
_has_warnings=""
for host in $nodesIPs; do
	_sources=$(ssh -F ~/.aba/ssh.conf -q core@$host 'chronyc -N sources' 2>/dev/null) || true
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

# Phase 4: ensure API server is available before returning.
# On SNO the MCO reboot takes the API offline; callers expect it back.
_api_available() {
	oc get nodes --no-headers >/dev/null 2>&1
}

_wait_rc=0
aba_wait_show "Waiting for API server to be available (Ctrl-C to skip)" 5 300 _api_available || _wait_rc=$?
if [ "$_wait_rc" -eq 130 ] || [ "$_wait_rc" -eq 143 ]; then
	echo
	aba_info "Aborted by user."
	exit 0
elif [ "$_wait_rc" -ne 0 ]; then
	aba_warning "API server not available after 5 min. Cluster may still be recovering."
fi

aba_info_ok "API server available."
