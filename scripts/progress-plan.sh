#!/bin/bash
# progress-plan.sh — Emit PLAN events for all workflows
#
# Single source of truth for every workflow's progress steps.
# Called two ways:
#   1. From PHONY _progress_plan-* Makefile prereqs (mirror, bundle)
#   2. Directly from scripts that are entry points (day2, cluster-*)
#
# Each case only knows its OWN steps — never another workflow's steps.
# When "make sync" triggers install as a dependency, _progress_plan-install
# fires first (as install's prereq) and _progress_plan-sync fires later.
# The progress dialog grows as new PLANs arrive in batches.
#
# PLAN order must match execution order.  Auto-complete marks
# predecessors of the active step — misordering causes confusing
# Skipped→In Progress flips.
#
# Weight (4th field): relative cost of each step for progress bar accuracy.
# Omit for default weight of 1.  Rough categories:
#   1-2 = seconds, 5 = tens of seconds, 10-20 = minutes, 50+ = many minutes

source "$(dirname "$0")/include_all.sh"

case "$1" in

	# ── Mirror workflows (called from _progress_plan-* Makefile targets) ──

	install)
		# Only emit PLANs when install will actually run.
		# When .available exists, the registry is already installed — nothing to show.
		# This prevents Skipped items cluttering the dialog for a cached sync.
		[ -f .available ] && exit 0
		aba_progress "PLAN|rpms_ext|Install required packages|5"
		aba_progress "PLAN|reg_config|Validate configuration|2"
		aba_progress "PLAN|reg_env|Check environment|2"
		aba_progress "PLAN|reg_firewall|Configure firewall|2"
		aba_progress "PLAN|reg_download|Download registry software|10"
		aba_progress "PLAN|reg_install|Install registry|15"
		aba_progress "PLAN|reg_postcfg|Configure credentials|3"
		aba_progress "PLAN|reg_verify|Verify connectivity|2"
		;;

	sync)
		# Sync only knows about its own steps — never install steps.
		# If install is needed, _progress_plan-install (prereq of install) handles that.
		#
		# Order matches Make's execution of sync prerequisites:
		#   .rpmsint → install → _progress_plan-sync → status-preflight → reg-sync.sh
		aba_progress "PLAN|rpms_int|Install required packages|5"
		aba_progress "PLAN|preflight|Preflight checks|2"
		aba_progress "PLAN|catalogs_dl|Download operator catalogs|10"
		aba_progress "PLAN|versions|Verify release versions|2"
		aba_progress "PLAN|tools|Prepare tools|3"
		aba_progress "PLAN|registry|Registry access|2"
		aba_progress "PLAN|sync|Mirror images|70"
		aba_progress "PLAN|finalize|Finalize|2"
		;;

	save)
		# Order matches Make's execution:
		#   .rpmsext → status-preflight → reg-save.sh
		# When called during bundle, these IDs are already declared by
		# the bundle plan — the receiver dedupes by ID (first PLAN wins).
		aba_progress "PLAN|rpms_ext|Install required packages|3"
		aba_progress "PLAN|sv_preflight|Preflight checks|2"
		aba_progress "PLAN|sv_tools|Download CLI tools|5"
		aba_progress "PLAN|sv_save|Save images to disk|70"
		aba_progress "PLAN|sv_cli_wait|Wait for CLI tools|5"
		aba_progress "PLAN|sv_finalize|Pack transfer config|3"
		;;

	load)
		aba_progress "PLAN|rpms_int|Install required packages|5"
		aba_progress "PLAN|ld_preflight|Preflight checks|2"
		aba_progress "PLAN|ld_registry|Verify registry access|3"
		aba_progress "PLAN|ld_load|Load images to registry|70"
		aba_progress "PLAN|ld_finalize|Update state|2"
		;;

	uninstall)
		aba_progress "PLAN|uninst_remove|Remove registry|10"
		aba_progress "PLAN|uninst_cleanup|Clean up|3"
		;;

	# ── Bundle workflow (called from _progress_plan-bundle Makefile target) ──

	bundle)
		# Bundle wraps save — pre-declare shared IDs so save's plan
		# is silently deduped by the receiver (first PLAN wins per ID).
		# Save can still contribute extra steps bundle didn't declare.
		aba_progress "PLAN|bnd_preflight|Validate configuration|2"
		aba_progress "PLAN|rpms_ext|Install required packages|3"
		aba_progress "PLAN|sv_preflight|Preflight checks|2"
		aba_progress "PLAN|sv_tools|Download CLI tools|5"
		aba_progress "PLAN|sv_save|Save images to disk|70"
		aba_progress "PLAN|sv_cli_wait|Wait for CLI tools|5"
		aba_progress "PLAN|sv_finalize|Pack transfer config|3"
		aba_progress "PLAN|bnd_pack|Pack bundle|10"
		;;

	# ── Day2 workflows (called directly from scripts) ──

	day2)
		aba_progress "PLAN|access|Accessing cluster|3"
		aba_progress "PLAN|credentials|Registry credentials|5"
		aba_progress "PLAN|trustca|Registry trust CA|5"
		aba_progress "PLAN|resources|IDMS/ITMS resources|10"
		aba_progress "PLAN|catalogs|CatalogSources|10"
		aba_progress "PLAN|signatures|Release signatures|5"
		aba_progress "PLAN|manifests|Custom manifests|5"
		aba_progress "PLAN|stabilize|Cluster stabilization|20"
		;;

	day2-ntp)
		aba_progress "PLAN|ntp_access|Access cluster|3"
		aba_progress "PLAN|ntp_apply|Apply NTP config|10"
		aba_progress "PLAN|ntp_verify|Verify NTP on nodes|10"
		;;

	day2-osus)
		aba_progress "PLAN|osus_access|Access cluster|3"
		aba_progress "PLAN|osus_operator|Install OSUS operator|20"
		aba_progress "PLAN|osus_deploy|Deploy Update Service|15"
		aba_progress "PLAN|osus_stabilize|Wait for cluster stable|30"
		;;

	day2-virt)
		aba_progress "PLAN|virt_access|Access cluster|3"
		aba_progress "PLAN|virt_config|Configure boot sources|10"
		aba_progress "PLAN|virt_verify|Verify configuration|5"
		;;

	# ── Cluster lifecycle (called directly from scripts) ──

	cluster-shutdown)
		aba_progress "PLAN|sd_preflight|Preflight checks|2"
		aba_progress "PLAN|sd_access|Accessing the cluster|3"
		aba_progress "PLAN|sd_shutdown|Shutdown nodes|10"
		aba_progress "PLAN|sd_poweroff|Wait for power off|30"
		;;

	cluster-startup)
		aba_progress "PLAN|su_power|Power on cluster|5"
		aba_progress "PLAN|su_api|Wait for Cluster API|20"
		aba_progress "PLAN|su_nodes|Uncordon nodes|5"
		aba_progress "PLAN|su_nodes_ready|Wait for nodes ready|15"
		aba_progress "PLAN|su_console|Wait for OpenShift Console|20"
		aba_progress "PLAN|su_cos|Wait for Cluster Operators|30"
		;;

	cluster-upgrade)
		aba_progress "PLAN|ug_preflight|Preflight checks|2"
		aba_progress "PLAN|ug_day2|Update mirror resources|15"
		aba_progress "PLAN|ug_trigger|Trigger upgrade|5"
		aba_progress "PLAN|ug_progress|Wait for upgrade|70"
		;;

	*)
		echo "[ABA] Unknown workflow: ${1:-<none>}" >&2
		exit 1
		;;
esac
