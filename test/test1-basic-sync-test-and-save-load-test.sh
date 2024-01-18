#!/bin/bash -e
# This test is for a connected bastion.  It will sync images and install clusters, 
# then savd/load images and install clusters. 

cd `dirname $0`
cd ..

#./aba --version 4.13.27 --vmw ~/.vmware.conf 
./aba --version 4.14.8 --vmw ~/.vmware.conf 

install_cluster() {
	rm -rf $1
	mkdir -p $1
	#ln -fs ../templates $1
	ln -fs ../templates/Makefile $1/Makefile
	cp templates/aba-$1.conf $1/aba.conf
	make -C $1
	echo $1 completed
	make -C $1 delete  # delete to free up disk space!
}

install_all_clusters() {
	for c in $@
	do
		echo Runtest: creating cluster $c
		install_cluster $c
		#make -C $c delete
	done

	#for c in $@
	#do
		#echo Runtest: deleting cluster $c
		#install_cluster $c
	#done
}

set -x
#make -C mirror uninstall

make -C mirror clean
#####
ver=$(cat ./target-ocp-version.conf)

# Copy and edit mirror.conf if needed
cp -f templates/mirror.conf .
sed -i "s/ocp_target_ver=[0-9]\+\.[0-9]\+\.[0-9]\+/ocp_target_ver=$ver/g" ./mirror.conf
####

## test for remote mirror
#sed -i "s/registry.example.com/registry2.example.com/g" ./mirror.conf
#sed -i "s#reg_ssh=#reg_ssh=~/.ssh/id_rsa#g" ./mirror.conf
## test for remote mirror

#######################
#echo Runtest: START - sync
#
#make sync   # This will install and sync
#
##install_all_clusters sno compact standard 
#install_all_clusters sno

######################
echo Runtest: START - load

make -C mirror uninstall
make -C mirror clean

make save load   #  This will save, install, load
#install_all_clusters sno compact standard 
install_all_clusters standard
