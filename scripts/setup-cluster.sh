#!/bin/bash -e
# Create the cluster dir

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

source <(normalize-aba-conf)   # Fetch the domain name
verify-aba-conf || aba_abort "$_ABA_CONF_ERR"

# Set defaults
name=standard
type=standard

. <(process_args $*)

[ ! "$name" ] && aba_abort "Error: cluster name misssing!" 

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

if [ -s cluster.conf ]; then
	aba_info "Using existing '$name/cluster.conf'."
else
	aba_info "Creating '$name/cluster.conf' file for cluster type '$type'."
fi

exec_cmd="scripts/create-cluster-conf.sh name=$name type=$type domain=$domain starting_ip=$starting_ip ports=$ports ingress_vip=$ingress_vip master_cpu_count=$master_cpu_count master_mem=$master_mem worker_cpu_count=$worker_cpu_count worker_mem=$worker_mem data_disk=$data_disk api_vip=$api_vip ingress_vip=$ingress_vip num_workers=$num_workers num_masters=$num_masters vlan=$vlan ssh_key_file=$ssh_key_file mirror_name=$mirror_name"

aba_debug "Running: $exec_cmd"

$exec_cmd

# Apply any CLI-passed values to cluster.conf (only writes if value differs).
# Handles the case where cluster.conf already existed and
# create-cluster-conf.sh exited early ([ -s cluster.conf ] && exit 0).
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

[ "$step" ] && target="$step"

msg="Install the cluster with: aba -d $name install  OR  cd $name; aba install"
[ "$target" ] && msg="Proceed by running: aba -d $name $target  OR  cd $name; aba $target"

# adding "exit 0" here to give best practise instuctions to cd into the cluster dir!
if [ "$ask" ]; then
	echo
	aba_info "The cluster directory has been created: $name"
	aba_info "$msg"
	echo

	exit 0
fi

# Let's be explicit, only run make if there is a given target, e.g. 'install' or 'iso' etc
if [ "$target" ]; then
	aba_info "Targeting step: $target in dir: $PWD" >&2
	exec_cmd="make -s $target"
	aba_debug "Running: $exec_cmd (in $PWD)"
	$exec_cmd
fi

