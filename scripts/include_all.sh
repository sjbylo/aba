# Code that all scripts need.  Ensure this script does not create any std output.
# Add any arg1 to turn off the below Error trap

echo_black()	{ [ "$TERM" ] && tput setaf 0; echo -e "$@"; [ "$TERM" ] && tput sgr0; }
echo_red()	{ [ "$TERM" ] && tput setaf 1; echo -e "$@"; [ "$TERM" ] && tput sgr0; }
echo_green()	{ [ "$TERM" ] && tput setaf 2; echo -e "$@"; [ "$TERM" ] && tput sgr0; }
echo_yellow()	{ [ "$TERM" ] && tput setaf 3; echo -e "$@"; [ "$TERM" ] && tput sgr0; }
echo_blue()	{ [ "$TERM" ] && tput setaf 4; echo -e "$@"; [ "$TERM" ] && tput sgr0; }
echo_magenta()	{ [ "$TERM" ] && tput setaf 5; echo -e "$@"; [ "$TERM" ] && tput sgr0; }
echo_cyan()	{ [ "$TERM" ] && tput setaf 6; echo -e "$@"; [ "$TERM" ] && tput sgr0; }
echo_white()	{ [ "$TERM" ] && tput setaf 7; echo -e "$@"; [ "$TERM" ] && tput sgr0; }

cat_cyan()	{ [ "$TERM" ] && tput setaf 6; cat; [ "$TERM" ] && tput sgr0; }
cat_red()	{ [ "$TERM" ] && tput setaf 1; cat; [ "$TERM" ] && tput sgr0; }

if ! [[ "$PATH" =~ "$HOME/bin:" ]]; then
	[ "$DEBUG_ABA" ] && echo "$0: Adding $HOME/bin to \$PATH for user $(whoami)" >&2
	PATH="$HOME/bin:$PATH"
fi

umask 077

if [ ! "$tmp_dir" ]; then
	export tmp_dir=$(mktemp -d /tmp/.aba.$(whoami).XXXX)
	mkdir -p $tmp_dir 
	cleanup() {
		[ "$DEBUG_ABA" ] && echo "$0: Cleaning up temporary directory [$tmp_dir] ..." >&2
		rm -rf "$tmp_dir"
	}
	
	# Set up the trap to call cleanup on script exit or termination
	trap cleanup EXIT
fi

# Function to display an error message and the last executed command
show_error() {
	local exit_code=$?
	echo 
	echo_red "Script error: " >&2
	echo_red "Error occurred in command: '$BASH_COMMAND'" >&2
	echo_red "Error code: $exit_code" >&2

	exit $exit_code
}

# Set the trap to call the show_error function on ERR signal
[ ! "$1" ] && trap 'show_error' ERR


normalize-aba-conf() {
	# Normalize or sanitize the config file
	# Remove all chars from lines with <whitespace>#<anything>
	# Remove all whitespace lines
	# Remove all leading and trailing whitespace
	# Correct ask=? which must be either =1 or = (empty)
	# Extract machine_network and prefix_length from the CIDR notation
	# Ensure only one arg after 'export'
	# Prepend "export "
	[ ! -s aba.conf ] && echo "ask=true" && return 0  # if aba.conf is missing, output a safe default, "ask=true"

	cat aba.conf | \
		sed -E	-e "s/^\s*#.*//g" \
			-e '/^[ \t]*$/d' -e "s/^[ \t]*//g" -e "s/[ \t]*$//g" \
			-e "s/ask=0\b/ask=/g" -e "s/ask=false/ask=/g" \
			-e "s/ask=1\b/ask=true/g" \
			-e 's#(machine_network=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/#\1\nprefix_length=#g' | \
		awk '{print $1}' | \
		sed	-e "s/^/export /g";

}

normalize-mirror-conf()
{
	# Normalize or sanitize the config file
	# Ensure any ~/ is masked, e.g. \~/
	# Ensrue reg_ssh_user has a value
	# Ensure only one arg after 'export'
	# Prepend "export "

	[ ! -s mirror.conf ] &&                                                              return 0

	cat mirror.conf | \
		sed -E	-e "s/^\s*#.*//g" \
			-e "s/^reg_ssh_user=[[:space:]]+/reg_ssh_user=$(whoami) /g" \
			-e '/^[ \t]*$/d' -e "s/^[ \t]*//g" -e "s/[ \t]*$//g" \
			-e "s/^tls_verify=0\b/tls_verify= /g" -e "s/tls_verify=false/tls_verify= /g" \
			-e "s/^tls_verify=1\b/tls_verify=true /g" \
			-e 's/^reg_root=~/reg_root=\\~/g' | \
		awk '{print $1}' | \
		sed	-e "s/^/export /g"
}

normalize-cluster-conf()
{
	# Normalize or sanitize the config file
	# Remove all chars from lines with <whitespace>#<anything>
	# Remove all whitespace lines
	# Remove all leading and trailing whitespace
	# Extract machine_network and prefix_length from the CIDR notation
	# Ensure only one arg after 'export'
	# Prepend "export "

	[ ! -s cluster.conf ] &&                                                               return 0

	cat cluster.conf | \
		sed -E	-e "s/^\s*#.*//g" \
			-e '/^[ \t]*$/d' -e "s/^[ \t]*//g" -e "s/[ \t]*$//g" \
			-e 's#(machine_network=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/#\1\nprefix_length=#g' | \
		awk '{print $1}' | \
		sed -e "s/^/export /g";

	# Add any missing default values, mainly for backwards compat.
	grep -q ^hostPrefix= cluster.conf	|| echo export hostPrefix=23
	grep -q ^port0= cluster.conf 		|| echo export port0=eth0
}

normalize-vmware-conf()
{
        # Normalize or sanitize the config file
	# Determine if ESXi or vCenter
	# Ensure only one arg after 'export'
	# Prepend "export "
	# Convert VMW_FOLDER to VC_FOLDER for backwards compat!

	[ ! -f vmware.conf ] &&                                                              return 0  # vmware.conf can be empty

        vars=$(cat vmware.conf | \
		sed -E	-e "s/^\s*#.*//g" \
			-e '/^[ \t]*$/d' -e "s/^[ \t]*//g" -e "s/[ \t]*$//g" \
			-e "s/^VMW_FOLDER=/VC_FOLDER=/g" | \
		awk '{print $1}' | \
                sed	-e "s/^/export /g")
	eval "$vars"
	# Detect if ESXi is used and set the VC_FOLDER that ESXi prefers, and ignore GOVC_DATACENTER and GOVC_CLUSTER. 
        if govc about | grep -q "^API type:.*HostAgent$"; then
		echo "$vars" | sed -e "s#VC_FOLDER.*#VC_FOLDER=/ha-datacenter/vm#g" -e "/GOVC_DATACENTER/d" -e "/GOVC_CLUSTER/d"
		echo export VC=
	else
		echo "$vars"
		echo export VC=1
	fi
}

install_rpms() {
	# Try to install the RPMs only if they are missing
	local rpms_to_install=

	for rpm in $@
	do
		# Check if each rpm is already installed.  Don't run dnf unless we have to.
		rpm -q --quiet $rpm || rpms_to_install="$rpms_to_install $rpm" 
	done

	if [ "$rpms_to_install" ]; then
		echo "Installing missing rpms:$rpms_to_install (logging to .dnf-install.log)"
		if ! sudo dnf install $rpms_to_install -y >> .dnf-install.log 2>&1; then
			echo_red "Warning: an error occured whilst trying to install RPMs, see the logs at .dnf-install.log." >&2
			echo_red "If dnf cannot be used to install rpm packages, please install the following packages manually and try again!" >&2
			echo_magenta $rpms_to_install

			return 1
		fi
	fi
}

ask() {
	source <(normalize-aba-conf)  # if aba.conf does not exist, this outputs 'ask=true' to be on the safe side.
	[ ! "$ask" ] && return 0  # reply "default reply"

	# Default reply is 'yes' (or 'no') and return 0
	yn_opts="(Y/n)"
	def_responce=y
	[ "$1" == "-n" ] && def_responce=n && yn_opts="(y/N)" && shift
	[ "$1" == "-y" ] && def_responce=y && yn_opts="(Y/n)" && shift
	timer=
	[ "$1" == "-t" ] && timer="-t $1" && shift && shift 

	echo_yellow -n "$@? $yn_opts: "
	read $timer yn

	# Return default responce, 0
	[ ! "$yn" ] && return 0

	[ "$def_responce" == "y" ] && [ "$yn" == "y" -o "$yn" == "Y" ] && return 0
	[ "$def_responce" == "n" ] && [ "$yn" == "n" -o "$yn" == "N" ] && return 0

	# return "non-default" responce 
	return 1

#	if [ "$def_responce" == "y" ]; then
#		[ ! "$yn" -o "$yn" == "y" -o "$yn" == "Y" ] && return 0
#	else
#		# Return default responce
#		[ ! "$yn" ] && return 0
#		[ "$yn" == "n" -o "$yn" == "N" ] && return 0 
#		[ "$yn" != "y" -a "$yn" != "Y" ] && return 0
#	fi
#
#	# return "non-default" responce 
#	return 1
}

edit_file() {
	conf_file=$1
	shift
	msg="$*"

	if [ "$ask" ]; then
		if [ ! "$editor" -o "$editor" == "none" ]; then
			echo
			echo_yellow "The file '$PWD/$conf_file' has been created. Please edit/verify it & continue/try again."

			return 1
		else
			ask "$msg" || return 1
			$editor $conf_file
		fi
	else
		#echo_yellow "$msg? (auto answered, ask=$ask)"
		echo_yellow "'$conf_file' has been created for you (skipping edit since ask=false in aba.conf)."
	fi

	return 0
}

try_cmd() {
	# Run a command, if it fails, try again after 'pause' seconds
	# Usage: try_cmd [-q] <pause> <backoff> <total>
	local quiet=
	[ "$1" = "-q" ] && local quiet=1 && local out=">/dev/null 2>&1" && shift
	local pause=$1; shift		# initial pause time in sec
	local backoff=$1; shift		# add backoff time to pause time
	local total=$1; shift		# total number of tries

	local count=1

	[ ! "$quiet" ] && echo_cyan "Attempt $count/$total of command: \"$*\""

	#echo DEBUG: eval "$*" "$out"
	#while ! eval $* $out
	echo  >>.cmd.out 
	echo cmd $* >>.cmd.out 
	while ! eval $* >>.cmd.out 2>&1
	do
		if [ $count -ge $total ]; then
			[ ! "$quiet" ] && echo_red "Giving up on command \"$*\"" >&2
			# Return non-zero
			return 1
		fi

		[ ! "$quiet" ] && echo Pausing $pause seconds ...
		sleep $pause

		let pause=$pause+$backoff
		let count=$count+1

		[ ! "$quiet" ] && echo_cyan "Attempt $count/$total of command: \"$*\""
		#echo DEBUG: eval "$*" "$out"
		echo cmd $* >>.cmd.out 
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

output_error() { echo_red "$@" >&2; }

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

files_on_same_device() {
	# Check if two file paths were provided
	if [ "$#" -ne 2 ]; then
		echo "Usage: files_on_same_device <file_path1> <file_path2>"

		return 1
	fi

	# Get the device number for each file path using 'stat'
	DIR1=$(dirname "$1")
	DIR2=$(dirname "$2")

	DEV1=$(stat -c %d "$DIR1")
	DEV2=$(stat -c %d "$DIR2")

	# Compare the device numbers
	[ "$DEV1" == "$DEV2" ] && return 0 || return 1
}

fetch_latest_version() {
	# $1 must be one of 'stable', 'fast' or 'candidate'
	local c=stable
	[ "$1" ] && c=$1
	[ "$c" = "eus" ] && c=stable   # .../ocp/eus/release.txt does not exist. FIXME: Use oc-mirror for this instead of curl?
	rel=$(curl -f --connect-timeout 10 --retry 2 -sL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$c/release.txt) || return 1
	# Get the latest OCP version number, e.g. 4.14.6
	ver=$(echo "$rel" | grep -E -o "Version: +[0-9]+\.[0-9]+\.[0-9]+" | awk '{print $2}')
	[ "$ver" ] && echo $ver || return 1
}

# Replace a value in a conf file, taking care of white-space and optional commented ("#") values
replace-value-conf() {
	# $1 file
	# $2 is name of value to change
	# $3 new value (optional)
	[ ! -s $1 ] && echo "Error: No such file: $PWD/$1" >&2 && exit 1
	[ ! "$2" ] && echo "Error: missing value!" >&2 && exit 1
	[ "$DEBUG_ABA" ] && echo "Replacing config value [$2] with [$3] in file: $1" >&2
	sed -i "s|^[# \t]*${2}=[^ \t#]*\(.*\)|${2}=${3}\1|g" $1
}
