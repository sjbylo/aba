#!/bin/bash 

source scripts/include_all.sh

[ "$1" ] && set -x

umask 077

source <(normalize-aba-conf)
source <(normalize-mirror-conf)

[ ! "$reg_ssh_user" ] && reg_ssh_user=$(whoami)

export reg_url=https://$reg_host:$reg_port

###if [ -s regcreds/rootCA.pem -a -s regcreds/pull-secret-mirror.json ]; then

# Check if 'registry' credentials exist, e.g. provided by user or auto-generated by mirror installer 
# For existing registry, user must provide the 'regcreds/pull-secret-mirror.json' and the 'regcreds/rootCA.pem' files. 
if [ -s regcreds/pull-secret-mirror.json ]; then

	scripts/reg-verify.sh
	exit
fi

# Detect any existing mirror registry?

# Check for Quay...
[ "$http_proxy" ] && echo "$no_proxy" | grep -q "\b$reg_host\b" || no_proxy=$no_proxy,$reg_host		  # adjust if proxy in use
reg_code=$(curl -ILsk -o /dev/null -w "%{http_code}\n" https://$reg_host:${reg_port}/health/instance || true)

if [ "$reg_code" = "200" ]; then
	[ "$TERM" ] && tput setaf 1
	echo
	echo "Warning: Quay registry found at $reg_host:$reg_port."
	echo "         To use this registry, copy its pull secret file and root CA file into 'mirror/regcreds/' and try again."
	echo "         The files must be named 'regcreds/pull-secret-mirror.json' and 'regcreds/rootCA.pem' respectively."
	echo "         The pull secret file can also be created and verified using 'make password'"
	echo "         See the README.md for further instructions."
	echo 
	[ "$TERM" ] && tput sgr0

	exit 1
fi

# Check for any endpoint ...
reg_code=$(curl -ILsk -o /dev/null -w "%{http_code}\n" https://$reg_host:${reg_port}/ || true)

if [ "$reg_code" = "200" ]; then
	[ "$TERM" ] && tput setaf 1
	echo
	echo "Warning: Endpoint found at $reg_host:$reg_port."
	echo "         If this is your existing registry, copy its pull secret file and root CA file into 'mirror/regcreds/' and try again."
	echo "         The files must be named 'regcreds/pull-secret-mirror.json' and 'regcreds/rootCA.pem' respectively."
	echo "         The pull secret file can also be created and verified using 'make password'"
	echo "         See the README.md for further instructions."
	echo 
	[ "$TERM" ] && tput sgr0

	exit 1
fi

# Has user defined a registry root dir?
if [ "$reg_root" ]; then
	if echo "$reg_root" | grep -q ^~; then
		# We will replace ~ with /home/$reg_ssh_user
		reg_root=$(echo "$reg_root" | sed "s#~#/home/$reg_ssh_user#g")
	fi

	echo "Using registry root dir: $reg_root"
	reg_root_opt="--quayRoot $reg_root --quayStorage $reg_root/quay-storage --pgStorage $reg_root/pg-data"
else
	# The default path
	##reg_root=$HOME/quay-install
	##reg_root=~/quay-install
	#reg_root=~$reg_ssh_user/quay-install  # This must be the path *where Quay will be installed*
	reg_root=/home/$reg_ssh_user/quay-install  # This must be the path *where Quay will be installed*
	echo "Using default registry root dir: $reg_root"
fi


cat > .ssh.conf <<END
StrictHostKeyChecking no
UserKnownHostsFile=/dev/null
ConnectTimeout=15
END

# Install Quay mirror on remote host if ssh key defined 
if [ "$reg_ssh" ]; then
	ask "Install Quay mirror registry appliance onto $reg_host?" || exit 1

	echo "Installing Quay registry on to $reg_host ..."

	if ! ssh -F .ssh.conf $reg_ssh_user@$reg_host hostname; then
		[ "$TERM" ] && tput setaf 1
		echo
		echo "Error: Can't ssh to $reg_ssh_user@$reg_host"
		echo "Configure passwordless ssh to $reg_ssh_user@$reg_host and try again."
		echo
		[ "$TERM" ] && tput sgr0

		exit 1
	else
		echo "Ssh access to [$reg_host] is working ..."
	fi

	# Workaround START ########
	# See: https://access.redhat.com/solutions/7040517 "Installing the mirror-registry to a remote disconnected host fails (on the first attempt)"
	# Check for known issue where images need to be loaded on the remote host first
	# This will load the needed images and fix the problem 
	# Only need to do this workaround once
	ssh -F .ssh.conf $reg_ssh_user@$reg_host "rpm -q podman || rpm -q jq || sudo dnf install podman jq -y"
	ssh -F .ssh.conf $reg_ssh_user@$reg_host podman images | grep -q ^registry.access.redhat.com/ubi8/pause || \
	(
		echo "Implementing workaround to install Quay on remote host ... see https://access.redhat.com/solutions/7040517 for more."
		ssh -F .ssh.conf $reg_ssh_user@$reg_host mkdir -p .abatmp
		scp -F .ssh.conf mirror-registry.tar.gz $reg_ssh_user@$reg_host:.abatmp/
		ssh -F .ssh.conf $reg_ssh_user@$reg_host "cd .abatmp && tar xmzf mirror-registry.tar.gz"
		ssh -F .ssh.conf $reg_ssh_user@$reg_host "cd .abatmp && ./mirror-registry install"
		ssh -F .ssh.conf $reg_ssh_user@$reg_host "cd .abatmp && ./mirror-registry uninstall --autoApprove"
		ssh -F .ssh.conf $reg_ssh_user@$reg_host rm -rf .abatmp 
	)
	# Workaround END ########
			
	# FIXME: this is not used
	# If the key is missing, then generate one
	[ ! -s $reg_ssh ] && ssh-keygen -t rsa -f $reg_ssh -N ''

	# Note that the mirror-registry installer does not open the port for us
	echo Allowing firewall access to the registry at $reg_host/$reg_port ...
	ssh -F .ssh.conf $reg_ssh_user@$reg_host -- "sudo firewall-cmd --state && \
		sudo firewall-cmd --add-port=$reg_port/tcp --permanent && \
			sudo firewall-cmd --reload"

	echo "Installing mirror registry on the host [$reg_host] with user $reg_ssh_user into dir $reg_root ..."

	if [ ! "$reg_pw" ]; then
		reg_pw=$(openssl rand -base64 12)
	fi

	# Generate the script to be used to delete this registry
	uninstall_cmd="./mirror-registry uninstall --targetUsername $reg_ssh_user --targetHostname $reg_host -k $reg_ssh $reg_root_opt --autoApprove -v"
	echo "reg_delete() { echo Running command: \"$uninstall_cmd\"; $uninstall_cmd;}" > ./reg-uninstall.sh.provision
	echo reg_host_to_del=$reg_host >> ./reg-uninstall.sh.provision

	echo "Running command: \"./mirror-registry install -v --quayHostname $reg_host \
		--targetUsername $reg_ssh_user --targetHostname $reg_host -k $reg_ssh --initPassword <hidden> $reg_root_opt\""

	./mirror-registry install -v \
  		--quayHostname $reg_host \
  		--targetUsername $reg_ssh_user \
  		--targetHostname $reg_host \
  		-k $reg_ssh \
		--initPassword $reg_pw $reg_root_opt

	# Now, activate the uninstall script 
	mv ./reg-uninstall.sh.provision reg-uninstall.sh

	rm -rf regcreds/*

	# Fetch root CA from remote host 
	scp -F .ssh.conf -p $reg_ssh_user@$reg_host:$reg_root/quay-rootCA/rootCA.pem regcreds/

	reg_user=init

	# Check if the cert needs to be updated
	sudo diff regcreds/rootCA.pem /etc/pki/ca-trust/source/anchors/rootCA.pem 2>/dev/null >&2 || \
		sudo cp regcreds/rootCA.pem /etc/pki/ca-trust/source/anchors/ && \
			sudo update-ca-trust extract

	[ ! "$tls_verify" ] && tls_verify_opts="--tls-verify=false"

	podman logout --all >/dev/null 
	echo -n "Checking registry access is working using 'podman login' ... "
	echo "Running: podman login $tls_verify_opts -u $reg_user -p $reg_pw $reg_url"
	podman login $tls_verify_opts -u $reg_user -p $reg_pw $reg_url 

	# Configure the pull secret for this mirror registry 
	echo "Generating regcreds/pull-secret-mirror.json file"

	export enc_password=$(echo -n "$reg_user:$reg_pw" | base64 -w0)

	# Inputs: enc_password, reg_host and reg_port 
	scripts/j2 ./templates/pull-secret-mirror.json.j2 > ./regcreds/pull-secret-mirror.json

	scripts/create-containers-auth.sh
else
	ask "Install Quay mirror registry appliance onto localhost `hostname`?" || exit 1

	echo "Installing Quay registry on localhost ..."

	# mirror-registry installer does not open the port for us
	echo Allowing firewall access on localhost to the registry at $reg_host/$reg_port ...
	sudo firewall-cmd --state && \
		sudo firewall-cmd --add-port=$reg_port/tcp --permanent && \
			sudo firewall-cmd --reload

	if [ ! "$reg_pw" ]; then
		reg_pw=$(openssl rand -base64 12)
	fi

	# Generate the script to be used to delete this registry
	uninstall_cmd="./mirror-registry uninstall --autoApprove $reg_root_opt -v"
	echo "reg_delete() { echo Running command: \"$uninstall_cmd\"; $uninstall_cmd;}" > ./reg-uninstall.sh.provision
	echo reg_host_to_del=$reg_host >> ./reg-uninstall.sh.provision

	echo "Running command: \"./mirror-registry install -v --quayHostname $reg_host $reg_root_opt\""

	./mirror-registry install -v \
  		--quayHostname $reg_host \
		--initPassword $reg_pw $reg_root_opt

	# Now, activate the uninstall script 
	mv ./reg-uninstall.sh.provision reg-uninstall.sh

	rm -rf regcreds/*

	# Fetch root CA from localhost 
	cp $reg_root/quay-rootCA/rootCA.pem regcreds/

	#################

	reg_user=init

	# Configure the pull secret for this mirror registry 
	## export reg_url=https://$reg_host:$reg_port

	# Check if the cert needs to be updated
	sudo diff regcreds/rootCA.pem /etc/pki/ca-trust/source/anchors/rootCA.pem 2>/dev/null >&2 || \
		sudo cp regcreds/rootCA.pem /etc/pki/ca-trust/source/anchors/ && \
			sudo update-ca-trust extract

	[ ! "$tls_verify" ] && tls_verify_opts="--tls-verify=false"

	podman logout --all >/dev/null 
	echo -n "Checking registry access is working using 'podman login' ... "
	echo "Running: podman login $tls_verify_opts -u $reg_user -p $reg_pw $reg_url"
	podman login $tls_verify_opts -u $reg_user -p $reg_pw $reg_url 

	echo "Generating regcreds/pull-secret-mirror.json file"
	export enc_password=$(echo -n "$reg_user:$reg_pw" | base64 -w0)

	# Inputs: enc_password, reg_host and reg_port 
	scripts/j2 ./templates/pull-secret-mirror.json.j2 > ./regcreds/pull-secret-mirror.json

	scripts/create-containers-auth.sh
fi

