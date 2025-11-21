#!/bin/bash 
# Create the vmware folder if it does not exist

[ ! "$1" ] && aba_abort "Usage: $(basename $0) <vsphere folder>" 

source scripts/include_all.sh

folder_list=
vc_folder=$1
msg_folder=$1
shift


if ! echo $vc_folder | grep -q ^/; then
	aba_abort "The vsphere folder must start with a '/' char!" 
fi

result=$(govc folder.create $vc_folder 2>&1) && aba_info "Folder $vc_folder created!" && exit 0  # Created ok
echo "$result" | grep -qi "already exists" &&  aba_info "Folder $vc_folder already exists!" && exit 0  

while echo "$result" | grep -qi "folder.*not found"
do
       	folder_list="$vc_folder $folder_list"
       	vc_folder=$(dirname $vc_folder)

	[ "$vc_folder" == "/" ] && aba_abort "Invalid folder name: '$msg_folder'"

	if govc folder.create $vc_folder >/dev/null 2>&1; then
		for f in $folder_list
		do
			[ "$f" == "/" ] && aba_abort "Invalid folder name: '$msg_folder'" 
			govc folder.create $f
		done
		[ $? -eq 0 ] && aba_info "Folder $f created!" || aba_info "Cannot create: '$f'"
		break
	fi
done


