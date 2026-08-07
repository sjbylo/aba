#!/bin/bash -e
# ssh into cluster nodes (default: rendezvous/node0; --all: every node)

ALL_NODES=
ONLY_MASTERS=
ONLY_WORKERS=
while [ "${1:-}" = "--all" ] || [ "${1:-}" = "--masters" ] || [ "${1:-}" = "--workers" ]; do
	case "$1" in
		--all)     ALL_NODES=1 ;;
		--masters) ONLY_MASTERS=1 ;;
		--workers) ONLY_WORKERS=1 ;;
	esac
	shift
done

[ ! -f scripts/include_all.sh ] && echo "Error: Cluster directory $PWD not yet initialized!  See: aba cluster --help" >&2 && exit 1
source scripts/include_all.sh 
trap - ERR

[ -f aba.conf ] && [ ! -L aba.conf ] && aba_abort "Only run this command in a 'cluster directory'.  See: aba cluster --help"
[ ! -f cluster.conf ] && aba_abort "This directory ($PWD) is not yet initialized as a cluster directory!  See: aba cluster --help"

aba_debug "Starting: $0 $* from $PWD"

source <(normalize-cluster-conf) 

verify-cluster-conf || exit 1

if [ -n "$ALL_NODES" ]; then
	[ -z "$*" ] && aba_abort "--all requires --cmd <command>"

	eval "$(scripts/cluster-config.sh)" || exit 1

	_all_ips=
	if [ -n "$ONLY_MASTERS" ] && [ -z "$ONLY_WORKERS" ]; then
		_all_ips="$CP_IP_ADDRESSES"
	elif [ -n "$ONLY_WORKERS" ] && [ -z "$ONLY_MASTERS" ]; then
		_all_ips="${WKR_IP_ADDR:-}"
		[ -z "$_all_ips" ] && aba_abort "No worker nodes in this cluster"
	else
		_all_ips="$CP_IP_ADDRESSES ${WKR_IP_ADDR:-}"
	fi

	_fail=0
	for _ip in $_all_ips; do
		aba_info "[$_ip] Running: $*"
		_rc=0
		ssh -F ~/.aba/ssh.conf -i "$ssh_key_file" core@"$_ip" -- "$@" > "$ABA_TMP/ssh-all.$$" 2>&1 || _rc=$?
		while IFS= read -r line; do echo "[$_ip] $line"; done < "$ABA_TMP/ssh-all.$$"
		rm -f "$ABA_TMP/ssh-all.$$"
		if [ "$_rc" -ne 0 ]; then
			aba_error "[$_ip] command failed (exit $_rc)"
			_fail=$(( _fail + 1 ))
		fi
	done

	[ "$_fail" -gt 0 ] && aba_abort "$_fail node(s) failed"
	exit 0
fi

[ ! -f iso-agent-based/rendezvousIP ] && aba_abort "$PWD/iso-agent-based/rendezvousIP file missing!  To create it, run: aba iso"
ip=$(cat iso-agent-based/rendezvousIP)

if [ "$*" ]; then
	aba_info "Running: ssh -i $ssh_key_file core@$ip -- $*"
	ssh -F ~/.aba/ssh.conf -i "$ssh_key_file" core@"$ip" -- "$@"
else
	aba_info "Running: ssh -i $ssh_key_file core@$ip"
	ssh -F ~/.aba/ssh.conf -i "$ssh_key_file" core@"$ip"
fi

