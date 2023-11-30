#!/bin/bash -e

. scripts/include_all.sh

[ "$1" ] && set -x

umask 077

source mirror.conf

echo "Ensure dependencies installed (podman python3-pip j2) ..."
inst=
# not needed rpm -q --quiet nmstate|| inst=1
# rpm -q --quiet podman || inst=1
# not needed rpm -q --quiet jq     || inst=1

### not needed [ "$inst" ] && sudo dnf install podman jq nmstate python3-pip -y >/dev/null 2>&1

which j2 >/dev/null 2>&1 || pip3 install j2cli  >/dev/null 2>&1

# Mirror registry installed?
[ "$http_proxy" ] && echo "$no_proxy" | grep -q "\b$reg_host\b" || no_proxy=$no_proxy,$reg_host			  # adjust if proxy in use
reg_code=$(curl -ILsk -o /dev/null -w "%{http_code}\n" https://$reg_host:${reg_port}/health/instance || true)

if [ "$reg_code" != "200" ]; then
	echo "Installing Quay registry on host $reg_host ..."

#	# Ensure registry dns entry exists and points to the bastion's ip
#	ip=$(dig +short $reg_host)
#	ip_int=$(ip route get 1 | grep -oP 'src \K\S+')

	# Host is remote 
#	if [ "$ip" != "$ip_int" ]; then

		if ! ssh $(whoami)@$reg_host hostname; then
			echo "Error: Can't ssh to $(whoami)@$reg_host"
			echo "Configure ssh to the host $reg_host and try again."
			exit 1
		else
			echo "Ssh access to [$reg_host] is working ..."
		fi

		echo "Installing mirror registry on the host [$reg_host] with user $(whoami) ..."

		echo "Running command './mirror-registry install --quayHostname $reg_host --targetUsername $(whoami) --quayHostname $reg_host -k ~/.ssh/id_rsa'"
		if [ "$reg_pw" ]; then
			set_pw="--initPassword $reg_pw"
			echo "Running command './mirror-registry install --quayHostname $reg_host --targetUsername $(whoami) --quayHostname $reg_host -k ~/.ssh/id_rsa'"
			./mirror-registry install -v \
		  		--targetHostname $reg_host \
		  		--targetUsername $(whoami) \
		  		--quayHostname $reg_host \
		  		-k ~/.ssh/id_rsa \
				--initPassword $reg_pw | tee .install.output || rm -f .install.output
		else
			./mirror-registry install -v \
		  		--targetHostname $reg_host \
		  		--targetUsername $(whoami) \
		  		--quayHostname $reg_host \
		  		-k ~/.ssh/id_rsa \
					| tee .install.output || rm -f .install.output
		fi

		#--quayRoot <example_1directory_name>

		# Fetch root CA from remote host so the connection can be tested
		if [ ! -d ~/quay-install/quay-rootCA ]; then
			mkdir -p ~/quay-install/quay-rootCA
			scp -p $(whoami)@$reg_host:quay-install/quay-rootCA/* ~/quay-install/quay-rootCA
		fi
	#else
		#[ "$http_proxy" ] && echo "$no_proxy" | grep -q "\blocalhost\b" || no_proxy=$no_proxy,localhost 		  # adjust if proxy in use
		#res_local=$(curl -ILsk -o /dev/null -w "%{http_code}\n" https://localhost:${reg_port}/health/instance || true)
		#
		#[ $res_local -eq 200 ] && echo "Registry already installed on localhost [$reg_host]" && exit 
		#
		#echo "Installing mirror registry on the localhost [$reg_host] ..."
		#echo "Running command './mirror-registry install --quayHostname $reg_host'"
		#./mirror-registry install --quayHostname $reg_host | tee .install.output || rm -f .install.output
		## Sample output of the above command
		## Quay is available at https://registry.lan:8443 with credentials (init, cG79mTdkAo0P3ZgLsy12VMi56NU48nla)
	#fi

	if [ -s .install.output ]; then
		echo Creating json registry credentials in ./registry-creds.txt ...
		line=$(grep -o "Quay is available at.*" .install.output)
		reg_user=$(echo $line | awk '{print $8}' | cut -d\( -f2 | cut -d, -f1)
		reg_password=$(echo $line | awk '{print $9}' | cut -d\) -f1 )
		echo -n $reg_user:$reg_password > ./registry-creds.txt 
	else
		echo No install script output .install.output found. Cannot configure registry credentials. Exiting ... && exit 
	fi

	echo Allowing access to the registry port [reg_port] ...
	ssh $(whoami)@$reg_host sudo firewall-cmd --state && sudo firewall-cmd --add-port=$reg_port/tcp --permanent && sudo firewall-cmd --reload
#else
	###echo 
	###echo WARNING: 
	###echo "Registry detected on localhost at https://localhost:${reg_port}/health/instance"

#	echo "This script does not yet support the use of an existing registry and needs to install Quay registry on this host (bastion) itself."
#	echo "If aba installed the detected registry, then continue to use it".
#
#	if [ "$res_remote" = "200" ]; then
#		echo 
#		echo "A registry was also detected at https://$reg_host:${reg_port}/health/instance"
##	fi
#	exit 1
fi

export reg_url=https://$reg_host:$reg_port

reg_creds=$(cat ./registry-creds.txt)

echo Checking registry access is working using "podman login" ...
podman login -u init -p $reg_password $reg_url --tls-verify=false 

scripts/create-containers-auth.sh

# Check if the cert needs to be updated
diff ~/quay-install/quay-rootCA/rootCA.pem /etc/pki/ca-trust/source/anchors/rootCA.pem 2>/dev/null >&2|| \
	sudo cp ~/quay-install/quay-rootCA/rootCA.pem /etc/pki/ca-trust/source/anchors/ && \
	sudo update-ca-trust extract

echo Generating imageContentSourcePolicy.yaml ...
j2 ./templates/image-content-sources.yaml.j2 > ./deps/image-content-sources.yaml
#ln -fs ./install-quay/image-content-sources.yaml ./deps

cp ~/quay-install/quay-rootCA/rootCA.pem deps/
