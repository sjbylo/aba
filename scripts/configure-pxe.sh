#!/bin/bash

source scripts/include_all.sh

[ "$1" ] && set -x

umask 077

#source <(normalize-aba-conf)
#source <(normalize-mirror-conf)

if [ ! -d iso-agent-based/boot-artifacts ]; then
	echo "Directory 'iso-agent-based/boot-artifacts' does not exist!"
	exit 1
fi

sudo dnf install httpd -y
sudo systemctl start httpd
sudo systemctl enable httpd

sudo firewall-cmd --add-port=80/tcp --permanent
sudo firewall-cmd --reload

sudo cp iso-agent-based/boot-artifacts/* /var/www/html
sudo chown -R apache /var/www/html

# Open up SELinux
sudo chcon -R -t httpd_sys_content_t /var/www/html

echo 
echo "PXE boot artifacts have been made available at:"
echo "http://<this host ip>/agent.x86_64-vmlinuz"
echo

