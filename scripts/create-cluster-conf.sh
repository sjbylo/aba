#!/usr/bin/bash 
# INTENT:    Ensure cluster.conf exists and has populated network fields
# CALLED BY: Makefile.cluster (cluster.conf target), aba CLI (--step cluster.conf)
# CWD:       Cluster directory (e.g. ~/aba/sno/)
# REQUIRES:  aba.conf (sourced via normalize-aba-conf), network access for auto-detection
# PRODUCES:  cluster.conf (new or updated), updates aba.conf with detected network values
# SIDE EFFECTS: Writes to aba.conf (network fields), may abort if ask=true and values were auto-detected
# IDEMPOTENT: Yes -- only fills empty fields, never overwrites user-set values
# ENV:       ASK_OVERRIDE (suppresses abort), name/type/starting_ip (for new clusters)

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

source <(normalize-aba-conf)

verify-aba-conf

if [ ! "$ocp_version" ]; then
	echo_red "Error: 'ocp_version' not set in aba/aba.conf.  Run aba in the root of Aba's repository or see the aba/README.md on how to get started."

	exit 1
fi

# --- Auto-detect empty network values in aba.conf (ALWAYS runs) ---
# Network values are optional in aba.conf (e.g. bundle workflow) but mandatory
# for cluster.conf.  Auto-detect any missing values and write them into aba.conf.
_filled=0
if [ ! "$domain" ]; then
	v=$(get_domain) && [ "$v" ] && replace-value-conf -q -n domain -v "$v" -f aba.conf && domain="$v"
	[ "$domain" ] && { aba_info "Auto-detected domain=$domain"; _filled=$((_filled+1)); }
fi
if [ ! "$machine_network" ]; then
	v=$(get_machine_network) && [ "$v" ] && replace-value-conf -q -n machine_network -v "$v" -f aba.conf && machine_network="$v"
	[ "$machine_network" ] && { aba_info "Auto-detected machine_network=$machine_network"; _filled=$((_filled+1)); }
fi
# Split CIDR into machine_network (IP) + prefix_length for the cluster.conf template
if [[ "$machine_network" == */* ]]; then
	export prefix_length="${machine_network#*/}"      # CIDR prefix (10.0.0.0/24 → 24)
	machine_network="${machine_network%/*}"           # IP part (10.0.0.0/24 → 10.0.0.0)
fi
if [ ! "$dns_servers" ]; then
	v=$(get_dns_servers) && [ "$v" ] && replace-value-conf -q -n dns_servers -v "$v" -f aba.conf && dns_servers="$v"
	[ "$dns_servers" ] && { aba_info "Auto-detected dns_servers=$dns_servers"; _filled=$((_filled+1)); }
fi
if [ ! "$next_hop_address" ]; then
	v=$(get_next_hop) && [ "$v" ] && replace-value-conf -q -n next_hop_address -v "$v" -f aba.conf && next_hop_address="$v"
	[ "$next_hop_address" ] && { aba_info "Auto-detected next_hop_address=$next_hop_address"; _filled=$((_filled+1)); }
fi
if [ ! "$ntp_servers" ]; then
	v=$(get_ntp_servers) && [ "$v" ] && replace-value-conf -q -n ntp_servers -v "$v" -f aba.conf && ntp_servers="$v"
	[ "$ntp_servers" ] && { aba_info "Auto-detected ntp_servers=$ntp_servers"; _filled=$((_filled+1)); }
fi
if [ $_filled -gt 0 ]; then
	if [ "$ask" ]; then
		aba_warning \
			"$_filled network value(s) were auto-detected and written to aba.conf." \
			"Please review aba.conf and re-run the command."
		exit 1
	fi
	aba_info "$_filled network value(s) were auto-detected and written to aba.conf."
fi

# --- For existing cluster.conf: fill empty network fields from aba.conf, then exit ---
if [ -s cluster.conf ]; then
	# Save aba.conf values (just auto-detected or already set)
	_aba_mn="$machine_network"
	_aba_pl="${prefix_length:-}"
	_aba_dns="$dns_servers"
	_aba_gw="$next_hop_address"
	_aba_ntp="$ntp_servers"

	# Load cluster.conf values into memory
	source <(normalize-cluster-conf)

	# Fill only empty fields in cluster.conf (non-destructive)
	[ ! "$machine_network" ] && [ "$_aba_mn" ] && [ -n "$_aba_pl" ] && replace-value-conf -q -n machine_network -v "${_aba_mn}/${_aba_pl}" -f cluster.conf
	[ ! "$dns_servers" ]     && [ "$_aba_dns" ] && replace-value-conf -q -n dns_servers -v "$_aba_dns" -f cluster.conf
	[ ! "$next_hop_address" ] && [ "$_aba_gw" ] && replace-value-conf -q -n next_hop_address -v "$_aba_gw" -f cluster.conf
	[ ! "$ntp_servers" ]     && [ "$_aba_ntp" ] && replace-value-conf -q -n ntp_servers -v "$_aba_ntp" -f cluster.conf

	# NTP fallback: only direct-connected clusters can reach public NTP (UDP 123 not proxied)
	if [ ! "$ntp_servers" ] && [ "$int_connection" = "direct" ]; then
		replace-value-conf -q -n ntp_servers -v "pool.ntp.org" -f cluster.conf
	fi

	exit 0
fi

# --- New cluster: everything below is for creating a fresh cluster.conf ---

# jinja2 module is needed for template rendering
scripts/install-rpms.sh internal

# If auto-detection failed for any mandatory values, tell the user which ones
_missing=0
[ ! "$domain" ]			&& { echo_red "Error: 'domain' could not be detected. Set it in aba.conf." >&2; _missing=$((_missing+1)); }
[ ! "$machine_network" ]	&& { echo_red "Error: 'machine_network' could not be detected. Set it in aba.conf." >&2; _missing=$((_missing+1)); }
[ ! "$dns_servers" ]		&& { echo_red "Error: 'dns_servers' could not be detected. Set it in aba.conf." >&2; _missing=$((_missing+1)); }
[ ! "$next_hop_address" ]	&& { echo_red "Error: 'next_hop_address' could not be detected. Set it in aba.conf." >&2; _missing=$((_missing+1)); }
# ntp_servers is not mandatory -- clusters can work without NTP if clocks are synced
[ $_missing -gt 0 ] && aba_abort "$_missing network value(s) could not be auto-detected. Set them in aba.conf."

name=standard
type=standard

. <(process_args "$@")

aba_debug "Creating cluster directory for [$name] of type [$type]"

# If not already set, set reasonable defaults
# Note: VMware mac address range for VMs is 00:50:56:00:00:00 to 00:50:56:3F:FF:FF 
if [ ! "$starting_ip" ] && [ "$machine_network" ] && [ "$prefix_length" ]; then
	export starting_ip=$(suggest_starting_ip "$machine_network" "$prefix_length")
fi
[ ! "$starting_ip" ]		&& export starting_ip=
[ ! "$mac_prefix" ]		&& export mac_prefix=00:50:56:2x:xx:
[ ! "$num_masters" ]		&& export num_masters=3
[ ! "$num_workers" ]		&& export num_workers=3
[ ! "$hostPrefix" ]		&& export hostPrefix=23
[ ! "$master_prefix" ]		&& export master_prefix=master
[ ! "$worker_prefix" ]		&& export worker_prefix=worker
[ ! "$ssh_key_file" ]		&& export ssh_key_file=~/.ssh/id_rsa
[ ! "$mirror_name" ]		&& export mirror_name=mirror
[ ! "$ports" ]			&& export ports=ens160
[ ! "$vlan" ]			&& export vlan=
[ ! "$master_cpu_count" ]	&& export master_cpu_count=10
[ ! "$master_mem" ]		&& export master_mem=20
[ ! "$worker_cpu_count" ]	&& export worker_cpu_count=5
[ ! "$worker_mem" ]		&& export worker_mem=10
[ ! "$int_connection" ]		&& export int_connection=
[ ! "$data_disk" ]		&& export data_disk=500

# NTP fallback: only direct-connected clusters can reach public NTP (UDP 123 not proxied)
if [ ! "$ntp_servers" ] && [ "$int_connection" = "direct" ]; then
	export ntp_servers="pool.ntp.org"
fi

# Now, need to create cluster.conf
export cluster_name=$name

# Set reasonable defaults for sno and compact
if [ "$type" = "sno" ]; then
	export num_masters=1
	export num_workers=0
	export mac_prefix=00:50:56:0x:xx:
elif [ "$type" = "compact" ]; then
	export num_masters=3
	export num_workers=0
	export mac_prefix=00:50:56:1x:xx:
fi

# This takes quite a few exported vars as input
if ! scripts/j2 templates/cluster.conf.j2 > cluster.conf; then
	rm -f cluster.conf
	echo_red "Error: failed to render cluster.conf (is python3 installed?)."
	exit 1
fi

# For sno, clear VIPs as they are not needed
if [ "$type" = "sno" ]; then
	replace-value-conf -q -n api_vip -v "" -f cluster.conf
	replace-value-conf -q -n ingress_vip -v "" -f cluster.conf
fi

edit_file cluster.conf "Edit the cluster.conf file to set all the required parameters for OpenShift installation" #### don't want error here, just stop || exit 1

exit 0

