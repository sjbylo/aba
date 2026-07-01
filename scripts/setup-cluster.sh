#!/bin/bash -e
# Create the cluster dir

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

source <(normalize-aba-conf)   # Fetch the domain name
verify-aba-conf || aba_abort "$_ABA_CONF_ERR"

# Set defaults
name=standard
type=

. <(process_args "$@")

[ ! "$name" ] && aba_abort "Error: cluster name missing!" 
_valid_cluster_name "$name" || exit 1

if [ ! -d "$name" ]; then
	mkdir $name
	cd $name
	ln -fs ../templates/Makefile.cluster Makefile
	exec_cmd="make -s init"
	aba_debug "Running: $exec_cmd (new cluster dir $name)"
	$exec_cmd
else
	if [ -s $name/Makefile ]; then
	       	if grep -q "Cluster Makefile" $name/Makefile; then
			cd $name 
			exec_cmd="make -s init"
			aba_debug "Running: $exec_cmd (existing cluster dir $name)"
			$exec_cmd  # Allow the dir to be "re-used",. i.e. don't touch any already created artifacts (cluster.con, agent*yaml, iso etc) 
		else
			aba_abort "Error: Directory $name invalid cluster dir."
		fi
	else
		cd $name
		ln -fs ../templates/Makefile.cluster Makefile
		exec_cmd="make -s init"
		aba_debug "Running: $exec_cmd (empty cluster dir $name)"
		$exec_cmd
	fi
fi

_existing_conf=false
if [ -s cluster.conf ]; then
	_existing_conf=true
	aba_debug "Found existing '$name/cluster.conf' — applying CLI values."
else
	aba_info "Creating '$name/cluster.conf' file for cluster type '${type:-standard}'."
fi

exec_cmd="scripts/create-cluster-conf.sh name=$name type=${type:-standard} domain=$domain starting_ip=$starting_ip ports=$ports ingress_vip=$ingress_vip master_cpu_count=$master_cpu_count master_mem=$master_mem worker_cpu_count=$worker_cpu_count worker_mem=$worker_mem data_disk=$data_disk api_vip=$api_vip ingress_vip=$ingress_vip num_workers=$num_workers num_masters=$num_masters vlan=$vlan ssh_key_file=$ssh_key_file mirror_name=$mirror_name"

aba_debug "Running: $exec_cmd"

$exec_cmd

# Apply any CLI-passed values to cluster.conf (only writes if value differs).
# Handles the case where cluster.conf already existed and
# create-cluster-conf.sh exited early ([ -s cluster.conf ] && exit 0).

# Map --type to num_masters/num_workers for existing clusters
if [ "$type" ] && [ -z "$num_masters" ]; then
	case "$type" in
		sno)      num_masters=1; num_workers=0 ;;
		compact)  num_masters=3; num_workers=0 ;;
		standard) num_masters=3; num_workers=${num_workers:-2} ;;
	esac
fi

# Track whether anything was updated for user feedback
_updated=""
[ "$num_masters" ]       && _updated="${_updated}num_masters=$num_masters "
[ "$num_workers" ]       && _updated="${_updated}num_workers=$num_workers "
[ "$int_connection" ]    && _updated="${_updated}int_connection=$int_connection "

[ "$int_connection" ]    && replace-value-conf -q -n int_connection    -v "$int_connection"    -f cluster.conf
[ "$api_vip" ]           && replace-value-conf -q -n api_vip           -v "$api_vip"           -f cluster.conf
[ "$ingress_vip" ]       && replace-value-conf -q -n ingress_vip       -v "$ingress_vip"       -f cluster.conf
[ "$starting_ip" ]       && replace-value-conf -q -n starting_ip       -v "$starting_ip"       -f cluster.conf
[ "$master_cpu_count" ]  && replace-value-conf -q -n master_cpu_count  -v "$master_cpu_count"  -f cluster.conf
[ "$master_mem" ]        && replace-value-conf -q -n master_mem        -v "$master_mem"        -f cluster.conf
[ "$worker_cpu_count" ]  && replace-value-conf -q -n worker_cpu_count  -v "$worker_cpu_count"  -f cluster.conf
[ "$worker_mem" ]        && replace-value-conf -q -n worker_mem        -v "$worker_mem"        -f cluster.conf
[ "$data_disk" ]         && replace-value-conf -q -n data_disk         -v "$data_disk"         -f cluster.conf
[ "$num_workers" ]       && replace-value-conf -q -n num_workers       -v "$num_workers"       -f cluster.conf
[ "$num_masters" ]       && replace-value-conf -q -n num_masters       -v "$num_masters"       -f cluster.conf
[ "$vlan" ]              && replace-value-conf -q -n vlan              -v "$vlan"              -f cluster.conf
[ "$ssh_key_file" ]      && replace-value-conf -q -n ssh_key_file      -v "$ssh_key_file"      -f cluster.conf
[ "$mirror_name" ]       && replace-value-conf -q -n mirror_name       -v "$mirror_name"       -f cluster.conf

[ "$_updated" ] && $_existing_conf && aba_info "Updated $name/cluster.conf: ${_updated% }"  # trim trailing space

# Re-link mirror/regcreds/mirror.conf to match the final mirror_name in cluster.conf.
# This is necessary because .init (above) ran before cluster.conf existed, so it
# defaulted mirror to ../mirror.  The Makefile.cluster cluster.conf recipe has the
# same logic, but Make skips it here because create-cluster-conf.sh already created
# cluster.conf -- the target file exists, so Make considers it up-to-date.
source <(normalize-cluster-conf)
_mn=${mirror_name:-mirror}
ln -sfn ../$_mn mirror
ln -sfn ~/.aba/mirror/$_mn regcreds
if [ -f mirror/mirror.conf ]; then ln -fs mirror/mirror.conf
else rm -f mirror.conf && touch mirror.conf; fi

[ "$step" ] && target="$step"

msg="Install the cluster with: aba -d $name install  OR  cd $name; aba install"
[ "$target" ] && msg="Proceed by running: aba -d $name $target  OR  cd $name; aba $target"

# Show "how to install" instructions and exit, unless a target step was given
if [ "$ask" ] && [ -z "$target" ]; then
	echo
	aba_info "The cluster directory has been created: $name"
	aba_info "$msg"
	echo

	exit 0
fi

# Let's be explicit, only run make if there is a given target, e.g. 'install' or 'iso' etc
if [ "$target" ]; then
	aba_debug "Targeting step: $target in dir: $PWD"
	exec_cmd="make -s $target"
	aba_debug "Running: $exec_cmd (in $PWD)"
	$exec_cmd
fi

