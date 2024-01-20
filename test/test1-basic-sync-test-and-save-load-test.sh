#!/bin/bash -e
# This test is for a connected bastion.  It will sync images and install clusters, 
# then savd/load images and install clusters. 

cd `dirname $0`
cd ..

./aba --version 4.13.27 --vmw ~/.vmware.conf 
#./aba --version 4.14.8 --vmw ~/.vmware.conf 
#make -C cli clean 
make -C cli
[ -s mirror/mirror.conf ] && touch mirror/mirror.conf

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

# If a mirror is not accessible, install one.  Otherwise, use existing mirror.
##if ! make -C mirror verify; then
	##make -C mirror uninstall clean
	#podman ps| grep registry.redhat.io/quay/quay-rhel8 && make -C mirror uninstall clean
	#ssh registry2.example.com -- podman ps| grep registry.redhat.io/quay/quay && (cd mirror; ./mirror-registry uuninstall)

	ver=$(cat ./target-ocp-version.conf)

	# Copy and edit mirror.conf 
	cp -f templates/mirror.conf mirror/
	sed -i "s/ocp_target_ver=[0-9]\+\.[0-9]\+\.[0-9]\+/ocp_target_ver=$ver/g" ./mirror/mirror.conf

	## test the internal bastion (registry2.example.com) as mirror
	sed -i "s/registry.example.com/registry2.example.com/g" ./mirror/mirror.conf  # Which host
	sed -i "s#reg_ssh=#reg_ssh=~/.ssh/id_rsa#g" ./mirror/mirror.conf	       # Remote or localhost

	make -C mirror install 
##fi

. mirror/mirror.conf
#make -C mirror verify 
echo "Mirror available at $reg_host:$reg_port"

######################
echo Runtest: START - sync

make -C mirror sync   # This will install and sync
#install_all_clusters sno compact standard 
install_all_clusters sno

#######################
#echo Runtest: START - load

make -C mirror save load   #  This will save, install, load
##install_all_clusters sno compact standard 
install_all_clusters sno

# Tidy up, if needed
##make -C mirror uninstall 

