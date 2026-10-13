#!/bin/bash
# USB_DEVICE is the documented override for the system-disk refusal.
# Bug #1124: the name was copied into usb_dev before the case, so
# USB_DEVICE=/dev/sda was refused. This test does not run write-usb or dd.

set -eo pipefail

cd "$(dirname "$0")/../.."
source scripts/cluster-write-usb.sh

fail=0

USB_DEVICE=/dev/sda
if usb_system_disk_refused /dev/sda; then
	echo "FAIL: USB_DEVICE=/dev/sda was refused"
	fail=1
else
	echo "PASS: USB_DEVICE=/dev/sda accepted"
fi

unset USB_DEVICE
if usb_system_disk_refused /dev/sda; then
	echo "PASS: prompt path still refuses /dev/sda"
else
	echo "FAIL: prompt path accepted /dev/sda"
	fail=1
fi

exit "$fail"
