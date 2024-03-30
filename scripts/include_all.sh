# Code that all scripts need.  Ensure this script does not create any std output.

umask 077

# Function to display an error message and the last executed command
show_error() {
	local exit_code=$?
	echo 
	[ "$TERM" ] && tput setaf 1
	echo Script error: 
	echo "Error occurred in command: '$BASH_COMMAND'"
	echo "Error code: $exit_code"
	[ "$TERM" ] && tput sgr0

	exit $exit_code
}

# Set the trap to call the show_error function on ERR signal
trap 'show_error' ERR

normalize-aba-conf() {
	# Normalize or sanitize the config file
	# Extract the machine_network and the prefix_length from the CIDR notation
	# Prepend "export "
	[ ! -s aba.conf ] && echo "aba/aba.conf missing! run: cd aba && ./aba" && exit 1
	cat aba.conf | \
		cut -d"#" -f1 | \
		sed -e '/^[ \t]*$/d' -e "s/^[ \t]*//g" -e "s/[ \t]*$//g" | \
			sed -e "s/ask=0\b/ask=/g" -e "s/ask=false/ask=/g" | \
			sed -e "s/ask=1\b/ask=true/g" | \
			sed -e "s#\(.*\)/#\1\nprefix_length=#g" | \
			sed -e "s/^/export /g";
}

normalize-mirror-conf()
{
	# Normalize or sanitize the config file
	# Ensure any ~/ is masked, e.g. \~/
	# Ensrue reg_ssh_user has a value
	# Prepend "export "
	cat mirror.conf | \
		cut -d"#" -f1 | \
			sed -E "s/^reg_ssh_user=[[:space:]]+|reg_ssh_user=$/reg_ssh_user=$(whoami)/g" | \
			sed -e '/^[ \t]*$/d' -e "s/^[ \t]*//g" -e "s/[ \t]*$//g" | \
			sed -e "s/^tls_verify=0\b/tls_verify=/g" -e "s/tls_verify=false/tls_verify=/g" | \
			sed -e "s/^tls_verify=1\b/tls_verify=true/g" | \
			sed -e 's/^reg_root=~/reg_root=\\~/g' | \
			sed -e "s/^/export /g"
}

normalize-cluster-conf()
{
	# Normalize or sanitize the config file
	# Prepend "export "
	cat cluster.conf | \
		cut -d"#" -f1 | \
		sed -e '/^[ \t]*$/d' -e "s/^[ \t]*//g" -e "s/[ \t]*$//g" | \
			sed -e "s/^/export /g";
}

normalize-vmware-conf()
{
        # Normalize or sanitize the config file
	# Determine if ESXi or vCenter
	# Prepend "export "
        vars=$(cat vmware.conf | \
                cut -d"#" -f1 | \
                sed -e '/^[ \t]*$/d' -e "s/^[ \t]*//g" -e "s/[ \t]*$//g" | \
                sed -e "s/^/export /g")
	eval "$vars"
	# Detect if ESXi is used and set the VC_FOLDER that ESXi likes
        if govc about | grep -q "^API type:.*HostAgent$"; then
		echo "$vars" | sed "s#VC_FOLDER.*#VC_FOLDER=/ha-datacenter/vm#g"
		echo export VC=
	else
		echo "$vars"
		echo export VC=1
	fi
}

###normalize-vmware-confOLD()
#{
	## Normalize or sanitize the config file
	## Prepend "export "
	#cat vmware.conf | \
		#cut -d"#" -f1 | \
		#sed -e '/^[ \t]*$/d' -e "s/^[ \t]*//g" -e "s/[ \t]*$//g" | \
			#sed -e "s/^/export /g";
#}

install_rpms() {
	for rpm in $@
	do
		# Check if each rpm is already installed.  Don't run dnf unless we have to.
		rpm -q --quiet $rpm && continue   # If at least one rpm is not installed, install rpms

		sudo dnf install $@ -y >> .dnf-install.log 2>&1
		break
	done
}

ask() {
	source <(normalize-aba-conf)
	[ ! "$ask" ] && return 0  # reply "yes"

	timer=
	[ "$1" = "-t" ] && shift && timer="-t $1" && shift

	echo
	echo -n "===> $@ (Y/n): "
	read $timer yn
	[ ! "$yn" -o "$yn" = "y" -o "$yn" = "Y" ] && return 0

	return 1
}

try_cmd() {
	local pause=$1; shift
	local interval=$1; shift
	local total=$1; shift
	local count=1
	echo "Attempt $count/$total of command: \"$*\""
	while ! eval $*
	do
		[ $count -ge $total ] && echo "Giving up!" && return 1
		echo Pausing $pause seconds ...
		sleep $pause
		let pause=$pause+$interval
		let count=$count+1
		echo "Attempt $count/$total of command: \"$*\""
	done
}

