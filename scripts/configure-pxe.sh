#!/bin/bash
# Create PXE env (not in nuse)

source scripts/include_all.sh

aba_debug "Starting: $0 $*"



umask 077

#source <(normalize-aba-conf)
#source <(normalize-mirror-conf)

if [ ! -d iso-agent-based/boot-artifacts ]; then
	aba_abort "Directory 'iso-agent-based/boot-artifacts' does not exist!"
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
aba_info "PXE boot artifacts have been made available at:"
aba_info "http://<this host ip>/agent.$ARCH-vmlinuz"
echo

