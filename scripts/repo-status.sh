#!/bin/bash
# repo-status.sh -- Report ABA repository state
#
# INTENT:    Source of truth for repo-level state queries (install, config,
#            CLI tools, infra platform, registry installers, connectivity).
# CALLED BY: aba status, TUI (--shell mode), aba-status.sh aggregator
# CWD:       $ABA_ROOT (repo root)
# PRODUCES:
#   default:  problems + next steps only (silent if all good)
#   --all:    full verbose dump
#   --shell:  sourceable key=value pairs for TUI and scripts
# SIDE EFFECTS: None (read-only)
# IDEMPOTENT: Yes

set -eo pipefail

source scripts/include_all.sh

[ -z "${INFO_ABA+x}" ] && export INFO_ABA=1

_mode="human"
_verbose=false
for arg in "$@"; do
	case "$arg" in
		shell|--shell) _mode="shell" ;;
		--all)         _verbose=true ;;
	esac
done

# --- Gather state ---

# ABA install
_aba_installed=false
[ -f "$HOME/bin/aba" ] && _aba_installed=true
_aba_version="${ABA_VERSION:-$(cat VERSION 2>/dev/null || echo unknown)}"

# Config
_aba_conf_exists=false
[ -f aba.conf ] && _aba_conf_exists=true

_ocp_version=""
_ocp_channel=""
_pull_secret_ok=false
if [ "$_aba_conf_exists" = "true" ]; then
	source <(normalize-aba-conf) 2>/dev/null || true
	_ocp_version="${ocp_version:-}"
	_ocp_channel="${ocp_channel:-}"
	if [ -n "${pull_secret_file:-}" ] && [ -s "$pull_secret_file" ]; then
		_pull_secret_ok=true
	fi
fi

# Internet / mode
_internet=false
_bundle_flag=false
[ -f .bundle ] && _bundle_flag=true

if [ "$_bundle_flag" = "true" ]; then
	# Bundle mode = disconnected, skip slow internet probe
	_internet=false
elif run_once -p -i "aba:check:api.openshift.com" >/dev/null 2>&1; then
	# Use cached successful result (instant)
	_internet=true
elif run_once -p -i "aba:check:mirror.openshift.com" >/dev/null 2>&1; then
	_internet=true
elif curl -sL --head --connect-timeout 1 --max-time 2 https://api.openshift.com/ >/dev/null 2>&1; then
	_internet=true
fi

_mode_detected="CONNO"
if [ "$_bundle_flag" = "true" ]; then
	if [ "$_internet" = "true" ]; then
		_mode_detected="CONNO"
	else
		_mode_detected="DISCO"
	fi
else
	if [ "$_internet" = "true" ]; then
		_mode_detected="CONNO"
	else
		_mode_detected="DISCO"
	fi
fi

# Infrastructure platform
_infra_platform="none"
[ -f vmware.conf ] && _infra_platform="vmware"
[ -f kvm.conf ] && _infra_platform="kvm"

# CLI tools installed
_cli_oc=false
_cli_oc_mirror=false
_cli_openshift_install=false
[ -x "$HOME/bin/oc" ] && _cli_oc=true
[ -x "$HOME/bin/oc-mirror" ] && _cli_oc_mirror=true
[ -x "$HOME/bin/openshift-install" ] && _cli_openshift_install=true

# Registry installer files available
_reg_installer_quay=false
_reg_installer_docker=false
_min_size=1000000
find mirror/ -maxdepth 1 -name "mirror-registry*.tar.gz" -size +${_min_size}c 2>/dev/null | grep -q . && _reg_installer_quay=true
find mirror/ -maxdepth 1 -name "docker-reg-image.tgz" -size +${_min_size}c 2>/dev/null | grep -q . && _reg_installer_docker=true

# Saved image archives
_saved_archives=false
find mirror/data/ -name "mirror_*.tar" -size +${_min_size}c 2>/dev/null | grep -q . && _saved_archives=true

# Mirror state
_mirror_installed=false
[ -f mirror/.available ] && _mirror_installed=true

_mirror_has_release=false

# Use mirror-status.sh --shell for accurate release image check (cached 60s)
if [ "$_mirror_installed" = "true" ]; then
	_cache_file="$HOME/.aba/cache/mirror_has_release"
	_cache_ttl=60
	_use_cache=false
	if [ -f "$_cache_file" ]; then
		_cache_age=$(( $(date +%s) - $(stat -c %Y "$_cache_file") ))
		[ "$_cache_age" -lt "$_cache_ttl" ] && _use_cache=true
	fi
	if [ "$_use_cache" = "true" ]; then
		_mirror_has_release=$(cat "$_cache_file")
	else
		_ms_out=$(cd mirror && "${ABA_ROOT:-.}"/scripts/mirror-status.sh --shell 2>/dev/null) || true
		if echo "$_ms_out" | grep -q '^mirror_has_release=true'; then
			_mirror_has_release=true
		fi
		mkdir -p "$HOME/.aba/cache"
		echo "$_mirror_has_release" > "$_cache_file"
	fi
fi

# Cluster quick scan
_cluster_count=0
_cluster_installed=0
_cluster_installing=0
_cluster_configured=0
_cluster_dirs=()
_cluster_installed_dirs=()
_cluster_installing_dirs=()
_cluster_configured_dirs=()
for _d in */cluster.conf; do
	[ -f "$_d" ] || continue
	_dir="${_d%/cluster.conf}"
	[[ "$_dir" == "mirror" || "$_dir" == "templates" ]] && continue

	if [ -f "$_dir/.install-complete" ]; then
		_cluster_count=$(( _cluster_count + 1 ))
		_cluster_installed=$(( _cluster_installed + 1 ))
		_cluster_dirs+=("$_dir")
		_cluster_installed_dirs+=("$_dir")
	elif [ -d "$_dir/iso-agent-based" ]; then
		_cluster_count=$(( _cluster_count + 1 ))
		_cluster_installing=$(( _cluster_installing + 1 ))
		_cluster_dirs+=("$_dir")
		_cluster_installing_dirs+=("$_dir")
	elif [ -f "$_dir/.init" ]; then
		_cluster_count=$(( _cluster_count + 1 ))
		_cluster_configured=$(( _cluster_configured + 1 ))
		_cluster_dirs+=("$_dir")
		_cluster_configured_dirs+=("$_dir")
	elif [ -f "$_dir/cluster.conf" ]; then
		# Has cluster.conf but no .init — configured only
		_cluster_count=$(( _cluster_count + 1 ))
		_cluster_configured=$(( _cluster_configured + 1 ))
		_cluster_configured_dirs+=("$_dir")
	fi
done

# --- Output ---

case $_mode in
shell)
	echo "aba_installed=$_aba_installed"
	echo "aba_version=$_aba_version"
	echo "aba_conf_exists=$_aba_conf_exists"
	echo "ocp_version=$_ocp_version"
	echo "ocp_channel=$_ocp_channel"
	echo "pull_secret=$_pull_secret_ok"
	echo "internet=$_internet"
	echo "mode=$_mode_detected"
	echo "bundle_flag=$_bundle_flag"
	echo "infra_platform=$_infra_platform"
	echo "cli_oc=$_cli_oc"
	echo "cli_oc_mirror=$_cli_oc_mirror"
	echo "cli_openshift_install=$_cli_openshift_install"
	echo "reg_installer_quay=$_reg_installer_quay"
	echo "reg_installer_docker=$_reg_installer_docker"
	echo "saved_archives=$_saved_archives"
	echo "mirror_installed=$_mirror_installed"
	echo "mirror_has_release=$_mirror_has_release"
	echo "cluster_count=$_cluster_count"
	echo "cluster_installed_count=$_cluster_installed"
	echo "cluster_installing_count=$_cluster_installing"
	echo "cluster_configured_count=$_cluster_configured"
	;;

*)
	# --- Verbose mode: full dump ---
	if [ "$_verbose" = "true" ]; then
		echo
		aba_info "ABA Repository Status"
		aba_info "====================="
		aba_info "  Version:        $_aba_version"
		aba_info "  Installed:      $_aba_installed"
		aba_info "  Config:         $([ "$_aba_conf_exists" = "true" ] && echo "configured" || echo "not configured")"

		if [ "$_aba_conf_exists" = "true" ]; then
			aba_info "  OCP version:    ${_ocp_version:-not set}"
			aba_info "  Channel:        ${_ocp_channel:-not set}"
			aba_info "  Pull secret:    $([ "$_pull_secret_ok" = "true" ] && echo "OK" || echo "missing")"
		fi

		aba_info "  Internet:       $([ "$_internet" = "true" ] && echo "available" || echo "offline")"
		aba_info "  Mode:           $_mode_detected"
		aba_info "  Platform:       $([ "$_infra_platform" != "none" ] && echo "$_infra_platform" || echo "bare metal (no vmware.conf/kvm.conf)")"

		echo
		aba_info "  CLI Tools"
		aba_info "    oc:                $([ "$_cli_oc" = "true" ] && echo "installed" || echo "not installed")"
		aba_info "    oc-mirror:         $([ "$_cli_oc_mirror" = "true" ] && echo "installed" || echo "not installed")"
		aba_info "    openshift-install: $([ "$_cli_openshift_install" = "true" ] && echo "installed" || echo "not installed")"

		echo
		aba_info "  Mirror"
		aba_info "    Registry:     $([ "$_mirror_installed" = "true" ] && echo "installed" || echo "not installed")"
		aba_info "    Quay installer:   $([ "$_reg_installer_quay" = "true" ] && echo "available" || echo "not found")"
		aba_info "    Docker installer: $([ "$_reg_installer_docker" = "true" ] && echo "available" || echo "not found")"
		aba_info "    Saved archives:   $([ "$_saved_archives" = "true" ] && echo "yes" || echo "none")"

		echo
		aba_info "  Clusters:       $_cluster_count (installed: $_cluster_installed, installing: $_cluster_installing, configured: $_cluster_configured)"

		# In --all mode, also run cluster-status if clusters exist
		if [ $_cluster_count -gt 0 ]; then
			echo
			"${ABA_ROOT:-.}"/scripts/cluster-status.sh
		fi

		echo
		exit
	fi

	# --- Default mode: summary + problems + next steps ---
	_problems=()
	_next_steps=()
	_milestone=""

	# Walk the workflow in order, tracking the last completed milestone
	if [ "$_aba_conf_exists" != "true" ]; then
		_milestone="ABA v${_aba_version} installed"
		_next_steps+=("Run 'aba' (or 'abatui') to configure")
	else
		_milestone="Configured for OCP ${_ocp_version:-?} (${_ocp_channel:-?})"

		if [ "$_pull_secret_ok" != "true" ]; then
			_problems+=("Pull secret missing or empty")
			_next_steps+=("Copy pull secret to: ${pull_secret_file:-~/.pull-secret.json} (see aba.conf)")
		fi
	fi

	if [ "$_aba_conf_exists" = "true" ] && [ "$_pull_secret_ok" = "true" ]; then
		_milestone="OCP ${_ocp_version:-?} configured, pull secret ready"
	fi

	if [ "$_mirror_installed" != "true" ] && [ "$_pull_secret_ok" = "true" ]; then
		if [ "$_mode_detected" = "DISCO" ]; then
			if [ "$_reg_installer_quay" != "true" ] && [ "$_reg_installer_docker" != "true" ]; then
				_problems+=("No registry installer found (disconnected mode)")
				_next_steps+=("Transfer a bundle containing registry installer files")
			else
				_next_steps+=("Run 'aba -d mirror install' to install the registry")
			fi
		else
			_next_steps+=("Run 'aba -d mirror install' to install a registry and sync images")
			_next_steps+=("Or 'aba -d mirror save' to save images for air-gapped transfer")
		fi
	fi

	if [ "$_mirror_installed" = "true" ]; then
		if [ "$_mirror_has_release" = "true" ]; then
			_milestone="Mirror ready with release image for v${_ocp_version:-?}"

			if [ $_cluster_count -eq 0 ]; then
				_next_steps+=("Run 'aba cluster --name <name> --type sno' to create a cluster")
			fi
		else
			_milestone="Registry installed (no release image yet)"
		fi
	fi

	if [ ${#_cluster_installing_dirs[@]} -gt 0 ]; then
		for _dir in "${_cluster_installing_dirs[@]}"; do
			_next_steps+=("Run 'aba -d $_dir mon' to monitor installation")
		done
	fi

	if [ ${#_cluster_configured_dirs[@]} -gt 0 ]; then
		for _dir in "${_cluster_configured_dirs[@]}"; do
			_next_steps+=("Run 'aba -d $_dir install' to install cluster '$_dir'")
		done
	fi

	if [ $_cluster_installed -gt 0 ] && [ $_cluster_installing -eq 0 ]; then
		_ready_names=()
		for _dir in "${_cluster_installed_dirs[@]}"; do
			_ready_names+=("$_dir")
		done
		_milestone="Cluster(s) ready: ${_ready_names[*]}"
	fi

	# Print results
	if [ ${#_problems[@]} -eq 0 ] && [ ${#_next_steps[@]} -eq 0 ]; then
		aba_info "$_milestone"
		exit
	fi

	echo
	aba_info "$_milestone"

	if [ ${#_problems[@]} -gt 0 ]; then
		for _p in "${_problems[@]}"; do
			aba_warn "  $_p"
		done
	fi

	if [ ${#_next_steps[@]} -gt 0 ]; then
		aba_info "Next:"
		for _n in "${_next_steps[@]}"; do
			aba_info "  → $_n"
		done
	fi
	echo
	;;
esac
