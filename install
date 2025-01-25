#!/bin/bash -e
# Simple Aba installer.  Copy aba command somewhere into the $PATH

# Check sudo or root access 
[ "$(sudo id -run)" != "root" ] && echo "Please configure passwordless sudo OR run aba as root, then try again!" >&2 && exit 1

# Check options
while echo "$1" | grep -q "^-"
do
	[ "$1" = "-q" ] && quiet=1 && shift
	[ "$1" = "-v" ] && cur_ver=$2 && shift 2
done

repo=sjbylo/aba
branch=main

# Required args
[ "$1" ] && repo="$1"
[ "$2" ] && branch="$2"

cur_dir=$PWD
#cd $(dirname $0)

# Only want to use git on the workstation with Internet access
if [ ! -f .bundle ]; then
	if ! which git 2>/dev/null >&2; then
		echo "Please install git and try again!" >&2

		exit 1
	fi
fi

# Check if aba script needs to be updated (only aba calls install using -v opt to set $cur_ver)
if [ -s ./scripts/aba.sh ] && grep -Eq "^ABA_VERSION=[0-9]+" ./scripts/aba.sh; then
	REPO_VER=$(grep "^ABA_VERSION=" ./scripts/aba.sh | cut -d= -f2)
	REPO_VER=$(echo $REPO_VER | grep -oE "^[0-9]{14}$")
fi

# if aba is not installed then consider no current ver
which aba >/dev/null 2>&1 || cur_ver=

if [ "$cur_ver" ]; then
	# if the version of aba in the repo is newer than the aba installed/called
	if [ "$REPO_VER" -a $REPO_VER -gt $cur_ver -a -x ./install ]; then
		echo aba script will update ... >&2  # Aba will update and re-execute itself (from aba script)
	else
	       [ ! "$quiet" ] && echo "aba is already up to date" >&2
	       exit 2 # This will cause aba to continue to run
	fi
fi

# If we are installing by piping into bash
if ! grep -q "Top level Makefile" Makefile 2>/dev/null; then
	if ! git clone -b $branch https://github.com/${repo}.git; then
		cd aba
		if ! git checkout $branch; then
			echo "Error checking out git branch $branch" >&2
			exit 1
		fi
		echo "Error fetching git repo from https://github.com/${repo}.git (branch: $branch)" >&2
		exit 1
	fi

	echo
	echo "Cloned aba into $PWD/aba" >&2
	cd aba
else
	[ "$cur_dir" = "$PWD" ] && quite=  # Since we're in the aba dir, no neeed to output instructions
fi

if [ -x scripts/aba.sh ]; then
	for d in /usr/local/bin /usr/local/sbin $HOME/bin
	do
		# Check is the dir exists in $PATH
		if echo $PATH | grep -q -e "$d:" -e "$d$"; then
			action=
			if [ -s "$d/aba" ]; then
				INSTALLED_VER=$(grep "^ABA_VERSION=" $d/aba | cut -d= -f2)
				if [ "$INSTALLED_VER" -a "$REPO_VER" -a $INSTALLED_VER -ne $REPO_VER ]; then
					action="updated to $d"
					quiet=1  # since aba has been updated, no need for guidance below
				else
					# Nothing to do
					[ "$INFO_ABA" ] && echo "aba is already up-to-date and installed at $d/aba" >&2
					exit 0
				fi
			else
				action="installed to $d"
			fi

			# Try to install aba
			if ! sudo cp -p scripts/aba.sh $d/aba; then
				echo "Error: Cannot install $PWD/scripts/aba.sh to $d/aba!  Please copy it into your \$PATH and name it aba." >&2

				exit 1
			else
				break
			fi
		fi
	done

	if [ ! "$action" ]; then
		echo "Cannot install $PWD/scripts/aba.sh!  Please copy it into your \$PATH and name it 'aba'." >&2

		exit 1
	fi

	echo "aba has been $action" >&2

	[ ! "$quiet" ] && echo "Run: cd aba; aba" >&2
	[ ! "$quiet" ] && echo "Run: cd aba -h for help or see the README.md file" >&2

	exit 0
else
	echo "Abort: Incomplete repo! aba script not found in $PWD/scripts/aba.sh" >&2

	exit 1
fi

