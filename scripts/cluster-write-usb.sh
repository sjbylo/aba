#!/bin/bash -e
# INTENT:       Write the cluster's agent-based ISO to a USB device using dd.
# CALLED BY:    aba write-usb (via aba.sh dispatch)
# CWD:          Cluster directory (e.g. ~/aba/sno/)
# REQUIRES:     cluster.conf, ISO file (iso-agent-based/agent.*.iso), target device
# PRODUCES:     Bootable USB device with raw ISO written byte-for-byte
# SIDE EFFECTS: Overwrites entire target device (all existing data destroyed)
# IDEMPOTENT:   Yes (re-running overwrites the same device)
# ENV:          USB_DEVICE — optional override for target device (e.g. /dev/sdb)

source scripts/include_all.sh

source <(normalize-cluster-conf)

ARCH=$(uname -m)
[ "$ARCH" = "amd64" ] && ARCH=x86_64

ASSETS_DIR="iso-agent-based"
iso_file="$ASSETS_DIR/agent.${ARCH}.iso"

[ ! -f "$iso_file" ] && aba_abort "ISO file not found: $PWD/$iso_file" \
	"Run 'aba iso' first to generate it."

iso_size=$(stat -c %s "$iso_file")
iso_size_human=$(numfmt --to=iec-i --suffix=B "$iso_size" 2>/dev/null || echo "${iso_size} bytes")
iso_sha256=$(sha256sum "$iso_file" | awk '{print $1}')

echo
aba_info "ISO file: $PWD/$iso_file"
aba_info "Size:     $iso_size_human"
aba_info "SHA256:   $iso_sha256"
echo

# Determine target device
usb_dev="${USB_DEVICE:-}"
if [ -z "$usb_dev" ]; then
	echo "Block devices on this system:"
	echo
	# Show only disk-type devices (no cd-rom, no NFS, no partitions).
	# Mark disks that have mounted partitions to help user avoid system disks.
	printf "  %-8s %8s  %-6s  %s\n" "DEVICE" "SIZE" "TRAN" "STATUS"
	while read -r _name _size _tran; do
		_mounts=$(lsblk -n -o MOUNTPOINTS "/dev/$_name" 2>/dev/null | grep '/' | xargs)
		_status=""
		if [ -n "$_mounts" ]; then
			_status="*** WARNING: HAS MOUNTED PARTITIONS *** ($_mounts)"
		fi
		printf "  %-8s %8s  %-6s  %s\n" "/dev/$_name" "$_size" "${_tran:---}" "$_status"
	done < <(lsblk -d -n -o NAME,SIZE,TRAN -e 11)
	echo
	# Check for USB-connected devices
	if ! lsblk -d -n -o NAME,TRAN -e 11 | grep -q 'usb'; then
		aba_warning "No USB devices detected. Insert a USB drive and try again, or specify the device manually."
		echo
	fi
	aba_warning "Choose carefully — the target device will be COMPLETELY OVERWRITTEN."
	echo
	read -rp "[ABA] Enter target device (e.g. /dev/sdX): " usb_dev
fi

[ -z "$usb_dev" ] && aba_abort "No target device specified."

# Validate it looks like a block device
[[ "$usb_dev" == /dev/* ]] || usb_dev="/dev/$usb_dev"
[ -b "$usb_dev" ] || aba_abort "Not a block device: $usb_dev"

# Safety: refuse to write to anything that looks like a system disk
case "$usb_dev" in
	/dev/sda|/dev/nvme0n1|/dev/vda)
		aba_abort "Refusing to write to $usb_dev (looks like a system disk)." \
			"Use USB_DEVICE=<dev> to override if you are certain."
		;;
esac

dev_size=$(lsblk -b -d -n -o SIZE "$usb_dev" 2>/dev/null || echo "unknown")
dev_model=$(lsblk -d -n -o MODEL "$usb_dev" 2>/dev/null | xargs || echo "unknown")

echo
aba_warning "This will OVERWRITE ALL DATA on: $usb_dev ($dev_model, $(numfmt --to=iec-i --suffix=B "$dev_size" 2>/dev/null || echo "$dev_size bytes"))"
echo
echo "Command that will be executed:"
echo
echo "  sudo dd if=$iso_file of=$usb_dev bs=4M conv=fsync status=progress"
echo

ask "Execute this command" || exit 0

# Unmount any mounted partitions from the device
for part in "${usb_dev}"*[0-9]; do
	[ -b "$part" ] && mountpoint -q "$part" 2>/dev/null && sudo umount "$part" 2>/dev/null || true
done

aba_info "Writing ISO to $usb_dev ..."
sudo dd if="$iso_file" of="$usb_dev" bs=4M conv=fsync status=progress
sync

echo
aba_info_ok "ISO written successfully to $usb_dev"
aba_info "You can now boot your server from this USB device."
aba_info "Verify: the server's BIOS/UEFI boot order must include USB boot."
aba_info "Tip: Most server management interfaces (iLO, iDRAC, BMC) can also mount"
aba_info "     the ISO as virtual media over the management network — no USB required."
