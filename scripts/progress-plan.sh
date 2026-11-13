#!/bin/bash
# progress-plan.sh — Emit PLAN events for all workflows
#
# Day-2 steps live in day2.sh. Save steps live in reg-save.sh.
# Every other workflow's steps are in the case below.
# Called two ways:
#   1. From PHONY _progress_plan-* Makefile prereqs (mirror, bundle)
#   2. Directly from scripts that are entry points (day2, cluster-*)
#
# A parent that always runs a child asks that child (`script plan`) and
# submits one list. The child prints PLAN lines and does not know the parent.
# Upgrade asks day-2 only when called as `cluster-upgrade --with-day2`.
# Bundle asks save, then adds its own steps. Sync does not ask install:
# install runs only when the mirror is missing, so those plans still arrive
# as separate batches.
#
# PLAN order must match execution order.  Auto-complete marks
# predecessors of the active step — misordering causes confusing
# Skipped→In Progress flips.
#
# Weight (4th field): relative cost of each step for progress bar accuracy.
# Omit for default weight of 1.  Rough categories:
#   1-2 = seconds, 5 = tens of seconds, 10-20 = minutes, 50+ = many minutes

source "$(dirname "$0")/include_all.sh"

# Submit a child's plan. The child prints PLAN lines and does not write
# the FIFO, so the parent decides when they are sent.
_emit_child_plan() {
	local _line
	while IFS= read -r _line; do
		if [ -n "$_line" ]; then
			aba_progress "$_line"
		fi
	done < <(bash "$(dirname "$0")/$1" plan)
	return 0
}

case "$1" in

	# ── Mirror workflows (called from _progress_plan-* Makefile targets) ──

	install)
		# Only emit PLANs when install will actually run.
		# When .available exists, the registry is already installed — nothing to show.
		# This prevents Skipped items cluttering the dialog for a cached sync.
		[ -f .available ] && exit 0
		# In progress immediately. Make still has to extract or download the
		# registry files before reg-install.sh starts, and that work has no
		# step of its own. One row covers every vendor.
		aba_progress "PLAN|reg_prep|Preparation|5"
		aba_progress "START|reg_prep"
		aba_progress "PLAN|rpms_ext|Install required packages|5"
		aba_progress "PLAN|reg_config|Validate configuration|2"
		aba_progress "PLAN|reg_env|Check environment|2"
		aba_progress "PLAN|reg_download|Download registry software|10"
		aba_progress "PLAN|reg_install|Install registry|15"
		aba_progress "PLAN|reg_firewall|Configure firewall|2"
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
		# The step list lives in reg-save.sh. Bundle asks for the same list.
		# When save runs during bundle, these IDs are already declared —
		# the receiver dedupes by ID (first PLAN wins).
		_emit_child_plan reg-save.sh
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

	stop)
		aba_progress "PLAN|stop_reg|Stop registry|5"
		aba_progress "PLAN|stop_verify|Verify stopped|2"
		;;

	start)
		aba_progress "PLAN|start_reg|Start registry|5"
		aba_progress "PLAN|start_verify|Verify running|3"
		;;

	# ── Bundle workflow (called from _progress_plan-bundle Makefile target) ──

	bundle)
		# Bundle always runs save. Ask save for its plan, then add the
		# steps that are bundle's own. Save does not know about bundle.
		# Order matches make-bundle.sh, then mirror save, then pack.
		aba_progress "PLAN|bnd_preflight|Validate configuration|2"
		_emit_child_plan reg-save.sh
		aba_progress "PLAN|bnd_cli_wait|Verify CLI tools|3"
		aba_progress "PLAN|bnd_pack|Pack bundle|10"
		;;

	# ── Day2 workflows (called directly from scripts) ──

	day2)
		_emit_child_plan day2.sh
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

	# ── Cluster install (Makefile.cluster _progress_plan-cluster-install) ──

	cluster-install)
		# Same steps on bm, vmw, and kvm. A step that does not apply on this
		# platform still gets START+DONE where the equivalent work finished
		# (VM power-on is Boot nodes; the bare-metal ask is that same step).
		aba_progress "PLAN|ci_config|Generate configs|10"
		aba_progress "PLAN|ci_preflight|Preflight checks|8"
		aba_progress "PLAN|ci_iso|Build agent ISO|15"
		aba_progress "PLAN|ci_vms|Stage nodes (VMs only)|10"
		aba_progress "PLAN|ci_boot|Boot nodes|10"
		aba_progress "PLAN|ci_mon|Monitor installation|70"
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
		# Preflight, then day-2 when the caller passes --with-day2, then
		# trigger and wait. No wrapper row. Day-2 does not know upgrade.
		# Order matches execution, so trigger is not marked No-op while
		# day-2 is still running.
		aba_progress "PLAN|ug_preflight|Preflight checks|2"
		if [ "${2:-}" = "--with-day2" ]; then
			_emit_child_plan day2.sh
		fi
		aba_progress "PLAN|ug_trigger|Trigger upgrade|5"
		aba_progress "PLAN|ug_progress|Wait for upgrade|70"
		;;

	*)
		echo "[ABA] Unknown workflow: ${1:-<none>}" >&2
		exit 1
		;;
esac
