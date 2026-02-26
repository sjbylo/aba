#!/bin/bash
# Dispatcher: installs the configured registry vendor (auto/quay/docker).
# Resolves reg_vendor, then exec's the appropriate vendor-specific script.
# For remote installs (reg_ssh_key defined), delegates to reg-install-remote.sh.

[ -z "${INFO_ABA+x}" ] && export INFO_ABA=1

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

source <(normalize-mirror-conf)

# REG_VENDOR_OVERRIDE lets Makefile backward-compat aliases force a specific vendor
vendor="${REG_VENDOR_OVERRIDE:-${reg_vendor:-auto}}"

# Resolve "auto": Quay if available for this architecture, else Docker
if [ "$vendor" = "auto" ]; then
	arch=$(uname -m)
	case "$arch" in
		aarch64|arm64) vendor=docker ;;
		*)             vendor=quay ;;
	esac
	aba_info "reg_vendor=auto resolved to '$vendor' for architecture $arch"
fi

# Persist resolved vendor for uninstall and status display
echo "$vendor" > .reg_vendor

# Dispatch: remote (SSH) or local
if [ "$reg_ssh_key" ]; then
	exec scripts/reg-install-remote.sh "$vendor" "$@"
else
	exec scripts/reg-install-${vendor}.sh "$@"
fi
