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

install_rpm podman python3-pip
install_pip j2cli


# Mirror registry installed?
[ "$http_proxy" ] && echo "$no_proxy" | grep -q "\b$reg_host\b" || no_proxy=$no_proxy,$reg_host			  # adjust if proxy in use
reg_code=$(curl -ILsk -o /dev/null -w "%{http_code}\n" https://$reg_host:${reg_port}/health/instance || true)

if [ "$reg_code" != "200" ]; then
	echo "Installing Quay registry on host $reg_host ..."

	if ! ssh -F .ssh.conf $(whoami)@$reg_host hostname; then
		echo "Error: Can't ssh to $(whoami)@$reg_host"
		echo "Configure ssh to the host $reg_host and try again."
		exit 1
	else
		echo "Ssh access to [$reg_host] is working ..."
	fi

	echo Allowing firewall access to the registry at $reg_host/$reg_port ...
	ssh -F .ssh.conf $(whoami)@$reg_host -- "sudo firewall-cmd --state && sudo firewall-cmd --add-port=$reg_port/tcp --permanent && sudo firewall-cmd --reload"

	echo "Installing mirror registry on the host [$reg_host] with user $(whoami) ..."

	if [ ! "$reg_pw" ]; then
		reg_pw=$(openssl rand -base64 12)
	fi

	echo "Running command './mirror-registry install --quayHostname $reg_host --targetUsername $(whoami) --quayHostname $reg_host -k ~/.ssh/id_rsa'"

	./mirror-registry install -v \
  		--targetHostname $reg_host \
  		--targetUsername $(whoami) \
  		--quayHostname $reg_host \
  		-k ~/.ssh/id_rsa \
		--initPassword $reg_pw 

	rm -rf deps/*

	# Fetch root CA from remote host 
	if [ ! -d ~/quay-install/quay-rootCA ]; then
		mkdir -p ~/quay-install/quay-rootCA
		scp -F .ssh.conf -p $(whoami)@$reg_host:quay-install/quay-rootCA/* ~/quay-install/quay-rootCA
	fi

	#if [ -s .install.output ]; then
		# Fixme
		echo Creating json registry credentials in ./registry-creds.txt ...

		#line=$(grep -o "Quay is available at.*" .install.output)
		#reg_user=$(echo $line | awk '{print $8}' | cut -d\( -f2 | cut -d, -f1)

		reg_user=init
		reg_password=$reg_pw

		#reg_password=$(echo $line | awk '{print $9}' | cut -d\) -f1 )

		echo -n $reg_user:$reg_password > ./registry-creds.txt 
	#else
		#echo No install script output .install.output found. Cannot configure registry credentials. Exiting ... && exit 
	#fi

	# Configure the pull secret for this mirror registry 
	export reg_url=https://$reg_host:$reg_port

	# Check if the cert needs to be updated
	diff ~/quay-install/quay-rootCA/rootCA.pem /etc/pki/ca-trust/source/anchors/rootCA.pem 2>/dev/null >&2 || \
		sudo cp ~/quay-install/quay-rootCA/rootCA.pem /etc/pki/ca-trust/source/anchors/ && \
			sudo update-ca-trust extract

	echo -n "Checking registry access is working using 'podman login': "
	podman login -u init -p $reg_password $reg_url 

	reg_creds=$(cat ./registry-creds.txt)
	scripts/create-containers-auth.sh

	cp ~/quay-install/quay-rootCA/rootCA.pem deps/

fi

