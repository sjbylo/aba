#!/bin/bash -ex
# Basic script to install registry for testing only

cd `dirname $0`

sudo dnf install hostname -y   # Hack due to tests for missing packages

curl --retry 3 -ILsk -o /dev/null https://localhost:8443/health/instance && echo "Mirror registry already installed on `hostname`" && exit 0

if ! rpm -q podman || ! rpm -q rsync; then
	sudo dnf install podman rsync -y
fi

if [ ! -x ./mirror-registry ]; then
	if file mirror-registry-amd64.tar.gz | grep -i "gzip compressed data"; then
		tar xvmzf mirror-registry-amd64.tar.gz 
	else
		echo "File corrupt? mirror-registry-amd64.tar.gz"
		exit 1
	fi
fi

[ ! "$data_dir" ] && data_dir=$HOME
reg_root=$data_dir/quay-install

##reg_root=~/quay-install  # ~ must be evaluated here
reg_pw=p4ssw0rd
[ "$1" ] && reg_host=$1 || reg_host=registry.example.com   #FIXME: needs to be param
reg_port=8443

# mirror-registry installer does not open the port for us
echo Allowing firewall access to the registry at $reg_host/$reg_port ...
sudo firewall-cmd --state && sudo firewall-cmd --add-port=$reg_port/tcp --permanent && sudo firewall-cmd --reload

echo "Installing mirror registry on the host [$reg_host] with user `whoami`@`hostname` ..."

./mirror-registry install --quayHostname $reg_host --initPassword $reg_pw 

reg_user=init

# Configure the pull secret for this mirror registry 
reg_url=https://$reg_host:$reg_port

# Fetch root CA from remote host 
#scp -F .ssh.conf -p $reg_ssh_user@$reg_host:$reg_root/quay-rootCA/rootCA.pem regcreds/

# Check if the cert needs to be updated
trust_root_ca $reg_root/quay-rootCA/rootCA.pem
#sudo diff $reg_root/quay-rootCA/rootCA.pem /etc/pki/ca-trust/source/anchors/rootCA.pem 2>/dev/null >&2 || \
#	sudo cp $reg_root/quay-rootCA/rootCA.pem /etc/pki/ca-trust/source/anchors/ && \
#		sudo update-ca-trust extract

podman logout --all 
echo -n "Checking registry access is working using 'podman login': "
podman login -u init -p $reg_pw $reg_url 

reg_creds="$reg_user:$reg_pw"
enc_password=$(echo -n "$reg_creds" | base64 -w0)

mkdir -p ~/.containers ~/.docker
cat << END >  ~/.docker/config.json
{
  "auths": {
    "$reg_host:$reg_port": { 
      "auth": "$enc_password"
    }
  }
}
END
cp ~/.docker/config.json ~/.containers/auth.json 


