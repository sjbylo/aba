#!/bin/bash
# cluster-status.sh -- Report cluster state
#
# INTENT:    Source of truth for cluster state queries (count, install status,
#            type, live health). Follows the mirror-status.sh pattern (ADR-014).
# CALLED BY: aba status --all, aba -d <cluster> status, TUI (--shell mode)
# CWD:       $ABA_ROOT (repo root) or a cluster directory (with --dir)
# PRODUCES:  Human-readable summary (default), sourceable key=value (--shell)
# SIDE EFFECTS: None (read-only)
# IDEMPOTENT: Yes

set -eo pipefail

source scripts/include_all.sh

[ -z "${INFO_ABA+x}" ] && export INFO_ABA=1

_mode="human"
_live=true
_single_dir=""
for arg in "$@"; do
	case "$arg" in
		shell|--shell) _mode="shell" ;;
		--no-live)     _live=false ;;
		--dir)         _next_is_dir=true ;;
		*)
			if [ "${_next_is_dir:-}" = "true" ]; then
				_single_dir="$arg"
				_next_is_dir=false
			fi
			;;
	esac
done

# --- Scan a single cluster dir and append to _clusters array ---
_scan_cluster_dir() {
	local _dir="$1"

	# Read cluster config
	local _num_masters="" _num_workers="" _cname="" _bdomain=""
	if [ -f "$_dir/cluster.conf" ]; then
		_num_masters=$(grep -m1 '^num_masters=' "$_dir/cluster.conf" 2>/dev/null | cut -d= -f2 | sed 's/[[:space:]]*#.*//' | xargs) || true
		_num_workers=$(grep -m1 '^num_workers=' "$_dir/cluster.conf" 2>/dev/null | cut -d= -f2 | sed 's/[[:space:]]*#.*//' | xargs) || true
		_cname=$(grep -m1 '^cluster_name=' "$_dir/cluster.conf" 2>/dev/null | cut -d= -f2 | sed 's/[[:space:]]*#.*//' | xargs) || true
		_bdomain=$(grep -m1 '^base_domain=' "$_dir/cluster.conf" 2>/dev/null | cut -d= -f2 | sed 's/[[:space:]]*#.*//' | xargs) || true
	fi

	# Derive type
	local _type="standard"
	if [ "${_num_masters:-3}" = "1" ] && [ "${_num_workers:-0}" = "0" ]; then
		_type="sno"
	elif [ "${_num_workers:-0}" = "0" ]; then
		_type="compact"
	fi

	# Install status
	local _status="installing"
	if [ -f "$_dir/.install-complete" ]; then
		_status="installed"
		_installed_count=$(( _installed_count + 1 ))
	elif [ -d "$_dir/iso-agent-based" ]; then
		_status="installing"
		_installing_count=$(( _installing_count + 1 ))
	elif [ -f "$_dir/.init" ]; then
		_status="configured"
		_configured_count=$(( _configured_count + 1 ))
	else
		_status="configured"
		_configured_count=$(( _configured_count + 1 ))
	fi

	_cluster_count=$(( _cluster_count + 1 ))
	_clusters+=("${_dir}|${_status}|${_type}|${_cname}|${_bdomain}")
}

# --- Gather state ---

_cluster_count=0
_installed_count=0
_installing_count=0
_configured_count=0
_clusters=()

if [ -n "$_single_dir" ]; then
	# Single cluster mode (aba -d <cluster> status)
	if [ -f "$_single_dir/cluster.conf" ]; then
		_scan_cluster_dir "$_single_dir"
	elif [ -f "cluster.conf" ]; then
		# --dir passed an absolute path, but cluster.conf is in CWD
		_scan_cluster_dir "."
	fi
else
	# All clusters mode (aba status --all)
	for _conf in */cluster.conf; do
		[ -f "$_conf" ] || continue
		_dir="${_conf%/cluster.conf}"
		[[ "$_dir" == "mirror" || "$_dir" == "templates" ]] && continue
		[[ "$_dir" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || continue
		_scan_cluster_dir "$_dir"
	done
fi

# --- Live health queries (parallel) ---

declare -A _health_map
declare -A _version_map

if [ "$_live" = "true" ] && [ ${#_clusters[@]} -gt 0 ]; then
	_tmpdir=$(mktemp -d)

	for _entry in "${_clusters[@]}"; do
		IFS='|' read -r _dir _status _type _cname _bdomain <<< "$_entry"
		[ "$_status" != "installed" ] && continue

		# Background health check
		(
			_kc=""
			# Check for kubeconfig inside the cluster dir
			if [ -f "$_dir/iso-agent-based/auth/kubeconfig" ]; then
				_kc="$(cd "$_dir" && pwd)/iso-agent-based/auth/kubeconfig"
			elif [ -n "$_cname" ] && [ -n "$_bdomain" ]; then
				_kc=$(cluster_kubeconfig "$_cname" "$_bdomain" 2>/dev/null) || true
			fi
			if [ -z "$_kc" ] || [ ! -f "$_kc" ]; then
				echo "unknown|" > "$_tmpdir/$(basename "$_dir")"
				exit 0
			fi

			_cv_json=$(KUBECONFIG="$_kc" oc get clusterversion version -o json --request-timeout=5s 2>/dev/null) || {
				echo "unreachable|" > "$_tmpdir/$(basename "$_dir")"
				exit 0
			}

			_ver=$(echo "$_cv_json" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("status",{}).get("desired",{}).get("version",""))' 2>/dev/null) || _ver=""

			_health="unknown"
			_avail=$(echo "$_cv_json" | python3 -c '
import sys, json
d = json.load(sys.stdin)
for c in d.get("status",{}).get("conditions",[]):
    if c["type"]=="Available": print(c["status"])
' 2>/dev/null) || _avail=""
			_prog=$(echo "$_cv_json" | python3 -c '
import sys, json
d = json.load(sys.stdin)
for c in d.get("status",{}).get("conditions",[]):
    if c["type"]=="Progressing": print(c["status"])
' 2>/dev/null) || _prog=""
			_deg=$(echo "$_cv_json" | python3 -c '
import sys, json
d = json.load(sys.stdin)
for c in d.get("status",{}).get("conditions",[]):
    if c["type"]=="Degraded": print(c["status"])
' 2>/dev/null) || _deg=""

			if [ "$_deg" = "True" ]; then
				_health="degraded"
			elif [ "$_prog" = "True" ]; then
				_health="progressing"
			elif [ "$_avail" = "True" ]; then
				_health="available"
			fi

			echo "${_health}|${_ver}" > "$_tmpdir/$(basename "$_dir")"
		) &
	done

	wait 2>/dev/null || true

	# Collect results
	for _entry in "${_clusters[@]}"; do
		IFS='|' read -r _dir _rest <<< "$_entry"
		_bn=$(basename "$_dir")
		if [ -f "$_tmpdir/$_bn" ]; then
			IFS='|' read -r _h _v < "$_tmpdir/$_bn"
			_health_map[$_dir]="$_h"
			_version_map[$_dir]="$_v"
		fi
	done

	rm -rf "$_tmpdir"
fi

# --- Output ---

_format_cluster_line() {
	local _dir="$1" _status="$2" _type="$3"
	local _h="${_health_map[$_dir]:-}"
	local _v="${_version_map[$_dir]:-}"

	local _status_display="$_status"
	if [ "$_status" = "installed" ]; then
		case "${_h:-unknown}" in
			available)   _status_display="running" ;;
			progressing) _status_display="progressing" ;;
			degraded)    _status_display="degraded" ;;
			unreachable) _status_display="unreachable" ;;
			*)           _status_display="installed" ;;
		esac
	fi

	local _ver_display=""
	[ -n "$_v" ] && _ver_display=" (v${_v})"

	local _name
	_name=$(basename "$_dir")
	aba_info "  ${_name}: ${_status_display}${_ver_display}  [${_type}]"
}

case $_mode in
shell)
	echo "cluster_count=$_cluster_count"
	echo "cluster_installed_count=$_installed_count"
	echo "cluster_installing_count=$_installing_count"
	echo "cluster_configured_count=$_configured_count"
	for _entry in "${_clusters[@]}"; do
		IFS='|' read -r _dir _status _type _cname _bdomain <<< "$_entry"
		_h="${_health_map[$_dir]:-}"
		_v="${_version_map[$_dir]:-}"
		_bn=$(basename "$_dir")
		echo "cluster=${_bn} status=${_status} type=${_type} health=${_h:-unknown} version=${_v:-}"
	done
	;;

*)
	if [ -n "$_single_dir" ]; then
		# Single cluster output
		for _entry in "${_clusters[@]}"; do
			IFS='|' read -r _dir _status _type _cname _bdomain <<< "$_entry"
			_format_cluster_line "$_dir" "$_status" "$_type"
		done
	else
		# All clusters output
		echo
		aba_info "Cluster Status"
		aba_info "=============="

		if [ $_cluster_count -eq 0 ]; then
			aba_info "  No clusters configured"
		else
			aba_info "  Total: $_cluster_count  (installed: $_installed_count, installing: $_installing_count, configured: $_configured_count)"
			echo

			for _entry in "${_clusters[@]}"; do
				IFS='|' read -r _dir _status _type _cname _bdomain <<< "$_entry"
				_format_cluster_line "$_dir" "$_status" "$_type"
			done
		fi
		echo
	fi
	;;
esac
