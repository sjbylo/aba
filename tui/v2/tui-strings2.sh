#!/usr/bin/env bash
# =============================================================================
# TUI v2 String Constants — All dialog titles, menu tags, and labels
# =============================================================================
# Single source of truth for the v2 TUI interface text.
# Both the TUI and automated tests source this file.

# --- BASH_SOURCE guard ---
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	echo "ERROR: This file should be sourced, not executed."
	exit 1
fi

# =============================================================================
# Dialog Titles — Common
# =============================================================================

TUI2_TITLE_WELCOME="ABA – OpenShift Installer"
TUI2_TITLE_CONFIRM_EXIT="Confirm Exit"
TUI2_TITLE_HELP="Help"
TUI2_TITLE_ERROR="Error"
TUI2_TITLE_CONFIRM_EXEC="Confirm Execution"

# =============================================================================
# Dialog Titles — Mode Detection
# =============================================================================

TUI2_TITLE_MODE_SELECT="INSTALLATION MODE"
TUI2_TITLE_BUNDLE_CONNECTED="Bundle on Connected Host"
TUI2_TITLE_DEAD_END="Cannot Proceed"

# =============================================================================
# Dialog Titles — Wizard (shared: CONNO initial + DIRECT)
# =============================================================================

TUI2_TITLE_PULL_SECRET="Red Hat Pull Secret"
TUI2_TITLE_PULL_SECRET_PASTE="Pull Secret – Paste JSON"
TUI2_TITLE_CHANNEL="OpenShift Channel"
TUI2_TITLE_VERSION="OpenShift Version"
TUI2_TITLE_VERSION_MANUAL="Manual Version"
TUI2_TITLE_VERSION_WAIT="Fetching Versions"
TUI2_TITLE_PLATFORM="Platform"
TUI2_TITLE_OPERATORS="Select Operators"
TUI2_TITLE_OPERATOR_SETS="Operator Sets"
TUI2_TITLE_OPERATOR_SEARCH="Search Operators"

# =============================================================================
# Dialog Titles — DISCO Mode
# =============================================================================

TUI2_TITLE_DISCO_MENU="DISCO Mode – Actions"
TUI2_TITLE_DISCO_INSTALL_REG="Install Registry"
TUI2_TITLE_DISCO_LOAD="Load Images"
TUI2_TITLE_DISCO_VIEW_ISC="ImageSet Configuration (read-only)"
TUI2_TITLE_DISCO_RESET="Reset to Connected Mode"
TUI2_TITLE_DISCO_LIGHT="Light Bundle Detected"

# =============================================================================
# Dialog Titles — CONNO Mode
# =============================================================================

TUI2_TITLE_CONNO_MENU="CONNO Mode – Actions"
TUI2_TITLE_CONNO_INSTALL_MIRROR="Install Mirror Registry"
TUI2_TITLE_CONNO_SAVE="Save Images"
TUI2_TITLE_CONNO_SYNC="Sync Images"
TUI2_TITLE_CONNO_VIEW_ISC="ImageSet Configuration"
TUI2_TITLE_CONNO_EDIT_ISC="Edit ImageSet Configuration"
TUI2_TITLE_CONNO_BUNDLE="Create Bundle"

# =============================================================================
# Dialog Titles — DIRECT Mode
# =============================================================================

TUI2_TITLE_DIRECT_MENU="DIRECT Mode – Actions"
TUI2_TITLE_DIRECT_WIZARD="Direct Install Setup"

# =============================================================================
# Dialog Titles — Cluster
# =============================================================================

TUI2_TITLE_CLUSTER_BASICS="Cluster – Basics"
TUI2_TITLE_CLUSTER_NAME="Cluster Name"
TUI2_TITLE_CLUSTER_BASE_DOMAIN="Base Domain"
TUI2_TITLE_CLUSTER_WORKER_COUNT="Worker Count"
TUI2_TITLE_CLUSTER_NETWORK="Cluster – Networking"
TUI2_TITLE_CLUSTER_MACHINE_NET="Machine Network"
TUI2_TITLE_CLUSTER_STARTING_IP="Starting IP"
TUI2_TITLE_CLUSTER_API_VIP="API VIP"
TUI2_TITLE_CLUSTER_INGRESS_VIP="Ingress VIP"
TUI2_TITLE_CLUSTER_DNS="DNS Servers"
TUI2_TITLE_CLUSTER_GATEWAY="Gateway"
TUI2_TITLE_CLUSTER_NTP="NTP Servers"
TUI2_TITLE_CLUSTER_IFACE="Cluster – Interfaces"
TUI2_TITLE_CLUSTER_PORT_NAMES="Port Names"
TUI2_TITLE_CLUSTER_VLAN="VLAN Tag"
TUI2_TITLE_CLUSTER_VM="Cluster – VM Resources"
TUI2_TITLE_CLUSTER_MASTER_CPU="Master CPUs"
TUI2_TITLE_CLUSTER_MASTER_MEM="Master Memory"
TUI2_TITLE_CLUSTER_WORKER_CPU="Worker CPUs"
TUI2_TITLE_CLUSTER_WORKER_MEM="Worker Memory"
TUI2_TITLE_CLUSTER_DATA_DISK="Data Disk"
TUI2_TITLE_CLUSTER_MAC_TEMPLATE="MAC Template"
TUI2_TITLE_CLUSTER_SELECT="Select Cluster"
TUI2_TITLE_CLUSTER_INSTALL="Install Cluster"
TUI2_TITLE_CLUSTER_MONITOR="Monitor Cluster"
TUI2_TITLE_CLUSTER_OSUS_WARN="OSUS Warning"

# =============================================================================
# Dialog Titles — Day-2
# =============================================================================

TUI2_TITLE_DAY2_MENU="Day-2 Operations"
TUI2_TITLE_DAY2_FULL="Day-2: Full Configuration"
TUI2_TITLE_DAY2_NTP="Day-2: NTP Configuration"
TUI2_TITLE_DAY2_OSUS="Day-2: OSUS (Cincinnati)"

# =============================================================================
# Dialog Titles — Platform Config
# =============================================================================

TUI2_TITLE_PLATFORM_CHECK="Platform Configuration Required"

# =============================================================================
# Menu Tags — DISCO Action Menu
# =============================================================================

TUI2_DISCO_TAG_INSTALL_REG="R"
TUI2_DISCO_TAG_LOAD="L"
TUI2_DISCO_TAG_INSTALL="I"
TUI2_DISCO_TAG_DAY2="D"
TUI2_DISCO_TAG_MONITOR="N"
TUI2_DISCO_TAG_VIEW_ISC="V"
TUI2_DISCO_TAG_RESET="X"

# =============================================================================
# Menu Tags — CONNO Action Menu
# =============================================================================

# Single-letter tags serve as keyboard shortcuts (press letter to jump to item).
# Matches v1 pattern: visible shortcut + clean label. Letters chosen to be unique
# and mnemonic (first letter of key word where possible).
TUI2_CONNO_TAG_INSTALL_MIRROR="M"
TUI2_CONNO_TAG_SAVE="S"
TUI2_CONNO_TAG_SYNC="Y"
TUI2_CONNO_TAG_VIEW_ISC="V"
TUI2_CONNO_TAG_OPERATORS="O"
TUI2_CONNO_TAG_BUNDLE="B"
TUI2_CONNO_TAG_INSTALL="I"
TUI2_CONNO_TAG_DAY2="D"
TUI2_CONNO_TAG_MONITOR="N"
TUI2_CONNO_TAG_SWITCH_DIRECT="X"
TUI2_CONNO_TAG_SWITCH_DISCO="Z"

# =============================================================================
# Menu Tags — DIRECT Action Menu
# =============================================================================

TUI2_DIRECT_TAG_INSTALL="I"
TUI2_DIRECT_TAG_DAY2="D"
TUI2_DIRECT_TAG_MONITOR="N"
TUI2_DIRECT_TAG_SWITCH_MIRROR="M"

# =============================================================================
# Menu Labels (plain text for greyed-out items)
# =============================================================================

TUI2_GREY_INSTALL_FIRST="[install cluster first]"
TUI2_GREY_REG_FIRST="[install registry first]"
TUI2_GREY_MIRROR_FIRST="[install mirror first]"
TUI2_GREY_ALREADY_INSTALLED="(installed)"
TUI2_GREY_NO_INTERNET="[no internet]"
TUI2_MSG_NO_INTERNET="This action requires internet access.\n\nRestore internet connectivity to use this feature."
TUI2_MSG_PAYLOAD_INCOMPLETE="Insufficient files for offline operation.\n\nRequired (minimum bundle equivalent):\n  • aba.conf\n  • cli/openshift-client-linux*.tar.gz (>1MB)\n  • cli/openshift-install-linux*.tar.gz (>1MB)\n  • cli/oc-mirror*.tar.gz (>1MB)\n  • mirror/mirror-registry*.tar.gz or docker-reg-image.tgz\n  • mirror/data/imageset-config.yaml (non-empty)\n  • EITHER: mirror running OR tar archives in mirror/data/\n\nTransfer a bundle or restore internet connectivity."

# =============================================================================
# Prompt / Message Text — Wizard
# =============================================================================

TUI2_MSG_CHANNEL_PROMPT="Choose the OpenShift update channel:"
TUI2_MSG_PLATFORM_PROMPT="Select target platform:"
TUI2_MSG_VERSION_FETCHING="Fetching versions for '%s' channel...\n\nPlease wait..."

# =============================================================================
# Prompt / Message Text — Cluster Validation
# =============================================================================

TUI2_MSG_INVALID_CLUSTER_NAME="Invalid cluster name.\n\nMust start with a letter and contain only lowercase a-z, 0-9, hyphens."
TUI2_MSG_DIRECT_CONN_LOCKED="Connection is locked to 'direct' in DIRECT mode."
TUI2_MSG_PLATFORM_CONFIG_MISSING="%s configuration not found.\n\nExpected: %s\nRequired fields: %s\n\nHow to proceed:"

# =============================================================================
# Prompt / Message Text — Mirror / ISC
# =============================================================================

TUI2_MSG_ISC_GENERATING="Generating ImageSet configuration...\n\nPlease wait."
TUI2_MSG_ISC_NOT_FOUND="ImageSet configuration file not found.\n\nFile: %s"
TUI2_MSG_ISC_SAVED="ImageSet configuration saved.\n\nABA will not overwrite your edits.\nUse 'Reset' to revert to auto-generated."
TUI2_MSG_ISC_RESET="ImageSet configuration reset to auto-generated.\n\nIt will be regenerated from current settings on next use."
TUI2_MSG_CATALOG_DOWNLOADING="Downloading operator catalogs for OpenShift %s...\n\nThis may take a few minutes."
TUI2_MSG_CATALOG_FAILED="Failed to download catalog: %s\n\nCheck internet connection and try again."

# =============================================================================
# Button Labels
# =============================================================================

TUI2_BTN_SELECT="Select"
TUI2_BTN_EXIT="Exit"
TUI2_BTN_BACK="Back"
TUI2_BTN_NEXT="Next"
TUI2_BTN_CANCEL="Cancel"
TUI2_BTN_SAVE="Save"
TUI2_BTN_SKIP="Skip"
TUI2_BTN_INSTALL="Install"
TUI2_BTN_SWITCH="Switch"
TUI2_BTN_TOGGLE="Toggle"
TUI2_BTN_REMOVE="Remove"
TUI2_BTN_DONE="Done"
TUI2_BTN_RETRY="Retry"
TUI2_BTN_BACK_TO_MENU="Back to Menu"
TUI2_BTN_CHECK_AGAIN="Check again"
TUI2_BTN_CONTINUE="Continue"
TUI2_BTN_EXIT_TUI="Exit TUI"
TUI2_BTN_DISCO_MODE="DISCO mode"
TUI2_BTN_CONNECTED_MODE="Connected mode"
TUI2_BTN_LIGHT_BUNDLE="Light bundle"
TUI2_BTN_FULL_BUNDLE="Full bundle"

# =============================================================================
# Messages — Mode Detection
# =============================================================================

TUI2_MSG_BUNDLE_INCOMPLETE="Bundle incomplete.\n\nThe bundle flag (.bundle) is present but no ImageSet\nconfiguration was found.\n\nRe-transfer the bundle or run 'aba reset'."
TUI2_MSG_BUNDLE_CONNECTED="This host has an ABA install bundle but also has internet access.\nThe bundle is intended for disconnected environments.\n\n• DISCO mode — use the bundle as intended\n• Connected mode — use internet access (mirror or direct)"
TUI2_MSG_DEAD_END="Cannot proceed.\n\nNo internet access and no bundle detected.\n\nTransfer a bundle from a connected host first,\nor ensure internet connectivity."
TUI2_MSG_MODE_SELECT="This choice affects the ENTIRE installation workflow.\n\n   How would you like to install OpenShift?"
TUI2_MSG_MODE_MIRROR="WITH MIRROR REGISTRY (recommended for production)"
TUI2_MSG_MODE_DIRECT="DIRECT FROM INTERNET (no mirror, simpler setup)"

# =============================================================================
# Messages — CONNO Action Menu
# =============================================================================

TUI2_MSG_CONNO_MENU=""  # Dynamic — set at runtime by _conno_menu_msg()
TUI2_MSG_MIRROR_REINSTALL="Mirror registry is already installed.\n\nReinstall it?"
TUI2_MSG_MIRROR_FIRST="Mirror registry is not installed.\n\nUse 'Install Mirror' to set up a local or remote registry first."
TUI2_MSG_CLUSTER_FIRST="No cluster installed yet.\n\nUse 'Install Cluster' to configure and provision a cluster first."

# =============================================================================
# Messages — Cluster Configuration
# =============================================================================

TUI2_MSG_CLUSTER_BASICS="Cluster Basics — select a row to edit/toggle:"
TUI2_MSG_CLUSTER_NETWORK="Network configuration — select a row to edit:"
TUI2_MSG_CLUSTER_IFACE="Interface configuration:"
TUI2_MSG_CLUSTER_VM="VM Resources (platform: %s):"
TUI2_MSG_CLUSTER_NAME_PROMPT="Enter cluster name (lowercase, a-z, 0-9, hyphens):"
TUI2_MSG_CLUSTER_WORKER_PROMPT="Number of worker nodes:"
TUI2_MSG_BASE_DOMAIN_PROMPT="Enter base domain for the cluster\n(e.g. example.com, ocp.local):"
TUI2_MSG_NET_CIDR_PROMPT="CIDR notation (e.g. 10.0.0.0/24):"
TUI2_MSG_NET_STARTING_IP_PROMPT="First IP for cluster nodes:"
TUI2_MSG_NET_API_VIP_PROMPT="Virtual IP for Kubernetes API:"
TUI2_MSG_NET_INGRESS_VIP_PROMPT="Virtual IP for ingress traffic:"
TUI2_MSG_NET_DNS_PROMPT="Comma-separated DNS server IPs:"
TUI2_MSG_NET_GATEWAY_PROMPT="Default gateway IP:"
TUI2_MSG_NET_NTP_PROMPT="Comma-separated NTP servers (optional):"
TUI2_MSG_IFACE_PORT_PROMPT="Network interface name(s):"
TUI2_MSG_IFACE_VLAN_PROMPT="VLAN tag (leave empty for none):"
TUI2_MSG_VM_MASTER_CPU_PROMPT="Number of CPUs per master node:"
TUI2_MSG_VM_MASTER_MEM_PROMPT="Memory per master node (GB):"
TUI2_MSG_VM_WORKER_CPU_PROMPT="Number of CPUs per worker node:"
TUI2_MSG_VM_WORKER_MEM_PROMPT="Memory per worker node (GB):"
TUI2_MSG_VM_DISK_PROMPT="Additional data disk size (GB, empty for none):"
TUI2_MSG_VM_MAC_PROMPT="MAC address prefix (e.g. 52:54:00):"
TUI2_MSG_OSUS_WARNING="The Cincinnati/OSUS operator does not appear to be in your ImageSet configuration.\n\nThe OSUS Day-2 operation may fail without it.\n\nContinue anyway?"
TUI2_MSG_NO_CLUSTERS="No clusters configured."
TUI2_MSG_NO_INSTALLED_CLUSTERS="No installed clusters found."

# =============================================================================
# Messages — Wizard (Pull Secret / Version / Platform)
# =============================================================================

TUI2_MSG_PULL_SECRET_FOUND="Pull secret found at:\n\n  %s\n"
TUI2_MSG_PULL_SECRET_PASTE="Paste your pull secret JSON:"
TUI2_MSG_PULL_SECRET_EMPTY="No pull secret entered."
TUI2_MSG_PULL_SECRET_INVALID="Invalid JSON. Please try again."
TUI2_MSG_VERSION_ENTRY="Enter version (x.y.z):"
TUI2_MSG_VERSION_MENU="Select OpenShift version (%s channel):"
TUI2_MSG_VERSION_MANUAL_PROMPT="Cannot fetch versions automatically.\n\nEnter OpenShift version manually (x.y.z):"
TUI2_MSG_VERSION_FETCH_FAIL="Cannot fetch version data (no internet?).\n\nUsing existing version: %s"

# =============================================================================
# Messages — Day-2
# =============================================================================

TUI2_MSG_DAY2_MENU="Select Day-2 operation:"

# =============================================================================
# Messages — DIRECT Mode
# =============================================================================

TUI2_MSG_DIRECT_MENU="Direct Mode — Install from internet (no mirror):"

# =============================================================================
# Messages — DISCO Mode
# =============================================================================

TUI2_MSG_DISCO_MENU="Disconnected Mode — Choose an action:"
TUI2_MSG_DISCO_REG_FIRST="Registry is not installed.\n\nUse 'Install Registry' to set up the mirror registry before loading images."
TUI2_MSG_DISCO_NO_INTERNET="This action requires internet access.\n\nRestore internet connectivity to switch to connected mode."
TUI2_MSG_DISCO_RESET_CONFIRM="Switch to connected mode?\n\nThe bundle state will be cleared and you will be asked\nto choose between Mirror and Direct installation modes."
TUI2_MSG_DISCO_LIGHT="Light bundle detected — no archive files found.\n\nCopy the image archive file(s) (mirror_*.tar) from your\ntransfer media to:\n\n  %s/mirror/data/\n\nThen select 'Check again'."

# =============================================================================
# Messages — Mirror Operations
# =============================================================================

TUI2_MSG_MIRROR_TARGET="Install a mirror registry:\n\nChoose installation target:"
TUI2_MSG_MIRROR_REMOTE_PROMPT="Enter the remote host (SSH target):\n\n(e.g., user@registry-host)"
TUI2_MSG_ISC_MENU="ImageSet Configuration:"
TUI2_MSG_OPERATOR_MENU="Operator Selection:"
TUI2_MSG_OPERATOR_SET_MENU="Select a set to add/remove:"
TUI2_MSG_OPERATOR_SEARCH_PROMPT="Enter operator name (or partial name) to search:"
TUI2_MSG_OPERATOR_SEARCH_MENU="Select to add/remove from basket:"
TUI2_MSG_OPERATOR_BASKET_MENU="Select to remove from basket:"
TUI2_MSG_NO_OPERATOR_SETS="No operator set files found."
TUI2_MSG_NO_SEARCH_RESULTS="No operators matching '%s' found."
TUI2_MSG_BASKET_EMPTY="Basket is empty.\n\nUse 'Select Operator Sets' or 'Search' to add operators."
TUI2_MSG_BUNDLE_PATH_PROMPT="Enter output path for install bundle:\n\n(Version suffix added automatically)"
TUI2_MSG_BUNDLE_LIGHT_CONFIRM="Output and mirror are on the same filesystem.\n\nUse --light to exclude large archives (saves disk space)?"

# =============================================================================
# Messages — Execution / Exit
# =============================================================================

TUI2_MSG_CONFIRM_EXIT="Exit ABA TUI?\n\nUnsaved changes will be lost."
TUI2_MSG_EXIT_HELP="Exiting the TUI:\n\n• Press ESC at any time to quit (with confirmation)\n• Press ESC again on confirmation to quit immediately\n• Click 'Exit' to confirm and quit\n• Click 'Continue' to return\n\nConfiguration is only saved when you complete actions."
TUI2_MSG_EXEC_MODE="Choose execution mode:"
TUI2_MSG_EDITOR_PROMPT="How would you like to edit?\n\n  %s"

# =============================================================================
# Messages — Pull Secret (multiline)
# =============================================================================

TUI2_MSG_PULL_SECRET_INFO="A Red Hat pull secret is required.\n\nGet yours from:\n  https://console.redhat.com/openshift/downloads#tool-pull-secret\n\nIt will be saved to:\n  ~/.pull-secret.json"

# =============================================================================
# Help Titles
# =============================================================================

TUI2_HELP_TITLE_MODE="Installation Mode"
TUI2_HELP_TITLE_CONNO="CONNO Mode"
TUI2_HELP_TITLE_DIRECT="DIRECT Mode"
TUI2_HELP_TITLE_DISCO="DISCO Mode"
TUI2_HELP_TITLE_BASICS="Cluster Basics"
TUI2_HELP_TITLE_NETWORK="Cluster Networking"
TUI2_HELP_TITLE_IFACE="Interfaces"
TUI2_HELP_TITLE_VM="VM Resources"
TUI2_HELP_TITLE_DAY2="Day-2 Operations"
TUI2_HELP_TITLE_CHANNEL="OpenShift Channels"
TUI2_HELP_TITLE_VERSION="Version Selection"
TUI2_HELP_TITLE_PLATFORM="Platform"
TUI2_HELP_TITLE_EXEC="Execution Options"
TUI2_HELP_TITLE_MIRROR="Install Mirror"
TUI2_HELP_TITLE_OPERATORS="Operator Selection"
