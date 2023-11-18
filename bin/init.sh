#!/bin/bash 
# Script to generate the agent-config.yaml and install-config.yaml files

DIR=$1.src

echo Checking if govc is installed
which govc 2>/dev/null || \
	curl -sL -o - "https://github.com/vmware/govmomi/releases/latest/download/govc_$(uname -s)_$(uname -m).tar.gz" | tar -C ~/bin -xvzf - govc

echo Checking if dig is installed
which dig 2>/dev/null || sudo dnf install bind-utils -y


# Ensure govc can access vCenter or ESXi
if [ ! -s ~/.vmware.conf ]; then
	mkdir -p $DIR 
	cp common/templates/vmware.conf ~/.vmware.conf
	echo "Please edit the values in ~/.vmware.conf to enable authentication with vCenter/ESXi"
	read -t 5 yn
	vi ~/.vmware.conf
	. ~/.vmware.conf
	echo Testing connection to VMware:
	govc about || exit 1
	exec $0 $@
fi

# If both files are already defined, use them as is. 
if [ -s $DIR/agent-config.yaml -a -s $DIR/install-config.yaml ]
then
	exit 0
fi

# Ensure the top level config file is configured 
if [ ! -s $DIR/aba.conf ]; then
	mkdir -p $DIR 
	cp common/templates/aba.conf $DIR
	echo "Please edit the values in $DIR/aba.conf to define the cluster configuration"
	read -t 5 yn
	vi $DIR/aba.conf
	exec $0 $@
fi

# If the files already exist, try to use them, don't overwrite them
if [ -s $DIR/aba.conf -a ! -s $DIR/agent-config.yaml -a ! -s $DIR/install-config.yaml ]
then
	source $DIR/aba.conf

	# Set the rendezvous_ip to the the first master's ip
	export rendezvous_ip=$machine_ip_prefix$starting_ip_index

	# Some validation 
	[ $num_masters -ne 1 -a $num_masters -ne 3 ] && echo "Error: number of masters can only be '1' or '3'" && exit 1
	[ $num_masters -eq 1 -a $num_workers -ne 0 ] && echo "Error: number of workers must be '0' if number of masters is '1 (SNO)" && exit 1
	# If not SNO, then ensure api_vip and ingress_vip are defined 
	if [ $num_masters -eq 1 -a $num_workers -eq 0 ]; then
		:
	else
		# if not SNO
		[ ! "$api_vip" -o ! "$ingress_vip" ] && echo "Error: api_vip and ingress_vip must be defined for this configuration" && exit 1
	fi

set -x

	export pull_secret=
	export ssh_key_pub=
	export additional_trust_bundle=
	export image_content_sources=

	pull_secret_mirror_file=pull-secret-mirror.json  # FIXME add to config file?
	[ -s install-mirror/$pull_secret_mirror_file ] && \
		export pull_secret=$(cat install-mirror/$pull_secret_mirror_file) || \
		echo WARNING: No pull secret file found at install-mirror/$pull_secret_mirror_file
	[ -s $additional_trust_bundle_file ] && \
		export additional_trust_bundle=$(cat $additional_trust_bundle_file) || \
		echo WARNING: No key $additional_trust_bundle_file
	[ -s $ssh_key_file ] && \
		export ssh_key_pub=$(cat $ssh_key_file) || \
		echo WARNING: No file $ssh_key_file ...
	[ -s install-mirror/$image_content_sources_file ] && \
		export image_content_sources=$(cat install-mirror/$image_content_sources_file) || \
		echo WARNING: No file install-mirror/$image_content_sources_file ...

#export additional_trust_bundle_file=~/quay-install/quay-rootCA/rootCA.pem
#export ssh_key_file=~/.ssh/id_rsa.pub
#export image_content_sources_file=image-content-sources.yaml

	
#export cluster_name=ocp1
#export base_domain=example.com
## Set your ingress and api IP addresses (ignored for single node OpenShift (SNO)
#export api_vip="10.0.1.216"
#export ingress_vip="10.0.1.226

	# If NOT SNO...
	if [ $num_masters -ne 1 -o $num_workers -ne 0 ]; then

		# Ensure api DNS exists 
		ip=$(dig +short api.$cluster_name.$base_domain)
		[ ! "$ip" = "$api_vip" ] && echo "WARNING: DNS record api.$cluster_name.$base_domain not resolvable!" && exit 1

		# Ensure apps DNS exists 
		ip=$(dig +short x.apps.$cluster_name.$base_domain)
		[ ! "$ip" = "$ingress_vip" ] && echo "WARNING: DNS record \*.apps.$cluster_name.$base_domain not resolvable!" && exit 1
	fi

#export reg_host=registry.example.com
#export reg_port=8443
#export reg_path=openshift4

	# Ensure registry dns entry exists 
	ip=$(dig +short $reg_host)
	ip_int=$(ip route get 1 | grep -oP 'src \K\S+')
	[ ! "$ip" = "$ip_int" ] && echo "WARNING: DNS record $reg_host is not resolvable!" && exit 1


	# Use j2cli to render the templates
	j2 common/templates/agent-config.yaml.j2 -o $DIR/agent-config.yaml 
	j2 common/templates/install-config.yaml.j2 -o $DIR/install-config.yaml 

	exec $0 $@
fi

