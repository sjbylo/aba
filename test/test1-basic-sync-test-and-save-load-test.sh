#!/bin/bash -e
# This test is for a connected bastion.  It will install registry on remote bastion and then sync images and install clusters, 
# ... then savd/load images and install clusters. 

source scripts/include_all.sh
cd `dirname $0`
cd ..

mylog() {
	echo $*
	echo $* >> test/test.log
}

mylog
mylog "===> Starting test $0"
mylog

#> test/test.log

> mirror/mirror.conf
#make distclean 
make -C mirror distclean 
#make uninstall clean 

./aba --version 4.14.9 --vmw ~/.vmware.conf 
#make -C cli clean 
make -C cli

mylog Revert a snapshot and power on the internal bastion vm

(
	source <(normalize-vmware-conf)
	govc snapshot.revert -vm bastion2-internal-rhel8 Latest
	sleep 8
	govc vm.power -on bastion2-internal-rhel8
	sleep 5
)
# Wait for host to come up
ssh $(whoami)@registry2.example.com -- "date" || sleep 2
ssh $(whoami)@registry2.example.com -- "date" || sleep 3
ssh $(whoami)@registry2.example.com -- "date" || sleep 8

set -x

source <(normalize-aba-conf)

# Copy and edit mirror.conf 
scripts/j2 templates/mirror.conf.j2 > mirror/mirror.conf

### sed -i "s/ocp_target_ver=[0-9]\+\.[0-9]\+\.[0-9]\+/ocp_target_ver=$ocp_version/g" ./mirror/mirror.conf

# Various mirror tests:

mylog Confgure mirror to install on remote bastion2 

sed -i "s/registry.example.com/registry2.example.com/g" ./mirror/mirror.conf	# Install on registry2 
sed -i "s#reg_ssh=#reg_ssh=~/.ssh/id_rsa#g" ./mirror/mirror.conf	     	# Remote or localhost

#sed -i "s#channel=.*#channel=fast          #g" ./mirror/mirror.conf	    	# test channel
#sed -i "s#reg_root=#reg_root=~/my-quay-mirror#g" ./mirror/mirror.conf	     	# test other storage location
#sed -i "s#reg_pw=.*#reg_pw=             #g" ./mirror/mirror.conf	    	# test random password 
### sed -i "s#tls_verify=true#tls_verify=            #g" ./mirror/mirror.conf  	# test tlsverify = false # sno install fails 
### sed -i "s#reg_port=.*#reg_pw=443             #g" ./mirror/mirror.conf	    	# test port change
#sed -i "s#reg_path=.*#reg_path=mypath             #g" ./mirror/mirror.conf	    	# test path

mylog Install mirror 

make -C mirror install 

source <(cd mirror;normalize-mirror-conf)

mylog "Mirror available at $reg_host:$reg_port"

######################
mylog make sync
make -C mirror sync   # This will install and sync
mylog make sync done

mylog make sno
rm -rf sno
make sno target=iso
mylog make sno done

mylog make sno delete
make -C sno delete 
mylog make sno delete done

#######################
mylog make save load
make -C mirror save load   #  This will save, install then load
mylog make save load done

mylog make sno
rm -rf sno
make sno target=iso
mylog make sno done

mylog "Installation successful"

mylog make sno delete
make -C sno delete 
mylog "Deletion successful"

mylog make mirror uninstall 

make -C mirror uninstall 

########################
########################
########################

# Copy and edit mirror.conf 
#cp -f templates/mirror.conf mirror/
#scripts/j2 templates/mirror.conf.j2 > mirror/mirror.conf
#sed -i "s/ocp_target_ver=[0-9]\+\.[0-9]\+\.[0-9]\+/ocp_target_ver=$ocp_version/g" ./mirror/mirror.conf

mylog Various mirror tests:

mylog Confgure mirror to install on remote bastion2 in ~/my-quay-mirror, with random password to /mypath 

#sed -i "s/registry.example.com/registry2.example.com/g" ./mirror/mirror.conf	# Install on registry2 
#sed -i "s#reg_ssh=#reg_ssh=~/.ssh/id_rsa#g" ./mirror/mirror.conf	     	# Remote or localhost

sed -i "s#reg_root=#reg_root=~/my-quay-mirror#g" ./mirror/mirror.conf	     	# test other storage location
sed -i "s#reg_pw=.*#reg_pw=             #g" ./mirror/mirror.conf	    	# test random password 
### sed -i "s#tls_verify=true#tls_verify=            #g" ./mirror/mirror.conf  	# test tlsverify = false # sno install fails 
sed -i "s#reg_path=.*#reg_path=mypath             #g" ./mirror/mirror.conf	    	# test path

mylog make mirror install
make -C mirror install 
mylog make mirror install done

######
# Remove all traces of CA files 
### rm -f mirror/regcreds/*pem   # Test without CA file
### sudo rm -f /etc/pki/ca-trust/source/anchors/rootCA*pem
### sudo update-ca-trust extract

mylog rm mirror/save
rm -rf mirror/save   # The process will halt, otherwise with "You already have images saved on local disk"
######


source <(cd mirror;normalize-mirror-conf)

mylog "Mirror available at $reg_host:$reg_port"

######################
mylog make sync

make -C mirror sync   # This will install and sync

mylog make sno
rm -rf sno
make sno target=iso
mylog make sno done

mylog make sno delete
make -C sno delete 
mylog make sno delete done

#######################

mylog make save load 
make -C mirror save load   #  This will save, install then load
mylog make save load done

mylog install sno
rm -rf sno
make sno target=iso
mylog install sno done

mylog make sno delete
make -C sno delete 
mylog make sno delete done

mylog "===> Test save/load complete "

mylog Test use-case for not using VMware 

> vmware.conf
rm -rf compact 

### mkdir compact 
### ln -s ../templates/Makefile compact
### scripts/j2 templates/cluster-compact.conf > compact/cluster.conf

# This needs to be made manuually, since we only want to run "make iso"
source <(normalize-aba-conf)
mylog "make -C compact iso"
rm -rf compact
make compact target=iso
#mkdir  compact
#ln -s ../templates/Makefile compact/Makefile
#scripts/j2 templates/cluster-compact.conf > compact/cluster.conf
#make -C compact iso 
mylog "make -C compact iso - done"

mylog "===> Test 'no vmware' complete "

mylog Tidy up mirror
make -C mirror uninstall 

mylog "===> Test $0 complete "

[ -f test/test.log ] && cp test/test.log test/test.log.bak

