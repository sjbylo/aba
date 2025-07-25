#!/bin/bash 
# Either connect to an existing registry or install a fresh one.

source scripts/include_all.sh

[ "$1" ] && set -x

umask 077

source <(normalize-aba-conf)
source <(normalize-mirror-conf)

verify-aba-conf || exit 1
verify-mirror-conf || exit 1

# If we're installing a mirror, then we do need all the "internal" rpms, esp. podman!
scripts/install-rpms.sh internal

export reg_hostport=$reg_host:$reg_port
export reg_url=https://$reg_hostport

# Check if mirror 'registry' credentials exist, e.g. provided by user or auto-generated by mirror installer 
# For existing registry, user must provide the 'regcreds/pull-secret-mirror.json' and the 'regcreds/rootCA.pem' files in regcreds/.
if [ -s regcreds/pull-secret-mirror.json ]; then
	scripts/reg-verify.sh

	exit
fi

# Detect any existing mirror registry?

# Check for Quay...
[ "$http_proxy" ] && echo "$no_proxy" | grep -q "\b$reg_host\b" || no_proxy=$no_proxy,$reg_host		  # adjust if proxy in use
[ "$INFO_ABA" ] && echo_white Probing $reg_url/health/instance
reg_code=$(curl --retry 2 --connect-timeout 10 -ILsk -o /dev/null -w "%{http_code}\n" $reg_url/health/instance || true)

if [ "$reg_code" = "200" ]; then
	echo
	echo_red "Warning: Existing Quay registry found at $reg_url/health/instance." >&2
	echo_red "         To use this registry, copy its pull secret file and root CA file into 'mirror/regcreds/' and try again." >&2
	echo_red "         The files must be named 'pull-secret-mirror.json' and 'rootCA.pem' respectively." >&2
	echo_red "         The pull secret file can also be created and verified using 'aba password'" >&2
	echo_red "         See the README.md for further information." >&2
	echo 

	exit 1
fi

# Check for any endpoint ...
[ "$INFO_ABA" ] && echo_white Probing $reg_url/
reg_code=$(curl --retry 2 --connect-timeout 10 -ILsk -o /dev/null -w "%{http_code}\n" $reg_url/ || true)

if [ "$reg_code" = "200" ]; then
	echo
	echo_red "Warning: Endpoint found at $reg_url/." >&2
	echo_red "         If this is your existing registry, copy its pull secret file and root CA file into 'aba/mirror/regcreds/' and try again." >&2
	echo_red "         The files must be named 'pull-secret-mirror.json' and 'rootCA.pem' respectively." >&2
	echo_red "         The pull secret file can also be created and verified using 'aba password'" >&2
	echo_red "         See the README.md for further information." >&2
	echo 

	exit 1
fi

# Hack to get the home path right
## FIX # fix_home=/home/$reg_ssh_user
## FIX # [ "$reg_ssh_user" = "root" ] && fix_home=/root

# Is registry root dir value defined?
if [ "$reg_root" ]; then
	## FIX # if echo "$reg_root" | grep -q ^~; then
		## FIX # # Must replace ~ with the remote user's home dir
		## FIX # reg_root=$(echo "$reg_root" | sed "s#~#$fix_home#g")
	## FIX # fi

	# Check for absolute path
	#if ! echo "$reg_root" | grep -q ^/; then
	if [[ "$reg_root" != /* && "$reg_root" != ~* ]]; then
		echo_red "Error: reg_root value must be an 'absolute path', i.e. starting with a '/' or a '~' char! Fix this in mirror/mirror.conf and try again!" >&2
		exit 1
	fi

	# Fetch the actual absolute dir path for $reg_root
	####reg_root=$(ssh -i $reg_ssh_key -F .ssh.conf $reg_ssh_user@$reg_host echo $reg_root)

	##reg_root_opts="--quayRoot \"$reg_root\" --quayStorage \"$reg_root/quay-storage\" --sqliteStorage \"$reg_root/sqlite-storage\""
	##reg_root_opts="--quayRoot $reg_root --quayStorage $reg_root/quay-storage --sqliteStorage $reg_root/sqlite-storage"
	##echo_white "Using registry root dir: $reg_root and options: $reg_root_opts"
else
	# The default path
	# This must be the path *where Quay will be installed*
	## FIX # reg_root=$fix_home/quay-install
	reg_root="~/quay-install"
	echo_white "Using default registry root dir: $reg_root"
fi


cat > .ssh.conf <<END
StrictHostKeyChecking no
UserKnownHostsFile=/dev/null
ConnectTimeout=15
LogLevel=ERROR
END

flag_file=/tmp/.$(whoami).$RANDOM
rm -f $flag_file

# Check the hostname (FDQN) resolveds to an expected IP address
fqdn_ip=$(dig +short $reg_host | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}') || true
if [ ! "$fqdn_ip" ]; then
	echo
	echo_red "Error: '$reg_host' does not resolve properly (IP address expected!)." >&2
	echo_red "       Correct the problem and try again!" >&2
	echo

	exit 1
fi

# Install Quay mirror on **remote host** if ssh key defined 
if [ "$reg_ssh_key" ]; then
	# First, ensure the reg host points to a remote host and not this localhost
	[ "$INFO_ABA" ] && echo_cyan "You have configured the mirror to be a remote host (since 'reg_ssh_key' is defined in 'mirror/mirror.conf')."
	[ "$INFO_ABA" ] && echo_cyan "Verifying FQDN '$reg_host' points to a remote host ..."

	# try to create a random file on the host and check the file does not exist on this localhost 
	if ! ssh -i $reg_ssh_key -F .ssh.conf $reg_ssh_user@$reg_host touch $flag_file; then
		echo
		echo_red "Error: Can't ssh to '$reg_ssh_user@$reg_host' using key '$reg_ssh_key'" >&2
		echo_red "       Configure password-less ssh to the remote host '$reg_ssh_user@$reg_host' and try again." >&2
		echo

		exit 1
	else
		# If the flag file exists, then the FQDN points to this host (config wrong!) 
		if [ -f $flag_file ]; then
			echo
			echo_red "Error: The mirror registry is configured to be on a *remote* host but '$reg_host'" >&2
			echo_red "       resolves to $fqdn_ip, which reaches this localhost ($(hostname)) instead!" >&2
			echo_red "       If '$reg_host' should point to this localhost ($(hostname)), undefine 'reg_ssh_key' in 'aba/mirror/mirror.conf'." >&2
			echo_red "       If '$reg_host' is meant be point to a remote host, update the DNS record ($reg_host) to resolve to an IP that can reach the *remote* host via ssh." >&2
			echo_red "       Correct the problem and try again." >&2
			echo

			rm -f $flag_file

			exit 1
		fi

		ssh -i $reg_ssh_key -F .ssh.conf $reg_ssh_user@$reg_host rm -f $flag_file

		echo "Ssh access to remote host ($reg_ssh_user@$reg_host using key $reg_ssh_key) is working ..."
	fi

	ask "Install Quay mirror registry appliance on remote host, accessable via $reg_hostport" || exit 1
	echo "Installing Quay registry to remote host at $reg_ssh_user@$reg_host ..."

	# Workaround START ########
	# See: https://access.redhat.com/solutions/7040517 "Installing the mirror-registry to a remote disconnected host fails (on the first attempt)"
	# Check for known issue where images need to be loaded on the remote host first
	# This will load the needed images and fix the problem 
	# Only need to do this workaround once
	echo_cyan "Running checks on remote host: $reg_host.  See $PWD/.remote_host_check.out file for output."

	> .remote_host_check.out
	err=
	ssh -i $reg_ssh_key -F .ssh.conf $reg_ssh_user@$reg_host "set -x; ip a" >> .remote_host_check.out 2>&1
	ssh -i $reg_ssh_key -F .ssh.conf $reg_ssh_user@$reg_host "set -x; rpm -q podman || sudo dnf install podman jq -y" >> .remote_host_check.out 2>&1 || err=1
	ssh -i $reg_ssh_key -F .ssh.conf $reg_ssh_user@$reg_host "set -x; rpm -q jq 	|| sudo dnf install podman jq -y" >> .remote_host_check.out 2>&1 || err=1
	ssh -i $reg_ssh_key -F .ssh.conf $reg_ssh_user@$reg_host "set -x; podman images" >> .remote_host_check.out 2>&1 || err=1

	[ "$err" ] && echo_red "Install 'podman' and 'jq' on the remote host '$reg_host' and try again." && exit 1

	# FIXME: this is not used
	# If the key is missing, then generate one
	####[ ! -s $reg_ssh_key ] && ssh-keygen -t rsa -f $reg_ssh_key -N ''

	# Note that the mirror-registry installer does not open the port for us
	echo Allowing firewall access to the registry at $reg_host/$reg_port ...
	ssh -i $reg_ssh_key -F .ssh.conf $reg_ssh_user@$reg_host -- "sudo firewall-cmd --state && \
		sudo firewall-cmd --add-port=$reg_port/tcp --permanent && \
			sudo firewall-cmd --reload"

	if [ "$reg_root" ]; then
		# Fetch the actual absolute dir path for $reg_root.  "~" on remote host may be diff. to this localhost. Ansible installer does not eval "~"
		reg_root=$(ssh -i $reg_ssh_key -F .ssh.conf $reg_ssh_user@$reg_host echo $reg_root)

		reg_root_opts="--quayRoot $reg_root --quayStorage $reg_root/quay-storage --sqliteStorage $reg_root/sqlite-storage"
		##echo_white "Using registry root dir: $reg_root and options: $reg_root_opts"

		echo_white "Using registry root dir: $reg_root and options: $reg_root_opts"
	else
		echo_white "Using registry root dir: $reg_root"
	fi

	echo "Installing mirror registry on the remote host [$reg_host] with user $reg_ssh_user into dir $reg_root ..."

	if [ ! "$reg_pw" ]; then
		reg_pw=$(openssl rand -base64 12)
	fi

	# Generate the script to be used to delete this registry
	uninstall_cmd="eval ./mirror-registry uninstall --targetUsername $reg_ssh_user --targetHostname $reg_host -k $reg_ssh_key $reg_root_opts --autoApprove -v"
	###echo "reg_delete() { echo Running command: \"$uninstall_cmd\"; $uninstall_cmd; ssh -i $reg_ssh_key -F .ssh.conf $reg_ssh_user@$reg_host \"rm -rf $reg_root\"; }" > ./reg-uninstall.sh
	echo "reg_delete() { echo Running command: \"$uninstall_cmd\"; $uninstall_cmd;}" > ./reg-uninstall.sh
	echo reg_host_to_del=$reg_host >> ./reg-uninstall.sh
	[ "$INFO_ABA" ] && echo_cyan "Created Quay uninstall script at $PWD/reg-uninstall.sh"

	#cmd="./mirror-registry install -v --quayHostname $reg_host --targetUsername $reg_ssh_user --targetHostname $reg_host \
  	#	-k $reg_ssh_key --initPassword $reg_pw $reg_root_opts"
	cmd="./mirror-registry install -v --quayHostname $reg_host --targetUsername $reg_ssh_user --targetHostname $reg_host -k $reg_ssh_key $reg_root_opts"

	echo_cyan "Installing mirror registry with command:"
	echo_cyan "$cmd --initPassword <hidden>"

	eval $cmd --initPassword $reg_pw   # eval needed for "~"

	if [ -d regcreds ]; then
		rm -rf regcreds.bk
		mv regcreds regcreds.bk
	fi
	mkdir regcreds

	# Fetch root CA from remote host 
	echo "Fetching root CA from remote host: $reg_ssh_user@$reg_host:$reg_root/quay-rootCA/rootCA.pem"
	scp -i $reg_ssh_key -F .ssh.conf -p $reg_ssh_user@$reg_host:$reg_root/quay-rootCA/rootCA.pem regcreds/

	[ ! "$reg_user" ] && reg_user=init

	# Check if the cert needs to be updated
	$SUDO diff regcreds/rootCA.pem /etc/pki/ca-trust/source/anchors/rootCA.pem 2>/dev/null >&2 || \
		$SUDO cp regcreds/rootCA.pem /etc/pki/ca-trust/source/anchors/ && \
			$SUDO update-ca-trust extract

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
else
	# First, ensure the reg host points to this localhost and not a remote host
	# Sanity check to see if the correct host was defined
	# Resolve FQDN
	[ "$INFO_ABA" ] && echo_cyan "You have configured the mirror to be on this localhost (since 'reg_ssh_key' is undefined in 'aba.conf')."
	[ "$INFO_ABA" ] && echo_cyan "Verifying FQDN '$reg_host' (IP: fqdn_ip) points to this localhost ..."

	# Get local IP addresses
	local_ips=$(hostname -I)

	# For local install, we check if FQDN IP DOES NOT match any local IPs
	# We will leave this only as a warning, not an error since sometimes there is a NAT in use which is difficult to check
	if ! echo "$local_ips" | grep -qw "$fqdn_ip"; then
		echo
		echo_red "Warning: The mirror registry is configured on this localhost ($(hostname)) but '$reg_host'" >&2
		echo_red "         resolves to $fqdn_ip, which DOES NOT reach this localhost via ssh!" >&2
		echo_red "         If '$reg_host' is meant to point to a remote host, set 'reg_ssh_key' in 'aba/mirror/mirror.conf'." >&2
		echo_red "         If '$reg_host' should point to this *localhost*, update the DNS record to resolve to an IP address that correctly reaches $(hostname)." >&2

		echo
		sleep 2

		##exit 1  # We will leave this only as a warning, not an error since sometimes there is a NAT in use which is difficult to check
	fi

#	if ! ssh -F .ssh.conf $reg_host touch $flag_file >/dev/null 2>&1; then
#		# This is to be expected and can be ignored
#		:
#	else
#		if [ ! -f $flag_file ]; then
#			echo
#			echo_red "Error: $reg_host is a remote host! Correct the problem in mirror/mirror.conf (define reg_ssh_key?) and try again." >&2
#			echo
#
#			exit 1
#		else
#			rm -f $flag_file
#		fi
#	fi

ask "Install Quay mirror registry appliance to '$(hostname)' (localhost), accessable via $reg_hostport" || exit 1
	echo "Installing Quay registry on localhost ..."

	# mirror-registry installer does not open the port for us
	echo Allowing firewall access to this host at $reg_host/$reg_port ...
	$SUDO firewall-cmd --state && \
		$SUDO firewall-cmd --add-port=$reg_port/tcp --permanent && \
			$SUDO firewall-cmd --reload

	# Create random password
	if [ ! "$reg_pw" ]; then
		reg_pw=$(openssl rand -base64 12)
	fi

	if [ "$reg_root" ]; then
		reg_root_opts="--quayRoot $reg_root --quayStorage $reg_root/quay-storage --sqliteStorage $reg_root/sqlite-storage"
		echo_white "Using registry root dir: $reg_root and options: $reg_root_opts"
	else
		echo_white "Using registry root dir: $reg_root"
	fi

	# Generate the script to be used to delete this registry
	uninstall_cmd="eval ./mirror-registry uninstall --autoApprove $reg_root_opts -v"
	echo "reg_delete() { echo Running command: \"$uninstall_cmd\"; $uninstall_cmd;}" > ./reg-uninstall.sh
	echo reg_host_to_del=$reg_host >> ./reg-uninstall.sh
	[ "$INFO_ABA" ] && echo_cyan "Created Quay uninstall script at $PWD/reg-uninstall.sh"

	#cmd="./mirror-registry install -v --quayHostname $reg_host --initPassword $reg_pw $reg_root_opts"
	cmd="./mirror-registry install -v --quayHostname $reg_host $reg_root_opts"

	echo_cyan "Installing mirror registry with command:"
	echo_cyan "$cmd --initPassword <hidden>"

	eval $cmd --initPassword $reg_pw   # eval needed for "~"

	if [ -d regcreds ]; then
		rm -rf regcreds.bk
		mv regcreds regcreds.bk
	fi
	mkdir regcreds

	# Fetch root CA from localhost 
	eval cp $reg_root/quay-rootCA/rootCA.pem regcreds/   # eval since $reg_root may container "~"

	#################

	[ ! "$reg_user" ] && reg_user=init

	# Configure the pull secret for this mirror registry 
	## export reg_url=https://$reg_hostport

	# Check if the cert needs to be updated
	$SUDO diff regcreds/rootCA.pem /etc/pki/ca-trust/source/anchors/rootCA.pem 2>/dev/null >&2 || \
		$SUDO cp regcreds/rootCA.pem /etc/pki/ca-trust/source/anchors/ && \
			$SUDO update-ca-trust extract

	[ ! "$tls_verify" ] && tls_verify_opts="--tls-verify=false"

	podman logout --all >/dev/null 
	echo -n "Checking registry access is working using 'podman login' ... "
	echo "Running: podman login $tls_verify_opts -u $reg_user -p $reg_pw $reg_url"
	podman login $tls_verify_opts -u $reg_user -p $reg_pw $reg_url 

	echo "Generating regcreds/pull-secret-mirror.json file"
	export enc_password=$(echo -n "$reg_user:$reg_pw" | base64 -w0)

	# Inputs: enc_password, reg_host and reg_port 
	scripts/j2 ./templates/pull-secret-mirror.json.j2 > ./regcreds/pull-secret-mirror.json
fi

echo
echo_green "Registry installated/configured successfully!"
