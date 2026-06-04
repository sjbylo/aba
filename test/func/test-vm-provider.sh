#!/bin/bash
# Functional tests for the VM provider seam (scripts/vm-provider.sh + adapters).
#
# These tests exercise the provider through its public interface (the vmp_*
# primitive contract and the driver verbs) with the hypervisor CLIs (virsh,
# govc) mocked. No real libvirt or vCenter is required, so the suite runs
# anywhere -- which is the testability win the seam exists to provide.

set -euo pipefail

cd "$(dirname "$0")/../.."  # Change to ABA root
export ABA_ROOT="$(pwd)"

# Adapters depend on include_all.sh helpers (aba_debug, vm_name, ...), exactly
# as they do in production where it is always sourced first.
source scripts/include_all.sh

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); echo "  ok   - $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; }

# Build a throwaway dir with mock hypervisor CLIs on PATH. The mocks read a
# space-separated list of "existing" VM names from $MOCK_VMS and a list of
# "powered on" names from $MOCK_VMS_ON.
setup_mocks() {
	MOCK_DIR=$(mktemp -d)

	cat > "$MOCK_DIR/virsh" <<-'EOF'
	#!/bin/bash
	# Minimal virsh mock. Recognises: dominfo <name>, domstate <name>.
	cmd=
	name=
	for a in "$@"; do
		case "$a" in
			dominfo|domstate|start|shutdown|destroy) cmd=$a ;;
			-c|qemu*) ;;  # ignore connection URI
			*) name=$a ;;
		esac
	done
	exists() { for v in $MOCK_VMS;    do [ "$v" = "$name" ] && return 0; done; return 1; }
	is_on()  { for v in $MOCK_VMS_ON; do [ "$v" = "$name" ] && return 0; done; return 1; }
	case "$cmd" in
		dominfo)  exists || exit 1; echo "Name: $name"; echo "CPU(s): 8"; echo "Max memory: 16777216 KiB"; echo "State: running"; exit 0 ;;
		domstate) exists || exit 1; is_on && echo "running" || echo "shut off"; exit 0 ;;
		# Mutating ops echo "<cmd> <name>" so the driver's iteration is observable.
		start|shutdown|destroy) echo "$cmd $name"; exit 0 ;;
		*) exit 0 ;;
	esac
	EOF

	cat > "$MOCK_DIR/govc" <<-'EOF'
	#!/bin/bash
	# Minimal govc mock. Recognises: vm.info -json <name>, vm.power -on|-s|-off <name>.
	sub=$1
	name=${!#}
	exists() { for v in $MOCK_VMS;    do [ "$v" = "$name" ] && return 0; done; return 1; }
	is_on()  { for v in $MOCK_VMS_ON; do [ "$v" = "$name" ] && return 0; done; return 1; }
	if [ "$sub" = "vm.power" ]; then echo "power $2 $name"; exit 0; fi
	if ! exists; then echo '{"virtualMachines":null}'; exit 0; fi
	if is_on; then ps=poweredOn; else ps=poweredOff; fi
	echo "{\"virtualMachines\":[{\"runtime\":{\"powerState\":\"$ps\"},\"config\":{\"hardware\":{\"numCPU\":8,\"memoryMB\":16384}}}]}"
	EOF

	chmod +x "$MOCK_DIR/virsh" "$MOCK_DIR/govc"
	export PATH="$MOCK_DIR:$PATH"
}

teardown_mocks() { [ -n "${MOCK_DIR:-}" ] && rm -rf "$MOCK_DIR"; }

trap teardown_mocks EXIT

echo "=== VM provider seam ==="
setup_mocks
export LIBVIRT_URI="qemu:///system"

# ---------------------------------------------------------------------------
# Behavior: the kvm adapter reports whether a single VM exists, via virsh.
# ---------------------------------------------------------------------------
( source scripts/vm-kvm.sh
  export MOCK_VMS="ocp1-master1 ocp1-worker1"
  vmp_exists "ocp1-master1" ) \
	&& ok "kvm vmp_exists: returns 0 for an existing VM" \
	|| bad "kvm vmp_exists: returns 0 for an existing VM"

( source scripts/vm-kvm.sh
  export MOCK_VMS="ocp1-master1"
  vmp_exists "ghost" ) \
	&& bad "kvm vmp_exists: returns non-zero for a missing VM" \
	|| ok "kvm vmp_exists: returns non-zero for a missing VM"

# ---------------------------------------------------------------------------
# Behavior: the vmw adapter reports whether a single VM exists, via govc.
# ---------------------------------------------------------------------------
( source scripts/vm-vmw.sh
  export MOCK_VMS="ocp1-master1 ocp1-worker1"
  vmp_exists "ocp1-worker1" ) \
	&& ok "vmw vmp_exists: returns 0 for an existing VM" \
	|| bad "vmw vmp_exists: returns 0 for an existing VM"

( source scripts/vm-vmw.sh
  export MOCK_VMS="ocp1-master1"
  vmp_exists "ghost" ) \
	&& bad "vmw vmp_exists: returns non-zero for a missing VM" \
	|| ok "vmw vmp_exists: returns non-zero for a missing VM"

# ---------------------------------------------------------------------------
# Behavior: vmp_is_on reports power state, per adapter.
# ---------------------------------------------------------------------------
( source scripts/vm-kvm.sh
  export MOCK_VMS="ocp1-master1" MOCK_VMS_ON="ocp1-master1"
  vmp_is_on "ocp1-master1" ) \
	&& ok "kvm vmp_is_on: returns 0 for a running VM" \
	|| bad "kvm vmp_is_on: returns 0 for a running VM"

( source scripts/vm-kvm.sh
  export MOCK_VMS="ocp1-master1" MOCK_VMS_ON=""
  vmp_is_on "ocp1-master1" ) \
	&& bad "kvm vmp_is_on: returns non-zero for a stopped VM" \
	|| ok "kvm vmp_is_on: returns non-zero for a stopped VM"

( source scripts/vm-vmw.sh
  export MOCK_VMS="ocp1-master1" MOCK_VMS_ON="ocp1-master1"
  vmp_is_on "ocp1-master1" ) \
	&& ok "vmw vmp_is_on: returns 0 for a powered-on VM" \
	|| bad "vmw vmp_is_on: returns 0 for a powered-on VM"

( source scripts/vm-vmw.sh
  export MOCK_VMS="ocp1-master1" MOCK_VMS_ON=""
  vmp_is_on "ocp1-master1" ) \
	&& bad "vmw vmp_is_on: returns non-zero for a powered-off VM" \
	|| ok "vmw vmp_is_on: returns non-zero for a powered-off VM"

# ---------------------------------------------------------------------------
# Contract conformance: every adapter must define every primitive. This is the
# guard that stops the kvm and vmw families drifting apart -- a verb added to
# one adapter but forgotten in the other fails here, loudly, with no hypervisor.
# ---------------------------------------------------------------------------
VMP_CONTRACT="vmp_exists vmp_is_on vmp_info vmp_power_on vmp_power_off vmp_kill"

for adapter in kvm vmw; do
	for fn in $VMP_CONTRACT; do
		if ( source "scripts/vm-${adapter}.sh"; declare -F "$fn" >/dev/null ); then
			ok "$adapter adapter defines $fn"
		else
			bad "$adapter adapter defines $fn"
		fi
	done
done

# ---------------------------------------------------------------------------
# Behavior: vmp_info prints "<numCPU> <memoryGB> <state>" for an existing VM.
# ---------------------------------------------------------------------------
( source scripts/vm-vmw.sh
  export MOCK_VMS="ocp1-master1" MOCK_VMS_ON="ocp1-master1"
  out=$(vmp_info "ocp1-master1")
  [ "$out" = "8 16GB poweredOn" ] ) \
	&& ok "vmw vmp_info: prints cpu/mem/state" \
	|| bad "vmw vmp_info: prints cpu/mem/state"

# ---------------------------------------------------------------------------
# Driver: vm_provider_load selects the adapter from the platform, and rejects
# platforms that have no VM provider. This is the single seam that replaces the
# string-concatenated "${HV}-${verb}.sh" dispatch.
# ---------------------------------------------------------------------------
( source scripts/vm-provider.sh
  vm_provider_load kvm
  export MOCK_VMS="ocp1-master1"
  vmp_exists "ocp1-master1" ) \
	&& ok "driver: platform=kvm loads the kvm adapter" \
	|| bad "driver: platform=kvm loads the kvm adapter"

( source scripts/vm-provider.sh
  vm_provider_load vmw
  export MOCK_VMS="ocp1-master1"
  vmp_exists "ocp1-master1" ) \
	&& ok "driver: platform=vmw loads the vmw adapter" \
	|| bad "driver: platform=vmw loads the vmw adapter"

( source scripts/vm-provider.sh; vm_provider_load bm ) >/dev/null 2>&1 \
	&& bad "driver: platform=bm is rejected" \
	|| ok "driver: platform=bm is rejected"

( source scripts/vm-provider.sh; vm_provider_load wibble ) >/dev/null 2>&1 \
	&& bad "driver: unknown platform is rejected" \
	|| ok "driver: unknown platform is rejected"

# ---------------------------------------------------------------------------
# Driver: the shared host-iteration verbs. These replace the per-script
# "for name in $CP_NAMES $WORKER_NAMES" loops duplicated across both families.
# Host names come from the env (CLUSTER_NAME, CP_NAMES, WORKER_NAMES) exactly
# as cluster-config.sh sets them.
# ---------------------------------------------------------------------------
( source scripts/vm-provider.sh
  vm_provider_load kvm
  export CLUSTER_NAME="ocp1" CP_NAMES="master1" WORKER_NAMES="worker1"
  export MOCK_VMS="ocp1-worker1"      # only one of the cluster's VMs exists
  vm_exists_any ) \
	&& ok "driver vm_exists_any: 0 when any cluster VM exists" \
	|| bad "driver vm_exists_any: 0 when any cluster VM exists"

( source scripts/vm-provider.sh
  vm_provider_load kvm
  export CLUSTER_NAME="ocp1" CP_NAMES="master1" WORKER_NAMES="worker1"
  export MOCK_VMS="other-master1"     # a different cluster's VM
  vm_exists_any ) \
	&& bad "driver vm_exists_any: non-zero when no cluster VM exists" \
	|| ok "driver vm_exists_any: non-zero when no cluster VM exists"

( source scripts/vm-provider.sh
  vm_provider_load vmw
  export CLUSTER_NAME="ocp1" CP_NAMES="master1" WORKER_NAMES=""
  export MOCK_VMS="ocp1-master1" MOCK_VMS_ON="ocp1-master1"
  vm_on_any ) \
	&& ok "driver vm_on_any: 0 when any cluster VM is powered on" \
	|| bad "driver vm_on_any: 0 when any cluster VM is powered on"

( source scripts/vm-provider.sh
  vm_provider_load kvm
  export CLUSTER_NAME="ocp1" CP_NAMES="master1" WORKER_NAMES="worker1"
  export MOCK_VMS="ocp1-master1 ocp1-worker1" MOCK_VMS_ON="ocp1-master1 ocp1-worker1"
  out=$(vm_ls)
  echo "$out" | grep -q "ocp1-master1" && echo "$out" | grep -q "ocp1-worker1" ) \
	&& ok "driver vm_ls: lists every cluster VM" \
	|| bad "driver vm_ls: lists every cluster VM"

# ---------------------------------------------------------------------------
# Driver: power verbs act on every cluster VM through the adapter primitives.
# The mock virsh/govc don't change state, so we assert the driver iterates the
# right VMs (via vmp_power_on/off/kill) rather than asserting final state.
# vm_kill powers off without confirmation; vm_start/vm_stop honour 'ask'.
# ---------------------------------------------------------------------------
( source scripts/vm-provider.sh
  vm_provider_load kvm
  export CLUSTER_NAME="ocp1" CP_NAMES="master1 master2" WORKER_NAMES="worker1"
  export MOCK_VMS="ocp1-master1 ocp1-master2 ocp1-worker1"
  export MOCK_VMS_ON="ocp1-master1 ocp1-master2 ocp1-worker1"
  out=$(vm_kill 2>&1)
  echo "$out" | grep -q "destroy ocp1-master1" \
    && echo "$out" | grep -q "destroy ocp1-master2" \
    && echo "$out" | grep -q "destroy ocp1-worker1" ) \
	&& ok "driver vm_kill: powers off every cluster VM" \
	|| bad "driver vm_kill: powers off every cluster VM"

# vm_kill is a no-op when no VMs are powered on (fresh install scenario).
( source scripts/vm-provider.sh
  vm_provider_load kvm
  export CLUSTER_NAME="ocp1" CP_NAMES="master1" WORKER_NAMES="worker1"
  export MOCK_VMS="ocp1-master1 ocp1-worker1" MOCK_VMS_ON=""
  out=$(vm_kill 2>&1)
  [ -z "$out" ] ) \
	&& ok "driver vm_kill: no-op when no VMs are powered on" \
	|| bad "driver vm_kill: no-op when no VMs are powered on"

( source scripts/vm-provider.sh
  vm_provider_load kvm
  ask() { return 0; }  # auto-approve: vm_start always calls ask()
  export ask= CLUSTER_NAME="ocp1" CP_NAMES="master1" WORKER_NAMES="worker1"
  export MOCK_VMS="ocp1-master1 ocp1-worker1" MOCK_VMS_ON=""
  out=$(vm_start 2>&1)
  echo "$out" | grep -q "start ocp1-master1" && echo "$out" | grep -q "start ocp1-worker1" ) \
	&& ok "driver vm_start: starts every cluster VM (ask off)" \
	|| bad "driver vm_start: starts every cluster VM (ask off)"

( source scripts/vm-provider.sh
  vm_provider_load kvm
  export ask= CLUSTER_NAME="ocp1" CP_NAMES="master1" WORKER_NAMES="worker1"
  export MOCK_VMS="ocp1-master1 ocp1-worker1" MOCK_VMS_ON="ocp1-master1 ocp1-worker1"
  out=$(vm_stop 2>&1)
  echo "$out" | grep -q "shutdown ocp1-master1" && echo "$out" | grep -q "shutdown ocp1-worker1" ) \
	&& ok "driver vm_stop: shuts down every cluster VM (ask off)" \
	|| bad "driver vm_stop: shuts down every cluster VM (ask off)"

# Host scoping: masters= restricts the verb to control-plane VMs only.
( source scripts/vm-provider.sh
  vm_provider_load kvm
  ask() { return 0; }  # auto-approve: vm_start always calls ask()
  export ask= CLUSTER_NAME="ocp1" CP_NAMES="master1" WORKER_NAMES="worker1"
  export MOCK_VMS="ocp1-master1 ocp1-worker1" MOCK_VMS_ON=""
  out=$(vm_start masters 2>&1)
  echo "$out" | grep -q "start ocp1-master1" && ! echo "$out" | grep -q "ocp1-worker1" ) \
	&& ok "driver vm_start masters: scopes to control-plane VMs" \
	|| bad "driver vm_start masters: scopes to control-plane VMs"

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
