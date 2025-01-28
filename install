#!/bin/bash
# Simple Aba installer.  Copy aba command somewhere into the $PATH

# Check sudo or root access 
[ "$(sudo id -run)" != "root" ] && echo "Please configure passwordless sudo OR run aba as root, then try again!" >&2 && exit 1

# Check options
while echo "$1" | grep -q "^-"
do
	[ "$1" = "-q" ] && quiet=1 && shift
	[ "$1" = "-v" ] && cur_ver=$2 && shift 2
done

branch=main
repo=sjbylo/aba

# Required args
[ "$1" ] && branch="$1"
[ "$2" ] && repo="$2"

is_repo_available() {
	[ -s ./scripts/aba.sh -a -x ./scripts/aba.sh ] && return 0
	[ "$0" != "--" -a "$0" != "bash" ] && cd $(dirname $0) && return 1
	return 0
}

download_repo() {
	if ! which git 2>/dev/null >&2; then
		echo "Please install git and try again!" >&2

		exit 1
	fi

	if ! grep -q "Top level Makefile" Makefile 2>/dev/null; then
		echo Cloning into $PWD with "git clone -b $branch https://github.com/${repo}.git"
		if ! git clone -b $branch https://github.com/${repo}.git; then
			echo "Error fetching git repo from https://github.com/${repo}.git (branch: $branch)" >&2

			exit 1
		fi

		echo
		echo "Cloned aba branch $branch into $PWD/aba" >&2
		cd aba
#	else
#		[ "$cur_dir" = "$PWD" ] && quite=  # Since we are in the aba dir, no neeed to output instructions
	fi
}

aba_is_installed() {
	# if aba is not installed then consider no current ver
	which aba >/dev/null 2>&1 && return 0 || return 1
}

get_repo_ver() {
	grep "^ABA_VERSION=" ./scripts/aba.sh | cut -d= -f2 | grep -oE "^[0-9]{14}$"
}

if is_repo_available; then
	cd $(dirname $0) 
else
	download_repo
fi

# Sanity check ...
[ ! -x scripts/aba.sh ] && echo "Abort: Incomplete aba repo! aba script not found in $PWD/scripts/aba.sh" >&2 && exit 1

# Install aba somewhere into the $PATH 
for d in /usr/local/bin /usr/local/sbin $HOME/bin
do
	# Check is the proposed dir exists in $PATH
	if echo $PATH | grep -q -e "$d:" -e "$d$"; then
		action=
		if [ -s "$d/aba" -a -x "$d/aba" ]; then
			repo_ver=$(get_repo_ver)
			INSTALLED_VER=$(grep "^ABA_VERSION=[0-9]" $d/aba | cut -d= -f2)
			[ "$DEBUG_ABA" ] && echo INSTALLED_VER=$INSTALLED_VER and repo_ver=$repo_ver >&2
			if [ "$INSTALLED_VER" -a "$repo_ver" ] && [ $INSTALLED_VER -lt $repo_ver ]; then
				action=updated
				ret=2 # If aba is updated we want aba to re-execute itself (see aba)
				#quiet=1  # since aba has been updated, no need for guidance below
			else
				# Nothing to do
				#[ "$INFO_ABA" ] && echo "aba is already up-to-date and installed at $d/aba" >&2
				[ ! "$quiet" ] && echo aba is already up-to-date

				exit 0
			fi
		else
			action=installed
			ret=0
		fi

		# If it's ~/bin and it's missing create it
		[ "$d" = "$HOME/bin" -a ! -d $d ] && mkdir -p $d

		# Now, try to install aba
		if sudo cp -p scripts/aba.sh $d/aba; then
			sudo chmod +x $d/aba
			[ ! "$quiet" ] && echo aba has been $action to $d/aba
			exit $ret  # Success
		fi
	fi
done

[ ! "$quiet" ] && echo "Cannot install $PWD/scripts/aba.sh!  Please copy it into your \$PATH and name it 'aba'." >&2

exit 1

