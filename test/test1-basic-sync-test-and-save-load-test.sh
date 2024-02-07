#!/bin/bash -e
# This test is for a connected bastion.  It will install registry on remote bastion and then sync images and install clusters, 
# ... then savd/load images and install clusters. 

cd `dirname $0`
cd ..

> mirror/mirror.conf
#make distclean 
make -C mirror distclean 
#make uninstall clean 

./aba --version 4.14.9 --vmw ~/.vmware.conf 
#make -C cli clean 
make -C cli
[ -s mirror/mirror.conf ] && touch mirror/mirror.conf
#rm -f mirror/.installed mirror/regcreds/*

install_cluster() {
	rm -rf $1
	mkdir -p $1
	#ln -fs ../templates $1
	ln -fs ../templates/Makefile $1/Makefile
	scripts/j2 templates/cluster-$1.conf > $1/cluster.conf
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


#### ver=$(cat ./target-ocp-version.conf)
source ./aba.conf

# Copy and edit mirror.conf 
scripts/j2 templates/mirror.conf.j2 > mirror/mirror.conf
### sed -i "s/ocp_target_ver=[0-9]\+\.[0-9]\+\.[0-9]\+/ocp_target_ver=$ocp_version/g" ./mirror/mirror.conf

# Various mirror tests:

sed -i "s/registry.example.com/registry2.example.com/g" ./mirror/mirror.conf	# Install on registry2 
sed -i "s#reg_ssh=#reg_ssh=~/.ssh/id_rsa#g" ./mirror/mirror.conf	     	# Remote or localhost
#sed -i "s#channel=.*#channel=fast          #g" ./mirror/mirror.conf	    	# test channel
#sed -i "s#reg_root=#reg_root=~/my-quay-mirror#g" ./mirror/mirror.conf	     	# test other storage location
#sed -i "s#reg_pw=.*#reg_pw=             #g" ./mirror/mirror.conf	    	# test random password 
### sed -i "s#tls_verify=true#tls_verify=            #g" ./mirror/mirror.conf  	# test tlsverify = false # sno install fails 
### sed -i "s#reg_port=.*#reg_pw=443             #g" ./mirror/mirror.conf	    	# test port change
#sed -i "s#reg_path=.*#reg_path=mypath             #g" ./mirror/mirror.conf	    	# test path

make -C mirror install 

. mirror/mirror.conf

echo "Mirror available at $reg_host:$reg_port"

######################
echo Runtest: START - sync

make -C mirror sync   # This will install and sync

install_all_clusters sno

#######################
#echo Runtest: START - load

make -C mirror save load   #  This will save, install then load

install_all_clusters sno

# Tidy up
make -C mirror uninstall 

########################
########################
########################

# Copy and edit mirror.conf 
#cp -f templates/mirror.conf mirror/
#scripts/j2 templates/mirror.conf.j2 > mirror/mirror.conf
#sed -i "s/ocp_target_ver=[0-9]\+\.[0-9]\+\.[0-9]\+/ocp_target_ver=$ocp_version/g" ./mirror/mirror.conf

# Various mirror tests:

#sed -i "s/registry.example.com/registry2.example.com/g" ./mirror/mirror.conf	# Install on registry2 
#sed -i "s#reg_ssh=#reg_ssh=~/.ssh/id_rsa#g" ./mirror/mirror.conf	     	# Remote or localhost
sed -i "s#reg_root=#reg_root=~/my-quay-mirror#g" ./mirror/mirror.conf	     	# test other storage location
sed -i "s#reg_pw=.*#reg_pw=             #g" ./mirror/mirror.conf	    	# test random password 
### sed -i "s#tls_verify=true#tls_verify=            #g" ./mirror/mirror.conf  	# test tlsverify = false # sno install fails 
sed -i "s#reg_path=.*#reg_path=mypath             #g" ./mirror/mirror.conf	    	# test path

make -C mirror install 

######
# Remove all traces of CA files 
### rm -f mirror/regcreds/*pem   # Test without CA file
### sudo rm -f /etc/pki/ca-trust/source/anchors/rootCA*pem
### sudo update-ca-trust extract

rm -rf mirror/save   # The process will halt, otherwise with "You already have images saved on local disk"
######


. mirror/mirror.conf

echo "Mirror available at $reg_host:$reg_port"

######################
echo Runtest: START - sync

make -C mirror sync   # This will install and sync

install_all_clusters sno

echo "===> Test sync complete "

#######################
#echo Runtest: START - load

make -C mirror save load   #  This will save, install then load

install_all_clusters sno

echo "===> Test save/load complete "

##### Test not using VMware #####

> vmware.conf
rm -rf compact 
mkdir compact 
ln -s ../templates/Makefile compact
scripts/j2 templates/cluster-compact.conf > compact/cluster.conf
make -C compact iso 

echo "===> Test no vmware complete "

# Tidy up
make -C mirror uninstall 

echo "===> Test complete "
