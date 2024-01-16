#!/bin/bash -ex

cd `dirname $0`

##reg_host=host
##reg_port=999
##enc_password=xyz
##mkdir -p ~/.containers ~/.docker
##cat << END >  ~/.docker/config.json
##{
  ##"auths": {
    ##"$reg_host:$reg_port": { 
      ##"auth": "$enc_password"
    ##}
  ##}
##}
##END
##echo DONE
##exit

##cp ~/.docker/config.json ~/.containers/auth.json 

curl -ILsk -o /dev/null https://localhost:8443/health/instance && echo "Mirror registry already installed on `hostname`" && exit 0

if ! rpm -q podman || ! rpm -q rsync; then
	sudo dnf install podman rsync -y
fi

[ ! -x ./mirror-registry ] && tar xvmzf mirror-registry.tar.gz

reg_root=~/quay-install
reg_pw=password
[ "$1" ] && reg_host=$1 || reg_host=registry2.example.com
reg_port=8443

# mirror-registry installer does not open the port for us
echo Allowing firewall access to the registry at $reg_host/$reg_port ...
sudo firewall-cmd --state && sudo firewall-cmd --add-port=$reg_port/tcp --permanent && sudo firewall-cmd --reload

echo "Installing mirror registry on the host [$reg_host] with user $(whoami) ..."

./mirror-registry install --quayHostname $reg_host --initPassword $reg_pw 

reg_user=init

# Configure the pull secret for this mirror registry 
reg_url=https://$reg_host:$reg_port

# Fetch root CA from remote host 
#scp -F .ssh.conf -p $(whoami)@$reg_host:$reg_root/quay-rootCA/rootCA.pem regcreds/

# Check if the cert needs to be updated
sudo diff $reg_root/quay-rootCA/rootCA.pem /etc/pki/ca-trust/source/anchors/rootCA.pem 2>/dev/null >&2 || \
	sudo cp $reg_root/quay-rootCA/rootCA.pem /etc/pki/ca-trust/source/anchors/ && \
		sudo update-ca-trust extract

podman logout --all 
echo -n "Checking registry access is working using 'podman login': "
podman login -u init -p $reg_pw $reg_url 

reg_creds="$reg_user:$reg_pw"
enc_password=$(echo -n "$reg_creds" | base64 -w0)

# Inputs: enc_password, reg_host and reg_port 
#scripts/j2 ./templates/pull-secret-mirror.json.j2 > ./regcreds/pull-secret-mirror.json

# Merge the two files
#jq -s '.[0] * .[1]' ./regcreds/pull-secret-mirror.json $pull_secret_file > ./regcreds/pull-secret-full.json
#cp ./regcreds/pull-secret-full.json ~/.docker/config.json
#cp ./regcreds/pull-secret-full.json ~/.containers/auth.json

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


