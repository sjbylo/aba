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
		#cut -d"#" -f1 | \
	cat aba.conf | \
		sed -E "s/^\s*#.*//g" | \
		sed -e '/^[ \t]*$/d' -e "s/^[ \t]*//g" -e "s/[ \t]*$//g" | \
			sed -e "s/ask=0\b/ask=/g" -e "s/ask=false/ask=/g" | \
			sed -e "s/ask=1\b/ask=true/g" | \
			sed -e "s#\(^machine_network=[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}\)/#\1\nprefix_length=#g" | \
			sed -e "s/^/export /g";

}

normalize-mirror-conf()
{
	# Normalize or sanitize the config file
	# Ensure any ~/ is masked, e.g. \~/
	# Ensrue reg_ssh_user has a value
	# Prepend "export "
	#[ ! -s mirror.conf ] && echo "Warning: no 'mirror.conf' file defined in $PWD" >&2 && return 0
	[ ! -s mirror.conf ] &&                                                              return 0
		#cut -d"#" -f1 | \
			#sed -E "s/^reg_ssh_user=[[:space:]]+|reg_ssh_user=$/reg_ssh_user=$(whoami) /g" | \
	cat mirror.conf | \
		sed -E "s/^\s*#.*//g" | \
			sed -E "s/^reg_ssh_user=[[:space:]]+/reg_ssh_user=$(whoami) /g" | \
			sed -e '/^[ \t]*$/d' -e "s/^[ \t]*//g" -e "s/[ \t]*$//g" | \
			sed -e "s/^tls_verify=0\b/tls_verify= /g" -e "s/tls_verify=false/tls_verify= /g" | \
			sed -e "s/^tls_verify=1\b/tls_verify=true /g" | \
			sed -e 's/^reg_root=~/reg_root=\\~/g' | \
			sed -e "s/^/export /g"
}

normalize-cluster-conf()
{
	# Normalize or sanitize the config file
	# Prepend "export "
	#[ ! -s cluster.conf ] && echo "Warning: no 'cluster.conf' file defined in $PWD" >&2 && return 0
	[ ! -s cluster.conf ] &&                                                               return 0
		##cut -d"#" -f1 | \
	cat cluster.conf | \
		sed -E "s/^\s*#.*//g" | \
		sed -e '/^[ \t]*$/d' -e "s/^[ \t]*//g" -e "s/[ \t]*$//g" | \
			sed -e "s/^/export /g";
}

normalize-vmware-conf()
{
        # Normalize or sanitize the config file
	# Determine if ESXi or vCenter
	# Prepend "export "
	# Convert VMW_FOLDER to VC_FOLDER for backwards compat!
	#[ ! -f vmware.conf ] && echo "Warning: no 'vmware.conf' file defined in $PWD" >&2 && return 0  # vmware.conf can be empty
	[ ! -f vmware.conf ] &&                                                              return 0  # vmware.conf can be empty
                #cut -d"#" -f1 | \  # Can't use this since passwords can contain '#' char(s)!
		#sed -E "s/\s+# [[:print:]]+$//g" | \
        vars=$(cat vmware.conf | \
		sed -E "s/^\s*#.*//g" | \
                sed -e '/^[ \t]*$/d' -e "s/^[ \t]*//g" -e "s/[ \t]*$//g" | \
		sed -e "s/^VMW_FOLDER=/VC_FOLDER=/g" | \
                sed -e "s/^/export /g")
	eval "$vars"
	# Detect if ESXi is used and set the VC_FOLDER that ESXi likes.  Ignore GOVC_DATACENTER and GOVC_CLUSTER. 
        if govc about | grep -q "^API type:.*HostAgent$"; then
		echo "$vars" | sed -e "s#VC_FOLDER.*#VC_FOLDER=/ha-datacenter/vm#g" -e "/GOVC_DATACENTER/d" -e "/GOVC_CLUSTER/d"
		echo export VC=
	else
		echo "$vars"
		echo export VC=1
	fi
}

install_rpms() {
	local rpms_to_install=

	for rpm in $@
	do
		# Check if each rpm is already installed.  Don't run dnf unless we have to.
		rpm -q --quiet $rpm || rpms_to_install="$rpms_to_install $rpm" 
	done

	if [ "$rpms_to_install" ]; then
		echo "Rpms not installed:$rpms_to_install"
		[ "$rpms_to_install" ] && sudo dnf install $@ -y >> .dnf-install.log 2>&1
	fi
}

ask() {
	source <(normalize-aba-conf)
	[ ! "$ask" ] && return 0  # reply "default reply"

	# Default reply is 'yes' (or 'no') and return 0
	yn_opts="(Y/n)"
	def_val=y
	[ "$1" == "-n" ] && def_val=n && yn_opts="(y/N)" && shift
	[ "$1" == "-y" ] && def_val=y && yn_opts="(Y/n)" && shift
	timer=
	[ "$1" == "-t" ] && timer="-t $1" && shift && shift 

	## echo
	echo_cyan -n "===> $@ $yn_opts: "
	read $timer yn

	if [ "$def_val" == "y" ]; then
		[ ! "$yn" -o "$yn" == "y" -o "$yn" == "Y" ] && return 0
	else
		[ ! "$yn" ] && return 0
		[ "$yn" == "n" -o "$yn" == "N" ] && return 0 
		[ "$yn" != "y" -a "$yn" != "Y" ] && return 0
	fi

	# return "non-default" responce 
	return 1
}

edit_file() {
	conf_file=$1
	shift
	msg="$*"
	if [ ! "$editor" -o "$editor" == "none" ]; then
		echo
		echo_cyan "The file '$(basename $PWD)/$conf_file' has been created.  Please edit it and continue (by repeating your last action)."

		return 1
	else
		if [ "$ask" ]; then
			ask "$msg?" || return 1
			$editor $conf_file
		else
			echo "$msg? (auto answer)"
		fi
	fi
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

# Function to check if a version is greater than another version
is_version_greater() {
    local version1=$1
    local version2=$2

    # Sort the versions
    local sorted_versions=$(printf "%s\n%s" "$version1" "$version2" | sort -V | tr "\n" "|")

    # Check if version1 is the last one in the sorted list
     [[ "$sorted_versions" != "$version1|$version2|" ]]
}

output_error() { echo_red "$@"; }

echo_red()	{ [ "$TERM" ] && tput setaf 1; echo -e "$@"; [ "$TERM" ] && tput sgr0; }
echo_green()	{ [ "$TERM" ] && tput setaf 2; echo -e "$@"; [ "$TERM" ] && tput sgr0; }
echo_yellow()	{ [ "$TERM" ] && tput setaf 3; echo -e "$@"; [ "$TERM" ] && tput sgr0; }
echo_blue()	{ [ "$TERM" ] && tput setaf 4; echo -e "$@"; [ "$TERM" ] && tput sgr0; }
echo_magenta()	{ [ "$TERM" ] && tput setaf 5; echo -e "$@"; [ "$TERM" ] && tput sgr0; }
echo_cyan()	{ [ "$TERM" ] && tput setaf 6; echo -e "$@"; [ "$TERM" ] && tput sgr0; }
echo_white()	{ [ "$TERM" ] && tput setaf 7; echo -e "$@"; [ "$TERM" ] && tput sgr0; }

# 0: Black
# 1: Red
# 2: Green
# 3: Yellow
# 4: Blue
# 5: Magenta
# 6: Cyan
# 7: White

longest_line() {
    # Calculate the longest line from stdin
    awk '{
        if (length($0) > max) {
            max = length($0)
            longest = $0
        }
    } END {
        print max
    }'
}

