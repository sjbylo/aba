#!/bin/bash
# =============================================================================
# TUI Shared Constants — Single source of truth for dialog titles and menu IDs
# =============================================================================
#
# Both the TUI (abatui.sh) and the automated tests (test/func/)
# source this file. Changing a string here keeps both sides in sync.
#
# Rules:
#   1. Every --title string used in a dialog MUST have a constant here.
#   2. Every numbered menu item in the action menu MUST have a constant here.
#   3. When adding/renaming a dialog, update the constant first, then both
#      the TUI code and the test that references it.
#   4. Constants are READONLY after sourcing — treat them as immutable.
#
# Usage:
#   source tui/tui-strings.sh          # from TUI
#   source "$ABA_ROOT/tui/tui-strings.sh"  # from tests
# =============================================================================

# --- Abort if executed directly ---
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	echo "ERROR: This file should be sourced, not executed."
	exit 1
fi

# =============================================================================
# Dialog Titles — Wizard Flow
# =============================================================================

TUI_TITLE_WELCOME="ABA – OpenShift Installer"
TUI_TITLE_INTERNET_REQUIRED="Internet Access Required"
TUI_TITLE_RESUME="Existing Configuration Found"
TUI_TITLE_CHANNEL="OpenShift Channel"
TUI_TITLE_VERSION="OpenShift Version"
TUI_TITLE_VERSION_FETCH_FAILED="Version Fetch Failed"
TUI_TITLE_CONFIRM="Confirm Selection"
TUI_TITLE_PULL_SECRET="Red Hat Pull Secret"
TUI_TITLE_PULL_SECRET_REQUIRED="Pull Secret Required"
TUI_TITLE_PULL_SECRET_PASTE="Red Hat Pull Secret - Paste JSON below"
TUI_TITLE_PULL_SECRET_VALIDATION_FAILED="Pull Secret Validation Failed"
TUI_TITLE_VALIDATION_ERROR="Validation Error"
TUI_TITLE_PLATFORM="Platform & Network"
TUI_TITLE_OPERATORS="Select Operators"
TUI_TITLE_EMPTY_BASKET="Empty Basket"
TUI_TITLE_OPERATOR_SETS="Operator Sets"
TUI_TITLE_SELECT_OPERATORS="Select Operators"
TUI_TITLE_IMAGESET="ImageSet Configuration"

# =============================================================================
# Dialog Titles — Action Screens
# =============================================================================

TUI_TITLE_ACTION_MENU="Choose Next Action"
TUI_TITLE_SETTINGS="Settings"
TUI_TITLE_ADVANCED="Advanced Options"
TUI_TITLE_CREATE_BUNDLE="Create Bundle"
TUI_TITLE_DISK_SPACE_WARNING="Disk Space Warning"
TUI_TITLE_LOCAL_QUAY="Local Quay Registry"
TUI_TITLE_LOCAL_DOCKER="Local Docker Registry"
TUI_TITLE_REMOTE_QUAY="Remote Quay Registry (SSH)"
TUI_TITLE_CONFIRM_EXEC="Confirm Execution"

# =============================================================================
# Dialog Titles — Utility
# =============================================================================

TUI_TITLE_CONFIRM_EXIT="Confirm Exit"
TUI_TITLE_HELP="ABA Help"
TUI_TITLE_ERROR="Error"

# =============================================================================
# Action Menu — Letter Tags
# =============================================================================
# These are the single-letter tags for the "Choose Next Action" dialog.
# The letter matches the underlined mnemonic in each label.

TUI_ACTION_VIEW_IMAGESET=V
TUI_ACTION_RESET_IMAGESET=A
TUI_ACTION_CREATE_BUNDLE=B
TUI_ACTION_SAVE_IMAGES=S
TUI_ACTION_LOCAL_REGISTRY=L
TUI_ACTION_REMOTE_REGISTRY=R
TUI_ACTION_RERUN_WIZARD=W
TUI_ACTION_SETTINGS=C
TUI_ACTION_ADVANCED=O

# =============================================================================
# Action Menu — Display Labels
# =============================================================================
# Mnemonic letter is underlined via \Zu...\Zn (requires dialog --colors).
# For test assertions, use the plain-text versions below.

TUI_ACTION_LABEL_VIEW_IMAGESET="\ZuV\Zniew Generated ImageSet Config"
TUI_ACTION_LABEL_VIEW_IMAGESET_USER="\ZuV\Zniew User-Edited ImageSet Config"
TUI_ACTION_LABEL_RESET_IMAGESET="Reset to \ZuA\Znuto-Generated ImageSet Config"
TUI_ACTION_LABEL_CREATE_BUNDLE="Create Air-Gapped Install \ZuB\Znundle"
TUI_ACTION_LABEL_SAVE_IMAGES="\ZuS\Znave Images to Local Archive"
TUI_ACTION_LABEL_LOCAL_REGISTRY="Install & Sync to \ZuL\Znocal Registry"
TUI_ACTION_LABEL_REMOTE_REGISTRY="Install & Sync to \ZuR\Znemote Registry via SSH"
TUI_ACTION_LABEL_RERUN_WIZARD="Rerun \ZuW\Znizard"
TUI_ACTION_LABEL_SETTINGS="\ZuC\Znonfigure..."
TUI_ACTION_LABEL_ADVANCED="Advanced \ZuO\Znptions..."

# Plain-text versions for test assertions (dialog strips \Zu/\Zn on screen)
TUI_ACTION_TEXT_VIEW_IMAGESET="View Generated ImageSet Config"
TUI_ACTION_TEXT_VIEW_IMAGESET_USER="View User-Edited ImageSet Config"
TUI_ACTION_TEXT_RESET_IMAGESET="Reset to Auto-Generated ImageSet Config"

# =============================================================================
# Settings Menu — Item Numbers
# =============================================================================

TUI_SETTINGS_AUTO_ANSWER=1
TUI_SETTINGS_REGISTRY_TYPE=2
TUI_SETTINGS_RETRY_COUNT=3

