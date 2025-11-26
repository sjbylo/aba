#!/bin/bash -e
# Quick test to create ISO/cluster for a container (ARM and/or x86_64 both work)

export DOCKER=podman

# Check if already logged in
if echo "$(jq -r '.auths["quay.io"].auth' ~/.docker/config.json | base64 -d)" | grep -q sbylo; then
	echo Already logged into quay.io
else
	# Be sure to log into quay.io# Use robot key from quay.io UI
	[ ! -s ~/.quay.io.key ] && echo "Please store quay.io robot key to ~/.quay.io.key and try again!" >&2 && exit 1
	$DOCKER login quay.io -u sjbylo+robot -p $(cat ~/.quay.io.key)
fi

#############################

arch=$(uname -m)
cont_name=test-stream9

##echo Stopping $cont_name
##$DOCKER stop $cont_name || true
##while $DOCKER ps | awk '{print $NF}' | grep $cont_name
##do
##	echo Sleeping 1s ...
##	sleep 1
##done
##sleep 1

#echo Removing $cont_name
#$DOCKER rm -v $cont_name || true
#sleep 1

# 7200
if ! $DOCKER ps | grep -i $cont_name; then
	if ! $DOCKER ps -a | grep -i $cont_name; then
		echo "Starting $arch quay.io/centos/centos:stream9 container"
		#$DOCKER run -d --rm --name $cont_name  quay.io/centos/centos:stream9 sleep infinity || \
		$DOCKER run -d --rm --name $cont_name  quay.io/centos/centos:stream9 sleep infinity
	else
		$DOCKER start -d --rm --name $cont_name  quay.io/centos/centos:stream9 sleep infinity
	fi
fi

sleep 0.5

echo "Copy ~/.ssh into container ..."
$DOCKER cp ~/.ssh $cont_name:/root

echo "Copy ~/.proxy-set.sh into container ..."
$DOCKER cp ~/.proxy-set.sh $cont_name:/root

echo "Copy ~/.pull-secret.json into container ..."
$DOCKER cp ~/.pull-secret.json $cont_name:/root

echo "Copy ~/. vmware.conf into container ..."
$DOCKER cp ~/.vmware.conf    $cont_name:/root/.vmware.conf
$DOCKER cp ~/.vmware.conf.vc $cont_name:/root/.vmware.conf

# install aba and run tests
$DOCKER exec -i $cont_name bash <<'END'
set -e
set -x
arch=$(uname -m)
echo "PATH=$HOME/bin:$PATH" >> $HOME/.bashrc
PATH=$HOME/bin:$PATH
echo "alias ll='ls -l'" >> $HOME/.bashrc
alias ll='ls -l'
echo Arch = $arch
chown root.root ~/.ssh/*
echo TERM=$TERM
export TERM=xterm 
echo TERM=$TERM
cd
pwd
ls -l .*conf .*json .*.sh
ls -l .ssh
source ~/.proxy-set.sh
#export no_proxy=.lan,.example.com
#export http_proxy=http://10.0.1.8:3128
#export https_proxy=http://10.0.1.8:3128
env | grep -i proxy
#set +x
echo "Installing aba ..."
[ ! -d aba ] && bash -c "$(curl -fsSL https://raw.githubusercontent.com/sjbylo/aba/refs/heads/dev/install)" -- dev
set -x
cd aba
#aba -d cli govc
echo "Config aba.conf ..."
aba -A --channel stable --version latest -p vmw
grep -e ocp_channel -e ocp_version aba.conf
echo DONE PART 1
END

if [ "$arch" = "x86_64" ]; then

$DOCKER exec -i $cont_name bash <<'END'
set -e
echo START PART 2
arch=$(uname -m)
echo Arch = $arch
source ~/.proxy-set.sh
echo TERM=$TERM
export TERM=xterm 
echo TERM=$TERM
cd ~/aba
scp -rp steve@mirror.example.com:aba/mirror/regcreds/* mirror/regcreds
ls -l mirror/regcreds
aba -y mirror -H mirror.example.com -k "~/.ssh/id_rsa" -U steve
#sed -i "s/^.*reg_ssh_user=.*/reg_ssh_user=steve/g" mirror.conf
#sed -i "s#^.*reg_ssh_key=.*#reg_ssh_key=~/.ssh/id_rsa#g" mirror.conf
# reg_ssh_key=~/.ssh/id_rsa
grep -e mirror.example.com -e steve -e reg_ssh_key mirror/mirror.conf
#rm -fv vmware.conf
aba vmw
###
###cp .shortcuts.conf shortcuts.conf
cname=sno2
aba -y cluster --name $cname -t sno --starting-ip 10.0.1.202 -s cluster.conf
# aba cluster -n $cname -t sno --starting-ip 10.0.1.202
echo "Config $cname cluster.conf ..."
cd $cname
echo "Genrate ISO ..."
aba iso
echo "Install cluster ..."
aba 
echo DONE PART 2
END

#[ "$arch" = "aarch64" ] && echo "Not installing cluster on arm, exiting" && exit 0

else

$DOCKER exec -i $cont_name bash <<'END'
arch=$(uname -m)
echo Arch = $arch
exit
aba cluster --name $cname --type sno --int-connection proxy --starting-ip 10.0.1.201 -s cluster.conf
echo "Config $cname cluster.conf ..."
cd $cname
####echo 00:50:56:05:7B:01 > macs.conf
echo "Genrate ISO ..."
aba iso
[ "$arch" = "aarch64" ] && echo "Not installing cluster on arm, exiting" && exit 0
echo "Install cluster ..."
aba 
END


fi

#$DOCKER cp $cont_name:/root/aba/sno2/iso-agent-based/agent.$arch.iso .
#sudo chown steve agent.$arch.iso
#rm -f ~/tmp/agent.$arch.iso
#mv -f agent.$arch.iso ~/tmp

