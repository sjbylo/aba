#!/bin/bash -e
# Create the cluster dir

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

source <(normalize-aba-conf)   # Fetch the domain name
verify-aba-conf || exit 1

# Set defaults
name=standard
type=standard

. <(process_args $*)

[ ! "$name" ] && aba_abort "Error: cluster name misssing!" 

if [ ! -d "$name" ]; then
	mkdir $name
	cd $name
	ln -fs ../templates/Makefile 
	make -s init
else
	if [ -s $name/Makefile ]; then
	       	if grep -q "Cluster Makefile" $name/Makefile; then
			cd $name 
			#rm -f $name/cluster.conf  # Refresh/overwrite the config if creating the cluster dir
			#make -s clean init  # We clean here since 'aba cluster' is meant to cerate a fresh/new cluster dir and not re-use it.
			make -s       init  # Allow the dir to be "re-used",. i.e. don't touch any already created artifacts (cluster.con, agent*yaml, iso etc) 
		else
			aba_abort "Error: Directory $name invalid cluster dir."
		fi
	else
		cd $name
		ln -fs ../templates/Makefile 
		make -s init
	fi
fi

aba_info "Creating '$name/cluster.conf' file for cluster type '$type'."

create_cluster_cmd="scripts/create-cluster-conf.sh name=$name type=$type domain=$domain starting_ip=$starting_ip ports=$ports ingress_vip=$ingress_vip master_cpu_count=$master_cpu_count master_mem=$master_mem worker_cpu_count=$worker_cpu_count worker_mem=$worker_mem data_disk=$data_disk api_vip=$api_vip ingress_vip=$ingress_vip"

aba_debug Running: $create_cluster_cmd

$create_cluster_cmd

[ "$step" ] && target="$step"

msg="Install the cluster with 'aba -d $name install OR cd $name; aba install'"
[ "$target" ] && msg="Proceed with command: $target by runing: aba -d $name $target  OR  cd $name; aba $target"

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
	aba_info "Running: make -s $target" >&2
	make -s $target
fi

exit 0

