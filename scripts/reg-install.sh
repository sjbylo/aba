#!/bin/bash 

source scripts/include_all.sh

[ "$1" ] && set -x

umask 077

source mirror.conf

cat > .ssh.conf <<END
StrictHostKeyChecking no
UserKnownHostsFile=/dev/null
ConnectTimeout=15
END

install_rpm podman 

# Check for existing reg.creds (provided by user)
#if [ -s regcreds/rootCA.pem -a -s regcreds/pull-secret-mirror.json ]; then
if [ -s regcreds/pull-secret-mirror.json ]; then

	###
	sudo rm -vf /etc/pki/ca-trust/source/anchors/rootCA*.pem
	sudo update-ca-trust extract
	###

	reg_url=https://$reg_host:$reg_port

	#if [ "$tls_verify" -a -s regcreds/rootCA.pem ]; then
	if [ -s regcreds/rootCA.pem ]; then
		# Check if the cert needs to be updated
		sudo diff regcreds/rootCA.pem /etc/pki/ca-trust/source/anchors/rootCA-existing.pem 2>/dev/null >&2 || \
			sudo cp regcreds/rootCA.pem /etc/pki/ca-trust/source/anchors/rootCA-existing.pem && \
				sudo update-ca-trust extract && \
					echo "Cert 'regcreds/rootCA.pem' updated in system"
	fi

	[ ! "$tls_verify" ] && tls_verify_opts="--tls-verify=false"

	podman logout --all 
	echo -n "Checking registry access is working using 'podman login': "
	podman login $tls_verify_opts --authfile regcreds/pull-secret-mirror.json $reg_url 

	echo "Valid registry credential files found in mirror/regcreds/.  Using existing registry $reg_url"

	exit 0
fi

# Mirror registry already installed?
[ "$http_proxy" ] && echo "$no_proxy" | grep -q "\b$reg_host\b" || no_proxy=$no_proxy,$reg_host		  # adjust if proxy in use
reg_code=$(curl -ILsk -o /dev/null -w "%{http_code}\n" https://$reg_host:${reg_port}/health/instance || true)

if [ "$reg_code" = "200" ]; then
	echo "Quay registry found at $reg_host:$reg_port. "
	echo
	echo "If this registry is your existing registry, copy this registry's pull secret and root CA files into 'mirror/regcreds/'."
	echo -n "See the README for instructions.  Hit RETURN to continue: "
	echo 
	read yn

	exit 1
fi

# Has user defined a registry root dir?
if [ "$reg_root" ]; then
	# FIXME
	#reg_root_opt="--quayRoot $reg_root --quayStorage ${reg_root}-storage"
	reg_root_opt="--quayStorage ${reg_root}-storage"
else
	# The default path
	reg_root=$HOME/quay-install
fi

# Remote installs if ssh key defined 
if [ "$reg_ssh" ]; then
	# Workaround START
	# See: https://access.redhat.com/solutions/7040517
	# Check for known issue where images need to be loaded on the remote host first
	# This will load the needed images and fix the problem 
	# Only need to do this workaround once
	ssh -F .ssh.conf $(whoami)@$reg_host "rpm -q podman || sudo dnf install podman -y"
	ssh -F .ssh.conf $(whoami)@$reg_host podman images | grep -q ^registry.access.redhat.com/ubi8/pause || \
	(
		
		ssh -F .ssh.conf $(whoami)@$reg_host mkdir -p .abatmp
		scp -F .ssh.conf mirror-registry.tar.gz $(whoami)@$reg_host:.abatmp/
		ssh -F .ssh.conf $(whoami)@$reg_host "cd .abatmp && tar xmzf mirror-registry.tar.gz"
		ssh -F .ssh.conf $(whoami)@$reg_host "cd .abatmp && ./mirror-registry install"
		ssh -F .ssh.conf $(whoami)@$reg_host "cd .abatmp && ./mirror-registry uninstall --autoApprove"
		ssh -F .ssh.conf $(whoami)@$reg_host rm -rf .abatmp 
	)
	# Workaround END
			
	echo "Installing Quay registry on remote host $reg_host ..."

	# If the key is missing, then generate one
	[ ! -s $reg_ssh ] && ssh-keygen -t rsa -f $reg_ssh -N ''

	if ! ssh -F .ssh.conf $(whoami)@$reg_host hostname; then
		echo "Error: Can't ssh to $(whoami)@$reg_host"
		echo "Configure passwordless ssh to the host $reg_host and try again."
		exit 1
	else
		echo "Ssh access to [$reg_host] is working ..."
	fi

	echo Allowing firewall access to the registry at $reg_host/$reg_port ...
	ssh -F .ssh.conf $(whoami)@$reg_host -- "sudo firewall-cmd --state && \
		sudo firewall-cmd --add-port=$reg_port/tcp --permanent && \
			sudo firewall-cmd --reload"

	echo "Installing mirror registry on the host [$reg_host] with user $(whoami) ..."

	if [ ! "$reg_pw" ]; then
		reg_pw=$(openssl rand -base64 12)
	fi

	echo "Running command './mirror-registry install --quayHostname $reg_host --targetUsername $(whoami) --targetHostname $reg_host -k $reg_ssh --initPassword <hidden> $reg_root_opt'"

	./mirror-registry install -v \
  		--quayHostname $reg_host \
  		--targetUsername $(whoami) \
  		--targetHostname $reg_host \
  		-k $reg_ssh \
		--initPassword $reg_pw $reg_root_opt

	# Generate the script to be used to delete this registry
	cmd="./mirror-registry uninstall --targetUsername $(whoami) --targetHostname $reg_host -k $reg_ssh --autoApprove"
	echo "echo Running command \"$cmd\"" > ./reg-uninstall.sh
	echo "$cmd" >> ./reg-uninstall.sh

	rm -rf regcreds/*

	reg_user=init

	echo -n $reg_user:$reg_pw > .registry-creds.txt 

	# Configure the pull secret for this mirror registry 
	export reg_url=https://$reg_host:$reg_port

	# Fetch root CA from remote host 
	scp -F .ssh.conf -p $(whoami)@$reg_host:$reg_root/quay-rootCA/rootCA.pem regcreds/

	# Check if the cert needs to be updated
	sudo diff regcreds/rootCA.pem /etc/pki/ca-trust/source/anchors/rootCA.pem 2>/dev/null >&2 || \
		sudo cp regcreds/rootCA.pem /etc/pki/ca-trust/source/anchors/ && \
			sudo update-ca-trust extract

	podman logout --all 
	echo -n "Checking registry access is working using 'podman login': "
	podman login -u init -p $reg_pw $reg_url 

	reg_creds=$(cat .registry-creds.txt)
	scripts/create-containers-auth.sh

else
	echo "Installing Quay registry on localhost ..."

	echo Allowing firewall access on localhost to the registry at $reg_host/$reg_port ...
	sudo firewall-cmd --state && \
		sudo firewall-cmd --add-port=$reg_port/tcp --permanent && \
			sudo firewall-cmd --reload

	echo "Installing mirror registry on localhost ..."

	if [ ! "$reg_pw" ]; then
		reg_pw=$(openssl rand -base64 12)
	fi

	echo "Running command './mirror-registry install --quayHostname $reg_host $reg_root_opt'"

	./mirror-registry install -v \
  		--quayHostname $reg_host \
		--initPassword $reg_pw $reg_root_opt

	# Generate the script to be used to delete this registry
	cmd="./mirror-registry uninstall --autoApprove"
	echo "echo Running command  \"$cmd\"" > ./reg-uninstall.sh
	echo "$cmd" >> ./reg-uninstall.sh

	rm -rf regcreds/*

	reg_user=init

	echo -n $reg_user:$reg_pw > .registry-creds.txt 

	# Configure the pull secret for this mirror registry 
	export reg_url=https://$reg_host:$reg_port

	cp $reg_root/quay-rootCA/rootCA.pem regcreds/

	# Check if the cert needs to be updated
	sudo diff regcreds/rootCA.pem /etc/pki/ca-trust/source/anchors/rootCA.pem 2>/dev/null >&2 || \
		sudo cp regcreds/rootCA.pem /etc/pki/ca-trust/source/anchors/ && \
			sudo update-ca-trust extract

	podman logout --all 
	echo -n "Checking registry access is working using 'podman login': "
	podman login -u init -p $reg_pw $reg_url 

	reg_creds=$(cat .registry-creds.txt)
	scripts/create-containers-auth.sh
fi

