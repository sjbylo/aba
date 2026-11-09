#!/usr/bin/env bash
# =============================================================================
# Suite: Bare-metal MAC matrix and boot-to-agent
# =============================================================================
# Purpose: Replay the CLI matrix that was driven by hand on the lab:
#          MAC gates that must stop before an ISO, and BM / VMware installs
#          that only need the agent on :8090 (not a finished OpenShift).
#
# What it tests (no VM):
#   - Too few MACs: placeholder stays, the review gate stops, a second run
#     of the same file does not ask again
#   - Duplicate MACs, including a repeat past the slots this cluster needs
#   - Corrupt text with no valid MAC
#   - More unique MACs than nodes: warning, first N used
#   - Hand-edited agent-config.yaml kept when it is newer than macs.conf
#   - cluster.conf newer than the YAML rebuilds even when macs.conf is older
#   - `aba install --step` is rejected. `aba iso` builds the image and
#     does not run the monitor. `aba install` still does.
#   - platform=vmw invents MACs and skips the BM review gate
#
# What it tests (vSphere, then the VM is deleted):
#   - platform=bm SNO, compact, and standard: ISO via `aba -y iso`,
#     then tools/bm-sim-boot.sh, curl the rendezvous :8090, destroy the VMs
#   - platform=vmw SNO: `aba iso`, `aba upload`, `aba create --start`
#     (no monitor), agent answers, `aba delete` removes the VM
#
# MACs written into policy tests (00:50:56:BE:...) are never attached to a VM.
# Boot tests write macs.conf the way ABA invents VM MACs: a per-type prefix
# with 'x' nibbles (00:50:56:0x:xx: SNO, 1x compact, 2x standard), each 'x'
# replaced once per cluster, last octet the port index. That stays inside
# the VMware static range and is different on every run.
#
# The TUI wizard is not driven here. The pool runner is non-interactive CLI.
# The TUI calls this same review gate.
# =============================================================================

set -u

_SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SUITE_DIR/../lib/framework.sh"
source "$_SUITE_DIR/../lib/config-helpers.sh"
source "$_SUITE_DIR/../lib/suite-helpers.sh"

# Policy-only dir. These MACs must never be handed to govc.
MAC_DIR="e2e-bmmac${POOL_NUM}"
BM_SNO="e2e-bm-sno${POOL_NUM}"
BM_CPT="e2e-bm-cpt${POOL_NUM}"
BM_STD="e2e-bm-std${POOL_NUM}"
VMW_SNO="e2e-vmw-sno${POOL_NUM}"

# Same prefixes as create-cluster-conf.sh. Each 'x' is one random hex digit,
# drawn once per cluster so the ports share a prefix and differ by index.
# Fourth octet stays <= 0x2f, inside VMware's 00:50:56:00:00:00-3f:ff:ff.
_bm_mac_prefix() {
	local kind=$1 pat i ch out
	case "$kind" in
		sno) pat='00:50:56:0x:xx:' ;;
		compact) pat='00:50:56:1x:xx:' ;;
		*) pat='00:50:56:2x:xx:' ;;
	esac
	out=""
	i=0
	while [ "$i" -lt "${#pat}" ]; do
		ch="${pat:$i:1}"
		if [ "$ch" = "x" ]; then
			out="${out}$(printf '%x' $(( RANDOM % 16 )))"
		else
			out="${out}${ch}"
		fi
		i=$(( i + 1 ))
	done
	printf '%s\n' "$out"
}

_bm_set_key() {
	local file=$1 key=$2 val=$3
	if grep -q "^${key}=" "$file"; then
		sed -i "s|^${key}=.*|${key}=${val}|" "$file"
	else
		printf '%s=%s\n' "$key" "$val" >> "$file"
	fi
}

# Scratch files for this suite live in one directory so a run can delete
# them in one step. The old names were loose files in ~/tmp.
_bm_out_reset() {
	rm -rf "$HOME/tmp/e2e-tests"
	rm -f "$HOME"/tmp/bm-*.out "$HOME"/tmp/bm-matrix-*
	mkdir -p "$HOME/tmp/e2e-tests"
}

# j2 render can ignore the CLI starting-ip. Rewrite the fields the agent
# actually uses, and pin memory at 20 so vmw-create does not ask (a prompt
# on /dev/null would stop the boot).
_bm_fix_conf() {
	local dir=$1 kind=$2
	local f="$dir/cluster.conf" start
	case "$kind" in
		sno) start=$(pool_node_ip) ;;
		*) start=$(pool_starting_ip "$kind") ;;
	esac
	_bm_set_key "$f" ports ens160
	_bm_set_key "$f" starting_ip "$start"
	_bm_set_key "$f" machine_network "$(pool_machine_network)"
	# 10.0.0.1 is the .1 of 10.0.0.0/20, and nothing answers ARP there.
	# 10.0.1.5 is on this subnet and forwards to the internet. A direct
	# quay.io release pull needs that path. Mirror installs do not.
	_bm_set_key "$f" next_hop_address 10.0.1.5
	_bm_set_key "$f" ntp_servers "${NTP_IP:-10.0.1.8}"
	_bm_set_key "$f" master_mem 20
	_bm_set_key "$f" worker_mem 20
	if [ "$kind" = "sno" ]; then
		_bm_set_key "$f" api_vip ""
		_bm_set_key "$f" ingress_vip ""
		_bm_set_key "$f" num_masters 1
		_bm_set_key "$f" num_workers 0
	else
		_bm_set_key "$f" api_vip "$(pool_api_vip)"
		_bm_set_key "$f" ingress_vip "$(pool_apps_vip)"
		_bm_set_key "$f" num_masters 3
		if [ "$kind" = "compact" ]; then
			_bm_set_key "$f" num_workers 0
		else
			_bm_set_key "$f" num_workers 2
		fi
	fi
	touch "$f"
	echo "[bm-matrix] $dir kind=$kind starting_ip=$start"
	grep -E '^(starting_ip|ports|api_vip|ingress_vip|num_masters|num_workers|machine_network|next_hop_address|master_mem)=' "$f"
}

_bm_write_macs() {
	local dir=$1 n=$2 kind=$3 i=1 prefix
	prefix=$(_bm_mac_prefix "$kind")
	: > "$dir/macs.conf"
	while [ "$i" -le "$n" ]; do
		printf '%s%02x\n' "$prefix" "$i" >> "$dir/macs.conf"
		i=$(( i + 1 ))
	done
	echo "[bm-matrix] $dir macs.conf"
	cat "$dir/macs.conf"
}

# Pool dnsmasq (e2e-pool.conf) only has the standard cluster names.
# infra-dns.sh does nothing here: there is no aba-upstream.conf marker.
# verify-config.sh still requires api.<name> and *.apps.<name>.
_bm_dns_add() {
	local name=$1 api_ip=$2 apps_ip=$3
	local domain conf
	domain=$(pool_domain)
	conf="/etc/dnsmasq.d/aba-${name}.${domain}.conf"
	printf 'address=/api.%s.%s/%s\naddress=/.apps.%s.%s/%s\n' \
		"$name" "$domain" "$api_ip" "$name" "$domain" "$apps_ip" \
		| sudo tee "$conf" >/dev/null
	sudo systemctl restart dnsmasq
	echo "[bm-matrix] DNS api.${name}.${domain} -> ${api_ip}"
}

_bm_dns_del() {
	local name=$1
	sudo rm -f "/etc/dnsmasq.d/aba-${name}.$(pool_domain).conf"
	sudo systemctl restart dnsmasq || true
}

# Drop sim VMs for one cluster name. Safe when none exist.
# tools/bm-sim-delete.sh uses the cluster dir when it is still there, and
# ~/aba/vmware.conf when the dir was already removed.
_bm_destroy_vms() {
	local name=$1 domain=${2:-}
	tools/bm-sim-delete.sh "$name" || true
	if [ -n "$domain" ]; then
		scripts/infra-dns.sh remove-cluster "$name" "$domain" || true
	fi
	_bm_dns_del "$name" || true
}

_bm_wait_agent() {
	local ip=$1 i=0 code=""
	while [ "$i" -lt 36 ]; do
		code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 "http://${ip}:8090/" || true)
		echo "[bm-matrix] agent ${ip}:8090 http=${code}"
		case "$code" in
			4*) return 0 ;;
		esac
		i=$(( i + 1 ))
		sleep 10
	done
	echo "[bm-matrix] agent did not answer on ${ip}:8090" >&2
	return 1
}

# ISO, sim-boot, agent, then always delete the VMs. Leaves the dir on failure
# so the log and ISO are still there for RCA.
# platform=bm does not install govc. The sim boot still uploads with it.
_bm_ensure_govc() {
	export PATH="$HOME/bin:$PATH"
	if ! command -v govc >/dev/null 2>&1; then
		make -sC cli govc
	fi
}

_bm_agent_boot() {
	local dir=$1 kind=$2 rc=0
	_bm_ensure_govc
	aba --platform bm
	# Not `work || rc=$?`: bash turns set -e off for the whole left-hand side
	# of ||, so a failed grep would still boot the VM.
	set +e
	( set -e; _bm_agent_boot_work "$dir" "$kind" )
	rc=$?
	set -e
	_bm_destroy_vms "$dir" "$(pool_domain)" || true
	if [ "$rc" -eq 0 ]; then
		rm -rf "$dir"
		e2e_remove_from_cluster_cleanup "$PWD/$dir"
	fi
	return "$rc"
}

_bm_agent_boot_work() {
	local dir=$1 kind=$2 start nmac log
	rm -rf "$dir"
	case "$kind" in
		sno)
			start=$(pool_node_ip)
			nmac=1
			aba cluster -n "$dir" -t sno --starting-ip "$start" --image-source direct --step cluster.conf
			;;
		compact)
			start=$(pool_starting_ip compact)
			nmac=3
			aba cluster -n "$dir" -t compact --starting-ip "$start" \
				--api-vip "$(pool_api_vip)" --ingress-vip "$(pool_apps_vip)" \
				--image-source direct --step cluster.conf
			;;
		standard)
			start=$(pool_starting_ip standard)
			nmac=5
			aba cluster -n "$dir" -t standard --starting-ip "$start" --num-workers 2 \
				--api-vip "$(pool_api_vip)" --ingress-vip "$(pool_apps_vip)" \
				--image-source direct --step cluster.conf
			;;
		*)
			echo "unknown kind $kind" >&2
			return 1
			;;
	esac
	e2e_add_to_cluster_cleanup "$PWD/$dir"
	_bm_fix_conf "$dir" "$kind"
	_bm_write_macs "$dir" "$nmac" "$kind"
	if [ "$kind" = "sno" ]; then
		_bm_dns_add "$dir" "$start" "$start"
	else
		_bm_dns_add "$dir" "$(pool_api_vip)" "$(pool_apps_vip)"
	fi
	ln -sfn ../vmware.conf "$dir/vmware.conf"
	mkdir -p "$HOME/tmp/e2e-tests"
	log="$HOME/tmp/e2e-tests/bm-matrix-${dir}.iso"
	# `aba iso` stops after the image. `aba install` would continue into the monitor.
	set -o pipefail
	timeout 40m aba -y --dir "$dir" iso 2>&1 | tee "$log"
	grep -q 'Bare-metal MAC check' "$log"
	grep -q 'ISO ready' "$log"
	if grep -q 'wait-for install-complete' "$log"; then
		echo "[bm-matrix] aba iso entered the monitor" >&2
		return 1
	fi
	# shellcheck disable=SC2143
	if grep -q 'xx:xx:xx:xx:xx:xx' "$dir/agent-config.yaml"; then
		echo "[bm-matrix] placeholder MAC survived into the ISO inputs" >&2
		return 1
	fi
	ls "$dir"/iso-agent-based/agent.*.iso >/dev/null
	_bm_destroy_vms "$dir" "$(pool_domain)" || true
	tools/bm-sim-boot.sh "$dir"
	_bm_wait_agent "$start"
}

_vmw_agent_boot() {
	local dir=$1 rc=0
	_bm_ensure_govc
	aba --platform vmw
	# See _bm_agent_boot: set -e must stay on inside the work function.
	set +e
	( set -e; _vmw_agent_boot_work "$dir" )
	rc=$?
	set -e
	# VMs go away either way. The dir stays on failure so the ISO and log remain.
	_bm_destroy_vms "$dir" "$(pool_domain)" || true
	if [ "$rc" -eq 0 ]; then
		aba -y --dir "$dir" delete --force >/dev/null 2>&1 || true
		rm -rf "$dir"
		e2e_remove_from_cluster_cleanup "$PWD/$dir" || true
	fi
	return "$rc"
}

_vmw_agent_boot_work() {
	local dir=$1 start log
	rm -rf "$dir"
	start=$(pool_node_ip)
	aba cluster -n "$dir" -t sno --starting-ip "$start" --image-source direct --step cluster.conf
	e2e_add_to_cluster_cleanup "$PWD/$dir"
	_bm_fix_conf "$dir" sno
	_bm_dns_add "$dir" "$start" "$start"
	# No macs.conf: VMs invent a MAC from mac_prefix. That is the vmw path.
	rm -f "$dir/macs.conf" "$dir/agent-config.yaml"
	touch "$dir/cluster.conf"
	ln -sfn ../vmware.conf "$dir/vmware.conf"
	mkdir -p "$HOME/tmp/e2e-tests"
	log="$HOME/tmp/e2e-tests/bm-matrix-${dir}.vmw"
	set -o pipefail
	timeout 40m aba -y --dir "$dir" iso 2>&1 | tee "$log"
	if grep -q 'wait-for install-complete' "$log"; then
		echo "[bm-matrix] aba iso entered the monitor" >&2
		return 1
	fi
	aba -y --dir "$dir" upload
	aba -y --dir "$dir" create --start
	if grep -q 'xx:xx:xx:xx:xx:xx' "$dir/agent-config.yaml"; then
		echo "[bm-matrix] vmw YAML contains the BM placeholder" >&2
		return 1
	fi
	grep -q '00:50:56:' "$dir/agent-config.yaml"
	test -s "$dir"/iso-agent-based/agent.*.iso
	_bm_wait_agent "$start"
}

# --- Suite ------------------------------------------------------------------

e2e_setup

plan_tests \
	"Setup: install and configure" \
	"Too few MACs stop" \
	"Duplicate MACs rejected" \
	"Corrupt MAC text rejected" \
	"Too many MACs use the first N" \
	"Hand-edited agent-config kept" \
	"cluster.conf outranks macs.conf" \
	"aba install --step is rejected" \
	"VMware invents MACs and skips the BM gate" \
	"BM SNO: agent up, then delete" \
	"BM compact: agent up, then delete" \
	"BM standard: agent up, then delete" \
	"VMware SNO: agent up, then delete" \
	"Cleanup: restore platform"

suite_begin "bm-mac-matrix"

# ============================================================================
# 1. Setup
# ============================================================================
test_begin "Setup: install and configure"

e2e_install_aba

suite_configure_aba
suite_verify_aba_conf
suite_setup_vmware_env
suite_setup_ntp

e2e_run "Ensure mirror dir exists" "make -sC mirror init"

# ~/tmp/e2e-tests is this suite's scratch dir. Wipe it here so a grep cannot
# match a file left by the previous run, and again at the end.
e2e_run "Reset suite output dir" "_bm_out_reset"

e2e_run "Set platform=bm" "aba --platform bm"
e2e_run "Verify aba.conf: platform=bm" "grep ^platform=bm aba.conf"

e2e_run "Remove leftover policy dir" "rm -rf $MAC_DIR"
e2e_add_to_cluster_cleanup "$PWD/$MAC_DIR"
e2e_run "Create policy cluster (cluster.conf only)" \
	"aba cluster -n $MAC_DIR -t sno --starting-ip $(pool_node_ip) --image-source direct --step cluster.conf"
e2e_run "Pin SNO ports and starting IP" "_bm_fix_conf $MAC_DIR sno"

test_end

# ============================================================================
# 2. Too few MACs
# One real MAC, two ports. Generator pads the placeholder. The gate stops.
# The same YAML, already asked, stops again without a new Yes/No.
# ============================================================================
test_begin "Too few MACs stop"

e2e_run "Two ports" \
	"cd $MAC_DIR && _bm_set_key cluster.conf ports 'ens160,ens192' && touch cluster.conf"
e2e_run "One MAC in macs.conf" \
	"printf '%s\n' '00:50:56:BE:E2:01' > $MAC_DIR/macs.conf"
e2e_run "Drop any previous YAML and ask stamps" \
	"rm -f $MAC_DIR/agent-config.yaml $MAC_DIR/.bm-config-asked $MAC_DIR/.bm-config-reviewed"

e2e_run "Generate agent-config.yaml" \
	"cd $MAC_DIR && scripts/create-agent-config.sh > \$HOME/tmp/e2e-tests/bm-few-gen.out 2>&1"
e2e_run "YAML contains the one real MAC" \
	"grep -q '00:50:56:BE:E2:01' $MAC_DIR/agent-config.yaml"
e2e_run "YAML contains the placeholder for the missing slot" \
	"grep -q 'xx:xx:xx:xx:xx:xx' $MAC_DIR/agent-config.yaml"

e2e_run_must_fail "Review gate stops while the placeholder remains" \
	"cd $MAC_DIR && ASK_OVERRIDE=1 scripts/bm-ask-edit.sh > \$HOME/tmp/e2e-tests/bm-few-ask.out 2>&1"

e2e_run "Stop names the placeholder" \
	"grep -q 'still contains placeholder' \$HOME/tmp/e2e-tests/bm-few-ask.out"
e2e_run "Stop names the shortfall" \
	"grep -q 'Have 1 of 2' \$HOME/tmp/e2e-tests/bm-few-ask.out"
e2e_run "ISO review stamp was not written" \
	"test ! -f $MAC_DIR/.bm-config-reviewed"

e2e_run "Backdate YAML, macs.conf, and cluster.conf" \
	"touch -d '2020-01-01 00:00:00' $MAC_DIR/agent-config.yaml $MAC_DIR/macs.conf $MAC_DIR/cluster.conf"
e2e_run "Ask stamp is newer than that YAML" \
	"touch -d '2020-01-02 00:00:00' $MAC_DIR/.bm-config-asked"
e2e_run_must_fail "Same file already asked does not prompt again" \
	"cd $MAC_DIR && ASK_OVERRIDE=1 scripts/bm-ask-edit.sh > \$HOME/tmp/e2e-tests/bm-few-again.out 2>&1"

e2e_run "Second stop still names the placeholder" \
	"grep -q 'still contains placeholder' \$HOME/tmp/e2e-tests/bm-few-again.out"
e2e_run "Second stop has no Yes prompt" \
	"! grep -q 'Yes:' \$HOME/tmp/e2e-tests/bm-few-again.out"

test_end

# ============================================================================
# 3. Duplicates — in the needed slots, and past them
# head -n used to hide a repeat that sat after the first N lines.
# ============================================================================
test_begin "Duplicate MACs rejected"

e2e_run "One port" \
	"cd $MAC_DIR && _bm_set_key cluster.conf ports ens160 && touch cluster.conf"
e2e_run "Drop previous YAML and ask stamps" \
	"rm -f $MAC_DIR/agent-config.yaml $MAC_DIR/.bm-config-asked $MAC_DIR/.bm-config-reviewed"
e2e_run "Two copies of one MAC" \
	"printf '%s\n' '00:50:56:BE:E2:01' '00:50:56:BE:E2:01' > $MAC_DIR/macs.conf"
e2e_run_must_fail "Generator rejects the duplicate" \
	"cd $MAC_DIR && scripts/create-agent-config.sh > \$HOME/tmp/e2e-tests/bm-dup.out 2>&1"

e2e_run "Duplicate message names the problem" \
	"grep -q 'Duplicate MAC' \$HOME/tmp/e2e-tests/bm-dup.out"
e2e_run "Duplicate message reports 2 total, 1 unique" \
	"grep -q '2 total, 1 unique' \$HOME/tmp/e2e-tests/bm-dup.out"

e2e_run "Two ports" \
	"cd $MAC_DIR && _bm_set_key cluster.conf ports 'ens160,ens192' && touch cluster.conf"
e2e_run "Repeat sits after the two needed slots" \
	"printf '%s\n' '00:50:56:BE:E2:01' '00:50:56:BE:E2:02' '00:50:56:BE:E2:01' > $MAC_DIR/macs.conf"
e2e_run "Drop YAML so a rejected run cannot leave one behind" \
	"rm -f $MAC_DIR/agent-config.yaml"
e2e_run_must_fail "Generator rejects the duplicate past the needed count" \
	"cd $MAC_DIR && scripts/create-agent-config.sh > \$HOME/tmp/e2e-tests/bm-dup2.out 2>&1"

e2e_run "Duplicate message reports 3 total, 2 unique" \
	"grep -q '3 total, 2 unique' \$HOME/tmp/e2e-tests/bm-dup2.out"
e2e_run "No YAML was written" \
	"test ! -f $MAC_DIR/agent-config.yaml"

test_end

# ============================================================================
# 4. Corrupt text
# ============================================================================
test_begin "Corrupt MAC text rejected"

e2e_run "One port" \
	"cd $MAC_DIR && _bm_set_key cluster.conf ports ens160 && touch cluster.conf"
e2e_run "Drop previous YAML" \
	"rm -f $MAC_DIR/agent-config.yaml"
e2e_run "macs.conf has no valid MAC" \
	"printf '%s\n' 'not-a-mac' '00:zz:zz:zz:zz:zz' > $MAC_DIR/macs.conf"
e2e_run_must_fail "Generator rejects the corrupt file" \
	"cd $MAC_DIR && scripts/create-agent-config.sh > \$HOME/tmp/e2e-tests/bm-bad.out 2>&1"

e2e_run "Corrupt file names the expected form" \
	"grep -q 'No valid MAC addresses' \$HOME/tmp/e2e-tests/bm-bad.out"

test_end

# ============================================================================
# 5. Too many unique MACs
# ============================================================================
test_begin "Too many MACs use the first N"

e2e_run "Drop previous YAML and ask stamps" \
	"rm -f $MAC_DIR/agent-config.yaml $MAC_DIR/.bm-config-asked $MAC_DIR/.bm-config-reviewed"
e2e_run "Three unique MACs, SNO needs one" \
	"printf '%s\n' '00:50:56:BE:E2:01' '00:50:56:BE:E2:02' '00:50:56:BE:E2:03' > $MAC_DIR/macs.conf"
e2e_run "cluster.conf newer than macs.conf" \
	"touch $MAC_DIR/cluster.conf"
e2e_run "Generate agent-config.yaml" \
	"cd $MAC_DIR && scripts/create-agent-config.sh > \$HOME/tmp/e2e-tests/bm-extra.out 2>&1"

e2e_run "Warning says the first MAC is used" \
	"grep -q 'Using the first 1' \$HOME/tmp/e2e-tests/bm-extra.out"
e2e_run "YAML has the first MAC" \
	"grep -q '00:50:56:BE:E2:01' $MAC_DIR/agent-config.yaml"
e2e_run "YAML does not have the second MAC" \
	"! grep -q '00:50:56:BE:E2:02' $MAC_DIR/agent-config.yaml"
e2e_run "YAML has no placeholder" \
	"! grep -q 'xx:xx:xx:xx:xx:xx' $MAC_DIR/agent-config.yaml"

test_end

# ============================================================================
# 6. Hand-edited YAML, no macs.conf
# ============================================================================
test_begin "Hand-edited agent-config kept"

# INFO_ABA=1: aba_info is silent unless aba itself turned it on. These
# commands call the scripts directly, so the keep lines would not be printed.
e2e_run "Remove macs.conf and ask stamps" \
	"rm -f $MAC_DIR/macs.conf $MAC_DIR/.bm-config-asked $MAC_DIR/.bm-config-reviewed"
e2e_run "Hand-written YAML" \
	"printf '%s\n' 'macAddress: 00:50:56:BE:E9:99' > $MAC_DIR/agent-config.yaml"
e2e_run "cluster.conf is older than the YAML" \
	"touch -d '2020-01-01 00:00:00' $MAC_DIR/cluster.conf && touch $MAC_DIR/agent-config.yaml"
e2e_run "Generate, which should keep the YAML" \
	"cd $MAC_DIR && INFO_ABA=1 scripts/create-agent-config.sh > \$HOME/tmp/e2e-tests/bm-keep.out 2>&1"
e2e_run "Keep message was printed" \
	"grep -q 'keeping existing agent-config.yaml' \$HOME/tmp/e2e-tests/bm-keep.out"
e2e_run "Hand-written MAC is still in the YAML" \
	"grep -q '00:50:56:BE:E9:99' $MAC_DIR/agent-config.yaml"

e2e_run "Review gate" \
	"cd $MAC_DIR && INFO_ABA=1 ASK_OVERRIDE=1 scripts/bm-ask-edit.sh > \$HOME/tmp/e2e-tests/bm-keep-ask.out 2>&1"
e2e_run "Gate says it is keeping the YAML" \
	"grep -q 'Keeping agent-config.yaml' \$HOME/tmp/e2e-tests/bm-keep-ask.out"
e2e_run "Gate left the hand-written MAC in place" \
	"grep -q '00:50:56:BE:E9:99' $MAC_DIR/agent-config.yaml"
e2e_run "Gate did not write a placeholder" \
	"! grep -q 'xx:xx:xx:xx:xx:xx' $MAC_DIR/agent-config.yaml"

test_end

# ============================================================================
# 7. cluster.conf newer than the YAML wins over an older macs.conf
# ============================================================================
test_begin "cluster.conf outranks macs.conf"

e2e_run "One port" \
	"cd $MAC_DIR && _bm_set_key cluster.conf ports ens160"
e2e_run "macs.conf has the MAC that should win" \
	"printf '%s\n' '00:50:56:BE:E2:22' > $MAC_DIR/macs.conf"
e2e_run "YAML still has a different MAC" \
	"printf '%s\n' 'macAddress: 00:50:56:BE:E2:11' > $MAC_DIR/agent-config.yaml"
e2e_run "Drop ask stamps" \
	"rm -f $MAC_DIR/.bm-config-asked $MAC_DIR/.bm-config-reviewed"
e2e_run "macs.conf is the oldest file" \
	"touch -d '2020-01-01 00:00:00' $MAC_DIR/macs.conf"
e2e_run "YAML is newer than macs.conf" \
	"touch -d '2020-01-01 00:00:02' $MAC_DIR/agent-config.yaml"
e2e_run "cluster.conf is the newest file" \
	"touch -d '2020-01-01 00:00:04' $MAC_DIR/cluster.conf"
e2e_run "Regenerate agent-config.yaml" \
	"cd $MAC_DIR && scripts/create-agent-config.sh > \$HOME/tmp/e2e-tests/bm-rank.out 2>&1"
e2e_run "YAML has the MAC from macs.conf" \
	"grep -q '00:50:56:BE:E2:22' $MAC_DIR/agent-config.yaml"
e2e_run "YAML no longer has the hand-written MAC" \
	"! grep -q '00:50:56:BE:E2:11' $MAC_DIR/agent-config.yaml"
e2e_run "Generator did not keep the old YAML" \
	"! grep -q 'will not replace it' \$HOME/tmp/e2e-tests/bm-rank.out"

test_end

# ============================================================================
# 8. aba install --step is rejected; aba iso does not monitor
# ============================================================================
test_begin "aba install --step is rejected"

e2e_run "aba install --step iso is rejected" \
	"aba -d $MAC_DIR install --step iso > \$HOME/tmp/e2e-tests/bm-step.out 2>&1 || true; grep -q 'cannot be used with install' \$HOME/tmp/e2e-tests/bm-step.out"

e2e_run "install rule does not read target=" \
	"! grep -q 'filter-out install' templates/Makefile.cluster"

e2e_run "Dry-run aba iso" \
	"cd $MAC_DIR && timeout 90 make -n iso > \$HOME/tmp/e2e-tests/bm-make-iso.out 2>&1"
e2e_run "iso does not reach the monitor" \
	"! grep -q 'monitor-install.sh' \$HOME/tmp/e2e-tests/bm-make-iso.out"
e2e_run "iso still builds the image" \
	"grep -q 'generate-image.sh' \$HOME/tmp/e2e-tests/bm-make-iso.out"

e2e_run "Dry-run aba install" \
	"cd $MAC_DIR && timeout 90 make -n install > \$HOME/tmp/e2e-tests/bm-make-full.out 2>&1"
e2e_run "install still runs the monitor" \
	"grep -q 'monitor-install.sh' \$HOME/tmp/e2e-tests/bm-make-full.out"

test_end

# ============================================================================
# 9. platform=vmw invents MACs and does not ask the BM question
# ============================================================================
test_begin "VMware invents MACs and skips the BM gate"

e2e_run "Set platform=vmw" "aba --platform vmw"

e2e_run "Remove macs.conf, YAML, and ask stamps" \
	"rm -f $MAC_DIR/macs.conf $MAC_DIR/agent-config.yaml $MAC_DIR/.bm-config-asked $MAC_DIR/.bm-config-reviewed"
e2e_run "Touch cluster.conf so a missing YAML is regenerated" \
	"touch $MAC_DIR/cluster.conf"
e2e_run "Generate agent-config.yaml" \
	"cd $MAC_DIR && scripts/create-agent-config.sh > \$HOME/tmp/e2e-tests/bm-vmw-gen.out 2>&1"
e2e_run "YAML has an invented VMware MAC" \
	"grep -q '00:50:56:' $MAC_DIR/agent-config.yaml"
e2e_run "YAML has no bare-metal placeholder" \
	"! grep -q 'xx:xx:xx:xx:xx:xx' $MAC_DIR/agent-config.yaml"

e2e_run "Run the review gate" \
	"cd $MAC_DIR && ASK_OVERRIDE=1 scripts/bm-ask-edit.sh > \$HOME/tmp/e2e-tests/bm-vmw-ask.out 2>&1"
e2e_run "Gate did not ask the bare-metal question" \
	"! grep -q 'Bare-metal MAC check' \$HOME/tmp/e2e-tests/bm-vmw-ask.out"
e2e_run "Invented MAC is still in the YAML" \
	"grep -q '00:50:56:' $MAC_DIR/agent-config.yaml"

e2e_run "Restore platform=bm" "aba --platform bm"
e2e_run "Verify aba.conf: platform=bm" "grep ^platform=bm aba.conf"

test_end

# ============================================================================
# 10-13. Boot until the agent answers, then delete the VMs.
# image_source=direct so this suite does not need a mirrored registry.
# ens160 is the lab NIC. eno1 (the BM default) never comes up on these VMs.
# ============================================================================
test_begin "BM SNO: agent up, then delete"

e2e_run -r 1 1 "BM SNO ISO, sim boot, agent, destroy" \
	"_bm_agent_boot $BM_SNO sno"

test_end

test_begin "BM compact: agent up, then delete"

e2e_run -r 1 1 "BM compact ISO, sim boot, agent, destroy" \
	"_bm_agent_boot $BM_CPT compact"

test_end

test_begin "BM standard: agent up, then delete"

e2e_run -r 1 1 "BM standard ISO, sim boot, agent, destroy" \
	"_bm_agent_boot $BM_STD standard"

test_end

test_begin "VMware SNO: agent up, then delete"

e2e_run -r 1 1 "VMware SNO through .vms-ready, agent, delete" \
	"_vmw_agent_boot $VMW_SNO"

test_end

# ============================================================================
# 14. Leave the pool on vmw and drop anything this suite created
# ============================================================================
test_begin "Cleanup: restore platform"

e2e_run "Destroy leftover BM SNO VMs" \
	"_bm_destroy_vms $BM_SNO \$(pool_domain)"
e2e_run "Destroy leftover BM compact VMs" \
	"_bm_destroy_vms $BM_CPT \$(pool_domain)"
e2e_run "Destroy leftover BM standard VMs" \
	"_bm_destroy_vms $BM_STD \$(pool_domain)"
e2e_run "Destroy leftover VMware SNO VMs" \
	"_bm_destroy_vms $VMW_SNO \$(pool_domain)"

e2e_run "Remove policy cluster dir" "rm -rf $MAC_DIR"
e2e_run "Remove BM SNO dir" "rm -rf $BM_SNO"
e2e_run "Remove BM compact dir" "rm -rf $BM_CPT"
e2e_run "Remove BM standard dir" "rm -rf $BM_STD"
e2e_run "Remove VMware SNO dir" "rm -rf $VMW_SNO"

e2e_remove_from_cluster_cleanup "$PWD/$MAC_DIR"
e2e_remove_from_cluster_cleanup "$PWD/$BM_SNO"
e2e_remove_from_cluster_cleanup "$PWD/$BM_CPT"
e2e_remove_from_cluster_cleanup "$PWD/$BM_STD"
e2e_remove_from_cluster_cleanup "$PWD/$VMW_SNO"

e2e_run "Restore platform=vmw" "aba --platform vmw"
e2e_run "Verify aba.conf: platform=vmw" "grep ^platform=vmw aba.conf"
e2e_run "Remove suite output dir" "rm -rf \"\$HOME/tmp/e2e-tests\"; rm -f \"\$HOME\"/tmp/bm-*.out \"\$HOME\"/tmp/bm-matrix-*"

test_end

suite_end; _rc=$?

exit $_rc
