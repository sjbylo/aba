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

#install_rpm podman python3-pip
install_rpm podman 
#install_pip j2cli

if [ -s deps/rootCA.pem -a -s deps/pull-secret-mirror.json ]; then

	# Check if the cert needs to be updated
	sudo diff deps/rootCA.pem /etc/pki/ca-trust/source/anchors/rootCA-existing.pem 2>/dev/null >&2 || \
		sudo cp deps/rootCA.pem /etc/pki/ca-trust/source/anchors/rootCA-existing.pem && \
			sudo update-ca-trust extract

	podman logout --all 
	echo -n "Checking registry access is working using 'podman login': "
	export reg_url=https://$reg_host:$reg_port
	podman login --authfile deps/pull-secret-mirror.json $reg_url 

	echo "Valid existing registry credential files found in mirror/deps/.  Using existing registry."

	exit 0
fi

# Mirror registry installed?
[ "$http_proxy" ] && echo "$no_proxy" | grep -q "\b$reg_host\b" || no_proxy=$no_proxy,$reg_host		  # adjust if proxy in use
reg_code=$(curl -ILsk -o /dev/null -w "%{http_code}\n" https://$reg_host:${reg_port}/health/instance || true)

if [ "$reg_code" = "200" ]; then
	echo "Registry found at $reg_host:$reg_port. "
	
	echo
	echo "If this registry is your existing registry, copy this registry's pull secret and root CA files into 'mirror/deps'."
	echo -n "See the README for instructions.  Hit RETURN to continue: "
	echo 
	read yn

	exit 0
fi


if [ "$reg_root" ]; then
	# FIXME
	#reg_root_opt="--quayRoot $reg_root --quayStorage ${reg_root}-storage"
	reg_root_opt="--quayStorage ${reg_root}-storage"
else
	reg_root=$HOME/quay-install
fi

##if [ "$reg_code" != "200" ]; then

# remote installs
if [ "$reg_ssh" ]; then
	echo "Installing Quay registry on remote host $reg_host ..."

	# FIXME: We are using ssh, even if the registry is installed locally. 
	###[ ! -s ~/.ssh/id_rsa ] && mkdir -p ~/.ssh && ssh-keygen -b 2048 -t rsa -f ~/.ssh/id_rsa -N ""

	if ! ssh -F .ssh.conf $(whoami)@$reg_host hostname; then
		echo "Error: Can't ssh to $(whoami)@$reg_host"
		echo "Configure ssh to the host $reg_host and try again."
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

	echo "Running command './mirror-registry install --quayHostname $reg_host --targetUsername $(whoami) --taregtHostname $reg_host -k ~/.ssh/id_rsa --initPassword <hidden> $reg_root_opt'"

	./mirror-registry install -v \
  		--quayHostname $reg_host \
  		--targetUsername $(whoami) \
  		--targetHostname $reg_host \
  		-k ~/.ssh/id_rsa \
		--initPassword $reg_pw $reg_root_opt

	rm -rf deps/*

	reg_user=init

	echo -n $reg_user:$reg_pw > registry-creds.txt 

	# Configure the pull secret for this mirror registry 
	export reg_url=https://$reg_host:$reg_port

	# Fetch root CA from remote host 
	scp -F .ssh.conf -p $(whoami)@$reg_host:$reg_root/quay-rootCA/rootCA.pem deps/

	# Check if the cert needs to be updated
	sudo diff deps/rootCA.pem /etc/pki/ca-trust/source/anchors/rootCA.pem 2>/dev/null >&2 || \
		sudo cp deps/rootCA.pem /etc/pki/ca-trust/source/anchors/ && \
			sudo update-ca-trust extract

	podman logout --all 
	echo -n "Checking registry access is working using 'podman login': "
	podman login -u init -p $reg_pw $reg_url 

	reg_creds=$(cat registry-creds.txt)
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

	rm -rf deps/*

	echo Creating json registry credentials in registry-creds.txt ...

	reg_user=init

	echo -n $reg_user:$reg_pw > registry-creds.txt 

	# Configure the pull secret for this mirror registry 
	export reg_url=https://$reg_host:$reg_port

	cp $reg_root/quay-rootCA/rootCA.pem deps/

	# Check if the cert needs to be updated
	sudo diff deps/rootCA.pem /etc/pki/ca-trust/source/anchors/rootCA.pem 2>/dev/null >&2 || \
		sudo cp deps/rootCA.pem /etc/pki/ca-trust/source/anchors/ && \
			sudo update-ca-trust extract

	podman logout --all 
	echo -n "Checking registry access is working using 'podman login': "
	podman login -u init -p $reg_pw $reg_url 

	reg_creds=$(cat registry-creds.txt)
	scripts/create-containers-auth.sh
fi

