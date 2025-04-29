#!/bin/bash
# Create PXE env (not in nuse)

source scripts/include_all.sh

[ "$1" ] && set -x

umask 077

#source <(normalize-aba-conf)
#source <(normalize-mirror-conf)

if [ ! -d iso-agent-based/boot-artifacts ]; then
	echo "Directory 'iso-agent-based/boot-artifacts' does not exist!"
	exit 1
fi

$SUDO dnf install httpd -y
$SUDO systemctl start httpd
$SUDO systemctl enable httpd

$SUDO firewall-cmd --add-port=80/tcp --permanent
$SUDO firewall-cmd --reload

$SUDO cp iso-agent-based/boot-artifacts/* /var/www/html
$SUDO chown -R apache /var/www/html

# Open up SELinux
$SUDO chcon -R -t httpd_sys_content_t /var/www/html

echo 
echo "PXE boot artifacts have been made available at:"
echo "http://<this host ip>/agent.$arch_sys-vmlinuz"
echo

