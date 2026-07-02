#!/bin/bash
# deploy.sh -- One-command orchestrator for an air-gapped OpenShift install.
#
# INTENT:   Run the existing aba steps in the right order as an idempotent,
#           resumable pipeline so a whole disconnected install is one command:
#
#             config import -> mirror install -> mirror load -> iso
#                           -> (boot nodes) -> monitor -> day2
#
#           Each step is wrapped in run_once -S, so re-running 'aba deploy' skips
#           already-completed steps and resumes where it left off. A failed step
#           halts the pipeline; fix it and re-run to continue.
#
# NODE BOOT: aba cannot boot bare-metal nodes (BMC/PXE is out of scope). On bare
#           metal deploy pauses after the ISO is built; boot the node(s) from the
#           ISO, then re-run 'aba deploy' to resume at install monitoring.
#           Hypervisors (vmw/kvm) boot their VMs automatically via 'make install'.
#
# DESCRIPTOR: an optional deploy.conf (sourced key=value, like aba.conf) may set
#           site_dir (configs to import; default 'site') and cluster_name.
#
# USAGE:    aba deploy [--site <dir>] [--cluster <name>] [--dry-run]
#
# PREVIEW:  ABA_DEPLOY_DRY_RUN=1 aba deploy   (or --dry-run) prints the plan only.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
cd "$SCRIPT_DIR/.." || exit 1
source scripts/include_all.sh

# deploy is a user-facing orchestrator: make aba_info progress (and the dry-run
# preview) visible even when this script is run directly (aba.sh sets this too).
export INFO_ABA=1

# deploy_run <aba_home> <site_dir> <cluster> <platform>
# Orchestrate the ordered, resumable pipeline. aba_home is the aba root directory
# (passed explicitly so this stays independent of aba.sh globals). Honors
# ABA_DEPLOY_DRY_RUN to print the plan without executing anything.
deploy_run() {
	local aba_home="$1" site_dir="$2" cluster="$3" platform="$4"

	# Scope run_once state per aba tree (and, once known, per cluster) so deploy state
	# never collides across trees/clusters that share $HOME/.aba/runner. A fresh
	# re-deploy after a teardown clears the cached state with 'aba deploy --restart'.
	local _scope; _scope="$(printf '%s' "$aba_home" | cksum | cut -d' ' -f1)"

	# Run (or, in dry-run, preview) one pipeline step. run_once -S runs the step once
	# across invocations, so a re-run skips a COMPLETED step (resume).
	_step() {
		local id="$1" msg="$2"; shift 2
		if [ -n "$ABA_DEPLOY_DRY_RUN" ]; then
			aba_info "DRY RUN [$id]: $*"
			return 0
		fi
		local task="aba:deploy:$_scope:$id"
		[ -n "$DEPLOY_RESTART" ] && run_once -r -i "$task" >/dev/null 2>&1   # --restart: force re-run
		# run_once -S caches a FAILED step too and would keep returning that cached
		# failure; reset a previously failed step so a re-run retries it.
		local prev_exit
		prev_exit="$(run_once -E -i "$task" 2>/dev/null)"
		[ -n "$prev_exit" ] && [ "$prev_exit" != "0" ] && run_once -r -i "$task" >/dev/null 2>&1
		aba_info "==> $msg"
		local rc=0
		run_once -w -S -m "$msg" -i "$task" -- "$@" || rc=$?
		[ "$rc" -eq 0 ] || aba_abort "aba deploy: step '$id' failed (exit $rc). Fix the problem and re-run 'aba deploy' to resume."
		return 0
	}

	aba_info "Deploying from site '$site_dir' ..."

	# Config import FIRST so nothing re-templates over the imported files, and so the
	# cluster dir + aba.conf exist before we resolve the cluster and platform. Skip it
	# when there is no site payload (an already-configured tree deploys in place).
	if [ -d "$aba_home/$site_dir" ] || [ -d "$site_dir" ]; then
		_step config-import "Importing site configuration" "$aba_home/scripts/config-import.sh" import "$site_dir"
	else
		aba_info "No site payload at '$site_dir' - using the configs already in place."
	fi

	# Resolve cluster + platform from the imported/available configs (read-only, so
	# this is also correct in dry-run). Detecting AFTER import means a bring-your-own
	# -configs deploy works with just a site payload, and hypervisor clusters take the
	# 'make install' path instead of the bare-metal pause. The multi-cluster abort runs
	# here (not inside _detect_cluster's $() subshell) so it actually exits deploy.
	if [ -z "$cluster" ]; then
		local _found _n
		_found="$(_detect_cluster "$aba_home" "$site_dir")"
		_n="$(printf '%s' "$_found" | grep -c . || true)"
		[ "$_n" -gt 1 ] && aba_abort "aba deploy: multiple clusters found ($(printf '%s' "$_found" | tr '\n' ' ')); pick one with --cluster <name> or cluster_name in deploy.conf."
		cluster="$(printf '%s' "$_found" | head -1)"
	fi
	[ -n "$platform" ] || platform="$(cd "$aba_home" && _detect_platform)"
	[ -n "$cluster" ] || aba_abort "aba deploy: no cluster specified and none found (set cluster_name in deploy.conf or use --cluster <name>)."
	_scope="$_scope:$cluster"   # scope subsequent steps per cluster too
	aba_info "Cluster '$cluster' (platform ${platform:-unknown})"

	_step mirror-install "Installing/connecting the mirror registry"  make -C "$aba_home/mirror" install
	_step mirror-load    "Loading images into the mirror registry"    make -C "$aba_home/mirror" load
	_step iso            "Generating the agent-based ISO"             make -C "$aba_home/$cluster" iso

	# Node boot gate. Hypervisors boot automatically; anything else (bare metal or
	# unknown) pauses once after the ISO so the operator can boot the node(s).
	if [ "$platform" != "vmw" ] && [ "$platform" != "kvm" ]; then
		local _await="$aba_home/$cluster/.aba-deploy-await-boot"
		if [ -n "$ABA_DEPLOY_DRY_RUN" ]; then
			aba_info "DRY RUN [boot]: pause for manual node boot here, then re-run 'aba deploy' to resume"
		elif [ ! -f "$_await" ]; then
			: > "$_await"
			aba_info_ok "ISO ready. Boot your node(s) from the ISO, then re-run 'aba deploy' to continue."
			return 0
		else
			# Marker present: boot was already prompted. Latch (keep the marker) and
			# continue, so any re-run proceeds to the run_once-guarded monitor/day2
			# steps rather than pausing again.
			aba_info "Resuming after node boot; continuing to installation monitoring ..."
		fi
	fi

	# Bring up + monitor. Hypervisors create/boot VMs and monitor via 'make install';
	# bare metal (nodes already booted) just monitors via 'make mon'.
	if [ "$platform" = "vmw" ] || [ "$platform" = "kvm" ]; then
		_step install "Creating/booting VMs and monitoring the installation" make -C "$aba_home/$cluster" install
	else
		_step monitor "Monitoring the cluster installation"                  make -C "$aba_home/$cluster" mon
	fi

	# Day-2: mirror integration + waved custom manifests, run from the cluster dir.
	[ -n "$ABA_DEPLOY_DRY_RUN" ] || cd "$aba_home/$cluster" 2>/dev/null || aba_abort "aba deploy: cluster directory not found: $aba_home/$cluster"
	_step day2 "Applying day2 configuration (mirror integration + custom manifests)" "$aba_home/scripts/day2.sh"

	aba_info_ok "Deployment steps complete for cluster '$cluster'."
	return 0
}

# _detect_cluster <aba_home> <site_dir>: echo the cluster dir name(s) (subdirs with
# cluster.conf), one per line, from the first base that has any. Looks in the aba
# tree first, then falls back to the site payload (config-import materializes it into
# the tree). It never aborts - the caller decides what 0 or >1 results mean, so its
# exit status is not swallowed by a $() command substitution.
_detect_cluster() {
	local home="$1" site="$2" base d name out
	for base in "$home" "$home/$site" "$site"; do
		[ -d "$base" ] || continue
		out=""
		for d in "$base"/*/; do
			[ -d "$d" ] || continue
			[ -f "$d/cluster.conf" ] || continue
			name="$(basename "$d")"
			case "$name" in mirror|site|helm) continue ;; esac
			out="$out$name"$'\n'
		done
		[ -n "$out" ] && { printf '%s' "$out"; return 0; }
	done
}

# _detect_platform: echo the platform (vmw/kvm/bm) from aba.conf, or "".
_detect_platform() {
	( source <(normalize-aba-conf) 2>/dev/null; echo "$platform" )
}

# ---- run (the unit test extracts deploy_run and never reaches here) ----------
aba_debug "Starting: $0 $*"

aba_home="$PWD"   # header cd'd here (the aba root)
site_dir="site"
cluster_name=""
[ -f deploy.conf ] && source ./deploy.conf   # optional descriptor: site_dir, cluster_name

# Descriptor values (if set) become the defaults; CLI flags override below.
_site="${site_dir:-site}"
_cluster="${cluster_name:-}"

while [ "$1" ]; do
	case "$1" in
		--site)    [ -n "$2" ] || aba_abort "aba deploy: --site requires a value"; _site="$2"; shift 2 ;;
		--cluster) [ -n "$2" ] || aba_abort "aba deploy: --cluster requires a value"; _cluster="$2"; shift 2 ;;
		--dry-run) export ABA_DEPLOY_DRY_RUN=1; shift ;;
		--restart) export DEPLOY_RESTART=1; shift ;;   # clear cached step state (fresh re-deploy)
		import)    shift ;;   # tolerate a stray leading verb
		--*)       aba_abort "aba deploy: unknown option '$1' (see 'aba deploy --help')." ;;
		*)         shift ;;
	esac
done

# cluster + platform are resolved inside deploy_run, after config-import has
# materialized the cluster dir and aba.conf.
deploy_run "$aba_home" "$_site" "$_cluster" ""
