#!/bin/bash
# create-vm.sh -- Create a ready-to-use RHEL VM from ISO using govc + kickstart.
#
# Builds a RHEL VM with a fully automated kickstart install.  Supports
# configurable disk layout (single root LV, optional /home and swap),
# user account, sudo policy, NTP server, and more.
#
# Requires: govc, xorrisofs (or mkisofs/genisoimage), mtools, ssh
# See --help for full option list.

set -euo pipefail

# ── Source vmware.conf for govc defaults ──────────────────────────────────────
[ -f "$HOME/.vmware.conf" ] && source "$HOME/.vmware.conf"

export GOVC_URL="${GOVC_URL:-}" GOVC_USERNAME="${GOVC_USERNAME:-}"
export GOVC_PASSWORD="${GOVC_PASSWORD:-}" GOVC_INSECURE="${GOVC_INSECURE:-true}"
export GOVC_DATASTORE="${GOVC_DATASTORE:-}" GOVC_DATACENTER="${GOVC_DATACENTER:-}"

# ── Defaults ──────────────────────────────────────────────────────────────────
RHEL_VER=9
VM_NAME=""
VM_HOSTNAME=""
DISK_GB=100
HOME_GB=0
SWAP_GB=4
CPU=4
MEM_MB=8192
SSH_USER="user"
SUDO_NOPASSWD=1
NTP_SERVER="10.0.1.8"
NTP_POOL="rhel.pool.ntp.org"
DNS_SERVER=""
TIMEZONE="Asia/Singapore"
SSH_PUBKEY="$HOME/.ssh/id_rsa.pub"
VM_NETWORK="${GOVC_NETWORK:-Lab Network}"
MAC_ADDR=""
EXTRA_NETWORKS=()
EXTRA_MACS=()
VM_DATASTORE="${GOVC_DATASTORE:-}"
ISO_DATASTORE="NFS-Shared"
ISO_PATH=""
VC_FOLDER="${VC_FOLDER:-}"
SNAPSHOT_NAME="orig"
NO_PASSWORD=0
REGISTER=0
FORCE=0
DRY_RUN=0
POWER_ON=1

# Runtime state
_TMPDIR=""
_VM_IP=""
_VM_PW=""
_KS_DS_PATH=""
_SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -o LogLevel=ERROR"

# ── Usage / help ──────────────────────────────────────────────────────────────
usage() {
cat <<'EOF'
Usage: tools/create-vm.sh -n NAME [OPTIONS]

Create a ready-to-use RHEL VM from DVD ISO using govc and kickstart.

The VM is installed unattended, configured with the specified user account,
disk layout, and NTP settings, then shut down and snapshotted.

REQUIRED (at least one):
  -n, --name NAME         VM name in vCenter (derived from --hostname if omitted)
  -H, --hostname FQDN     Guest OS hostname (derived from --name if omitted)

DISK LAYOUT:
  -d, --disk GB           Total disk size (default: 100)
      --home GB           Add a separate /home LV of this size
      --swap GB           Swap LV size in GB (default: 4, use 0 to disable)

  By default the root LV (/) fills the entire disk minus /boot and /boot/efi.
  When --home or --swap are specified, root gets the remaining space.

USER ACCOUNT:
  -u, --user NAME         Username (default: user)
      --sudo-nopasswd     Passwordless sudo (default)
      --sudo-password     Require password for sudo
  -P, --no-password       No console password (SSH-only access)
  -S, --ssh-pubkey FILE   Public key to install (default: ~/.ssh/id_rsa.pub)

SYSTEM:
  -r, --rhel N            RHEL version: 8, 9, or 10 (default: 9)
      --ntp IP            NTP server IP (default: 10.0.1.8)
      --ntp-pool POOL     NTP pool name (default: rhel.pool.ntp.org)
      --dns IP            DNS server IP; ignores DHCP-provided DNS on all NICs
      --timezone TZ       Timezone (default: Asia/Singapore)

VM HARDWARE:
  -c, --cpu N             Number of CPUs (default: 4)
  -m, --mem MB            Memory in MB (default: 8192)
  -N, --network NET[,MAC] Primary network — gets the default route (default: GOVC_NETWORK)
      --add-net NET[,MAC] Add an extra NIC (subnet only, no default gw; repeatable)
      --mac ADDR          Set a specific MAC address on the primary NIC

VCENTER:
      --folder PATH       vCenter folder to place VM in
      --iso-datastore DS  Datastore with RHEL DVD ISO (default: NFS-Shared)
      --iso-path PATH     ISO path on datastore (auto-detected if unset)
      --vm-datastore DS   Datastore for VM disk (default: from ~/.vmware.conf)

OTHER:
  -s, --snapshot NAME     Snapshot name (default: orig)
      --no-snapshot       Skip snapshot creation
      --no-power-on       Leave VM powered off after snapshot
      --register          Register with Red Hat (requires SUB_USERNAME/SUB_PASSWORD)
  -f, --force             Destroy existing VM with same name
  -D, --dry-run           Show configuration + kickstart, then exit
  -h, --help              Show this help

ENVIRONMENT VARIABLES (optional):
  VM_PASSWORD         Console password for user (skips interactive prompt)
  SUB_USERNAME        Red Hat subscription username (enables registration)
  SUB_PASSWORD        Red Hat subscription password
  GOVC_*              Standard govc environment (or use ~/.vmware.conf)

EXAMPLES:
  # Minimal RHEL 10 VM, single root LV, no swap
  tools/create-vm.sh -r 10 -n conno -H conno.example.com -d 300 -P

  # RHEL 9 with /home and swap
  tools/create-vm.sh -r 9 -n myvm -d 200 --home 50 --swap 4

  # Custom user, password-protected sudo
  tools/create-vm.sh -n devbox --user alice --sudo-password

  # Specific MAC address for DHCP reservation
  tools/create-vm.sh -r 10 -n conno -d 300 --mac 00:0c:29:f2:49:43 -P

  # Multiple NICs (internal + internet)
  tools/create-vm.sh -r 10 -H myvm.example.com -d 100 -N "Lab Network" --add-net "Ext Network"

  # Different NTP server and timezone
  tools/create-vm.sh -n lab1 --ntp 192.168.1.1 --timezone America/New_York

  # Preview kickstart without creating anything
  tools/create-vm.sh -n test -D
EOF
exit 0
}

# ── Parse CLI arguments ───────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
	case "$1" in
		-r|--rhel)          RHEL_VER="$2"; shift 2 ;;
		-n|--name)          VM_NAME="$2"; shift 2 ;;
		-H|--hostname)      VM_HOSTNAME="$2"; shift 2 ;;
		-d|--disk)          DISK_GB="$2"; shift 2 ;;
		--home)             HOME_GB="$2"; shift 2 ;;
		--swap)             SWAP_GB="$2"; shift 2 ;;
		-u|--user)          SSH_USER="$2"; shift 2 ;;
		--sudo-nopasswd)    SUDO_NOPASSWD=1; shift ;;
		--sudo-password)    SUDO_NOPASSWD=0; shift ;;
		-P|--no-password)   NO_PASSWORD=1; shift ;;
		-S|--ssh-pubkey)    SSH_PUBKEY="$2"; shift 2 ;;
		--ntp)              NTP_SERVER="$2"; shift 2 ;;
		--ntp-pool)         NTP_POOL="$2"; shift 2 ;;
		--dns)              DNS_SERVER="$2"; shift 2 ;;
		--timezone)         TIMEZONE="$2"; shift 2 ;;
		-c|--cpu)           CPU="$2"; shift 2 ;;
		-m|--mem)           MEM_MB="$2"; shift 2 ;;
		-N|--network)
			# Accept "NETWORK" or "NETWORK,MAC"
			if [[ "$2" == *,* ]]; then
				VM_NETWORK="${2%%,*}"
				MAC_ADDR="${2#*,}"
			else
				VM_NETWORK="$2"
			fi
			shift 2 ;;
		--add-net)
			# Accept "NETWORK" or "NETWORK,MAC"
			if [[ "$2" == *,* ]]; then
				EXTRA_NETWORKS+=("${2%%,*}")
				EXTRA_MACS+=("${2#*,}")
			else
				EXTRA_NETWORKS+=("$2")
				EXTRA_MACS+=("")
			fi
			shift 2 ;;
		--mac)              MAC_ADDR="$2"; shift 2 ;;
		--folder)           VC_FOLDER="$2"; shift 2 ;;
		--iso-datastore)    ISO_DATASTORE="$2"; shift 2 ;;
		--iso-path)         ISO_PATH="$2"; shift 2 ;;
		--vm-datastore)     VM_DATASTORE="$2"; shift 2 ;;
		-s|--snapshot)      SNAPSHOT_NAME="$2"; shift 2 ;;
		--no-snapshot)      SNAPSHOT_NAME=""; shift ;;
		--no-power-on)      POWER_ON=0; shift ;;
		--register)         REGISTER=1; shift ;;
		-f|--force)         FORCE=1; shift ;;
		-D|--dry-run)       DRY_RUN=1; shift ;;
		-h|--help)          usage ;;
		*)                  echo "ERROR: unknown option: $1" >&2; echo "Try --help" >&2; exit 1 ;;
	esac
done

# ── Derived defaults ──────────────────────────────────────────────────────────
# Derive name ↔ hostname from each other
if [ -n "$VM_HOSTNAME" ] && [ -z "$VM_NAME" ]; then
	VM_NAME="${VM_HOSTNAME%%.*}"
elif [ -n "$VM_NAME" ] && [ -z "$VM_HOSTNAME" ]; then
	VM_HOSTNAME="${VM_NAME}.example.com"
elif [ -z "$VM_NAME" ] && [ -z "$VM_HOSTNAME" ]; then
	echo "ERROR: --name or --hostname is required" >&2
	echo "Try --help" >&2
	exit 1
fi

case "$RHEL_VER" in
	8)  _GUEST_ID="rhel8_64Guest" ;;
	9)  _GUEST_ID="rhel9_64Guest" ;;
	10) _GUEST_ID="rhel9_64Guest" ;;
	*)  echo "ERROR: unsupported --rhel version '$RHEL_VER' (use 8, 9, or 10)" >&2; exit 1 ;;
esac

# ── Helper functions ──────────────────────────────────────────────────────────
_rssh() { ssh $_SSH_OPTS "${SSH_USER}@${_VM_IP}" -- "$@"; }
_rscp() { scp $_SSH_OPTS "$@"; }

_find_mkiso() {
	local cmd
	for cmd in xorrisofs mkisofs genisoimage; do
		command -v "$cmd" >/dev/null 2>&1 && echo "$cmd" && return
	done
}


# ── Validate prerequisites ────────────────────────────────────────────────────
validate() {
	local errors=0

	for cmd in govc ssh scp; do
		if ! command -v "$cmd" >/dev/null 2>&1; then
			echo "ERROR: '$cmd' not found in PATH" >&2
			errors=$((errors + 1))
		fi
	done

	if [ -z "$(_find_mkiso)" ]; then
		echo "ERROR: mkisofs/genisoimage/xorrisofs not found (install xorriso)" >&2
		errors=$((errors + 1))
	fi

	if [ ! -f "$SSH_PUBKEY" ]; then
		echo "ERROR: SSH public key not found: $SSH_PUBKEY" >&2
		errors=$((errors + 1))
	fi

	if [ -z "$GOVC_URL" ]; then
		echo "ERROR: GOVC_URL not set (source ~/.vmware.conf or export GOVC_URL)" >&2
		errors=$((errors + 1))
	fi

	if [ -z "$VM_DATASTORE" ]; then
		echo "ERROR: VM datastore not set (--vm-datastore or GOVC_DATASTORE)" >&2
		errors=$((errors + 1))
	fi

	[ "$errors" -gt 0 ] && exit 1

	# Auto-detect RHEL ISO on the datastore
	if [ -z "$ISO_PATH" ]; then
		local iso_file
		iso_file=$(govc datastore.ls -ds "$ISO_DATASTORE" "images/" 2>/dev/null \
			| grep "rhel-${RHEL_VER}.*dvd\.iso" | head -1) || true
		if [ -z "$iso_file" ]; then
			echo "ERROR: no RHEL ${RHEL_VER} ISO found on [$ISO_DATASTORE] images/" >&2
			echo "  Upload an ISO or use --iso-path to specify the path" >&2
			exit 1
		fi
		ISO_PATH="images/$iso_file"
	fi

	# Handle existing VM
	if [ "$DRY_RUN" = 0 ] && govc find -type m -name "$VM_NAME" 2>/dev/null | grep -q .; then
		if [ "$FORCE" = 1 ]; then
			echo "  --force: destroying existing VM '$VM_NAME' ..."
			govc vm.power -off "$VM_NAME" 2>/dev/null || true
			govc vm.destroy "$VM_NAME" 2>/dev/null || true
		else
			echo "ERROR: VM '$VM_NAME' already exists (use --force to replace)" >&2
			exit 1
		fi
	fi
}

# ── Prompt for console password ───────────────────────────────────────────────
prompt_password() {
	[ "$NO_PASSWORD" = 1 ] && return
	if [ -n "${VM_PASSWORD:-}" ]; then
		_VM_PW="$VM_PASSWORD"
		return
	fi
	[ "$DRY_RUN" = 1 ] && return

	echo ""
	read -s -p "  Password for ${SSH_USER} (console access, empty to skip): " _VM_PW
	echo
	if [ -z "$_VM_PW" ]; then
		echo "  No password set (use -P to suppress this prompt)"
		return
	fi
	local _pw2
	read -s -p "  Confirm: " _pw2
	echo
	if [ "$_VM_PW" != "$_pw2" ]; then
		echo "ERROR: passwords do not match" >&2
		exit 1
	fi
}

# ── Cleanup trap ──────────────────────────────────────────────────────────────
cleanup() {
	[ -n "${_TMPDIR:-}" ] && [ -d "$_TMPDIR" ] && rm -rf "$_TMPDIR"
	if [ -n "${_KS_DS_PATH:-}" ]; then
		govc datastore.rm -ds "$VM_DATASTORE" "$_KS_DS_PATH" 2>/dev/null || true
	fi
}
trap cleanup EXIT

# ── Show configuration summary ────────────────────────────────────────────────
show_config() {
	local layout="/ (root only, ${DISK_GB} GB disk)"
	[ "$HOME_GB" -gt 0 ] && layout="/ + /home (${HOME_GB} GB)"
	[ "$SWAP_GB" -gt 0 ] && layout="${layout} + swap (${SWAP_GB} GB)"
	local sudo_mode="NOPASSWD"
	[ "$SUDO_NOPASSWD" = 0 ] && sudo_mode="password required"

	echo ""
	echo "=== Creating RHEL ${RHEL_VER} VM: ${VM_NAME} ==="
	echo ""
	echo "  RHEL version:   ${RHEL_VER}"
	echo "  VM name:        ${VM_NAME}"
	echo "  Hostname:       ${VM_HOSTNAME}"
	echo "  Disk layout:    ${layout}"
	echo "  CPU / Memory:   ${CPU} vCPU / ${MEM_MB} MB"
	echo "  Firmware:       EFI"
	echo "  NIC 0:          ${VM_NETWORK} (DHCP)"
	[ -n "$MAC_ADDR" ] && \
	echo "  MAC address:    ${MAC_ADDR}"
	local _nic_idx=1
	for _nic_idx in $(seq 0 $(( ${#EXTRA_NETWORKS[@]} - 1 )) 2>/dev/null); do
		local _extra_mac="${EXTRA_MACS[$_nic_idx]:-}"
		local _mac_info=""
		[ -n "$_extra_mac" ] && _mac_info=" (MAC: ${_extra_mac})"
		echo "  NIC $((_nic_idx + 1)):          ${EXTRA_NETWORKS[$_nic_idx]}${_mac_info}"
	done
	echo "  User:           ${SSH_USER} (sudo: ${sudo_mode})"
	echo "  NTP:            ${NTP_SERVER}, ${NTP_POOL}"
	[ -n "$DNS_SERVER" ] && \
	echo "  DNS:            ${DNS_SERVER} (DHCP DNS ignored)"
	echo "  Timezone:       ${TIMEZONE}"
	echo "  ISO:            [${ISO_DATASTORE}] ${ISO_PATH}"
	echo "  VM datastore:   ${VM_DATASTORE}"
	[ -n "$VC_FOLDER" ] && \
	echo "  Folder:         ${VC_FOLDER}"
	[ -n "$SNAPSHOT_NAME" ] && \
	echo "  Snapshot:       ${SNAPSHOT_NAME}"
	echo "  SSH pubkey:     ${SSH_PUBKEY}"
	if [ -n "${_VM_PW:-}" ]; then
		echo "  Password:       (set)"
	elif [ "$NO_PASSWORD" = 1 ]; then
		echo "  Password:       none (--no-password)"
	else
		echo "  Password:       none"
	fi
	if [ "$REGISTER" = 1 ] && [ -n "${SUB_USERNAME:-}" ]; then
		echo "  Registration:   ${SUB_USERNAME}"
	fi
	echo ""
}

# ── Step 1: Generate kickstart ────────────────────────────────────────────────
generate_kickstart() {
	echo "Step 1/7: Generating kickstart ..."

	_TMPDIR=$(mktemp -d /tmp/create-vm.XXXXXX)
	local ks="$_TMPDIR/ks.cfg"
	local pubkey
	pubkey=$(cat "$SSH_PUBKEY")

	# Build the partition / LVM section dynamically
	local lvm_lines="logvol / --fstype=xfs --vgname=rhel --name=root --size=1 --grow"
	[ "$SWAP_GB" -gt 0 ] && lvm_lines="${lvm_lines}
logvol swap --vgname=rhel --name=swap --size=${SWAP_GB}000"
	[ "$HOME_GB" -gt 0 ] && lvm_lines="${lvm_lines}
logvol /home --fstype=xfs --vgname=rhel --name=home --size=${HOME_GB}000"

	# Sudo configuration
	local sudo_line
	if [ "$SUDO_NOPASSWD" = 1 ]; then
		sudo_line="${SSH_USER} ALL=(ALL) NOPASSWD:ALL"
	else
		sudo_line="${SSH_USER} ALL=(ALL) ALL"
	fi

	# Build network lines: primary NIC + extra NICs, all DHCP.
	# If extra NICs exist, the primary (internal) gets high metric and the
	# last NIC (typically internet) gets low metric so it becomes the default route.
	# Only configure the primary NIC in kickstart. Extra NICs are configured
	# by the configure-nics firstboot service (Anaconda assigns multiple
	# network lines to devices unpredictably without --device).
	local net_lines="network --bootproto=dhcp --activate --onboot=yes --hostname=${VM_HOSTNAME}"
	# Explicit DNS: provide nameserver during install; DHCP DNS is suppressed
	# post-install via configure-nics firstboot service
	if [ -n "$DNS_SERVER" ]; then
		net_lines="${net_lines} --nameserver=${DNS_SERVER}"
	fi

	cat > "$ks" <<KSEOF
#version=RHEL${RHEL_VER}
# Automated RHEL ${RHEL_VER} kickstart -- generated by create-vm.sh

cdrom
text
firstboot --disable
eula --agreed

lang en_US.UTF-8
keyboard us
timezone ${TIMEZONE} --utc

${net_lines}

selinux --enforcing
firewall --enabled --ssh

rootpw --lock
user --name=${SSH_USER} --groups=wheel --shell=/bin/bash
sshkey --username=${SSH_USER} "${pubkey}"

bootloader --append="console=tty0" --location=mbr

ignoredisk --only-use=sda
clearpart --all --initlabel --drives=sda
zerombr
part /boot/efi --fstype=efi --size=600
part /boot --fstype=xfs --size=1024
part pv.01 --size=1 --grow
volgroup rhel pv.01
${lvm_lines}

%packages --ignoremissing
@core
openssh-server
sudo
chrony
cloud-utils-growpart
lvm2
open-vm-tools
-plymouth
%end

%post --log=/root/ks-post.log
set -ex

# ── expand-root.service: auto-grow / when vDisk is resized later ──
cat > /etc/systemd/system/expand-root.service <<'SVCEOF'
[Unit]
Description=Expand root filesystem to fill disk
After=local-fs.target
ConditionPathExists=!/var/lib/expand-root.done

[Service]
Type=oneshot
ExecStart=/usr/local/bin/expand-root.sh
ExecStartPost=/bin/touch /var/lib/expand-root.done
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF

cat > /usr/local/bin/expand-root.sh <<'SHEOF'
#!/bin/bash
set -x
DISK=/dev/sda
PART=3
growpart "\$DISK" "\$PART" || true
pvresize "\${DISK}\${PART}" || true
lvextend -l +100%FREE /dev/rhel/root || true
xfs_growfs / || true
SHEOF
chmod 755 /usr/local/bin/expand-root.sh
systemctl enable expand-root.service

# ── Chrony / NTP ──
cat > /etc/chrony.conf <<NTPEOF
server ${NTP_SERVER} iburst
server ${NTP_POOL} iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
NTPEOF
systemctl enable chronyd

# ── Sudoers ──
echo '${sudo_line}' > /etc/sudoers.d/${SSH_USER}
chmod 440 /etc/sudoers.d/${SSH_USER}

# ── configure-nics.service: activate unconfigured NICs on first boot ──
cat > /etc/systemd/system/configure-nics.service <<'NICSVC'
[Unit]
Description=Configure unconfigured NICs with DHCP
After=NetworkManager-wait-online.service
Wants=NetworkManager-wait-online.service
ConditionPathExists=!/var/lib/configure-nics.done

[Service]
Type=oneshot
ExecStart=/usr/local/bin/configure-nics.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
NICSVC

cat > /usr/local/bin/configure-nics.sh <<'NICSH'
#!/bin/bash
exec &>/var/log/configure-nics.log
set -x

EXPLICIT_DNS="${DNS_SERVER}"

# Wait for NetworkManager to discover all devices
for i in \$(seq 1 30); do
    devs=\$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '\$2=="ethernet"{print \$1}')
    [ -n "\$devs" ] && break
    sleep 2
done

configured=0
for dev in \$devs; do
    con=\$(nmcli -g GENERAL.CONNECTION device show "\$dev" 2>/dev/null)
    if [ -z "\$con" ] || [ "\$con" = "--" ]; then
        echo "Configuring \$dev with DHCP (no default route)"
        nmcli con add type ethernet con-name "\$dev" ifname "\$dev" \
            ipv4.method auto connection.autoconnect yes ipv4.never-default yes
        nmcli con up "\$dev" || true
        configured=\$(( configured + 1 ))
        con="\$dev"
    else
        # Ensure already-configured NICs (primary) allow default route
        cur=\$(nmcli -g ipv4.never-default con show "\$con" 2>/dev/null)
        if [ "\$cur" = "yes" ]; then
            echo "Fixing \$dev (\$con): enabling default route"
            nmcli con mod "\$con" ipv4.never-default no
            nmcli con up "\$con" || true
        fi
    fi
    # Explicit DNS: ignore DHCP DNS and use the specified server on all NICs
    if [ -n "\$EXPLICIT_DNS" ]; then
        echo "Setting DNS to \$EXPLICIT_DNS on \$con (ignoring DHCP DNS)"
        nmcli con mod "\$con" ipv4.ignore-auto-dns yes ipv4.dns "\$EXPLICIT_DNS"
        nmcli con up "\$con" || true
    fi
done
echo "Configured \$configured extra NIC(s)"
touch /var/lib/configure-nics.done
NICSH
chmod 755 /usr/local/bin/configure-nics.sh
systemctl enable configure-nics.service
systemctl enable NetworkManager-wait-online.service

# ── SSH hardening ──
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

%end

reboot --eject
KSEOF

	echo "  Kickstart: $ks"
}

# ── Step 2: Create OEMDRV ISO ─────────────────────────────────────────────────
create_oemdrv_iso() {
	echo "Step 2/7: Creating OEMDRV ISO ..."

	local mkiso isodir
	mkiso=$(_find_mkiso)
	isodir="$_TMPDIR/isoroot"
	mkdir -p "$isodir/EFI/BOOT" "$isodir/EFI/redhat" "$isodir/images"
	cp "$_TMPDIR/ks.cfg" "$isodir/"

	# RHEL 9+: EFI-bootable OEMDRV skips the DVD media check
	local _grubx64="/boot/efi/EFI/redhat/grubx64.efi"
	if [ "$RHEL_VER" -ge 9 ] && sudo test -f "$_grubx64" && command -v mmd >/dev/null 2>&1; then
		echo "  Building EFI-bootable OEMDRV (skips DVD media check) ..."
		sudo cp "$_grubx64" "$isodir/EFI/BOOT/BOOTX64.EFI"
		sudo chown "$USER" "$isodir/EFI/BOOT/BOOTX64.EFI"

		cat > "$isodir/EFI/BOOT/grub.cfg" <<'GRUBEOF'
set timeout=1
set default=0
menuentry 'Install RHEL' {
    search --set=root --no-floppy --file /images/pxeboot/vmlinuz
    linuxefi /images/pxeboot/vmlinuz inst.stage2=cdrom inst.ks=hd:LABEL=OEMDRV:/ks.cfg quiet
    initrdefi /images/pxeboot/initrd.img
}
GRUBEOF
		cp "$isodir/EFI/BOOT/grub.cfg" "$isodir/EFI/redhat/grub.cfg"

		truncate -s 5M "$isodir/images/efiboot.img"
		mkfs.vfat -n OEMDRV "$isodir/images/efiboot.img" >/dev/null
		mmd -i "$isodir/images/efiboot.img" ::/EFI ::/EFI/BOOT ::/EFI/redhat
		mcopy -i "$isodir/images/efiboot.img" "$isodir/EFI/BOOT/BOOTX64.EFI" ::/EFI/BOOT/
		mcopy -i "$isodir/images/efiboot.img" "$isodir/EFI/BOOT/grub.cfg" ::/EFI/BOOT/
		mcopy -i "$isodir/images/efiboot.img" "$isodir/EFI/redhat/grub.cfg" ::/EFI/redhat/

		"$mkiso" -V OEMDRV -R -J -quiet \
			-eltorito-alt-boot -e images/efiboot.img -no-emul-boot \
			-o "$_TMPDIR/ks.iso" "$isodir"
	else
		if [ "$RHEL_VER" -le 8 ]; then
			echo "  Building plain OEMDRV (RHEL ${RHEL_VER} DVD handles EFI boot)"
		else
			echo "  WARNING: EFI boot files or mtools not available; using plain OEMDRV ISO"
		fi
		"$mkiso" -V OEMDRV -R -J -quiet -o "$_TMPDIR/ks.iso" "$isodir/ks.cfg"
	fi

	echo "  ISO: $_TMPDIR/ks.iso ($(du -h "$_TMPDIR/ks.iso" | awk '{print $1}'))"
}

# ── Step 3: Upload OEMDRV ISO to datastore ────────────────────────────────────
upload_oemdrv_iso() {
	echo "Step 3/7: Uploading OEMDRV ISO ..."

	_KS_DS_PATH="_tmp/ks-${VM_NAME}.iso"
	govc datastore.mkdir -ds "$VM_DATASTORE" "_tmp" 2>/dev/null || true
	govc datastore.upload -ds "$VM_DATASTORE" "$_TMPDIR/ks.iso" "$_KS_DS_PATH"

	echo "  Uploaded: [${VM_DATASTORE}] ${_KS_DS_PATH}"
}

# ── Step 4: Create VM and attach ISOs ─────────────────────────────────────────
create_vm() {
	echo "Step 4/7: Creating VM ..."

	local folder_flag=""
	if [ -n "$VC_FOLDER" ]; then
		govc folder.create "$VC_FOLDER" 2>/dev/null || true
		folder_flag="-folder=$VC_FOLDER"
	fi

	govc vm.create \
		-firmware efi \
		-g "$_GUEST_ID" \
		-c "$CPU" \
		-m "$MEM_MB" \
		-disk "${DISK_GB}GB" \
		-disk.controller pvscsi \
		-ds "$VM_DATASTORE" \
		-net "$VM_NETWORK" \
		-net.adapter vmxnet3 \
		-on=false \
		$folder_flag \
		"$VM_NAME"
	echo "  Created: ${VM_NAME} (${CPU} vCPU, ${MEM_MB} MB, ${DISK_GB} GB, EFI, pvscsi)"

	# Set specific MAC address on primary NIC if requested
	if [ -n "$MAC_ADDR" ]; then
		govc vm.network.change -vm "$VM_NAME" -net "$VM_NETWORK" \
			-net.address "$MAC_ADDR" ethernet-0
		echo "  MAC:       ${MAC_ADDR} -> ethernet-0"
	fi

	# Add extra NICs (with optional MAC addresses)
	local _eidx
	for _eidx in $(seq 0 $(( ${#EXTRA_NETWORKS[@]} - 1 )) 2>/dev/null); do
		local _enet="${EXTRA_NETWORKS[$_eidx]}"
		local _emac="${EXTRA_MACS[$_eidx]:-}"
		govc vm.network.add -vm "$VM_NAME" -net "$_enet" -net.adapter vmxnet3
		if [ -n "$_emac" ]; then
			local _edev="ethernet-$((_eidx + 1))"
			govc vm.network.change -vm "$VM_NAME" -net "$_enet" \
				-net.address "$_emac" "$_edev"
			echo "  NIC added: ${_enet} (MAC: ${_emac})"
		else
			echo "  NIC added: ${_enet}"
		fi
	done

	govc device.boot -vm "$VM_NAME" -order disk,cdrom

	local cdrom1 cdrom2
	cdrom1=$(govc device.cdrom.add -vm "$VM_NAME")
	govc device.cdrom.insert -vm "$VM_NAME" -device "$cdrom1" \
		-ds "$VM_DATASTORE" "$_KS_DS_PATH"
	echo "  OEMDRV:    [${VM_DATASTORE}] ${_KS_DS_PATH} -> ${cdrom1}"

	cdrom2=$(govc device.cdrom.add -vm "$VM_NAME")
	govc device.cdrom.insert -vm "$VM_NAME" -device "$cdrom2" \
		-ds "$ISO_DATASTORE" "$ISO_PATH"
	echo "  RHEL ISO:  [${ISO_DATASTORE}] ${ISO_PATH} -> ${cdrom2}"

	govc vm.power -on "$VM_NAME"
	echo "  Powered on -- boot order: disk > cdrom (unattended install starting)"

	# RHEL 8: send keystrokes to skip DVD media check
	if [ "$RHEL_VER" -le 8 ]; then
		echo "  Waiting for DVD GRUB menu ..."
		sleep 15
		echo "  Selecting 'Install' (skipping media check) ..."
		govc vm.keystrokes -vm "$VM_NAME" -c KEY_UP
		sleep 1
		govc vm.keystrokes -vm "$VM_NAME" -c KEY_ENTER
	fi
}

# ── Step 5: Wait for install to finish ────────────────────────────────────────
wait_for_install() {
	echo "Step 5/7: Waiting for install to complete (up to 30 min) ..."

	local timeout=1800 elapsed=0

	echo "  Waiting for VM IP ..."
	while [ "$elapsed" -lt "$timeout" ]; do
		_VM_IP=$(govc vm.ip -wait 30s "$VM_NAME" 2>/dev/null) || true
		if [ -n "$_VM_IP" ]; then
			echo "  VM IP: ${_VM_IP} (after ~${elapsed}s)"
			break
		fi
		elapsed=$((elapsed + 30))
		if [ $((elapsed % 120)) -eq 0 ]; then
			echo "  ... still installing (~${elapsed}s)"
		fi
	done

	if [ -z "$_VM_IP" ]; then
		echo "ERROR: VM did not get an IP within ${timeout}s" >&2
		exit 1
	fi

	echo "  Waiting for SSH on ${SSH_USER}@${_VM_IP} ..."
	local ssh_timeout=600 ssh_elapsed=0
	while [ "$ssh_elapsed" -lt "$ssh_timeout" ]; do
		if ssh $_SSH_OPTS -o BatchMode=yes "${SSH_USER}@${_VM_IP}" "true" 2>/dev/null; then
			echo "  SSH ready (after ~${ssh_elapsed}s)"
			return
		fi
		sleep 15
		ssh_elapsed=$((ssh_elapsed + 15))
	done

	echo "ERROR: SSH not reachable on ${SSH_USER}@${_VM_IP} after ${ssh_timeout}s" >&2
	exit 1
}

# ── Step 6: Post-install & verify ─────────────────────────────────────────────
post_install() {
	echo "Step 6/7: Post-install verification ..."

	# Red Hat subscription (only when --register is passed)
	if [ "$REGISTER" = 1 ]; then
		if [ -n "${SUB_USERNAME:-}" ] && [ -n "${SUB_PASSWORD:-}" ]; then
			echo "  Registering with Red Hat (${SUB_USERNAME}) ..."
			# RHEL 10 workaround: subscription-manager crashes if /etc/pki/product
			# exists as a directory (BZ pending). Ensure it and product-default exist.
			_rssh "sudo mkdir -p /etc/pki/product /etc/pki/product-default 2>/dev/null; true"
			_rssh "sudo subscription-manager register \
				--username='${SUB_USERNAME}' --password='${SUB_PASSWORD}'" || \
				echo "  WARNING: registration failed (non-fatal)"
		else
			echo "  WARNING: --register specified but SUB_USERNAME/SUB_PASSWORD not set"
		fi
	fi

	# Console password
	if [ -n "${_VM_PW:-}" ]; then
		echo "  Setting console password for ${SSH_USER} ..."
		_rssh "echo '${SSH_USER}:${_VM_PW}' | sudo chpasswd"
		if [ "$SUDO_NOPASSWD" = 0 ]; then
			_rssh "sudo sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config"
		fi
	fi

	# Wait for configure-nics firstboot service to finish (activates extra NICs)
	if [ ${#EXTRA_NETWORKS[@]} -gt 0 ]; then
		echo "  Waiting for extra NIC(s) to activate ..."
		local nic_wait=0
		while [ "$nic_wait" -lt 90 ]; do
			if _rssh "test -f /var/lib/configure-nics.done" 2>/dev/null; then
				break
			fi
			sleep 5
			nic_wait=$((nic_wait + 5))
		done
		# Show all IPs
		local all_ips
		all_ips=$(_rssh "ip -4 -o addr show scope global | awk '{print \$2, \$4}'") || true
		echo "  NICs:${all_ips:+
$(echo "$all_ips" | sed 's/^/       /')}"
	fi

	# Verify critical settings
	local failures=0

	if _rssh "true" 2>/dev/null; then
		echo "  OK  SSH as ${SSH_USER}"
	else
		echo "  FAIL  SSH as ${SSH_USER}" >&2
		failures=$((failures + 1))
	fi

	if _rssh "sudo id" >/dev/null 2>&1; then
		echo "  OK  sudo"
	else
		echo "  FAIL  sudo" >&2
		failures=$((failures + 1))
	fi

	local hostname
	hostname=$(_rssh "hostname") || true
	if [ "$hostname" = "$VM_HOSTNAME" ]; then
		echo "  OK  hostname: ${hostname}"
	else
		echo "  WARN  hostname: '${hostname}' (expected: ${VM_HOSTNAME})"
	fi

	local ntp_src
	ntp_src=$(_rssh "chronyc sources 2>/dev/null | grep '${NTP_SERVER}'" 2>/dev/null) || true
	if [ -n "$ntp_src" ]; then
		echo "  OK  NTP: ${NTP_SERVER}"
	else
		echo "  WARN  NTP: ${NTP_SERVER} not in chronyc sources"
	fi

	# DNS check
	if [ -n "$DNS_SERVER" ]; then
		local resolv_dns
		resolv_dns=$(_rssh "grep '^nameserver' /etc/resolv.conf" 2>/dev/null) || true
		if echo "$resolv_dns" | grep -qw "$DNS_SERVER"; then
			local ns_count
			ns_count=$(echo "$resolv_dns" | wc -l)
			if [ "$ns_count" -eq 1 ]; then
				echo "  OK  DNS: ${DNS_SERVER} (only nameserver)"
			else
				echo "  WARN  DNS: ${DNS_SERVER} present but ${ns_count} nameservers in resolv.conf"
				echo "$resolv_dns" | sed 's/^/       /'
			fi
		else
			echo "  WARN  DNS: ${DNS_SERVER} not in resolv.conf"
			echo "$resolv_dns" | sed 's/^/       /'
		fi
	fi

	local lv_count
	lv_count=$(_rssh "sudo lvs --noheadings 2>/dev/null | wc -l") || true
	local expected_lvs=1
	[ "$SWAP_GB" -gt 0 ] && expected_lvs=$((expected_lvs + 1))
	[ "$HOME_GB" -gt 0 ] && expected_lvs=$((expected_lvs + 1))
	if [ "$lv_count" = "$expected_lvs" ]; then
		echo "  OK  LVM: ${lv_count} logical volume(s)"
	else
		echo "  WARN  LVM: ${lv_count} LV(s) (expected ${expected_lvs})"
	fi

	_rssh "sudo lvs" 2>/dev/null | while read -r line; do
		echo "       $line"
	done

	# Check internet connectivity
	if _rssh "ping -c1 -W5 8.8.8.8 >/dev/null 2>&1"; then
		echo "  OK  Internet access"
	else
		echo "  WARN  No internet access (check default route)"
	fi

	# Check registration
	if [ "$REGISTER" = 1 ]; then
		if _rssh "sudo subscription-manager identity >/dev/null 2>&1"; then
			echo "  OK  Red Hat registered"
		else
			echo "  WARN  Not registered with Red Hat"
		fi
	fi

	if [ "$failures" -gt 0 ]; then
		echo "  ERROR: ${failures} critical check(s) failed" >&2
		exit 1
	fi
	echo "  All checks passed."
}

# ── Step 7: Finalize (shutdown, cleanup, snapshot) ────────────────────────────
finalize() {
	echo "Step 7/7: Finalizing ..."

	echo "  Shutting down VM ..."
	_rssh "sudo shutdown -h now" 2>/dev/null || true

	echo "  Waiting for power off ..."
	local tries=0
	while [ "$tries" -lt 30 ]; do
		local state
		state=$(govc vm.info "$VM_NAME" 2>/dev/null \
			| awk '/Power state:/{print $NF}') || true
		[ "$state" = "poweredOff" ] && break
		sleep 2
		tries=$((tries + 1))
	done
	if [ "$tries" -ge 30 ]; then
		echo "  Force power off ..."
		govc vm.power -off "$VM_NAME" || true
	fi

	# Remove CD-ROM devices
	echo "  Removing CD-ROMs ..."
	for _dev in $(govc device.ls -vm "$VM_NAME" | awk '/cdrom/{print $1}'); do
		govc device.cdrom.eject -vm "$VM_NAME" -device "$_dev" 2>/dev/null || true
		govc device.remove -vm "$VM_NAME" -device "$_dev" 2>/dev/null || true
	done

	# Cleanup OEMDRV ISO from datastore
	if [ -n "${_KS_DS_PATH:-}" ]; then
		govc datastore.rm -ds "$VM_DATASTORE" "$_KS_DS_PATH" 2>/dev/null || true
		_KS_DS_PATH=""
	fi

	# Snapshot
	if [ -n "$SNAPSHOT_NAME" ]; then
		echo "  Creating snapshot: ${SNAPSHOT_NAME} ..."
		govc snapshot.create -vm "$VM_NAME" \
			-d "RHEL ${RHEL_VER}, ${SSH_USER}, ${DISK_GB}GB, ${VM_HOSTNAME}" \
			"$SNAPSHOT_NAME"
	fi

	# Annotate in vCenter
	local sudo_str="NOPASSWD"
	[ "$SUDO_NOPASSWD" = 0 ] && sudo_str="password"
	local disk_str="/ on LVM (single root LV)"
	[ "$HOME_GB" -gt 0 ] && disk_str="${disk_str}, /home (${HOME_GB} GB)"
	[ "$SWAP_GB" -gt 0 ] && disk_str="${disk_str}, swap (${SWAP_GB} GB)"

	local _notes
	_notes=$(cat <<-NOTESEOF
		RHEL ${RHEL_VER} VM
		Created: $(date '+%Y-%m-%d %H:%M:%S %Z')
		Created by: create-vm.sh

		Hardware: ${CPU} vCPU, ${MEM_MB} MB RAM, ${DISK_GB} GB disk (EFI, pvscsi)
		NICs: ${VM_NETWORK}$([ -n "$MAC_ADDR" ] && echo " (MAC: ${MAC_ADDR})")$(for _n in "${EXTRA_NETWORKS[@]}"; do echo -n ", ${_n}"; done)

		OS config:
		  User: ${SSH_USER} (sudo: ${sudo_str}, SSH pubkey auth)
		  Hostname: ${VM_HOSTNAME}
		  Timezone: ${TIMEZONE}
		  NTP: ${NTP_SERVER}, ${NTP_POOL}${DNS_SERVER:+
		  DNS: ${DNS_SERVER} (DHCP DNS ignored)}
		  Disk: ${disk_str}
		  SELinux: enforcing
	NOTESEOF
	)
	govc vm.change -vm "$VM_NAME" -annotation "$_notes" 2>/dev/null || true

	# Power on if requested
	if [ "$POWER_ON" = 1 ]; then
		echo "  Powering on ..."
		govc vm.power -on "$VM_NAME"
	fi

	echo ""
	echo "=== VM '${VM_NAME}' created successfully ==="
	[ -n "$SNAPSHOT_NAME" ] && \
	echo "  Snapshot:  ${SNAPSHOT_NAME}"
	echo "  VM IP:     ${_VM_IP} (DHCP -- may change)"
	echo ""
	echo "  Connect:"
	echo "    ssh ${SSH_USER}@${_VM_IP}"
	echo ""
	echo "  Revert to snapshot:"
	echo "    govc snapshot.revert -vm ${VM_NAME} ${SNAPSHOT_NAME:-orig}"
	echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════════════════
validate
prompt_password
show_config

if [ "$DRY_RUN" = 1 ]; then
	generate_kickstart
	echo ""
	echo "=== Kickstart content ==="
	cat "$_TMPDIR/ks.cfg"
	echo ""
	echo "[dry-run] Would create VM '$VM_NAME' from [$ISO_DATASTORE] $ISO_PATH"
	exit 0
fi

generate_kickstart
create_oemdrv_iso
upload_oemdrv_iso
create_vm
wait_for_install
post_install
finalize
