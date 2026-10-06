#!/bin/bash
# progress-plan.sh — Emit PLAN events for all workflows
#
# Single source of truth for every workflow's progress steps.
# Called two ways:
#   1. From PHONY _plan-* Makefile prereqs (mirror, bundle)
#   2. Directly from scripts that are entry points (day2, cluster-*)
#
# Each case only knows its OWN steps — never another workflow's steps.
# When "make sync" triggers install as a dependency, _plan-install
# fires first (as install's prereq) and _plan-sync fires later.
# The progress dialog grows as new PLANs arrive in batches.
#
# PLAN order must match execution order.  Auto-complete marks
# predecessors of the active step — misordering causes confusing
# Skipped→In Progress flips.

source "$(dirname "$0")/include_all.sh"

case "$1" in

	# ── Mirror workflows (called from _plan-* Makefile targets) ──

	install)
		# Only emit PLANs when install will actually run.
		# When .available exists, the registry is already installed — nothing to show.
		# This prevents Skipped items cluttering the dialog for a cached sync.
		[ -f .available ] && exit 0
		aba_progress "PLAN|rpms_ext|Install required packages"
		aba_progress "PLAN|reg_config|Validate configuration"
		aba_progress "PLAN|reg_env|Check environment"
		aba_progress "PLAN|reg_firewall|Configure firewall"
		aba_progress "PLAN|reg_download|Download registry software"
		aba_progress "PLAN|reg_install|Install registry"
		aba_progress "PLAN|reg_postcfg|Configure credentials"
		aba_progress "PLAN|reg_verify|Verify connectivity"
		;;

	sync)
		# Sync only knows about its own steps — never install steps.
		# If install is needed, _plan-install (prereq of install) handles that.
		#
		# Order matches Make's execution of sync prerequisites:
		#   .rpmsint → install → _plan-sync → status-preflight → reg-sync.sh
		aba_progress "PLAN|rpms_int|Install required packages"
		aba_progress "PLAN|preflight|Preflight checks"
		aba_progress "PLAN|catalogs_dl|Download operator catalogs"
		aba_progress "PLAN|versions|Verify release versions"
		aba_progress "PLAN|tools|Prepare tools"
		aba_progress "PLAN|registry|Registry access"
		aba_progress "PLAN|sync|Mirror images"
		aba_progress "PLAN|finalize|Finalize"
		;;

	save)
		# Order matches Make's execution:
		#   .rpmsext → status-preflight → reg-save.sh
		aba_progress "PLAN|rpms_ext|Install required packages"
		aba_progress "PLAN|sv_preflight|Preflight checks"
		aba_progress "PLAN|sv_tools|Download CLI tools"
		aba_progress "PLAN|sv_save|Save images to disk"
		aba_progress "PLAN|sv_cli_wait|Wait for CLI tools"
		aba_progress "PLAN|sv_finalize|Pack transfer config"
		;;

	load)
		aba_progress "PLAN|rpms_int|Install required packages"
		aba_progress "PLAN|ld_preflight|Preflight checks"
		aba_progress "PLAN|ld_registry|Verify registry access"
		aba_progress "PLAN|ld_load|Load images to registry"
		aba_progress "PLAN|ld_finalize|Update state"
		;;

	uninstall)
		aba_progress "PLAN|uninst_remove|Remove registry"
		aba_progress "PLAN|uninst_cleanup|Clean up"
		;;

	# ── Bundle workflow (called from _plan-bundle Makefile target) ──

	bundle)
		aba_progress "PLAN|bnd_preflight|Preflight checks"
		aba_progress "PLAN|bnd_save|Save images"
		aba_progress "PLAN|bnd_cli_wait|Wait for CLI tools"
		aba_progress "PLAN|bnd_pack|Pack bundle"
		;;

	# ── Day2 workflows (called directly from scripts) ──

	day2)
		aba_progress "PLAN|access|Accessing cluster"
		aba_progress "PLAN|credentials|Registry credentials"
		aba_progress "PLAN|trustca|Registry trust CA"
		aba_progress "PLAN|resources|IDMS/ITMS resources"
		aba_progress "PLAN|catalogs|CatalogSources"
		aba_progress "PLAN|signatures|Release signatures"
		aba_progress "PLAN|manifests|Custom manifests"
		aba_progress "PLAN|stabilize|Cluster stabilization"
		;;

	day2-ntp)
		aba_progress "PLAN|ntp_access|Access cluster"
		aba_progress "PLAN|ntp_apply|Apply NTP config"
		aba_progress "PLAN|ntp_verify|Verify NTP on nodes"
		;;

	day2-osus)
		aba_progress "PLAN|osus_access|Access cluster"
		aba_progress "PLAN|osus_operator|Install OSUS operator"
		aba_progress "PLAN|osus_deploy|Deploy Update Service"
		aba_progress "PLAN|osus_stabilize|Wait for cluster stable"
		;;

	day2-virt)
		aba_progress "PLAN|virt_access|Access cluster"
		aba_progress "PLAN|virt_config|Configure boot sources"
		aba_progress "PLAN|virt_verify|Verify configuration"
		;;

	# ── Cluster lifecycle (called directly from scripts) ──

	cluster-shutdown)
		aba_progress "PLAN|sd_preflight|Preflight checks"
		aba_progress "PLAN|sd_shutdown|Shutdown nodes"
		aba_progress "PLAN|sd_poweroff|Wait for power off"
		;;

	cluster-startup)
		aba_progress "PLAN|su_power|Power on cluster"
		aba_progress "PLAN|su_nodes|Uncordon nodes"
		aba_progress "PLAN|su_ready|Wait for cluster ready"
		;;

	cluster-upgrade)
		aba_progress "PLAN|ug_preflight|Preflight checks"
		aba_progress "PLAN|ug_day2|Update mirror resources"
		aba_progress "PLAN|ug_trigger|Trigger upgrade"
		aba_progress "PLAN|ug_progress|Wait for upgrade"
		;;

	*)
		echo "[ABA] Unknown workflow: ${1:-<none>}" >&2
		exit 1
		;;
esac
