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
	export editor=nano
else
	export editor=vi
fi

normalize-aba-conf() {
	# Normalize or sanitize the config file
	grep -q ^export aba.conf && cat aba.conf && return 0
	cat aba.conf | \
		cut -d"#" -f1 | \
		sed -e '/^[ \t]*$/d' -e "s/^[ \t]*//g" -e "s/[ \t]*$//g" | \
			sed -e "s/ask=0\b/ask=/g" -e "s/ask=false/ask=/g" | \
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
			sed -e "s/^/export /g";
}

normalize-cluster-conf()
{
#	# Normalize or sanitize the config file
	grep -q ^export cluster.conf && cat cluster.conf && return 0
	cat cluster.conf | \
		cut -d"#" -f1 | \
		sed -e '/^[ \t]*$/d' -e "s/^[ \t]*//g" -e "s/[ \t]*$//g" | \
			sed -e "s/tls_verify=0\b/tls_verify=/g" -e "s/tls_verify=false/tls_verify=/g" | \
			sed -e "s/^/export /g";
}

normalize-vmware-conf()
{
#	# Normalize or sanitize the config file
	cat vmware.conf | \
		cut -d"#" -f1 | \
		sed -e '/^[ \t]*$/d' -e "s/^[ \t]*//g" -e "s/[ \t]*$//g" | \
			sed -e "s/^/export /g";
}

#normalize-mirror-conf() {
#	# Normalize or sanitize the config file
#	cat mirror.conf | \
#		cut -d"#" -f1 | \
#		sed -e '/^[ \t]*$/d' -e "s/^[ \t]*//g" -e "s/[ \t]*$//g" | \
#			sed -e "s/ask=0\b/ask=/g" -e "s/ask=false/ask=/g" | \
#			sed -e "s/^/export /g";
#}


install_rpm() {
	rpmlist=
	for rpm in $@
	do
		rpm --quiet -q $rpm || rpmlist="$rpmlist $rpm"
	done
	[ "$rpmlist" ] && \
		echo "Installing rpms: $rpmlist" && \
			sudo dnf install -y $rpmlist >> .install.log 2>&1
	return 0
}

#install_pip() {
	#install_rpm jq
	#piplist=
	#for pip in $@
	#do
		#[ "$(pip3 list --format json| jq -r '.[].name | select(. == "'$pip'")')" ] || piplist="$piplist $pip"
	#done
	#[ "$piplist" ] && \
		#echo "Installing pip3: $piplist" && \
			##unset http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY && \
			#pip3 install --user $piplist >> .install.log  2>&1 
	#return 0
#}

