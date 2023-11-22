#!/bin/bash 
# Script to generate the agent-config.yaml and install-config.yaml files

[ ! "$1" ] && echo Usage: `basename $0` --dir directory && exit 1
[ "$DEBUG_ABA" ] && set -x

DIR=$1.src

# Ensure govc can access vCenter or ESXi
if [ ! -s ~/.vmware.conf ]; then
	mkdir -p $DIR 
	touch $DIR/agent.x86_64.iso.uploaded
	cp common/templates/vmware.conf ~/.vmware.conf

	echo 
	echo "Please edit the values in ~/.vmware.conf to enable authentication with vCenter/ESXi.  Hit return key to continue or Ctr-C to abort."
	read yn
	vi ~/.vmware.conf
	. ~/.vmware.conf
	echo Testing connection to VMware:

	echo Checking if govc is installed ...
	which govc 2>/dev/null || \
		curl -sL -o - "https://github.com/vmware/govmomi/releases/latest/download/govc_$(uname -s)_$(uname -m).tar.gz" | tar -C ~/bin -xvzf - govc

	govc about || exit 1

	echo Connection working

	govc about | grep -q "^Name: .*VMware ESXi$" && [ "$VMW_FODLER" != "/ha-datacenter/vm" ]  && echo "WARNING: if you use using ESXi API, then VMW_FOLDER needs to be set to '/ha-datacenter/vm' in ~/.vmware.conf" && exit 1

	exec $0 $@
fi

# If both files are already defined, use them as is. 
if [ -s $DIR/agent-config.yaml -a -s $DIR/install-config.yaml ]
then
	# But, if aba.conf has been changed ... refresh them ...
	if [ $DIR/aba.conf -nt $DIR/agent-config.yaml -a $DIR/aba.conf -nt $DIR/install-config.yaml ]; then
		echo Removing older files: $DIR/agent-config.yaml $DIR/install-config.yaml
		rm -f $DIR/agent-config.yaml $DIR/install-config.yaml 
	else
		####echo "Using files $DIR/agent-config.yaml $DIR/install-config.yaml"
		exit 0
	fi
fi

# Ensure the top level config file is configured 
if [ ! -s $DIR/aba.conf ]; then
	mkdir -p $DIR 
	touch $DIR/agent.x86_64.iso.uploaded
	cp common/templates/aba.conf $DIR

	echo
	echo "Please edit the values in $DIR/aba.conf to define the cluster configuration"
	echo "Hit return key to continue or Ctr-C to abort."
	read yn
	vi $DIR/aba.conf
	exec $0 $@
fi

# If aba.conf is available, generate the Agent-based config files from it.
if [ -s $DIR/aba.conf ]
then
	source $DIR/aba.conf
	source ~/.mirror.conf

	# Set the rendezvous_ip to the the first master's ip
	export rendezvous_ip=$machine_ip_prefix$starting_ip_index

	SNO=
	[ $num_masters -eq 1 -a $num_workers -eq 0 ] && SNO=1

	echo Validating the cluster configuraiton ...

	echo Checking master count is valid ...
	[ $num_masters -ne 1 -a $num_masters -ne 3 ] && echo "Error: number of masters can only be '1' or '3'" && exit 1

	echo Checking SNO config ...
	[ $num_masters -eq 1 -a $num_workers -ne 0 ] && echo "Error: number of workers must be '0' if number of masters is '1 (SNO)" && exit 1

	# If not SNO, then ensure api_vip and ingress_vip are defined 
	echo Checking api_vip and ingress_vip are defined ...
	if [ ! "$SNO" ]; then
		[ ! "$api_vip" -o ! "$ingress_vip" ] && echo "Error: 'api_vip' and 'ingress_vip' must be defined for this configuration" && exit 1
	fi


	export pull_secret=
	export ssh_key_pub=
	export additional_trust_bundle=
	export image_content_sources=

	pull_secret_mirror_file=pull-secret-mirror.json  

	# Generate the needed agent-based config files ...

	# Read in the needed files ...
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

	echo Checking if dig is installed ...
	which dig 2>/dev/null >&2 || sudo dnf install bind-utils -y

	ip_api=$(dig +short api.$cluster_name.$base_domain)
	ip_apps=$(dig +short x.apps.$cluster_name.$base_domain)

	# If NOT SNO...
	##if [ $num_masters -ne 1 -o $num_workers -ne 0 ]; then
	if [ ! "$SNO" ]; then
		# Ensure api DNS exists 
		[ "$ip_api" != "$api_vip" ] && echo "WARNING: DNS record [api.$cluster_name.$base_domain] does not resolve to [$api_vip]" && exit 1

		# Ensure apps DNS exists 
		[ "$ip_apps" != "$ingress_vip" ] && echo "WARNING: DNS record [\*.apps.$cluster_name.$base_domain] does not resolve to [$ingress_vip]" && exit 1
	else
		# Check values are pointing to "rendezvous_ip"
		# Ensure api DNS exists 
		[ "$ip_api" != "$rendezvous_ip" ] && \
			echo "WARNING: DNS record [api.$cluster_name.$base_domain] does not resolve to the rendezvous ip [$rendezvous_ip]" && exit 1

		# Ensure apps DNS exists 
		[ "$ip_apps" != "$rendezvous_ip" ] && \
			echo "WARNING: DNS record [\*.apps.$cluster_name.$base_domain] does not resolve to the rendezvous ip [$rendezvous_ip]" && exit 1
	fi

	# Ensure registry dns entry exists and points to the bastion's ip
	ip=$(dig +short $reg_host)
	ip_int=$(ip route get 1 | grep -oP 'src \K\S+')
	[ "$ip" != "$ip_int" ] && echo "WARNING: DNS record [$reg_host] is not resolvable!" && exit 1

	# Use j2cli to render the templates
	echo Generating Agent-based configuration files: $DIR/agent-config.yaml and $DIR/install-config.yaml 
	##[ ! -s $DIR/agent-config.yaml ] && \
	[ $DIR/aba.conf -nt $DIR/agent-config.yaml ] && \
		j2 common/templates/agent-config.yaml.j2   -o $DIR/agent-config.yaml   || echo WARNING: not overwriting $DIR/agent-config.yaml

	#[ ! -s $DIR/install-config.yaml ] && \
	[ $DIR/aba.conf -nt $DIR/install-config.yaml ] && \
		j2 common/templates/install-config.yaml.j2 -o $DIR/install-config.yaml || echo WARNING: not overwriting $DIR/install-config.yaml

	echo Generating image ...
	bin/generate-image.sh $@ || exit 

	exec $0 $@
fi


