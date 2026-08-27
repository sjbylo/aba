#!/bin/bash -e
# Import an existing OpenShift cluster into ABA.
# Auto-detects cluster identity, network topology, and image source from the
# live cluster API, then scaffolds a cluster directory so day2, upgrade,
# shutdown/startup, and other lifecycle commands work.

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

source <(normalize-aba-conf)

# --- Parse flags ---
_kubeconfig=""
_image_source=""
_name=""
_force=false

while [ $# -gt 0 ]; do
	case "$1" in
		--kubeconfig|-k)
			[ -z "${2:-}" ] && aba_abort "Missing argument after $1"
			_kubeconfig="$2"; shift 2 ;;
		--image-source)
			[ -z "${2:-}" ] && aba_abort "Missing argument after $1"
			_image_source="$2"; shift 2 ;;
		--name|-n)
			[ -z "${2:-}" ] && aba_abort "Missing argument after $1"
			_name="$2"; shift 2 ;;
		--force|-f)
			_force=true; shift ;;
		--help|-h)
			cat others/help-import.txt >&2
			exit 0 ;;
		*)
			aba_abort "Unknown option: $1. Use --help for usage." ;;
	esac
done

[ -z "$_kubeconfig" ] && aba_abort "Missing required --kubeconfig flag. Use: aba import --kubeconfig <path>"

# Resolve relative paths
_kubeconfig=$(cd "$(dirname "$_kubeconfig")" && echo "$PWD/$(basename "$_kubeconfig")")
[ -f "$_kubeconfig" ] || aba_abort "Kubeconfig not found: $_kubeconfig"

export KUBECONFIG="$_kubeconfig"

ensure_oc

# --- Validate cluster access ---
aba_info "Connecting to cluster ..."
cluster_api_reachable "$KUBECONFIG" || aba_abort "Cluster API is not reachable. Check your kubeconfig and network."
oc whoami --request-timeout='10s' >/dev/null 2>&1 || aba_abort "Cannot authenticate to cluster. Check kubeconfig credentials."

# --- Auto-detect cluster identity ---
aba_info "Auto-detecting cluster configuration ..."

_base_domain=$(oc get dns.config/cluster -o jsonpath='{.spec.baseDomain}' 2>/dev/null) || true
if [ -z "$_base_domain" ]; then
	aba_abort "Could not detect base_domain from cluster. Is the cluster healthy?"
fi

_cluster_name=$(oc get infrastructure/cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null | sed 's/-[a-z0-9]*$//') || true
if [ -z "$_cluster_name" ]; then
	_full_domain="$_base_domain"
	_cluster_name="${_full_domain%%.*}"
	_base_domain="${_full_domain#*.}"
else
	_bd_from_dns="$_base_domain"
	_base_domain="${_bd_from_dns#"${_cluster_name}".}"
	[ "$_base_domain" = "$_bd_from_dns" ] && _base_domain="$_bd_from_dns"
fi

aba_debug "Detected: cluster_name=$_cluster_name base_domain=$_base_domain"

# --- Auto-detect network ---
_machine_network=""
_prefix_length=""
_host_prefix=$(oc get network.config/cluster -o jsonpath='{.spec.clusterNetwork[0].hostPrefix}' 2>/dev/null) || true
_host_prefix="${_host_prefix:-23}"

# Get node IPs and counts
_master_ips=$(oc get nodes -l node-role.kubernetes.io/master -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null) || true
_worker_ips=$(oc get nodes -l node-role.kubernetes.io/worker,!node-role.kubernetes.io/master -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null) || true

_num_masters=$(echo "$_master_ips" | wc -w)
_num_workers=$(echo "$_worker_ips" | wc -w)
[ "$_num_masters" -eq 0 ] && aba_abort "Could not detect any master nodes. Is the cluster healthy?"

# Sort all node IPs numerically and pick the lowest as starting_ip
_all_ips="$_master_ips $_worker_ips"
_starting_ip=$(echo "$_all_ips" | tr ' ' '\n' | grep -E '^[0-9]' | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | head -1)
[ -z "$_starting_ip" ] && aba_abort "Could not detect node IP addresses."

# Detect machine_network: find the route that covers the node IP
_route_net=$(ip route show to match "$_starting_ip" 2>/dev/null \
	| grep -v '^default' | awk '{print $1}' | grep '/' | head -1) || true

if [ -n "$_route_net" ]; then
	_machine_network="${_route_net%/*}"
	_prefix_length="${_route_net#*/}"
else
	_machine_network="${machine_network:-$(echo "$_starting_ip" | sed 's/\.[0-9]*$/.0/')}"
	_prefix_length="${prefix_length:-24}"
fi

# Detect VIPs (non-SNO only)
_api_vip=""
_ingress_vip=""
if [ "$_num_masters" -gt 1 ]; then
	_api_vip=$(dig +short "api.${_cluster_name}.${_base_domain}" 2>/dev/null | head -1) || true
	_ingress_vip=$(dig +short "foo.apps.${_cluster_name}.${_base_domain}" 2>/dev/null | head -1) || true
fi

# Network defaults from bastion
_dns_servers=$(get_dns_servers 2>/dev/null) || true
_next_hop=$(get_next_hop 2>/dev/null) || true
_ntp_servers=$(get_ntp_servers 2>/dev/null) || true

# Detect OCP version
_ocp_version=$(oc get clusterversion version -o jsonpath='{.status.history[?(@.state=="Completed")].version}' 2>/dev/null | awk '{print $1}') || true

# --- Auto-detect image_source ---
if [ -z "$_image_source" ]; then
	_has_idms=$(oc get imagedigestmirrorset 2>/dev/null | grep -c -v '^NAME' || true)
	_has_itms=$(oc get imagetagmirrorset 2>/dev/null | grep -c -v '^NAME' || true)
	_has_icsp=$(oc get imagecontentsourcepolicy 2>/dev/null | grep -c -v '^NAME' || true)

	if [ "$(( _has_idms + _has_itms + _has_icsp ))" -gt 0 ]; then
		_image_source="mirror"
	else
		_proxy_http=$(oc get proxy/cluster -o jsonpath='{.spec.httpProxy}' 2>/dev/null) || true
		if [ -n "$_proxy_http" ]; then
			_image_source="proxy"
		else
			_image_source="direct"
		fi
	fi
fi

# --- Derive cluster type ---
_cluster_type="standard"
[ "$_num_masters" -eq 1 ] && [ "$_num_workers" -eq 0 ] && _cluster_type="sno"
[ "$_num_masters" -ge 3 ] && [ "$_num_workers" -eq 0 ] && _cluster_type="compact"

# --- Display summary ---
aba_info "Detected cluster configuration:"
echo "  cluster_name    = $_cluster_name"
echo "  base_domain     = $_base_domain"
echo "  cluster_type    = $_cluster_type ($_num_masters masters, $_num_workers workers)"
echo "  machine_network = $_machine_network/$_prefix_length"
echo "  starting_ip     = $_starting_ip"
[ -n "$_api_vip" ] && echo "  api_vip         = $_api_vip"
[ -n "$_ingress_vip" ] && echo "  ingress_vip     = $_ingress_vip"
echo "  image_source    = $_image_source"
[ -n "$_ocp_version" ] && echo "  ocp_version     = $_ocp_version"

# --- Check for existing state ---
_dir_name="${_name:-$_cluster_name}"
_state_dir="$HOME/.aba/clusters/${_cluster_name}.${_base_domain}"

if [ "$_force" = true ]; then
	[ -d "$_dir_name" ] && aba_info "Overwriting existing directory: $_dir_name/"
	[ -d "$_state_dir" ] && aba_info "Cleaning existing state: $_state_dir/"
	rm -rf "$_dir_name" "$_state_dir"
else
	[ -d "$_dir_name" ] && aba_abort "Directory '$_dir_name' already exists. Use --force to overwrite, or --name to pick a different name."
	[ -d "$_state_dir" ] && aba_abort "Cluster state directory already exists: $_state_dir/
       This may be from a previous install. Use --force to overwrite."
fi

mkdir -p "$_dir_name"

cd "$_dir_name"

# Scaffold: Makefile symlink + make init dependencies
ln -fs ../templates/Makefile.cluster Makefile

# Write cluster.conf
cat > cluster.conf <<EOF
cluster_name=$_cluster_name
base_domain=$_base_domain

api_vip=${_api_vip:-}
ingress_vip=${_ingress_vip:-}

machine_network=${_machine_network}/${_prefix_length}

starting_ip=$_starting_ip

hostPrefix=$_host_prefix

master_prefix=master
worker_prefix=worker

num_masters=$_num_masters
num_workers=$_num_workers

dns_servers=${_dns_servers:-}
next_hop_address=${_next_hop:-}
ntp_servers=${_ntp_servers:-}

ports=
vlan=

ssh_key_file=~/.ssh/id_rsa

image_source=$_image_source

mac_prefix=
master_cpu_count=
master_mem=
worker_cpu_count=
worker_mem=
data_disk=
EOF

# Run make init to create symlinks (scripts/, templates/, cli/, aba.conf, mirror, regcreds, mirror.conf)
make -s init

# --- Externalize state ---
mkdir -p "$_state_dir/backup"
chmod 700 "$_state_dir"
chmod 700 "$(dirname "$_state_dir")"

# Copy kubeconfig
cp -p "$_kubeconfig" "$_state_dir/kubeconfig"
chmod 600 "$_state_dir/kubeconfig"

# Write state.sh
cat > "$_state_dir/state.sh" <<EOF
cluster_name=$_cluster_name
base_domain=$_base_domain
cluster_type=$_cluster_type
platform=bm
starting_ip=$_starting_ip
machine_network=$_machine_network
prefix_length=$_prefix_length
cp_names=
worker_names=
image_source=$_image_source
installed_from=imported
installed_on=$(date -Iseconds)
EOF

# Backup cluster.conf
cp -p cluster.conf "$_state_dir/backup/"

# Convenience symlink
ln -sfn "$_state_dir" clusterstate

# Create rendezvousIP so 'aba ssh' works
mkdir -p iso-agent-based
echo "$_starting_ip" > iso-agent-based/rendezvousIP

# Mark as installed (cluster already exists)
touch .install-complete

aba_info "Cluster '$_cluster_name' imported into $_dir_name/"
aba_info ""
aba_info "Available commands:"
aba_info "  aba -d $_dir_name day2          Integrate with mirror registry"
aba_info "  aba -d $_dir_name day2-ntp      Configure NTP"
aba_info "  aba -d $_dir_name day2-osus     Configure update service"
aba_info "  aba -d $_dir_name upgrade       Upgrade the cluster"
aba_info "  aba -d $_dir_name getco         Show cluster operators"
aba_info "  aba -d $_dir_name shell         Open oc shell"
aba_info "  aba -d $_dir_name shutdown      Graceful shutdown"
