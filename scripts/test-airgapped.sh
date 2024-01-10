#!/bin/bash -ex

dir=`dirname $0`
cd $dir/..

install_cluster() {
	rm -rf $1
	mkdir -p $1
	#ln -fs ../templates $1
	ln -fs ../templates/Makefile $1/Makefile
	cp templates/aba-$1.conf $1/aba.conf
	make -C $1
	echo $1 completed
}

install_all_clusters() {
	for c in $@
	do
		echo Runtest: creating cluster $c
		install_cluster $c
		#make -C $c delete
	done
}

####make -C mirror uninstall  # FIXME... add back and also "make vmware.conf" to prep.

#####
ver=$(cat ./target-ocp-version.conf)

# Copy and edit mirror.conf if needed
cp -f templates/mirror.conf .

sed -i "s/ocp_target_ver=[0-9]\+\.[0-9]\+\.[0-9]\+/ocp_target_ver=$ver/g" ./mirror.conf
####

## test for remote mirror
sed -i "s/registry.example.com/registry2.example.com/g" ./mirror.conf
sed -i "s#reg_ssh=#reg_ssh=~/.ssh/id_rsa#g" ./mirror.conf
cp mirror.conf mirror
## test for remote mirror

######################
echo Runtest: START - airgap

bastion2=10.0.1.6

# Have quay running somewhere that the internal bastion can reach
make -C mirror install    # Install quay on internal bastion (just for testing)
rm -f mirror/.installed   # Needed, since the install will normally only be run on the internal bastion
rm -f mirror/.loaded      # Be sure this is not copied over in case it exists

make save
make -C mirror tidy   # Remove some crud

#####
# 
#sudo yum install nmap-ncat -y 
#ssh $(whoami)@$bastion2 sudo yum install  nmap-ncat -y  

p=22222
###ssh $(whoami)@$bastion2 -- "sudo firewall-cmd --add-port=$p/tcp --permanent && sudo firewall-cmd --reload"

#ssh $(whoami)@$bastion2 -- "rm -rf ~/bin/* ~/aba"
cd
# Use one of the other copy command!
#time tar czf - `find bin aba -type f ! -path "aba/.git*" -a ! -path "aba/cli/*"` | ssh $(whoami)@$bastion2 tar xvzf -
time rsync --progress --partial --times -avz --exclude '*/.git*' --exclude 'aba/cli/*' bin aba $(whoami)@10.0.1.6:

ssh $(whoami)@$bastion2 -- "cd ~/aba && make load sno" 


