#!/bin/bash
# create-template.sh -- Build a RHEL VM template from ISO using govc + kickstart.
#
# Creates a minimal RHEL VM suitable as a base template for E2E testing or
# standalone use.  The OS is installed unattended via a kickstart file
# delivered on an OEMDRV-labeled ISO that Anaconda auto-discovers.
#
# Requires: govc, xorrisofs (or mkisofs/genisoimage), mtools, ssh, scp
# See --help for full option list.

set -euo pipefail

# ── Source vmware.conf for govc defaults ──────────────────────────────────────
[ -f "$HOME/.vmware.conf" ] && source "$HOME/.vmware.conf"

export GOVC_URL="${GOVC_URL:-}" GOVC_USERNAME="${GOVC_USERNAME:-}"
export GOVC_PASSWORD="${GOVC_PASSWORD:-}" GOVC_INSECURE="${GOVC_INSECURE:-true}"
export GOVC_DATASTORE="${GOVC_DATASTORE:-}" GOVC_DATACENTER="${GOVC_DATACENTER:-}"

# ── Defaults (vmware.conf applied; CLI flags below override) ──────────────────
RHEL_VER=9
FULL_MODE=0
COPY_PRIVKEY=0
FORCE=0
DRY_RUN=0
ISO_DATASTORE="NFS-Shared"
ISO_PATH=""
VM_DATASTORE="${GOVC_DATASTORE:-}"
VM_NAME=""
VM_HOSTNAME="rhel-template"
DISK_GB=100
CPU=4
MEM_MB=8192
SSH_PUBKEY="$HOME/.ssh/id_rsa.pub"
VC_FOLDER="${VC_FOLDER:-}"
VM_NETWORK="VM Network"
SSH_USER="steve"
SNAPSHOT_NAME="aba-test"
NO_PASSWORD=0

# Runtime state
_TMPDIR=""
_VM_IP=""
_VM_PW=""
_CDROM1=""
_CDROM2=""
_KS_DS_PATH=""
_SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -o LogLevel=ERROR"

# ── Usage / help ──────────────────────────────────────────────────────────────
usage() {
cat <<'EOF'
Usage: tools/create-template.sh [OPTIONS]

Build a RHEL VM template from ISO using govc and an automated kickstart.

MODES:
  Default         Minimal template: steve user, SSH pubkey auth, NOPASSWD sudo,
                  expand-root.service, NTP, timezone Asia/Singapore.
                  Suitable as a base for E2E _prepare_golden or other automation.

  --full          Standalone ready-to-use VM.  Adds packages (git, tmux, podman,
                  etc.), SSH keypair, proxy files, tmux.conf, .gitconfig,
                  vmware.conf, pull-secret, ppods helper, ABA_TESTING=1, and a
                  2nd NIC on "External Network".  Implies --copy-privkey.

PASSWORD:
  By default the script prompts for a console password for steve.
  Set VM_PASSWORD in the environment to supply it non-interactively.
  Use -P / --no-password to skip entirely (no password, SSH-only access).

OPTIONS:
  -r, --rhel N            RHEL version: 8, 9, or 10 (default: 9)
  -F, --full              Deploy all user configs from bastion (standalone mode)
  -k, --copy-privkey      Copy SSH private key + config to the VM (pubkey only by default)
  -f, --force             Destroy existing VM with same name before creating
  -P, --no-password       Do not set a console password for steve

  -n, --name NAME         VM name (default: aba-e2e-template-rhel{N})
  -H, --hostname NAME     Guest OS hostname (default: rhel-template)
  -d, --disk GB           Initial disk size in GB (default: 100)
  -c, --cpu N             Number of CPUs (default: 4)
  -m, --mem MB            Memory in MB (default: 8192)
  -N, --network NET       Network name for the NIC (default: VM Network)

      --iso-datastore DS  Datastore with the RHEL DVD ISO (default: NFS-Shared)
      --iso-path PATH     ISO path on datastore (auto-detected from --rhel if unset)
      --vm-datastore DS   Datastore for the VM disk (default: from ~/.vmware.conf)
      --folder PATH       vCenter folder (default: from VC_FOLDER in ~/.vmware.conf)
  -S, --ssh-pubkey FILE   Public key for steve user (default: ~/.ssh/id_rsa.pub)
  -s, --snapshot NAME     Snapshot name after build (default: aba-test)

  -D, --dry-run           Show configuration + kickstart content, then exit
  -h, --help              Show this help

ENVIRONMENT VARIABLES (optional):
  VM_PASSWORD         Console password for steve (skips interactive prompt)
  SUB_USERNAME        Red Hat subscription username -- enables registration
  SUB_PASSWORD        Red Hat subscription password
  GOVC_*              Standard govc environment (or use ~/.vmware.conf)

EXAMPLES:
  # Minimal RHEL 9 template for E2E framework
  tools/create-template.sh --rhel 9

  # Skip password prompt (SSH-only access)
  tools/create-template.sh --rhel 9 -P

  # Standalone RHEL 9 VM with all user configs
  tools/create-template.sh --rhel 9 --full --name my-rhel9

  # Supply password non-interactively
  VM_PASSWORD=changeme tools/create-template.sh -r 9 -n my-vm

  # RHEL 8 template, also copy private key for SSH-out
  tools/create-template.sh -r 8 -k

  # With Red Hat subscription registration
  SUB_USERNAME=user@redhat.com SUB_PASSWORD=secret tools/create-template.sh

  # Preview without creating anything
  tools/create-template.sh -r 9 -D
EOF
exit 0
}

# ── Parse CLI arguments ───────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
	case "$1" in
		-r|--rhel)         RHEL_VER="$2"; shift 2 ;;
		-F|--full)         FULL_MODE=1; COPY_PRIVKEY=1; shift ;;
		-k|--copy-privkey) COPY_PRIVKEY=1; shift ;;
		-f|--force)        FORCE=1; shift ;;
		-P|--no-password)  NO_PASSWORD=1; shift ;;
		-n|--name)         VM_NAME="$2"; shift 2 ;;
		-H|--hostname)     VM_HOSTNAME="$2"; shift 2 ;;
		-d|--disk)         DISK_GB="$2"; shift 2 ;;
		-c|--cpu)          CPU="$2"; shift 2 ;;
		-m|--mem)          MEM_MB="$2"; shift 2 ;;
		-N|--network)      VM_NETWORK="$2"; shift 2 ;;
		--iso-datastore)   ISO_DATASTORE="$2"; shift 2 ;;
		--iso-path)        ISO_PATH="$2"; shift 2 ;;
		--vm-datastore)    VM_DATASTORE="$2"; shift 2 ;;
		--folder)          VC_FOLDER="$2"; shift 2 ;;
		-S|--ssh-pubkey)   SSH_PUBKEY="$2"; shift 2 ;;
		-s|--snapshot)     SNAPSHOT_NAME="$2"; shift 2 ;;
		-D|--dry-run)      DRY_RUN=1; shift ;;
		-h|--help)         usage ;;
		*)                 echo "ERROR: unknown option: $1" >&2; echo "Try --help" >&2; exit 1 ;;
	esac
done

# ── Derived defaults ──────────────────────────────────────────────────────────
[ -z "$VM_NAME" ] && VM_NAME="aba-e2e-template-rhel${RHEL_VER}"

case "$RHEL_VER" in
	8)  _GUEST_ID="rhel8_64Guest" ;;
	9)  _GUEST_ID="rhel9_64Guest" ;;
	10) _GUEST_ID="rhel9_64Guest" ;;
	*)  echo "ERROR: unsupported --rhel version '$RHEL_VER' (use 8, 9, or 10)" >&2; exit 1 ;;
esac

# ── Helper functions ──────────────────────────────────────────────────────────
_rssh() {
	ssh $_SSH_OPTS "${SSH_USER}@${_VM_IP}" -- "$@"
}

_rscp() {
	scp $_SSH_OPTS "$@"
}

_find_mkiso() {
	local cmd
	for cmd in xorrisofs mkisofs genisoimage; do
		if command -v "$cmd" >/dev/null 2>&1; then
			echo "$cmd"
			return
		fi
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

	# Auto-detect ISO on the datastore
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

	# Check for existing VM with the same name (skip in dry-run)
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
	local mode="minimal (base template)"
	[ "$FULL_MODE" = 1 ] && mode="full (standalone with user configs)"
	[ "$COPY_PRIVKEY" = 1 ] && [ "$FULL_MODE" = 0 ] && mode="minimal + private key"

	echo ""
	echo "=== Creating RHEL ${RHEL_VER} VM template: ${VM_NAME} ==="
	echo ""
	echo "  RHEL version:   ${RHEL_VER}"
	echo "  VM name:        ${VM_NAME}"
	echo "  Hostname:       ${VM_HOSTNAME}"
	echo "  Disk:           ${DISK_GB} GB"
	echo "  CPU / Memory:   ${CPU} vCPU / ${MEM_MB} MB"
	echo "  Firmware:       EFI"
	echo "  NIC:            ${VM_NETWORK} (DHCP)"
	echo "  ISO:            [${ISO_DATASTORE}] ${ISO_PATH}"
	echo "  VM datastore:   ${VM_DATASTORE}"
	[ -n "$VC_FOLDER" ] && \
	echo "  Folder:         ${VC_FOLDER}"
	echo "  Snapshot:       ${SNAPSHOT_NAME}"
	echo "  Mode:           ${mode}"
	echo "  SSH pubkey:     ${SSH_PUBKEY}"
	if [ -n "$_VM_PW" ]; then
		echo "  Password:       (set)"
	elif [ "$NO_PASSWORD" = 1 ]; then
		echo "  Password:       none (--no-password)"
	else
		echo "  Password:       none"
	fi
	if [ -n "${SUB_USERNAME:-}" ]; then
		echo "  Registration:   ${SUB_USERNAME}"
	else
		echo "  Registration:   skipped (SUB_USERNAME not set)"
	fi
	echo ""
}

# ── Step 1: Generate kickstart ────────────────────────────────────────────────
generate_kickstart() {
	echo "Step 1/8: Generating kickstart ..."

	_TMPDIR=$(mktemp -d /tmp/create-template.XXXXXX)
	local ks="$_TMPDIR/ks.cfg"
	local pubkey
	pubkey=$(cat "$SSH_PUBKEY")

	# System configuration (needs variable expansion for hostname, user, pubkey)
	cat > "$ks" <<KSEOF
#version=RHEL${RHEL_VER}
# Automated RHEL ${RHEL_VER} kickstart -- generated by create-template.sh

cdrom
text
firstboot --disable
eula --agreed

lang en_US.UTF-8
keyboard us
timezone Asia/Singapore --utc

network --bootproto=dhcp --activate --onboot=yes --hostname=${VM_HOSTNAME}

selinux --enforcing
firewall --enabled --ssh

rootpw --lock
user --name=${SSH_USER} --groups=wheel --shell=/bin/bash
sshkey --username=${SSH_USER} "${pubkey}"

bootloader --append="console=tty0 console=ttyS0,115200n8" --location=mbr

ignoredisk --only-use=sda
clearpart --all --initlabel --drives=sda
zerombr
part /boot/efi --fstype=efi --size=600
part /boot --fstype=xfs --size=1024
part pv.01 --size=1 --grow
volgroup rhel pv.01
logvol / --fstype=xfs --vgname=rhel --name=root --size=1 --grow
logvol swap --vgname=rhel --name=swap --size=4096

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

KSEOF

	# %post section -- literal content (no shell expansion), with __SSH_USER__
	# placeholder injected via sed afterward.
	cat >> "$ks" <<'POSTEOF'
%post --log=/root/ks-post.log
set -ex

# ── expand-root.service: auto-grow / on first boot when vDisk > LV ──
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
# Grow the LVM PV partition (sda3 = after EFI + /boot), then extend root LV.
set -x
DISK=/dev/sda
PART=3
growpart "$DISK" "$PART" || true
pvresize "${DISK}${PART}" || true
lvextend -l +100%FREE /dev/rhel/root || true
xfs_growfs / || true
SHEOF
chmod 755 /usr/local/bin/expand-root.sh
# Service is enabled in finalize(), not here -- avoids running on the template
# itself (where the disk is already the right size).

# ── Chrony / NTP ──
cat > /etc/chrony.conf <<'NTPEOF'
server 10.0.1.8 iburst
server rhel.pool.ntp.org iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
NTPEOF
systemctl enable chronyd

# ── Sudoers: passwordless sudo for the default user ──
echo '__SSH_USER__ ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/__SSH_USER__
chmod 440 /etc/sudoers.d/__SSH_USER__

# ── SSH hardening ──
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

%end

reboot --eject
POSTEOF

	# Replace placeholder with the actual SSH user name
	sed -i "s|__SSH_USER__|${SSH_USER}|g" "$ks"

	echo "  Kickstart: $ks"
}

# ── Step 2: Create OEMDRV ISO (EFI-bootable to skip DVD media check) ──────────
create_oemdrv_iso() {
	echo "Step 2/8: Creating OEMDRV ISO ..."

	local mkiso isodir
	mkiso=$(_find_mkiso)
	isodir="$_TMPDIR/isoroot"
	mkdir -p "$isodir/EFI/BOOT" "$isodir/EFI/redhat" "$isodir/images"
	cp "$_TMPDIR/ks.cfg" "$isodir/"

	# RHEL 8: plain OEMDRV -- the DVD boots its own GRUB and Anaconda
	# auto-discovers ks.cfg from the OEMDRV label.  EFI-bootable OEMDRV
	# causes a reboot loop on RHEL 8 because the NVRAM entry persists.
	# RHEL 9+: EFI-bootable OEMDRV -- custom GRUB skips the media check.
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

		# FAT image for El Torito EFI boot catalog
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
			echo "           (media check may run -- install grub2-efi-x64 + mtools to skip it)"
		fi
		"$mkiso" -V OEMDRV -R -J -quiet -o "$_TMPDIR/ks.iso" "$isodir/ks.cfg"
	fi

	echo "  ISO: $_TMPDIR/ks.iso ($(du -h "$_TMPDIR/ks.iso" | awk '{print $1}'))"
}

# ── Step 3: Upload OEMDRV ISO to datastore ────────────────────────────────────
upload_oemdrv_iso() {
	echo "Step 3/8: Uploading OEMDRV ISO ..."

	_KS_DS_PATH="_tmp/ks-${VM_NAME}.iso"
	govc datastore.mkdir -ds "$VM_DATASTORE" "_tmp" 2>/dev/null || true
	govc datastore.upload -ds "$VM_DATASTORE" "$_TMPDIR/ks.iso" "$_KS_DS_PATH"

	echo "  Uploaded: [${VM_DATASTORE}] ${_KS_DS_PATH}"
}

# ── Step 4: Create VM and attach ISOs ─────────────────────────────────────────
create_vm() {
	echo "Step 4/8: Creating VM ..."

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

	# Boot order: disk first, CDROM second.  On the first boot the disk is
	# empty so EFI falls through to the CDROM installer.  After the OS is
	# installed the disk is bootable and the CDROMs are never reached --
	# no ejection or reboot detection needed.
	govc device.boot -vm "$VM_NAME" -order disk,cdrom

	_CDROM1=$(govc device.cdrom.add -vm "$VM_NAME")
	govc device.cdrom.insert -vm "$VM_NAME" -device "$_CDROM1" \
		-ds "$VM_DATASTORE" "$_KS_DS_PATH"
	echo "  OEMDRV:    [${VM_DATASTORE}] ${_KS_DS_PATH} -> ${_CDROM1}"

	_CDROM2=$(govc device.cdrom.add -vm "$VM_NAME")
	govc device.cdrom.insert -vm "$VM_NAME" -device "$_CDROM2" \
		-ds "$ISO_DATASTORE" "$ISO_PATH"
	echo "  RHEL ISO:  [${ISO_DATASTORE}] ${ISO_PATH} -> ${_CDROM2}"

	govc vm.power -on "$VM_NAME"
	echo "  Powered on -- boot order: disk > cdrom (unattended install starting)"

	# RHEL 8 plain OEMDRV: DVD GRUB defaults to "Test this media & install".
	# Send Up+Enter to select "Install" (no media check) once the menu appears.
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
	echo "Step 5/8: Waiting for install to complete (up to 30 min) ..."

	local timeout=1800  elapsed=0

	# Phase 1: wait for open-vm-tools to report an IP
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
		echo "  Check the VM console in vCenter for installer status" >&2
		exit 1
	fi

	# Phase 2: wait for SSH
	echo "  Waiting for SSH on ${SSH_USER}@${_VM_IP} ..."
	local ssh_timeout=600  ssh_elapsed=0
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

# ── Step 6: Post-install configuration ────────────────────────────────────────
post_install() {
	echo "Step 6/8: Post-install configuration ..."

	# Red Hat subscription
	if [ -n "${SUB_USERNAME:-}" ] && [ -n "${SUB_PASSWORD:-}" ]; then
		# Detect proxy from environment for RHSM
		local _proxy_url="${https_proxy:-${HTTPS_PROXY:-${http_proxy:-${HTTP_PROXY:-}}}}"
		if [ -z "$_proxy_url" ] && [ -f "$HOME/.proxy-set.sh" ]; then
			_proxy_url=$(grep -i '^export HTTPS_PROXY=' "$HOME/.proxy-set.sh" 2>/dev/null | head -1 | sed 's/.*=//;s/"//g')
		fi
		if [ -n "$_proxy_url" ]; then
			local _proxy_host _proxy_port
			_proxy_host=$(echo "$_proxy_url" | sed 's|https\?://||;s|:.*||')
			_proxy_port=$(echo "$_proxy_url" | sed 's|.*:||;s|/.*||')
			echo "  Configuring RHSM proxy (${_proxy_host}:${_proxy_port}) ..."
			_rssh "sudo subscription-manager config \
				--server.proxy_hostname='${_proxy_host}' \
				--server.proxy_port='${_proxy_port}'" || true
		fi
		echo "  Registering with Red Hat (${SUB_USERNAME}) ..."
		_rssh "sudo subscription-manager register \
			--username='${SUB_USERNAME}' --password='${SUB_PASSWORD}'" || \
			echo "  WARNING: registration failed (non-fatal)"
	else
		echo "  Registration: skipped (SUB_USERNAME not set)"
	fi

	# Console password
	if [ -n "${_VM_PW:-}" ]; then
		echo "  Setting console password for ${SSH_USER} ..."
		_rssh "echo '${SSH_USER}:${_VM_PW}' | sudo chpasswd"
	fi

	# SSH private key + config (--copy-privkey or --full)
	if [ "$COPY_PRIVKEY" = 1 ]; then
		local privkey="${SSH_PUBKEY%.pub}"
		if [ -f "$privkey" ]; then
			echo "  Copying SSH keypair ..."
			_rssh "mkdir -p ~/.ssh && chmod 700 ~/.ssh"
			_rscp "$privkey" "${SSH_USER}@${_VM_IP}:~/.ssh/$(basename "$privkey")"
			_rscp "$SSH_PUBKEY" "${SSH_USER}@${_VM_IP}:~/.ssh/$(basename "$SSH_PUBKEY")"
			_rssh "chmod 600 ~/.ssh/$(basename "$privkey")"
		else
			echo "  WARNING: private key not found: $privkey"
		fi
		if [ -f "$HOME/.ssh/config" ]; then
			echo "  Copying ~/.ssh/config ..."
			_rscp "$HOME/.ssh/config" "${SSH_USER}@${_VM_IP}:~/.ssh/config"
			_rssh "chmod 600 ~/.ssh/config"
		fi
	else
		echo "  SSH private key: skipped (use --copy-privkey or --full)"
	fi

	# Full mode
	if [ "$FULL_MODE" = 1 ]; then
		deploy_full
	fi
}

# ── Deploy full user configs from bastion (--full) ────────────────────────────
deploy_full() {
	echo ""
	echo "  === Full mode: deploying user configs from bastion ==="

	# Packages
	echo "  Installing packages (git, tmux, podman, rsync, make, bind-utils) ..."
	_rssh "sudo dnf install -y git tmux podman rsync make bind-utils" || \
		echo "  WARNING: some packages may have failed"

	# tmux.conf
	if [ -f "$HOME/.tmux.conf" ]; then
		echo "  Copying .tmux.conf ..."
		_rscp "$HOME/.tmux.conf" "${SSH_USER}@${_VM_IP}:~/.tmux.conf"
	fi

	# Proxy files
	for f in .proxy-set.sh .proxy-unset.sh; do
		if [ -f "$HOME/$f" ]; then
			echo "  Copying $f ..."
			_rscp "$HOME/$f" "${SSH_USER}@${_VM_IP}:~/$f"
		fi
	done

	# pull-secret.json
	if [ -f "$HOME/.pull-secret.json" ]; then
		echo "  Copying .pull-secret.json ..."
		_rscp "$HOME/.pull-secret.json" "${SSH_USER}@${_VM_IP}:~/.pull-secret.json"
		_rssh "chmod 600 ~/.pull-secret.json"
	fi

	# vmware.conf
	if [ -f "$HOME/.vmware.conf" ]; then
		echo "  Copying .vmware.conf ..."
		_rscp "$HOME/.vmware.conf" "${SSH_USER}@${_VM_IP}:~/.vmware.conf"
		_rssh "chmod 600 ~/.vmware.conf"
	fi

	# .gitconfig
	if [ -f "$HOME/.gitconfig" ]; then
		echo "  Copying .gitconfig ..."
		_rscp "$HOME/.gitconfig" "${SSH_USER}@${_VM_IP}:~/.gitconfig"
	fi

	# ABA_TESTING=1
	echo "  Setting ABA_TESTING=1 ..."
	_rssh "sudo bash -c 'echo ABA_TESTING=1 >> /etc/environment'"
	_rssh "grep -q 'export ABA_TESTING=' ~/.bashrc || echo 'export ABA_TESTING=1' >> ~/.bashrc"

	# ppods helper script
	echo "  Installing ~/bin/ppods ..."
	_rssh "mkdir -p ~/bin"
	cat > "$_TMPDIR/ppods" <<'PPEOF'
#!/bin/bash
oc get po -A | awk '{split($3, arr, "/"); if (arr[1] != arr[2] && $4 != "Completed") print}'
PPEOF
	_rscp "$_TMPDIR/ppods" "${SSH_USER}@${_VM_IP}:~/bin/ppods"
	_rssh "chmod 755 ~/bin/ppods"

	# .bashrc: tmux helper function
	echo "  Adding tmux helper to .bashrc ..."
	cat > "$_TMPDIR/bashrc-tmux" <<'RCEOF'

# Auto-start or reattach tmux session
tmuxstart() {
	if [ -z "${TMUX:-}" ]; then
		tmux attach -t main 2>/dev/null || tmux new -s main
	fi
}
RCEOF
	_rscp "$_TMPDIR/bashrc-tmux" "${SSH_USER}@${_VM_IP}:/tmp/.bashrc-tmux"
	_rssh "grep -q 'tmuxstart()' ~/.bashrc || cat /tmp/.bashrc-tmux >> ~/.bashrc; rm -f /tmp/.bashrc-tmux"

	echo "  === Full mode deployment complete ==="
	echo ""
}

# ── Step 7: Verify template ──────────────────────────────────────────────────
verify_template() {
	echo "Step 7/8: Verifying template ..."
	local failures=0

	if _rssh "true" 2>/dev/null; then
		echo "  OK  SSH as ${SSH_USER}"
	else
		echo "  FAIL  SSH as ${SSH_USER}" >&2
		failures=$((failures + 1))
	fi

	if _rssh "sudo id" >/dev/null 2>&1; then
		echo "  OK  sudo (NOPASSWD)"
	else
		echo "  FAIL  sudo" >&2
		failures=$((failures + 1))
	fi

	if _rssh "test -f /etc/systemd/system/expand-root.service" >/dev/null 2>&1; then
		if _rssh "systemctl is-enabled expand-root.service" >/dev/null 2>&1; then
			echo "  OK  expand-root.service installed and enabled"
		else
			echo "  FAIL  expand-root.service installed but NOT enabled" >&2
			failures=$((failures + 1))
		fi
	else
		echo "  FAIL  expand-root.service not installed" >&2
		failures=$((failures + 1))
	fi

	local root_fs
	root_fs=$(_rssh "df -T / | tail -1 | awk '{print \$2}'") || true
	if [ "$root_fs" = "xfs" ]; then
		echo "  OK  / filesystem is XFS on LVM"
	else
		echo "  WARN  / filesystem is '${root_fs}' (expected xfs)"
	fi

	if _rssh "systemctl is-active chronyd" >/dev/null 2>&1; then
		echo "  OK  chronyd running"
	else
		echo "  WARN  chronyd not active"
	fi

	if _rssh "systemctl is-active vmtoolsd" >/dev/null 2>&1; then
		echo "  OK  open-vm-tools running"
	else
		echo "  WARN  vmtoolsd not active"
	fi

	if [ "$failures" -gt 0 ]; then
		echo "  ERROR: ${failures} critical check(s) failed" >&2
		exit 1
	fi
	echo "  All checks passed."
}

# ── Step 8: Finalize (shutdown, NIC, eject, snapshot) ─────────────────────────
finalize() {
	echo "Step 8/8: Finalizing ..."

	# Enable expand-root.service now (not in kickstart, to avoid running on the
	# template itself where the disk is already the right size).
	echo "  Enabling expand-root.service for clones ..."
	_rssh "sudo systemctl enable expand-root.service" || true

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

	# --full: add 2nd NIC while VM is off
	if [ "$FULL_MODE" = 1 ]; then
		echo "  Adding 2nd NIC: External Network ..."
		govc vm.network.add -vm "$VM_NAME" -net "External Network" \
			-net.adapter vmxnet3 || \
			echo "  WARNING: failed to add 2nd NIC"
	fi

	# Eject ISOs and remove ALL CDROM devices
	echo "  Removing CD-ROMs ..."
	for _dev in $(govc device.ls -vm "$VM_NAME" | awk '/cdrom/{print $1}'); do
		govc device.cdrom.eject -vm "$VM_NAME" -device "$_dev" 2>/dev/null || true
		govc device.remove -vm "$VM_NAME" -device "$_dev" 2>/dev/null || true
	done

	# Remove OEMDRV ISO from datastore
	if [ -n "${_KS_DS_PATH:-}" ]; then
		govc datastore.rm -ds "$VM_DATASTORE" "$_KS_DS_PATH" 2>/dev/null || true
		_KS_DS_PATH=""
	fi

	# Snapshot
	echo "  Creating snapshot: ${SNAPSHOT_NAME} ..."
	govc snapshot.create -vm "$VM_NAME" "$SNAPSHOT_NAME"

	# Annotate in vCenter Notes field
	local _mode="minimal"
	[ "$FULL_MODE" = 1 ] && _mode="full (standalone)"
	local _reg="none"
	[ -n "${SUB_USERNAME:-}" ] && _reg="${SUB_USERNAME}"
	local _nics="1 (VM Network)"
	[ "$FULL_MODE" = 1 ] && _nics="2 (VM Network, External Network)"

	local _notes
	_notes=$(cat <<-NOTESEOF
		RHEL ${RHEL_VER} VM Template
		Created: $(date '+%Y-%m-%d %H:%M:%S %Z')
		Created by: create-template.sh
		Mode: ${_mode}
		Snapshot: ${SNAPSHOT_NAME}

		Hardware: ${CPU} vCPU, ${MEM_MB} MB RAM, ${DISK_GB} GB disk (EFI, pvscsi)
		NICs: ${_nics}
		ISO: [${ISO_DATASTORE}] ${ISO_PATH}
		Datastore: ${VM_DATASTORE}

		OS config:
		  User: ${SSH_USER} (NOPASSWD sudo, SSH pubkey auth, console pw: $([ -n "${_VM_PW:-}" ] && echo "set" || echo "none"))
		  Root: locked (no direct access)
		  Hostname: ${VM_HOSTNAME}
		  Timezone: Asia/Singapore
		  NTP: 10.0.1.8, rhel.pool.ntp.org
		  Disk: single / on LVM (XFS), expand-root.service enabled
		  SELinux: enforcing
		  Registration: ${_reg}
	NOTESEOF
	)
	echo "  Setting vCenter Notes ..."
	govc vm.change -vm "$VM_NAME" -annotation "$_notes" 2>/dev/null || true

	echo ""
	echo "=== Template '${VM_NAME}' created successfully ==="
	echo "  Snapshot:  ${SNAPSHOT_NAME}"
	echo "  VM IP:     ${_VM_IP} (DHCP -- may change after clone)"
	echo ""
	echo "  Power on:"
	echo "    govc vm.power -on ${VM_NAME}"
	echo ""
	echo "  Clone with:"
	echo "    govc vm.clone -vm ${VM_NAME} -snapshot ${SNAPSHOT_NAME} -on=false <new-name>"
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
verify_template
finalize
