#!/bin/bash
# Simple Aba installer.  Copy aba command somewhere into the $PATH

uname -o | grep -q "^Darwin$" && echo "Install aba on RHEL or Fedora. Most tested is RHEL 9 (no oc-mirror for Mac OS!)." >&2 && exit 1

# We need git, which and id commands ....
required_pkgs=(git coreutils which)
missing_pkgs=()

for pkg in "${required_pkgs[@]}"; do
	if ! rpm -q "$pkg" >/dev/null; then
		missing_pkgs+=("$pkg")
	fi
done

if [ ${#missing_pkgs[@]} -gt 0 ]; then
	echo "Missing required packages: ${missing_pkgs[*]}" >&2
	echo "Please install them and try again." >&2
	exit 1
fi

SUDO=
which sudo 2>/dev/null >&2 && SUDO=sudo

# Check sudo or root access 
# If user is not root
if [ "$(id -run)" != "root" ]; then
	if [ "$SUDO" ]; then
		# If sudo does not lead to root without using a password prompt (-n)
		if [ "$($SUDO -n whoami)" != "root" ]; then
			echo "aba requires root access, directly or via sudo." >&2
			# If there is no passwordless access
			if ! $SUDO -ln 2>/dev/null | grep -q NOPASSWD; then
				echo "Passwordless sudo access is recommended." >&2
			fi
			echo -n "You must enter your password to install and use aba: " >&2
			[ "$($SUDO -p "Enter %p's password: " id -run)" != "root" ] && echo "Configure passwordless sudo OR run aba as root, then try again!" >&2 && exit 1
		fi
	else
		echo "Warning: sudo command is not available and aba is not running as root!" >&2
	fi
fi

# Check options
while echo "$1" | grep -q "^-"
do
	[ "$1" = "-q" ] && quiet=1 && shift
	[ "$1" = "-v" ] && cur_ver=$2 && shift 2
done

branch=main
repo=sjbylo/aba
msg=

# Required args
[ "$1" ] && branch="$1"
[ "$2" ] && repo="$2"

is_repo_available() {
	[ -s ./scripts/aba.sh -a -x ./scripts/aba.sh ] && return 0
	# If curl is used...
	[ "$0" = "--" -o "$0" = "bash" ] && return 1

	# We must have the repo, cd into it...
	cd $(dirname $0)
	return 0
}

download_repo() {
	if ! which git 2>/dev/null >&2; then
		echo "Please install git and try again!" >&2

		exit 1
	fi

	if ! grep -q "Top level Makefile" Makefile 2>/dev/null; then
		echo Cloning aba with: "git clone -b $branch https://github.com/${repo}.git" >&2
		if ! git clone -b $branch https://github.com/${repo}.git; then
			echo "Error fetching git repo from https://github.com/${repo}.git (branch: $branch)" >&2

			exit 1
		fi

		echo
		echo "Cloned aba branch $branch into $PWD/aba" >&2
		cd aba
	fi
}

aba_is_installed() {
	# if aba is not installed then consider no current ver
	which aba >/dev/null 2>&1 && return 0 || return 1
}

get_repo_ver() {
	grep "^ABA_VERSION=" ./scripts/aba.sh | cut -d= -f2 | grep -oE "^[0-9]{14}$"
}

if ! is_repo_available; then
	download_repo
	msg="Run: 'cd aba; aba' or see the README.md file"
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
				[ ! "$quiet" ] && echo aba is already up-to-date >&2

				exit 0
			fi
		else
			action=installed
			ret=0
		fi

		# If it's ~/bin and it's missing create it
		[ "$d" = "$HOME/bin" -a ! -d $d ] && mkdir -p $d

		# Now, try to install aba
		if $SUDO cp -p scripts/aba.sh $d/aba; then
			$SUDO chmod +x $d/aba
			[ ! "$quiet" ] && echo aba has been $action to $d/aba >&2
			[ ! "$quiet" -a -n "$msg" ] && source scripts/include_all.sh && echo_yellow "$msg" >&2

			exit $ret  # Success
		fi
	fi
done

[ ! "$quiet" ] && echo "Cannot install $PWD/scripts/aba.sh!  Please copy it into your \$PATH and name it 'aba'." >&2

exit 1

