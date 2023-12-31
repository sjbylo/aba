#!/bin/bash -e

install_cluster() {
	rm -rf $1
	mkdir -p $1
	#ln -fs ../templates $1
	ln -fs ../templates/Makefile $1/Makefile
	cp test/aba-$1.conf $1/aba.conf
	make -C $1
	#make -C $1 stop
}

install_all_clusters() {
	for c in $@
	do
		echo Runtest: creating cluster $c
		install_cluster $c
		make -C $c delete
	done

	#for c in $@
	#do
		#echo Runtest: deleting cluster $c
		#install_cluster $c
	#done
}

cp templates/mirror.conf .
#make vmware.conf

######################
echo Runtest: START - sync
mirror/mirror-registry uninstall --autoApprove || true
rm -rf mirror/deps
make -C mirror clean
make sync 
install_all_clusters sno compact standard 

######################
echo Runtest: START - load
mirror/mirror-registry uninstall --autoApprove || true
rm -rf mirror/deps
make -C mirror clean
make save load
install_all_clusters sno compact standard 

