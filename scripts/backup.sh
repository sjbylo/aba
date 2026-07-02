#!/bin/bash -e
# INTENT:      Create a tar archive (bundle) of the ABA repo for air-gap transfer
# CALLED BY:   make tarrepo, make tar, aba bundle, aba tar
# CWD:         ABA repo root
# ARGS:        [--inc] incremental backup (based on ~/.aba.previous.backup timestamp)
#              [--repo] exclude mirror_*.tar files (light bundle — user copies them separately)
#              [file] output path (default: /tmp/aba-backup-$USER.tar; "-" for stdout)
# PRODUCES:    tar archive with .bundle marker; ISC locked for disconnected side
# SIDE EFFECTS:
#   - Temporarily touches mirror/data/imageset-config.yaml to lock ISC in the tar
#   - Creates mirror/data/.isc-pinned if ISC was user-edited (bundle-only flag)
#   - Restores source repo after tar (touch .created, rm .isc-pinned) — user's workflow unaffected
#   - Removes .aba.conf.seen so user is prompted to edit aba.conf on the disconnected side
# IDEMPOTENT:  Yes (produces same tar for same inputs; refuses to overwrite existing output)
# ENV:         None required (sources scripts/include_all.sh)
#
# Usage: backup.sh [--inc] [--repo] [file]
#                   --inc	incremental backup based on the ~/.aba.previous.backup flag file's timestamp
#                   --repo	exclude all */mirror_*tar files from the archive due to disk space restictions.  Copy them separately, if needed.

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

dest=/tmp/aba-backup-$(whoami).tar	# Default file to write to
inc= 				# Full backup by default (not incremental) 
repo_only=			# Also include the data/mirror_*.tar files (for some use-cases it's more efficient to keep them separate) 

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

# Capture actual repo directory name before cd (needed when repo is not named "aba")
repo_dir=$(basename "$PWD")

# Assume this script is run via 'make ...' from aba's top level dir
cd ..  

# If script exits early (crash, Ctrl-C, tar failure): restore source repo to unlocked state.
# .bundle is a temp marker for tar --transform; .isc-pinned + ISC timestamp must be restored
# so the user's repo doesn't get stuck in a "locked" state after an interrupted bundle.
trap 'rm -f "${repo_dir}/.bundle" "${repo_dir}/mirror/data/.isc-pinned"; [ -f "${repo_dir}/mirror/data/.created" ] && touch "${repo_dir}/mirror/data/.created"' EXIT

# If this is the first run OR is doing a full backup ... set up for full backup (i.e. set time in past) 
[ ! -f ~/.aba.previous.backup -o ! "$inc" ] && touch -t 7001010000 ~/.aba.previous.backup 

# Notes:
# For the bundle we prefer only install files in cli/ and nothing under ~/bin
# Remove bin in favor of cli/
###bin			\
# vmware only needed on "private" bastion
#aba/vmware.conf		\

# The .bundle marker tells aba/TUI that this repo was unpacked from a bundle archive
# and should operate in disconnected (DISCO) mode. Lifecycle:
#   1. Created here (touch) — just before building the tar
#   2. Included in the tar archive
#   3. Removed from the SOURCE repo after tar completes (see rm -f below)
#      — the source repo is NOT a bundle, only the tar archive is
#   4. Appears on the disconnected host when the user unpacks: tar xvf bundle.tar
# NEVER manually 'touch .bundle' — it only makes sense inside an unpacked bundle
# where mirror/data/ contains the saved images matching the .index/ digests.
touch "${repo_dir}/.bundle"
rm -f "${repo_dir}/.aba.conf.seen"   # Ensure user can be offered to edit this conf file again on the internal/private network


# All 'find expr' below are by default "and"
file_list=$(find				\
	"${repo_dir}/install"			\
	"${repo_dir}/aba"			\
	"${repo_dir}/aba.conf"			\
	"${repo_dir}/.bundle"			\
	"${repo_dir}/cli"			\
	"${repo_dir}/rpms"			\
	"${repo_dir}/others"			\
	"${repo_dir}/scripts"			\
	"${repo_dir}/templates"			\
	"${repo_dir}/tui/v2"			\
	"${repo_dir}/Makefile"			\
	"${repo_dir}/README.md"			\
	"${repo_dir}/VERSION"			\
	"${repo_dir}/CHANGELOG.md"		\
	"${repo_dir}/LICENSE"			\
	"${repo_dir}/Troubleshooting.md"	\
	"${repo_dir}/.index"			\
	"${repo_dir}/mirror"			\
									\
	! -path "${repo_dir}/.git*"  					\
	! -path "${repo_dir}/cli/.init"  				\
	! -path "${repo_dir}/cli/.??*"	  				\
	! -path "${repo_dir}/mirror/.init" 	 			\
	! -path "${repo_dir}/mirror/.rpms"  				\
	! -path "${repo_dir}/mirror/.available"  			\
	! -path "${repo_dir}/mirror/.loaded" 				\
	! -path "${repo_dir}/mirror/mirror.conf"  			\
	! -path "${repo_dir}/mirror/mirror-registry"  			\
	! -path "${repo_dir}/mirror/execution-environment.tar"  	\
	! -path "${repo_dir}/mirror/image-archive.tar"  		\
	! -path "${repo_dir}/mirror/quay.tar"  				\
	! -path "${repo_dir}/mirror/pause.tar"  			\
	! -path "${repo_dir}/mirror/postgres.tar"  			\
	! -path "${repo_dir}/mirror/redis.tar"  			\
	! -path "${repo_dir}/mirror/regcreds"	  			\
	! -path "${repo_dir}/mirror/reg-uninstall.sh"  			\
	! -path "${repo_dir}/*/iso-agent-based*"  			\
	! -path "${repo_dir}/mirror/data/working-dir*"  		\
	! -path "${repo_dir}/mirror/sync/*"				\
	! -path "${repo_dir}/mirror/save/*"				\
	! -path "${repo_dir}/mirror/data/oc-mirror-workspace*"		\
	! -name "*.content-layer-digest"				\
	! -name "*.expected-count"					\
	! -path "${repo_dir}/test/output.log" 				\
	! -path "${repo_dir}/bundles*"	 				\
								\
	\( -type f -o -type l \)				\
								\
	-newer ~/.aba.previous.backup 				\
)

# Notes on the above
# See the "tar cf" command below and consider....
# Note, don't copy over any of the ".init", ".available", ".rpms" flag files etc, since these components are needed on the internal/private bastion
# Don't include/compress the 'image set' tar files since they are compressed already!
# Don't need to copy over the oc-mirror-workspace (or working-dir 'v2') dirs.  The needed yaml files for 'aba day2' are created at 'aba -d mirror load' (???).
# Don't copy over the "aba/test/output.log" since it's being written to by the test suite.  Tar may fail or stop since output.log is actively written to. 
# Added [! -path "aba/mirror/reg-uninstall.sh"] to be sure no old scripts are added. Intent is to install the registry *from* internal bastion/net.

# If we only want the repo, without the mirror tar files, then we need to filter these out of the list
[ "$repo_only" ] && file_list=$(echo "$file_list" | grep -E -v "^${repo_dir}/mirror/data/mirror_.*[0-9]{6}\.tar$") || true  # 'true' needed!

# Clean up file_list
file_list=$(echo "$file_list" | sed "s/^ *$//g")  # Just in case file_list="  " white space (is empty)

[ ! "$file_list" ] && aba_info "No new files to backup!" && exit 0
# Example: For incremental backup, there may be no new files 

# Output reminder message
if [ "$repo_only" ]; then
	#echo_magenta "IMPORTANT: NOT ADDING ANY IMAGE SET FILES TO THE INSTALL BUNDLE (*SPLIT BUNDLE*)." >&2
	#echo_magenta "           The image set archive file(s) are located at $PWD/aba/mirror/data/mirror_*.tar." >&2
	#echo_magenta "           You will need to copy them to your internal bastion, along with the install bundle file ($dest), and combine them." >&2
	#echo_magenta "           READ THE BELOW INSTRUCTIONS CAREFULLY!" >&2
	#echo_magenta "           To avoid this in future write the full install bundle to *external media* or to a *separate drive*." >&2

	echo_magenta "IMPORTANT: No image-set files are being added to this install bundle (*light bundle*)." >&2
	echo_magenta "           The image-set archive(s) are located at: ${PWD}/${repo_dir}/mirror/data/mirror_*.tar" >&2
	echo_magenta "           You must copy these archive files to your internal bastion together with the install bundle ($dest)," >&2
	echo_magenta "           and then combine them there." >&2
	echo_magenta "           PLEASE READ THE INSTRUCTIONS BELOW CAREFULLY." >&2
	echo_magenta "           To avoid light bundles in the future, write the full bundle to *external media* or a *separate filesystem*." >&2

fi

# If destination is NOT stdout (i.e. if in interactive mode)
if [ "$dest" != "-" ]; then
	if [ "$repo_only" ]; then
		echo
		echo_cyan "Writing *light* bundle file to $dest ... (to create a full install bundle instead, write the bundle directly to external media)."
		echo
		#aba_info "After the install bundle has been created, transfer it to your *internal bastion* using your chosen method, for example, portable media:"
		aba_info "Once the installation bundle has been created, copy it to your internal bastion using any suitable transfer method—for example, via portable media:"
		aba_info " cp $dest </path/to/your/portable/media/usb-stick/or/thumbdrive>"
		aba_info "Also transfer the image set archive file(s), for example, with:"
		aba_info " cp mirror/data/mirror_*.tar </path/to/your/portable/media/usb-stick/or/thumbdrive>"
		echo
		aba_info "After transferring the install bundle file and the image set archive file(s) to your internal bastion"
		aba_info "extract them into your home directory and"
		aba_info "then move the image set archive file(s) into the aba/mirror/data/ directory & continue by installing & running 'aba', for example, with the commands:"
		aba_info "  tar xvf $(basename $dest)"
		aba_info "  mv mirror_*.tar aba/mirror/data"
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
		aba_info "After transferring the install bundle file to your internal bastion"
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

# Bundle ISC protection: make ISC newer than .created so reg-create-imageset-config.sh
# will skip regeneration on the disconnected side. Without this, the ISC gets regenerated
# from local config (which may lack ocp_version_target, etc.) causing "no release images found"
# during oc-mirror load because the new ISC doesn't match the tar contents.
# .isc-pinned = user hand-edited the ISC before bundling, so the load side should NOT
# auto-unlock it (the user's customizations must persist permanently).
if [ -f "${repo_dir}/mirror/data/imageset-config.yaml" ] && [ -f "${repo_dir}/mirror/data/.created" ]; then
	if [ "${repo_dir}/mirror/data/imageset-config.yaml" -nt "${repo_dir}/mirror/data/.created" ]; then
		touch "${repo_dir}/mirror/data/.isc-pinned"
	else
		rm -f "${repo_dir}/mirror/data/.isc-pinned"
	fi
	touch "${repo_dir}/mirror/data/imageset-config.yaml"
fi

aba_info "Running: 'tar cf $dest $out_file_list...' from inside $PWD" >&2
aba_info "Please wait!" >&2

set +e   # Needed so we can capture the return code from tar and not just exit (bash -e)
tar cf "${dest}" --transform "s,^${repo_dir},aba," $file_list
ret=$?
rm -f "${repo_dir}/.bundle"  # Also cleaned up by EXIT trap, but explicit here for clarity

# Restore source repo after tar: touch .created so it's newer than ISC again.
# Without this, the user's connected-side repo would stay "locked" and
# subsequent 'aba save'/'aba sync' would skip ISC regeneration even after config changes.
[ -f "${repo_dir}/mirror/data/.created" ] && touch "${repo_dir}/mirror/data/.created"
rm -f "${repo_dir}/mirror/data/.isc-pinned"

if [ $ret -ne 0 ]; then
	echo >&2
	echo_red "Error: The tar command failed with return code $ret!" >&2
	echo_red "       The archive is very unlikely to be complete!  Fix the problem and try again!" >&2
	echo  >&2
	#aba_abort \
	#	"The tar command failed with return code $ret!" \
	#	"The archive is very unlikely to be complete!  Fix the problem and try again!" 

	exit $ret
fi

set -e

# If "not repo backup only" (so, if 'inc' or 'tar'), then always update timestamp file so that future inc backups will not backup everything.
# If using 'repo only, then you always want the whole repo to be backed up (so no need to use the timestamp file).
# NOTE: ONLY INC BACKUPS USE THIS FILE!!! See above. 
# Upon success, make a note of the time FIXME: Remove the 'inc' feature
touch ~/.aba.previous.backup

[ "$dest" != "-" ] && aba_info_ok "Install bundle written successfully to $dest!" >&2 || aba_info_ok "Install bundle streamed successfully to stdout!" >&2

