#!/bin/bash
# test-okd-lifecycle-guards.sh -- operations ABA does not support for OKD stop before they touch a cluster
#
# Covered: upgrade, upgrade-mon, day2-osus, day2-virt, --upgrade-to, import of an OKD cluster, the
# three TUI day-2 actions, and the distribution field of `status --shell`. The guard reads the
# distribution recorded for the installed cluster; aba.conf (the next install) is not consulted for
# cluster operations. Real scripts, scratch tree, no cluster and no network (okd-fixture-lib.sh).

cd "$(dirname "$0")/../.." || exit 1
ABA_ROOT="$PWD"
source test/func/okd-fixture-lib.sh

pass=0; fail=0
ok()  { echo "  ✓ $1"; pass=$(( pass + 1 )); }
bad() { echo "  ✗ $1"; fail=$(( fail + 1 )); }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1 (expected '$2', got '$3')"; }
has() { grep -qF -- "$3" <<<"$2" && ok "$1" || bad "$1 (missing '$3' in: $(head -c 400 <<<"$2"))"; }
hasnt() { grep -qF -- "$3" <<<"$2" && bad "$1 (unexpected '$3')" || ok "$1"; }
nonzero() { [ "$2" != 0 ] && ok "$1" || bad "$1 (rc was 0)"; }

fx_init
trap fx_cleanup EXIT
echo "=== test-okd-lifecycle-guards.sh ==="

MSG="unsupported for OKD in ABA"
CL="$FX_REPO/clu"
mk_cluster() {  # <state-distribution-line|none|nostate>
	rm -rf "$CL"; mkdir -p "$CL/clusterstate"
	printf 'cluster_name=clu\nbase_domain=example.test\nstarting_ip=10.0.0.10\nnum_masters=1\n' > "$CL/cluster.conf"
	ln -s ../scripts "$CL/scripts"; ln -s ../templates "$CL/templates"; ln -s ../aba.conf "$CL/aba.conf"
	ln -s ../templates/Makefile.cluster "$CL/Makefile"
	touch "$CL/.install-complete"
	case "$1" in
		nostate) rmdir "$CL/clusterstate" ;;
		none)    printf 'cluster_name=clu\nbase_domain=example.test\nplatform=bm\n' > "$CL/clusterstate/state.sh" ;;
		*)       printf 'cluster_name=clu\nbase_domain=example.test\nplatform=bm\n%s\n' "$1" > "$CL/clusterstate/state.sh" ;;
	esac
	fx_calls_reset
}
cl_run() {  # <script> [args] -- run from the cluster dir
	FX_OUT=$(cd "$CL" && env -i HOME="$FX_HOME" PATH="$FX_BIN:/usr/sbin:/usr/bin:/bin" PLAIN_OUTPUT=1 INFO_ABA=1 ABA_DO_NOT_UPDATE=1 \
		RUN_ONCE_CLEANED=1 FX_CALLS="$FX_CALLS" TMPDIR="$FX_ROOT" LC_ALL=C.UTF-8 timeout 60 bash "scripts/$1" "${@:2}" 2>&1 </dev/null)
	FX_RC=$?
}
aba_run() {  # <aba args> -- run the real aba.sh from the tree root
	FX_OUT=$(cd "$FX_REPO" && env -i HOME="$FX_HOME" PATH="$FX_BIN:/usr/sbin:/usr/bin:/bin" PLAIN_OUTPUT=1 INFO_ABA=1 ABA_DO_NOT_UPDATE=1 \
		RUN_ONCE_CLEANED=1 FX_CALLS="$FX_CALLS" TMPDIR="$FX_ROOT" LC_ALL=C.UTF-8 timeout 90 bash scripts/aba.sh "$@" 2>&1 </dev/null)
	FX_RC=$?
}
cluster_calls() { fx_calls | grep -c -E '^(oc|curl|skopeo|openshift-install) '; }

# ---------------------------------------------------------------- the scripts
fx_conf ocp   # next-install setting is ocp: the installed cluster decides
for s in cluster-upgrade.sh cluster-upgrade-mon.sh day2-config-osus.sh day2-config-virt.sh; do
	echo "--- $s"
	mk_cluster distribution=okd
	cl_run "$s"
	nonzero "okd cluster: rc" "$FX_RC"
	has "okd cluster: message" "$FX_OUT" "$MSG"
	eq "okd cluster: stopped before any oc/curl/skopeo call" 0 "$(cluster_calls)"
	mk_cluster none
	cl_run "$s"
	hasnt "cluster without the key (ocp): not blocked" "$FX_OUT" "$MSG"
	mk_cluster nostate
	cl_run "$s"
	hasnt "no cluster state: not blocked here" "$FX_OUT" "$MSG"
done
echo "--- the installed cluster decides, not aba.conf"
fx_conf okd
mk_cluster none
cl_run cluster-upgrade.sh
hasnt "aba.conf=okd but cluster installed as ocp: upgrade not blocked" "$FX_OUT" "$MSG"
fx_conf ocp

# ---------------------------------------------------------------- aba.sh dispatch
echo "--- aba.sh dispatch"
for t in upgrade upgrade-mon day2-osus day2-virt; do
	mk_cluster distribution=okd
	aba_run -d clu $t
	nonzero "aba -d clu $t on an okd cluster: rc" "$FX_RC"
	has "aba -d clu $t on an okd cluster: message" "$FX_OUT" "$MSG"
	eq "aba -d clu $t on an okd cluster: no cluster call" 0 "$(cluster_calls)"
done
# the dispatch guard also comes before the install-completion probe that talks to the cluster
for t in upgrade upgrade-mon day2-osus day2-virt; do
	mk_cluster distribution=okd
	rm -f "$CL/.install-complete"
	mkdir -p "$FX_HOME/.aba/clusters/clu.example.test" "$CL/iso-agent-based/auth"
	echo "apiVersion: v1" | tee "$FX_HOME/.aba/clusters/clu.example.test/kubeconfig" > "$CL/iso-agent-based/auth/kubeconfig"
	aba_run -d clu $t
	has "aba -d clu $t on an okd cluster, install not marked complete: message" "$FX_OUT" "$MSG"
	eq "aba -d clu $t on an okd cluster, install not marked complete: the cluster is not probed" 0 "$(cluster_calls)"
done
rm -rf "$FX_HOME/.aba/clusters/clu.example.test"
mk_cluster distribution=okd
aba_run -d clu upgrade --dry-run
has "upgrade --dry-run is blocked too" "$FX_OUT" "$MSG"
aba_run -d clu day2-ntp
hasnt "day2-ntp stays available" "$FX_OUT" "$MSG"
aba_run -d clu day2
hasnt "day2 stays available" "$FX_OUT" "$MSG"
mk_cluster none
aba_run -d clu upgrade
hasnt "ocp cluster: aba upgrade not blocked" "$FX_OUT" "$MSG"

echo "--- --upgrade-to"
printf 'reg_host=%s\nreg_port=%s\nreg_path=%s\nreg_vendor=docker\n' "$FX_HOST" "$FX_PORT" "$FX_REGPATH" > "$FX_MIR/mirror.conf"
fx_conf okd
aba_run -d mirror --upgrade-to 9.8.9-okd-scos.7
nonzero "okd: --upgrade-to rc" "$FX_RC"
has "okd: --upgrade-to message" "$FX_OUT" "$MSG"
eq "okd: mirror.conf not changed" "0" "$(grep -c ocp_upgrade_to "$FX_MIR/mirror.conf")"
aba_run -d mirror --upgrade-to none
has "okd: clearing the target is blocked too (nothing to clear)" "$FX_OUT" "$MSG"
fx_conf ocp
aba_run -d mirror --upgrade-to none
hasnt "ocp: --upgrade-to none works as before" "$FX_OUT" "$MSG"

# ---------------------------------------------------------------- aba import
echo "--- aba import refuses OKD clusters"
cat > "$FX_BIN/oc" <<'EOF'
#!/bin/bash
echo "oc $*" >> "$FX_CALLS"
case "$*" in
	whoami*) echo system:admin ;;
	*"get dns.config/cluster"*) echo example.test ;;
	*"infrastructureName"*) echo clu1-abcde ;;
	*"history[?"*) echo "${FX_OC_VERSION:-}" ;;
	*"desired.image"*) echo "${FX_OC_IMAGE:-}" ;;
	*"get nodes -l node-role.kubernetes.io/master"*) echo "10.0.0.11 10.0.0.12 10.0.0.13" ;;
esac
exit 0
EOF
chmod +x "$FX_BIN/oc"
cat >> "$FX_REPO/scripts/include_all.sh" <<'EOF'
ensure_oc() { return 0; }
cluster_api_reachable() { return 0; }
EOF
echo "apiVersion: v1" > "$FX_ROOT/kubeconfig"
imp() {  # <version> <image> [args] -- run import from the tree root; leave no state behind
	rm -rf "$FX_HOME/.aba/clusters/clu1.example.test" "$FX_REPO/clu1"
	imp_run "$@"
}
imp_run() {
	local v="$1" i="$2"; shift 2
	FX_OUT=$(cd "$FX_REPO" && env -i HOME="$FX_HOME" PATH="$FX_BIN:/usr/sbin:/usr/bin:/bin" PLAIN_OUTPUT=1 INFO_ABA=1 ABA_DO_NOT_UPDATE=1 \
		RUN_ONCE_CLEANED=1 FX_CALLS="$FX_CALLS" FX_OC_VERSION="$v" FX_OC_IMAGE="$i" TMPDIR="$FX_ROOT" LC_ALL=C.UTF-8 \
		timeout 60 bash scripts/cluster-import.sh --kubeconfig "$FX_ROOT/kubeconfig" "$@" 2>&1 </dev/null)
	FX_RC=$?
}
fx_conf ocp
imp "9.8.7-okd-scos.6" ""
nonzero "OKD version in ClusterVersion: rc" "$FX_RC"
has "OKD version: message" "$FX_OUT" "import"
has "OKD version: names OKD" "$FX_OUT" "OKD"
eq "OKD version: nothing written" "no" "$([ -e "$FX_HOME/.aba/clusters/clu1.example.test/state.sh" ] && echo yes || echo no)"
imp "" "quay.io/okd/scos-release@${FX_DIGEST}"
nonzero "OKD payload image, no version: rc" "$FX_RC"
has "OKD payload image: message" "$FX_OUT" "OKD"
imp "7.6.5" "quay.io/openshift-release-dev/ocp-release@${FX_DIGEST}"
hasnt "OCP cluster: not refused for OKD" "$FX_OUT" "OKD"
eq "OCP cluster: state.sh written" "yes" "$([ -s "$FX_HOME/.aba/clusters/clu1.example.test/state.sh" ] && echo yes || echo no)"
eq "OCP cluster: state.sh has no distribution" "0" "$(grep -c '^distribution=' "$FX_HOME/.aba/clusters/clu1.example.test/state.sh" 2>/dev/null)"
# a previous state that says okd (the live API cannot tell: stale kubeconfig) is never overwritten
mkdir -p "$FX_HOME/.aba/clusters/clu1.example.test"
printf 'cluster_name=clu1\nbase_domain=example.test\nplatform=kvm\ndistribution=okd\n' > "$FX_HOME/.aba/clusters/clu1.example.test/state.sh"
imp_run "7.6.5" "" --force
nonzero "prior okd state, --force: rc" "$FX_RC"
has "prior okd state: message" "$FX_OUT" "OKD"
eq "prior okd state kept" "distribution=okd" "$(grep '^distribution=' "$FX_HOME/.aba/clusters/clu1.example.test/state.sh")"
rm -rf "$FX_HOME/.aba/clusters/clu1.example.test" "$FX_REPO/clu1"

# ---------------------------------------------------------------- status --shell
echo "--- cluster-status --shell carries the distribution for okd only"
mk_cluster distribution=okd
FX_OUT=$(cd "$FX_REPO" && env -i HOME="$FX_HOME" PATH="$FX_BIN:/usr/sbin:/usr/bin:/bin" PLAIN_OUTPUT=1 bash scripts/cluster-status.sh --shell --no-live 2>&1)
has "okd cluster line" "$FX_OUT" "cluster=clu status=installed type=sno health=unknown version= distribution=okd"
mk_cluster none
FX_OUT=$(cd "$FX_REPO" && env -i HOME="$FX_HOME" PATH="$FX_BIN:/usr/sbin:/usr/bin:/bin" PLAIN_OUTPUT=1 bash scripts/cluster-status.sh --shell --no-live 2>&1)
eq "ocp cluster line unchanged" "cluster=clu status=installed type=sno health=unknown version=" "$(grep '^cluster=' <<<"$FX_OUT")"
mk_cluster nostate
FX_OUT=$(cd "$FX_REPO" && env -i HOME="$FX_HOME" PATH="$FX_BIN:/usr/sbin:/usr/bin:/bin" PLAIN_OUTPUT=1 bash scripts/cluster-status.sh --shell --no-live 2>&1)
eq "cluster without state unchanged" "cluster=clu status=installed type=sno health=unknown version=" "$(grep '^cluster=' <<<"$FX_OUT")"

# ---------------------------------------------------------------- TUI actions
echo "--- TUI: upgrade, OSUS and virtualization boot sources are blocked for okd clusters"
TUI="$ABA_ROOT/tui/v2/tui-cluster.sh"
tui_run() {  # <function> <state-line|none> -- the real function body, dialog and aba replaced
	mk_cluster "$2"
	local body; body=$(sed -n "/^$1() {/,/^}/p; /^_day2_okd_blocked() {/,/^}/p" "$TUI")
	FX_OUT=$(cd "$FX_REPO" && env -i HOME="$FX_HOME" PATH="$FX_BIN:/usr/sbin:/usr/bin:/bin" FX_CALLS="$FX_CALLS" bash -c "
		source $FX_REPO/scripts/include_all.sh noerr 2>/dev/null; trap - ERR
		ABA_ROOT=$FX_REPO; TUI2_TITLE_DAY2_MENU=T; TUI2_TITLE_DAY2_UPGRADE=T; TUI2_TITLE_DAY2_OSUS=T; TUI2_TITLE_DAY2_VIRT=T; TUI2_BTN_CONTINUE=c; TUI2_BTN_CANCEL=x; TUI2_TITLE_CLUSTER_OSUS_WARN=T
		ui_backtitle() { echo bt; }
		select_installed_cluster() { SELECTED_CLUSTER=clu; SELECTED_CLUSTER_DISPLAY=clu; return 0; }
		dlg() { echo \"DLG: \$*\"; return 0; }
		aba() { echo \"aba \$*\" >> \"\$FX_CALLS\"; return 0; }
		_exec_with_progress() { echo \"exec \$*\" >> \"\$FX_CALLS\"; return 0; }
		confirm_and_execute() { echo \"confirm \$*\" >> \"\$FX_CALLS\"; return 0; }
		$body
		$1
		echo \"rc=\$?\"" 2>&1)
}
for f in _day2_upgrade _day2_run_osus _day2_run_virt; do
	tui_run $f distribution=okd
	has "$f on okd: dialog explains" "$FX_OUT" "$MSG"
	eq "$f on okd: nothing is executed" 0 "$(fx_calls | grep -c -E '^(aba|exec|confirm|oc) ')"
	tui_run $f none
	hasnt "$f on ocp: not blocked" "$FX_OUT" "$MSG"
	eq "$f on ocp: still runs aba" 1 "$([ "$(fx_calls | grep -c -E '^(aba|exec|confirm) ')" -ge 1 ] && echo 1 || echo 0)"
done

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
