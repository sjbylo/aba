#!/bin/bash 
# Either connect to an existing registry or install a fresh one.

source scripts/include_all.sh

[ "$1" ] && set -x

umask 077

source <(normalize-aba-conf)
source <(normalize-mirror-conf)

# If we're installing a mirror, then we do need all the "internal" rpms, esp. podman!
scripts/install-rpms.sh internal

export reg_url=https://$reg_host:$reg_port

# Check if 'registry' credentials exist, e.g. provided by user or auto-generated by mirror installer 
# For existing registry, user must provide the 'regcreds/pull-secret-mirror.json' and the 'regcreds/rootCA.pem' files. 
if [ -s regcreds/pull-secret-mirror.json ]; then
	scripts/reg-verify.sh

	exit
fi

# Detect any existing mirror registry?

# Check for Quay...
[ "$http_proxy" ] && echo "$no_proxy" | grep -q "\b$reg_host\b" || no_proxy=$no_proxy,$reg_host		  # adjust if proxy in use
echo_white Probing $reg_url/health/instance
reg_code=$(curl --retry 3 --connect-timeout 10 -ILsk -o /dev/null -w "%{http_code}\n" $reg_url/health/instance || true)

if [ "$reg_code" = "200" ]; then
	echo
	echo_red "Warning: Quay registry found at $reg_url/health/instance." >&2
	echo_red "         To use this registry, copy its pull secret file and root CA file into 'mirror/regcreds/' and try again." >&2
	echo_red "         The files must be named 'pull-secret-mirror.json' and 'rootCA.pem' respectively." >&2
	echo_red "         The pull secret file can also be created and verified using 'aba password'" >&2
	echo_red "         See the README.md for further instructions." >&2
	echo 

	exit 1
fi

# Check for any endpoint ...
echo_white Probing $reg_url/
reg_code=$(curl --retry 3 --connect-timeout 10 -ILsk -o /dev/null -w "%{http_code}\n" $reg_url/ || true)

if [ "$reg_code" = "200" ]; then
	echo
	echo_red "Warning: Endpoint found at $reg_url/." >&2
	echo_red "         If this is your existing registry, copy its pull secret file and root CA file into 'aba/mirror/regcreds/' and try again." >&2
	echo_red "         The files must be named 'pull-secret-mirror.json' and 'rootCA.pem' respectively." >&2
	echo_red "         The pull secret file can also be created and verified using 'aba password'" >&2
	echo_red "         See the README.md for further instructions." >&2
	echo 

	exit 1
fi

# Is registry root dir value defined?
if [ "$reg_root" ]; then
	if echo "$reg_root" | grep -q ^~; then
		# Must replace ~ with /home/$reg_ssh_user
		reg_root=$(echo "$reg_root" | sed "s#~#/home/$reg_ssh_user#g")
	fi

	echo_white "Using registry root dir: $reg_root"
	reg_root_opt="--quayRoot $reg_root --quayStorage $reg_root/quay-storage --pgStorage $reg_root/pg-data"
else
	# The default path
	reg_root=/home/$reg_ssh_user/quay-install  # This must be the path *where Quay will be installed*
	echo_white "Using default registry root dir: $reg_root"
fi


cat > .ssh.conf <<END
StrictHostKeyChecking no
UserKnownHostsFile=/dev/null
ConnectTimeout=15
LogLevel=ERROR
END

flag_file=/tmp/.$(whoami).$RANDOM

# Install Quay mirror on **remote host** if ssh key defined 
if [ "$reg_ssh_key" ]; then
	# First, ensure the reg host points to a remote host and not this localhost
	echo_cyan "You have configured the mirror to be a remote host (since 'reg_ssh_key' is defined in 'aba.conf')."
	echo_cyan "Verifying FQDN '$reg_host' points to a remote host ..."

	if ! ssh -i $reg_ssh_key -F .ssh.conf $reg_ssh_user@$reg_host touch $flag_file; then
		echo
		echo_red "Error: Can't ssh to $reg_ssh_user@$reg_host using key '$reg_ssh_key'" >&2
		echo_red "       Configure password-less ssh to $reg_ssh_user@$reg_host and try again." >&2
		echo

		exit 1
	else
		# If the flag file exists, then the FQDN points to this host (config wrong!) 
		if [ -f $flag_file ]; then
			#echo
			#echo_red "Error: $reg_host is not a remote host! Correct the problem in mirror.conf (undefine reg_ssh_key?) and try again." >&2
			#echo

			echo
			echo_red "Error: FQDN '$reg_host' resolves to this host '`hostname`'!" >&2
			echo_red "       By unsetting 'reg_ssh_key' in 'mirror.conf', you have configued a *remote* mirror '$reg_host' (which resolves to '$fqdn_ip')." >&2
			echo_red "       If that should be the local host, please undefine the 'reg_ssh_key' value in 'mirror.conf'." >&2
			echo_red "       Otherwise, ensure the DNS record points to the correct *remote* host." >&2
			echo_red "       Please correct the problem and try again." >&2
			echo

			rm -f $flag_file

			exit 1
		fi

		echo "Ssh access to remote host ($reg_host) is working ..."
	fi

	ask "Install Quay mirror registry appliance remotly, accessable via $reg_host:$reg_port" || exit 1
	echo "Installing Quay registry to remote host at $reg_ssh_user@$reg_host ..."

	# Workaround START ########
	# See: https://access.redhat.com/solutions/7040517 "Installing the mirror-registry to a remote disconnected host fails (on the first attempt)"
	# Check for known issue where images need to be loaded on the remote host first
	# This will load the needed images and fix the problem 
	# Only need to do this workaround once
	ssh -i $reg_ssh_key -F .ssh.conf $reg_ssh_user@$reg_host "ip a"
	ssh -i $reg_ssh_key -F .ssh.conf $reg_ssh_user@$reg_host "rpm -q podman || sudo dnf install podman jq -y" || exit 1
	ssh -i $reg_ssh_key -F .ssh.conf $reg_ssh_user@$reg_host "rpm -q jq 	|| sudo dnf install podman jq -y" || exit 1
	ssh -i $reg_ssh_key -F .ssh.conf $reg_ssh_user@$reg_host "podman images" || exit 1
	ssh -i $reg_ssh_key -F .ssh.conf $reg_ssh_user@$reg_host podman images | grep -q ^registry.access.redhat.com/ubi8/pause || \
	(
		echo "Implementing workaround to install Quay on remote host ... see https://access.redhat.com/solutions/7040517 for more."
		ssh -i $reg_ssh_key -F .ssh.conf $reg_ssh_user@$reg_host mkdir -p .abatmp
		scp -i $reg_ssh_key -F .ssh.conf mirror-registry.tar.gz $reg_ssh_user@$reg_host:.abatmp/
		ssh -i $reg_ssh_key -F .ssh.conf $reg_ssh_user@$reg_host "cd .abatmp && tar xmzf mirror-registry.tar.gz"
		ssh -i $reg_ssh_key -F .ssh.conf $reg_ssh_user@$reg_host "cd .abatmp && ./mirror-registry install"
		ssh -i $reg_ssh_key -F .ssh.conf $reg_ssh_user@$reg_host "cd .abatmp && ./mirror-registry uninstall --autoApprove"
		ssh -i $reg_ssh_key -F .ssh.conf $reg_ssh_user@$reg_host rm -rf .abatmp/*
	)
	# Workaround END ########
			
	# FIXME: this is not used
	# If the key is missing, then generate one
	####[ ! -s $reg_ssh_key ] && ssh-keygen -t rsa -f $reg_ssh_key -N ''

	# Note that the mirror-registry installer does not open the port for us
	echo Allowing firewall access to the registry at $reg_host/$reg_port ...
	ssh -i $reg_ssh_key -F .ssh.conf $reg_ssh_user@$reg_host -- "sudo firewall-cmd --state && \
		sudo firewall-cmd --add-port=$reg_port/tcp --permanent && \
			sudo firewall-cmd --reload"

	echo "Installing mirror registry on the host [$reg_host] with user $reg_ssh_user into dir $reg_root ..."

	if [ ! "$reg_pw" ]; then
		reg_pw=$(openssl rand -base64 12)
	fi

	# Generate the script to be used to delete this registry
	uninstall_cmd="./mirror-registry uninstall --targetUsername $reg_ssh_user --targetHostname $reg_host -k $reg_ssh_key $reg_root_opt --autoApprove -v"
	echo "reg_delete() { echo Running command: \"$uninstall_cmd\"; $uninstall_cmd;}" > ./reg-uninstall.sh
	echo reg_host_to_del=$reg_host >> ./reg-uninstall.sh

	#cmd="./mirror-registry install -v --quayHostname $reg_host --targetUsername $reg_ssh_user --targetHostname $reg_host \
  	#	-k $reg_ssh_key --initPassword $reg_pw $reg_root_opt"
	cmd="./mirror-registry install -v --quayHostname $reg_host --targetUsername $reg_ssh_user --targetHostname $reg_host \
  		-k $reg_ssh_key $reg_root_opt"

	echo_cyan "Running command: \"$cmd --initPassword <hidden>\""

	$cmd --initPassword $reg_pw

	# Now, activate the uninstall script 
	### No need ### mv ./reg-uninstall.sh.provision reg-uninstall.sh

	rm -rf regcreds
	mkdir regcreds

	# Fetch root CA from remote host 
	scp -i $reg_ssh_key -F .ssh.conf -p $reg_ssh_user@$reg_host:$reg_root/quay-rootCA/rootCA.pem regcreds/

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

	#### TESTING WITHOUT - Added to reg-load/save/sync # scripts/create-containers-auth.sh
else
	# First, ensure the reg host points to this localhost and not a remote host
	# Sanity check to see if the correct host was defined
	# Resolve FQDN
	echo_cyan "You have configured the mirror to be on this localhost (since 'reg_ssh_key' is undefined in 'aba.conf')."
	echo_cyan "Verifying FQDN '$reg_host' points to this localhost ..."
	fqdn_ip=$(dig +short $reg_host | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}') || true

	if [ ! "$fqdn_ip" ]; then
		echo
		echo_red "Warning: '$reg_host' does not resolve to an IP addr!" >&2
		echo_red "         Please correct the problem and try again!" >&2
		echo
	fi

	# Get local IP addresses
	local_ips=$(hostname -I)

	# Check if FQDN IP matches any local IP
	if ! echo "$local_ips" | grep -qw "$fqdn_ip"; then
		echo
		echo_red "Warning: FQDN '$reg_host' does not resolve to an IP addr on this host '`hostname`'!" >&2
		echo_red "         By setting 'reg_ssh_key' in 'mirror.conf' you have configued the mirror to be on the local host '$reg_host' (which resolves to '$fqdn_ip')." >&2
		echo_red "         If that should be a remote host, please define the 'reg_ssh_key' value in 'mirror.conf'." >&2
		echo_red "         Otherwise, ensure the DNS record points to an IP address that can reach this local host '`hostname`'." >&2
		##echo_red "         Please correct the problem and try again." >&2
		echo

		##exit 1  # We will leave this only as a warning, not an error since sometimes there is a NAT in use
	fi

#	if ! ssh -F .ssh.conf $reg_host touch $flag_file >/dev/null 2>&1; then
#		# This is to be expected and can be ignored
#		:
#	else
#		if [ ! -f $flag_file ]; then
#			echo
#			echo_red "Error: $reg_host is a remote host! Correct the problem in mirror.conf (define reg_ssh_key?) and try again." >&2
#			echo
#
#			exit 1
#		else
#			rm -f $flag_file
#		fi
#	fi

	ask "Install Quay mirror registry appliance locally on host '`hostname`', accessable via $reg_host:$reg_port" || exit 1
	echo "Installing Quay registry on localhost ..."

	# mirror-registry installer does not open the port for us
	echo Allowing firewall access to this host at $reg_host/$reg_port ...
	sudo firewall-cmd --state && \
		sudo firewall-cmd --add-port=$reg_port/tcp --permanent && \
			sudo firewall-cmd --reload

	# Create random password
	if [ ! "$reg_pw" ]; then
		reg_pw=$(openssl rand -base64 12)
	fi

	# Generate the script to be used to delete this registry
	uninstall_cmd="./mirror-registry uninstall --autoApprove $reg_root_opt -v"
	echo "reg_delete() { echo Running command: \"$uninstall_cmd\"; $uninstall_cmd;}" > ./reg-uninstall.sh
	echo reg_host_to_del=$reg_host >> ./reg-uninstall.sh

	#cmd="./mirror-registry install -v --quayHostname $reg_host --initPassword $reg_pw $reg_root_opt"
	cmd="./mirror-registry install -v --quayHostname $reg_host $reg_root_opt"

	echo_cyan "Running command: \"$cmd --initPassword <hidden>\""

	$cmd --initPassword $reg_pw

	# Now, activate the uninstall script 
	### No need ### mv ./reg-uninstall.sh.provision reg-uninstall.sh

	rm -rf regcreds
	mkdir regcreds

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

	#### TESTING WITHOUT - Added to reg-load/save/sync # scripts/create-containers-auth.sh
fi

echo
echo_green "Registry installated/configured successfully!"
