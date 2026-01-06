#!/bin/bash 
# Run this script for day 2 config of NTP

source scripts/include_all.sh



umask 077

source <(normalize-aba-conf)
source <(normalize-cluster-conf)

verify-aba-conf || exit 1
verify-cluster-conf || exit 1

[ ! "$ntp_servers" ] && aba_abort "Define 'ntp_servers' value in 'aba.conf' to configure NTP" 

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

oc whoami || aba_abort "Unable to access the cluster using KUBECONFIG=$KUBECONFIG"

oc apply -f 99-master-chrony-conf-override.yaml
oc apply -f 99-worker-chrony-conf-override.yaml

echo
aba_info "OpenShift will now configure NTP on all nodes.  Node restart may be required and will take some time to complete."
echo

#######################
# Check config in cluster!
# 1. PRE-PROCESS TARGETS (Resolve DNS once & Deduplicate)
raw_targets=($ntp_servers)
ntp_targets=()

# Temporary array to hold all resolved IPs
temp_ips=()

for t in "${raw_targets[@]}"; do
	# Simple regex to check if it's already an IP
	if [[ $t =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
		temp_ips+=("$t")
	else
		# Resolve hostname to IP
		resolved_ip=$(getent hosts "$t" | awk '{print $1}' | head -n 1)
		if [ -n "$resolved_ip" ]; then
			temp_ips+=("$resolved_ip")
			aba_debug "Resolved $t to $resolved_ip"
		else
			echo_red "Warning: Could not resolve NTP target $t"
		fi
	fi
done

# Deduplicate the array (sort unique)
IFS=$'\n' ntp_targets=($(sort -u <<<"${temp_ips[*]}"))
unset IFS

echo_yellow "[ABA] Verifying all nodes have the following NTP sources configured: ${ntp_targets[*]} ... Hit Ctrl-C to stop."

# 2. Get list of Node IPs
nodesIPs=$(oc get nodes -owide --no-headers | awk '{print $6}')

# 3. Loop indefinitely until verification passes
while true; do
	all_nodes_compliant=true

	for host in $nodesIPs; do
		aba_debug "Checking NTP config in host: $host"

		# Fetch the chronyc sources output (IPs only) ONCE per host
		# Added Timeout and HostKey flags so script doesn't hang
		node_sources=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -q core@$host 'chronyc sources -n' 2>&1)

		aba_debug "Node: $host config:"
		aba_debug "\n$node_sources"

		# Check for EACH target IP inside the node's source list
		for target_ip in "${ntp_targets[@]}"; do
			
			aba_debug "Checking IP $target_ip in chrony config"

			# Use grep -F (fixed string) to match IP.
			if ! echo "$node_sources" | grep -Fq " $target_ip "; then
				# If ANY IP is missing, mark this run as failed
				all_nodes_compliant=false
				break 2 # Break out of both loops to wait/sleep
			fi
			aba_debug "target_ip $target_ip found!"
		done
	done

	# If the flag is still true, all nodes have all IPs
	if [ "$all_nodes_compliant" = true ]; then
		break
	fi

	# Wait before retrying
	sleep 5
done

aba_info "All nodes are synchronized!"
