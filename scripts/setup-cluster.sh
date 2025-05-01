#!/bin/bash -e
# Create the cluster build dir

source scripts/include_all.sh

source <(normalize-aba-conf)   # Fetch the domain name

verify-aba-conf || exit 1

name=standard
type=standard

. <(process_args $*)
#echo "$*" | grep -Eq '^([a-zA-Z_]\w*=?[^ ]*)( [a-zA-Z_]\w*=?[^ ]*)*$' || { echo_red "Error: incorrect params [$*]"; exit 1; }

# eval all key value args
. <(echo $* | tr " " "\n")

if [ ! -d $name ]; then
	mkdir $name
	cd $name
	ln -fs ../templates/Makefile 
	make -s init
else
	if [ -s $name/Makefile ]; then
	       	if grep -q "Cluster Makefile" $name/Makefile; then
			cd $name 
			rm -f cluster.conf  # Refresh/overwrite the config if creating the cluster dir
			make -s clean init
		else
			echo_red "Error: Directory $name invalid cluster dir." >&2 && exit 1
		fi
	else
		cd $name
		ln -fs ../templates/Makefile 
		make -s init
	fi
fi

echo_cyan "Creating '$name/cluster.conf' file for cluster type '$type'."
scripts/create-cluster-conf.sh name=$name type=$type domain=$domain starting_ip=$starting_ip ports=$ports ingress_vip=$ingress_vip

msg="Install the cluster with 'cd $name; aba'"
[ "$target" ] && msg="Process until step '$target' with 'cd $name; aba $target'"

# adding "exit 0" here to give best practise instuctions to cd into the cluster dir!
if [ "$ask" ]; then
	echo
	echo_cyan "The cluster directory has been created: $name"
	echo_cyan "$msg"
	echo

	exit 0
fi

make -s $target

