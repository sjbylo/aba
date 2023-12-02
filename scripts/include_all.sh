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

install_pip() {
	piplist=
	for pip in $@
	do
		[ "$(pip3 list --format json| jq -r '.[].name | select(. == "'$pip'")')" ] || piplist="$piplist $pip"
	done
	[ "$piplist" ] && \
		echo "Installing pip3: $piplist" && \
			pip3 install --user $piplist >> .install.log  2>&1 
	return 0
}

