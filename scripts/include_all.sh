# Code that all scripts need.  Ensure this script does not create any std output.

umask 077

# Function to display an error message and the last executed command
show_error() {
	local exit_code=$?
	echo 
	echo Script error: 
	echo "Error occurred in command: '$BASH_COMMAND'"
	echo "Error code: $exit_code"
	exit $exit_code
}

# Set the trap to call the show_error function on ERR signal
trap 'show_error' ERR

# Detect editor.  Assume nano if available
if which nano >/dev/null 2>&1; then
	# FIXME
	[ ! "$editor" ] && export editor=nano
else
	[ ! "$editor" ] && export editor=vi
fi

normalize-aba-conf() {
	# Normalize or sanitize the config file
	grep -q ^export aba.conf && cat aba.conf && return 0
	cat aba.conf | \
		cut -d"#" -f1 | \
		sed -e '/^[ \t]*$/d' -e "s/^[ \t]*//g" -e "s/[ \t]*$//g" | \
			sed -e "s/ask=0\b/ask=/g" -e "s/ask=false/ask=/g" | \
			sed -e "s/ask=1\b/ask=true/g" | \
			sed -e "s/^/export /g";
}

normalize-mirror-conf()
{
#	# Normalize or sanitize the config file
	grep -q ^export mirror.conf && cat mirror.conf && return 0
	cat mirror.conf | \
		cut -d"#" -f1 | \
		sed -e '/^[ \t]*$/d' -e "s/^[ \t]*//g" -e "s/[ \t]*$//g" | \
			sed -e "s/tls_verify=0\b/tls_verify=/g" -e "s/tls_verify=false/tls_verify=/g" | \
			sed -e "s/tls_verify=1\b/tls_verify=true/g" | \
			sed -e "s/^/export /g";
}

normalize-cluster-conf()
{
#	# Normalize or sanitize the config file
	grep -q ^export cluster.conf && cat cluster.conf && return 0
	cat cluster.conf | \
		cut -d"#" -f1 | \
		sed -e '/^[ \t]*$/d' -e "s/^[ \t]*//g" -e "s/[ \t]*$//g" | \
			sed -e "s/^/export /g";
}
###			sed -e "s/tls_verify=0\b/tls_verify=/g" -e "s/tls_verify=false/tls_verify=/g" | \

normalize-vmware-conf()
{
#	# Normalize or sanitize the config file
	cat vmware.conf | \
		cut -d"#" -f1 | \
		sed -e '/^[ \t]*$/d' -e "s/^[ \t]*//g" -e "s/[ \t]*$//g" | \
			sed -e "s/^/export /g";
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

