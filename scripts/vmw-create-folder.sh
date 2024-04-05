#!/bin/bash 

[ ! "$1" ] && echo "Usage: $(basename $0) <vsphere folder>" && exit 1

folder_list=
vc_folder=$1
shift
[ "$1" ] && set -x

if ! echo $vc_folder | grep -q ^/; then
	echo "vsphere folder must start with a '/'" 
	exit 1
fi

result=$(govc folder.create $vc_folder 2>&1) && echo "Folder $vc_folder created!" && exit 0  # Created ok
echo "$result" | grep -qi "already exists" &&  echo "Folder $vc_folder already exists!" && exit 0  

while echo "$result" | grep -qi "folder.*not found"
do
       	folder_list="$vc_folder $folder_list"
       	vc_folder=$(dirname $vc_folder)

	[ "$vc_folder" == "/" ] && echo "Invalid folder" && exit 1

	if govc folder.create $vc_folder >/dev/null 2>&1; then
		for f in $folder_list
		do
			[ "$f" == "/" ] && echo "Invalid folder" && exit 1
			#govc folder.create $f >/dev/null 2>&1
			govc folder.create $f
		done
		[ $? -eq 0 ] && echo "Folder $f created!" || echo Cannot create folder $f
		break
	fi
done


