#!/bin/bash -e
# Tar backup script for full OR incremental backup of the repo.  Used to only backup (and copy) the changes since the last backup.
# Usage: backup.sh [--inc] [--repo] [file]
#                   --inc	incremental backup based on the ~/.aba.previous.backup flag file's timestamp
#                   --repo	exclude all */mirror_*tar files from the archive due to disk space restictions.  Copy them separately, if needed.

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

dest=/tmp/aba-backup-$(whoami).tar	# Default file to write to
inc= 				# Full backup by default (not incremental) 
repo_only=			# Also include the save/mirror_*.tar files (for some use-cases it's more efficient to keep them separate) 

while echo "$1" | grep -q ^--[a-z]
do
	[ "$1" = "--repo" ] && repo_only=1 && shift	# Set to NOT include any mirror_*.tar files, which should be copied separately. 
	[ "$1" = "--inc" ] && inc=1 && shift    	# Set optional backup type to "incremental".  Full is default. 
done

[ "$1" ] && dest="$1"

# Append .tar if it's missing from filename (ignore for stdout) 
if [ "$dest" != "-" ]; then
	[ -d $dest ] && dest=$dest/aba-backup-$(whoami).tar	# The dest needs to be a file
	echo "$dest" | grep -q \.tar$ || dest="$dest.tar"	# append .tar if needed
	# If the destination file already exists...
	[ -s $dest ] && aba_abort "File $dest already exists. Aborting!" 
fi

# Assume this script is run via 'make ...' from aba's top level dir
cd ..  

# If this is the first run OR is doing a full backup ... set up for full backup (i.e. set time in past) 
[ ! -f ~/.aba.previous.backup -o ! "$inc" ] && touch -t 7001010000 ~/.aba.previous.backup 

# Notes:
# For the bundle we prefer only install files in cli/ and nothing under ~/bin
# Remove bin in favor of cli/
###bin			\
# vmware only needed on "private" bastion
#aba/vmware.conf		\

# Add the bundle flag file to the archive so when aba is run again it knows it's a bundle!
touch aba/.bundle  # Flag this archive as a bundle
rm -f aba/.aba.conf.seen   # Ensure user can be offered to edit this conf file again on the internal/private network

# All 'find expr' below are by default "and"
file_list=$(find		\
	aba/install		\
	aba/aba			\
	aba/aba.conf		\
	aba/.bundle		\
	aba/cli			\
	aba/rpms		\
	aba/others		\
	aba/scripts		\
	aba/templates		\
	aba/Makefile		\
	aba/README.md		\
	aba/Troubleshooting.md	\
	aba/mirror		\
								\
	! -path "aba/.git*"  					\
	! -path "aba/cli/.init"  				\
	! -path "aba/cli/.??*"	  				\
	! -path "aba/mirror/.init" 	 			\
	! -path "aba/mirror/.rpms"  				\
	! -path "aba/mirror/.installed"  			\
	! -path "aba/mirror/.loaded" 				\
	! -path "aba/mirror/mirror-registry"  			\
	! -path "aba/mirror/execution-environment.tar"  	\
	! -path "aba/mirror/image-archive.tar"  		\
	! -path "aba/mirror/quay.tar"  				\
	! -path "aba/mirror/pause.tar"  			\
	! -path "aba/mirror/postgres.tar"  			\
	! -path "aba/mirror/redis.tar"  			\
	! -path "aba/mirror/regcreds/*"	  			\
	! -path "aba/mirror/reg-uninstall.sh"  			\
	! -path "aba/*/iso-agent-based*"  			\
	! -path "aba/mirror/sync/working-dir*"  		\
	! -path "aba/mirror/save/working-dir*"			\
	! -path "aba/mirror/sync/oc-mirror-workspace*"  	\
	! -path "aba/mirror/save/oc-mirror-workspace*"		\
	! -path "aba/test/output.log" 				\
	! -path "aba/bundles*"	 				\
								\
	\( -type f -o -type l \)				\
								\
	-newer ~/.aba.previous.backup 				\
)

# Notes on the above
# See the "tar cf" command below and consider....
# Note, don't copy over any of the ".init", ".installed", ".rpms" flag files etc, since these components are needed on the internal/private bastion
# Don't include/compress the 'image set' tar files since they are compressed already!
# Don't need to copy over the oc-mirror-workspace (or working-dir 'v2') dirs.  The needed yaml files for 'aba day2' are created at 'aba -d mirror load' (???).
# Don't copy over the "aba/test/output.log" since it's being written to by the test suite.  Tar may fail or stop since output.log is actively written to. 
# Added [! -path "aba/mirror/reg-uninstall.sh"] to be sure no old scripts are added. Intent is to install the registry *from* internal bastion/net.

# If we only want the repo, without the mirror tar files, then we need to filter these out of the list
[ "$repo_only" ] && file_list=$(echo "$file_list" | grep -E -v "^aba/mirror/s.*/mirror_.*[0-9]{6}\.tar$") || true  # 'true' needed!

# Clean up file_list
file_list=$(echo "$file_list" | sed "s/^ *$//g")  # Just in case file_list="  " white space (is empty)

[ ! "$file_list" ] && aba_info "No new files to backup!" && exit 0
# Example: For incremental backup, there may be no new files 

# Output reminder message
if [ "$repo_only" ]; then
	#echo_magenta "IMPORTANT: NOT ADDING ANY IMAGE SET FILES TO THE INSTALL BUNDLE (*SPLIT BUNDLE*)." >&2
	#echo_magenta "           The image set archive file(s) are located at $PWD/aba/mirror/save/mirror_*.tar." >&2
	#echo_magenta "           You will need to copy them to your internal bastion, along with the install bundle file ($dest), and combine them." >&2
	#echo_magenta "           READ THE BELOW INSTRUCTIONS CAREFULLY!" >&2
	#echo_magenta "           To avoid this in future write the full install bundle to *external media* or to a *separate drive*." >&2

	echo_magenta "IMPORTANT: No image-set files are being added to this install bundle (*split bundle*)." >&2
	echo_magenta "           The image-set archive(s) are located at: $PWD/aba/mirror/save/mirror_*.tar" >&2
	echo_magenta "           You must copy these archive files to your internal bastion together with the install bundle ($dest)," >&2
	echo_magenta "           and then combine them there." >&2
	echo_magenta "           PLEASE READ THE INSTRUCTIONS BELOW CAREFULLY." >&2
	echo_magenta "           To avoid split bundles in the future, write the full bundle to *external media* or a *separate filesystem*." >&2

fi

# If destination is NOT stdout (i.e. if in interactive mode)
if [ "$dest" != "-" ]; then
	if [ "$repo_only" ]; then
		echo
		echo_cyan "Writing *split* bundle file to $dest ... (to create a full install bundle instead, write the bundle directly to external media)."
		echo
		#aba_info "After the install bundle has been created, transfer it to your *internal bastion* using your chosen method, for example, portable media:"
		aba_info "Once the installation bundle has been created, copy it to your internal bastion using any suitable transfer method—for example, via portable media:"
		aba_info " cp $dest </path/to/your/portable/media/usb-stick/or/thumbdrive>"
		aba_info "Also transfer the image set archive file(s), for example, with:"
		aba_info " cp mirror/save/mirror_*.tar </path/to/your/portable/media/usb-stick/or/thumbdrive>"
		echo
		aba_info "After transfering the install bundle file and the image set archive file(s) to your internal bastion"
		aba_info "extract them into your home directory and"
		aba_info "then move the image set archive file(s) into the aba/mirror/save/ directory & continue by installing & running 'aba', for example, with the commands:"
		aba_info "  tar xvf $(basename $dest)"
		aba_info "  mv mirror_*.tar aba/mirror/save"
		aba_info "  cd aba"
		aba_info "  ./install"
		aba_info "  aba"
		echo
		aba_info "Run 'aba -h' for all options."
		echo
	else
		echo
		echo_cyan "Writing *all-in-one* install bundle file to $dest ..."
		echo
		#aba_info "After the install bundle has been created, transfer it to your *internal bastion* using your chosen method, for example, portable media:"
		aba_info "Once the installation bundle has been created, copy it to your internal bastion using any suitable transfer method—for example, via portable media:"
		aba_info " cp $dest </path/to/your/portable/media/usb-stick/or/thumbdrive>"
		echo
		aba_info "After transfering the install bundle file to your internal bastion"
		aba_info "extract it into your home directory and"
		aba_info "then continue by installing & running 'aba', for example, with the commands:"
		aba_info "  tar xvf $(basename $dest)"
		aba_info "  cd aba"
		aba_info "  ./install"
		aba_info "  aba"
		echo
		aba_info "Run 'aba -h' for all options."
		echo
	fi
fi

if [ "$inc" ]; then
	aba_info "Writing 'incremental' tar archive of repo to $dest" >&2  # Must use stderr otherwise the tar archive becomes corrupt
else
	aba_info "Writing tar file to $dest" >&2
fi

out_file_list=$(echo $file_list | cut -c-90)

aba_info "Running: 'tar cf $dest $out_file_list...' from inside $PWD" >&2
aba_info "Please wait!" >&2

set +e   # Needed so we can capture the return code from tar and not just exit (bash -e) 
tar cf $dest $file_list
ret=$?
rm -f aba/.bundle  # We don't want this repo to be labeled as 'bundle', only the tar archive should be
if [ $ret -ne 0 ]; then
	echo >&2
	echo_red "Error: The tar command failed with return code $ret!" >&2
	echo_red "       The archive is very likely incomplete!  Fix the problem and try again!" >&2
	echo  >&2
	#aba_abort \
	#	"The tar command failed with return code $ret!" \
	#	"The archive is very likely incomplete!  Fix the problem and try again!" 

	exit $ret
fi

set -e

# If "not repo backup only" (so, if 'inc' or 'tar'), then always update timestamp file so that future inc backups will not backup everything.
# If using 'repo only, then you always want the whole repo to be backed up (so no need to use the timestamp file).
# NOTE: ONLY INC BACKUPS USE THIS FILE!!! See above. 
# Upon success, make a note of the time FIXME: Remove the 'inc' feature
touch ~/.aba.previous.backup

[ "$dest" != "-" ] && aba_info_ok "Install bundle written successfully to $dest!" >&2 || aba_info_ok "Install bundle streamed successfully to stdout!" >&2

