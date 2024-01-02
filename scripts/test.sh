#!/bin/bash -e

install_cluster() {
	rm -rf $1
	mkdir -p $1
	#ln -fs ../templates $1
	ln -fs ../templates/Makefile $1/Makefile
	cp test/aba-$1.conf $1/aba.conf
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

#####
ver=$(cat ./target-ocp-version.conf)

# Copy and edit mirror.conf if needed
cp -f templates/mirror.conf .

sed -i "s/ocp_target_ver=[0-9]\+\.[0-9]\+\.[0-9]\+/ocp_target_ver=$ver/g" ./mirror.conf
####

######################
echo Runtest: START - sync
make -C mirror mirror-registry
mirror/mirror-registry uninstall --autoApprove || true
rm -rf mirror/deps
rm -rf mirror/save
make -C mirror clean
make sync 
install_all_clusters sno compact standard 

######################
echo Runtest: START - load
make -C mirror mirror-registry
mirror/mirror-registry uninstall --autoApprove || true
rm -rf mirror/deps
rm -rf mirror/save
make -C mirror clean
make save load
install_all_clusters sno compact standard 

