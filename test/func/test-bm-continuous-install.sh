#!/bin/bash
# Test: BM continuous install stamps, ask scripts, no legacy markers
# Regression for: BACKLOG #B80

cd "$(dirname "$0")/../.." || exit 1

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }

echo "=== BM continuous install (#B80) ==="

# Scripts exist and are executable
for s in bm-ask-edit.sh bm-ask-boot.sh; do
	if [ -x "scripts/$s" ]; then
		_pass "scripts/$s executable"
	else
		_fail "scripts/$s executable"
	fi
	bash -n "scripts/$s" && _pass "scripts/$s bash -n" || _fail "scripts/$s bash -n"
done

# Makefile: one chain, new stamps, no legacy
mf=templates/Makefile.cluster
if grep -q 'TARGET_DEPENDENCIES = check ../aba.conf iso .vms-stopped .iso-uploaded .vms-ready .bm-bmc-boot-done .install-complete' "$mf"; then
	_pass "unified TARGET_DEPENDENCIES"
else
	_fail "unified TARGET_DEPENDENCIES"
fi

for bad in '.bm-message' '.bm-nextstep' '.autopoweroff' '.autoupload' '.autorefresh' '.auto-agent-up:'; do
	if grep -qF "$bad" "$mf"; then
		_fail "Makefile must not contain $bad"
	else
		_pass "Makefile free of $bad"
	fi
done

# progress-plan has cluster-install
if grep -q 'cluster-install)' scripts/progress-plan.sh; then
	_pass "progress-plan.sh cluster-install"
else
	_fail "progress-plan.sh cluster-install"
fi

# Primed/backup must not fabricate .bm-message
if grep -n 'bm-message' scripts/backup.sh scripts/transfer-primed.sh 2>/dev/null; then
	_fail "backup/transfer-primed still reference .bm-message"
else
	_pass "backup/transfer-primed have no .bm-message"
fi

# aba.sh stamp sync uses new names
if grep -q 'touch .vms-stopped .iso-uploaded .vms-ready' scripts/aba.sh; then
	_pass "aba.sh create/refresh sync new stamps"
else
	_fail "aba.sh create/refresh sync new stamps"
fi
if grep -qE 'touch \.autopoweroff|\.autoupload|\.autorefresh' scripts/aba.sh; then
	_fail "aba.sh still touches old stamps"
else
	_pass "aba.sh has no old stamp touches"
fi

# wait-agent is on install Make chain only (not inside monitor — aba mon must skip)
if ! grep -q 'wait-agent-up.sh' scripts/monitor-install.sh; then
	_pass "monitor-install does not call wait-agent-up"
else
	_fail "monitor-install must not call wait-agent-up (breaks aba mon)"
fi
if awk '/^\.install-complete:/{p=1} p&&/wait-agent-up/{found=1} p&&/^[^[:space:]#]/{if(!/^\.install-complete:/) exit} END{exit !found}' templates/Makefile.cluster; then
	_pass ".install-complete calls wait-agent-up (first install only)"
else
	_fail ".install-complete must call wait-agent-up"
fi

# TUI BM no longer forces --step iso only
if grep -q 'install_step="iso"' tui/v2/tui-cluster.sh; then
	_fail "TUI still forces BM install_step=iso"
else
	_pass "TUI does not force BM iso-only step"
fi

# TUI install uses progress dialog for ALL platforms (not BM-only)
if grep -A20 'Installing cluster' tui/v2/tui-cluster.sh | grep -q 'confirm_and_execute'; then
	_fail "TUI install still uses confirm_and_execute for some platforms"
else
	_pass "TUI install does not use confirm_and_execute"
fi
if grep -A30 'Installing cluster' tui/v2/tui-cluster.sh | grep -q '_exec_with_progress'; then
	_pass "TUI install uses _exec_with_progress for all platforms"
else
	_fail "TUI install missing _exec_with_progress"
fi

# bm-ask-edit: macs_should_apply policy + prompts (DRY via macs_*)
if grep -q 'macs_should_apply' scripts/bm-ask-edit.sh; then
	_pass "bm-ask-edit uses macs_should_apply"
else
	_fail "bm-ask-edit must call macs_should_apply"
fi
if grep -q 'cluster_conf_outranks_agent' scripts/bm-ask-edit.sh && grep -q 'cluster_conf_outranks_agent' scripts/create-agent-config.sh; then
	_pass "cluster.conf newer than agent-config.yaml forces a rebuild"
else
	_fail "bm-ask-edit and create-agent-config must rebuild when cluster.conf is newer"
fi
if grep -q 'Generating agent-config.yaml for review' scripts/bm-ask-edit.sh; then
	_pass "bm-ask-edit pre-generates YAML for review when macs ready"
else
	_fail "bm-ask-edit must generate agent-config.yaml before review ask when macs ready"
fi
if grep -q 'macs_report' scripts/bm-ask-edit.sh; then
	_pass "bm-ask-edit shows macs_report in ask/log"
else
	_fail "bm-ask-edit must call macs_report for ready/errors/content"
fi
if grep -q '======== Bare-metal MAC check' scripts/bm-ask-edit.sh; then
	_pass "bm-ask-edit review ask covers macs.conf and agent-config.yaml"
else
	_fail "bm-ask-edit missing unified review ask"
fi
if grep -q 'macs.conf (preferred)' scripts/bm-ask-edit.sh \
	&& grep -q 'Cluster Install wizard and add the MAC addresses (preferred), then Retry' scripts/bm-ask-edit.sh \
	&& ! grep -q 'edit macs.conf (preferred), then Retry' scripts/bm-ask-edit.sh; then
	_pass "CLI prefers macs.conf; TUI prefers the cluster install wizard"
else
	_fail "preferred path must be macs.conf on CLI and the wizard on TUI"
fi
if grep -q 'Have all ${mac_expected:-?} required MAC addresses been added?' scripts/bm-ask-edit.sh \
	&& grep -q 'stop this run and go back to the Cluster Install wizard' scripts/bm-ask-edit.sh \
	&& grep -q 'missing slots are ${BM_MAC_PLACEHOLDER}' scripts/bm-ask-edit.sh \
	&& grep -q 'Have the servers been booted with the ISO file?' scripts/bm-ask-boot.sh \
	&& grep -q 'start monitoring installation progress' scripts/bm-ask-boot.sh \
	&& grep -q 'aba_cmd write-usb' scripts/bm-ask-boot.sh; then
	_pass "TUI asks name the wizard and keep write-usb; placeholder token is stripped for the TUI report"
else
	_fail "TUI MAC/boot wording drifted"
fi
if grep -q "BM_MAC_PLACEHOLDER='xx:xx:xx:xx:xx:xx'" scripts/include_all.sh \
	&& grep -q 'BM_MAC_PLACEHOLDER' scripts/create-agent-config.sh \
	&& grep -q 'placeholder' scripts/create-agent-config.sh \
	&& ! grep -q "xx:xx:xx:xx:xx:xx" scripts/create-agent-config.sh; then
	_pass "create-agent-config writes BM placeholder MACs (does not invent, does not abort)"
else
	_fail "BM placeholder MAC must be the single BM_MAC_PLACEHOLDER constant"
fi
# Ask1 must be reachable: Make must NOT require agent-config.yaml before bm-ask-edit
if grep -q 'Stopped: agent-config.yaml still contains placeholder' scripts/bm-ask-edit.sh \
	&& grep -q '_placeholders_before' scripts/bm-ask-edit.sh \
	&& grep -q 'were just written' scripts/bm-ask-edit.sh; then
	_pass "fresh placeholders ask(); a later unfixed re-run stops"
else
	_fail "fresh placeholders must ask(); an already-unfixed file must stop"
fi
# No = pause only; same install command is safe to re-run
if grep -q 're-run the SAME command' scripts/bm-ask-edit.sh && grep -q 're-run the SAME command' scripts/bm-ask-boot.sh \
	&& ! grep -q 'idempotent' scripts/bm-ask-edit.sh && ! grep -q 'idempotent' scripts/bm-ask-boot.sh; then
	_pass "BM asks highlight No → fix → re-run same install"
else
	_fail "BM ask No lines must say re-run the SAME command, without the word idempotent"
fi
# Make writes agent-config.yaml, then the recipe asks the user to edit it.
_rev_deps=$(grep -E '^\.bm-config-reviewed:' templates/Makefile.cluster | head -1)
if echo "$_rev_deps" | grep -q 'agent-config.yaml'; then
	_pass "review target depends on agent-config.yaml so Make writes it before the ask"
else
	_fail ".bm-config-reviewed must depend on agent-config.yaml (generate, then ask)"
fi
if grep -q -- '-nt' templates/Makefile.cluster; then
	_fail "Makefile must not shell-test -nt; agent-config.yaml already depends on cluster.conf"
else
	_pass "Makefile leaves newer-than to the agent-config.yaml rule"
fi
if grep -A8 '^\.bm-config-reviewed:' templates/Makefile.cluster | grep -q '\$(MAKE).*agent-config.yaml'; then
	_fail "review recipe must not rebuild agent-config.yaml after the ask"
else
	_pass "review recipe does not rebuild agent-config.yaml after the ask"
fi
_iso_deps=$(grep -E '^iso-agent-based/agent\.\$\(arch\)\.iso:' templates/Makefile.cluster | head -1)
if echo "$_iso_deps" | grep -q 'agent-config.yaml' && echo "$_iso_deps" | grep -q 'install-config.yaml'; then
	_pass "ISO target depends on install-config.yaml and agent-config.yaml"
else
	_fail "ISO target must depend on install-config.yaml and agent-config.yaml"
fi
if echo "$_iso_deps" | grep -q '\.bm-config-reviewed'; then
	_pass "ISO target still runs the review ask before the image"
else
	_fail "ISO target must depend on .bm-config-reviewed"
fi
if grep -E '^install:' templates/Makefile.cluster | grep -q '$(TARGET_DEPENDENCIES)' \
	&& ! grep -E '^install:' templates/Makefile.cluster | grep -q 'filter-out'; then
	_pass "aba install runs the full chain and does not read target="
else
	_fail "install must depend on TARGET_DEPENDENCIES only (no --step on aba install)"
fi
_step_out=$(./aba install --step iso 2>&1 || true)
if echo "$_step_out" | grep -q 'cannot be used with install'; then
	_pass "aba install --step is rejected"
else
	_fail "aba install --step must be rejected, got: $_step_out"
fi
if grep -A3 '^\.preflight-done:' templates/Makefile.cluster | grep -q '\.bm-config-reviewed'; then
	_pass ".preflight-done runs after .bm-config-reviewed"
else
	_fail ".preflight-done must depend on .bm-config-reviewed (Ask1 before create/preflight)"
fi
# TUI must not re-derive nodes×ports for MAC completeness
if grep -q 'macs_status' tui/v2/tui-cluster.sh && ! grep -qE '_expected_macs=\$\(\(' tui/v2/tui-cluster.sh; then
	_pass "TUI uses macs_status (dumb consumer)"
else
	_fail "TUI must call macs_status, not local expected-count math"
fi
if grep -q 'Stage nodes (VMs only)' scripts/progress-plan.sh; then
	_pass "progress plan labels ci_vms as Stage nodes (VMs only)"
else
	_fail "ci_vms plan label should be Stage nodes (VMs only)"
fi

# Runtime layout: cluster dir with scripts → ../scripts
_td=$(mktemp -d)
trap 'rm -rf "$_td"' EXIT
mkdir -p "$_td/scripts" "$_td/sno-bm-test"
ln -sf "$PWD/scripts/include_all.sh" "$_td/scripts/include_all.sh"
cat > "$_td/scripts/create-agent-config.sh" <<'EOF'
#!/bin/bash
echo "stub create-agent-config" >&2
touch agent-config.yaml
echo regenerated > .regen-stamp
exit 0
EOF
chmod +x "$_td/scripts/create-agent-config.sh"
cp scripts/bm-ask-edit.sh "$_td/scripts/"
for _h in normalize-aba-conf.sh normalize-cluster-conf.sh replace-value-conf; do
	[ -e "$PWD/scripts/$_h" ] && ln -sf "$PWD/scripts/$_h" "$_td/scripts/$_h"
done
ln -sfn ../scripts "$_td/sno-bm-test/scripts"
cat > "$_td/aba.conf" <<'EOF'
ocp_version=4.19.0
ocp_channel=stable
platform=bm
pull_secret=dummy
editor=none
ask=true
EOF
cat > "$_td/sno-bm-test/cluster.conf" <<'EOF'
cluster_name=sno-bm-test
base_domain=example.com
api_vip=
ingress_vip=
machine_network=10.0.1.0
prefix_length=24
starting_ip=10.0.1.10
num_masters=1
num_workers=0
ports=ens1f0
mac_prefix=00:50:56:1a:2b:
platform=bm
EOF
ln -sfn ../aba.conf "$_td/sno-bm-test/aba.conf"
touch "$_td/sno-bm-test/install-config.yaml" "$_td/sno-bm-test/agent-config.yaml" "$_td/sno-bm-test/mirror.conf"

export PATH="$_td/scripts:$PWD/scripts:$PATH"
export ASK_ALWAYS=1
unset ASK_OVERRIDE

# Empty macs + existing YAML: Enter keeps YAML (no regen)
rm -f "$_td/sno-bm-test/.regen-stamp" "$_td/sno-bm-test/macs.conf"
_out=$(cd "$_td/sno-bm-test" && echo "" | bash scripts/bm-ask-edit.sh 2>&1) && _rc=0 || _rc=$?
if [ "$_rc" -eq 0 ] && echo "$_out" | grep -q 'Bare-metal MAC check' \
	&& [ ! -f "$_td/sno-bm-test/.regen-stamp" ]; then
	_pass "empty macs + YAML: Enter keeps agent-config (no regen)"
else
	_fail "empty macs + YAML should keep agent-config (rc=$_rc)"
	echo "$_out" | tail -30
fi

# Complete macs, no YAML yet → pre-generate BEFORE ask so file exists to review
rm -f "$_td/sno-bm-test/agent-config.yaml" "$_td/sno-bm-test/.regen-stamp"
printf '00:50:56:1a:2b:01\n' > "$_td/sno-bm-test/macs.conf"
_out=$(cd "$_td/sno-bm-test" && echo "" | bash scripts/bm-ask-edit.sh 2>&1) && _rc=0 || _rc=$?
# create stub runs before ask; review prompt must point at a real agent-config.yaml
if [ "$_rc" -eq 0 ] && [ -f "$_td/sno-bm-test/agent-config.yaml" ] \
	&& [ -f "$_td/sno-bm-test/.regen-stamp" ] \
	&& echo "$_out" | grep -q 'Bare-metal MAC check' \
	&& echo "$_out" | grep -q 'stub create-agent-config'; then
	_pass "macs ready, no YAML: pre-generates agent-config before review ask"
else
	_fail "macs ready should create agent-config.yaml before ask (rc=$_rc)"
	echo "$_out" | tail -30
fi

# Complete macs newer than YAML → pre-gen (or post-ask regen) runs create
sleep 1
printf '00:50:56:1a:2b:01\n' > "$_td/sno-bm-test/macs.conf"
rm -f "$_td/sno-bm-test/.regen-stamp"
_out=$(cd "$_td/sno-bm-test" && echo "" | bash scripts/bm-ask-edit.sh 2>&1) && _rc=0 || _rc=$?
if [ "$_rc" -eq 0 ] && [ -f "$_td/sno-bm-test/.regen-stamp" ]; then
	_pass "newer complete macs.conf: regenerates for review"
else
	_fail "newer complete macs should regen (rc=$_rc)"
	echo "$_out" | tail -30
fi

# agent-config newer than complete macs → keep YAML (no regen)
sleep 1
touch "$_td/sno-bm-test/agent-config.yaml"
rm -f "$_td/sno-bm-test/.regen-stamp"
_out=$(cd "$_td/sno-bm-test" && echo "" | bash scripts/bm-ask-edit.sh 2>&1) && _rc=0 || _rc=$?
if [ "$_rc" -eq 0 ] && [ ! -f "$_td/sno-bm-test/.regen-stamp" ] \
	&& echo "$_out" | grep -q 'Yes: build the agent ISO'; then
	_pass "agent-config newer than macs: keep YAML (no regen)"
else
	_fail "newer agent-config should ignore macs (rc=$_rc)"
	echo "$_out" | tail -30
fi

# cluster.conf newer than the YAML, macs.conf older → rebuild anyway
sleep 1
touch "$_td/sno-bm-test/cluster.conf"
rm -f "$_td/sno-bm-test/.regen-stamp"
_out=$(cd "$_td/sno-bm-test" && echo "" | bash scripts/bm-ask-edit.sh 2>&1) && _rc=0 || _rc=$?
if [ "$_rc" -eq 0 ] && [ -f "$_td/sno-bm-test/.regen-stamp" ]; then
	_pass "cluster.conf newer than YAML: regenerates even when macs.conf is older"
else
	_fail "newer cluster.conf must regen agent-config (rc=$_rc)"
	echo "$_out" | tail -30
fi

# Pause-and-edit: empty macs → during keep-YAML prompt, write newer macs → y → regen
rm -f "$_td/sno-bm-test/macs.conf" "$_td/sno-bm-test/.regen-stamp"
touch "$_td/sno-bm-test/agent-config.yaml"
_out=$(
	cd "$_td/sno-bm-test" || exit 1
	(
		sleep 0.5
		printf '00:50:56:1a:2b:01\n' > macs.conf
	) &
	{ sleep 0.7; echo y; } | bash scripts/bm-ask-edit.sh 2>&1
) && _rc=0 || _rc=$?
if [ "$_rc" -eq 0 ] && [ -f "$_td/sno-bm-test/.regen-stamp" ]; then
	_pass "empty→edit macs during pause→y regenerates"
else
	_fail "empty→edit macs during pause→y should regen (rc=$_rc)"
	echo "$_out" | tail -30
fi

# Make already wrote placeholders (review prerequisite). Not asked yet → ask.
sleep 1
printf 'macAddress: xx:xx:xx:xx:xx:xx\n' > "$_td/sno-bm-test/agent-config.yaml"
rm -f "$_td/sno-bm-test/macs.conf" "$_td/sno-bm-test/.bm-config-asked" "$_td/sno-bm-test/.regen-stamp"
_out=$(cd "$_td/sno-bm-test" && echo n | bash scripts/bm-ask-edit.sh 2>&1) && _rc=0 || _rc=$?
if echo "$_out" | grep -q '? (y/n)' && [ -f "$_td/sno-bm-test/.bm-config-asked" ]; then
	_pass "file already written, not yet asked: ask to edit it"
else
	_fail "a pre-built agent-config.yaml must be asked about (rc=$_rc)"
	echo "$_out" | tail -30
fi

# Same file already asked, placeholders still there → stop, no question
sleep 1
touch "$_td/sno-bm-test/.bm-config-asked"
_out=$(cd "$_td/sno-bm-test" && echo n | bash scripts/bm-ask-edit.sh 2>&1) && _rc=0 || _rc=$?
if [ "$_rc" -ne 0 ] && echo "$_out" | grep -q 'still contains placeholder' \
	&& ! echo "$_out" | grep -q '? (y/n)'; then
	_pass "same unfixed file already asked: stop without asking again"
else
	_fail "re-run of an asked placeholder file must stop (rc=$_rc)"
	echo "$_out" | tail -30
fi
if echo "$_out" | grep -q 'aba install' && ! echo "$_out" | grep -q 'aba -d'; then
	_pass "re-run text is 'aba install' when already in the directory"
else
	_fail "re-run text must not use aba -d from inside the cluster dir"
	echo "$_out" | tail -20
fi

# aba_cmd: -d only when aba was invoked with -d / --dir.
source scripts/include_all.sh
_cmd_td=$(mktemp -d)
(
	cd "$_cmd_td" || exit 1
	mkdir -p ocp other
	cd ocp || exit 1
	unset ABA_TARGET_DIR
	[ "$(aba_cmd install)" = "aba install" ] || exit 1
	[ "$(aba_cmd install -y)" = "aba install -y" ] || exit 1
	[ "$(aba_cmd_for "$PWD" mon)" = "aba mon" ] || exit 1
	[ "$(aba_cmd_for "$_cmd_td/other" unstick)" = "aba -d other unstick" ] || exit 1
	ABA_TARGET_DIR="$PWD"
	[ "$(aba_cmd mon)" = "aba -d ocp mon" ] || exit 1
	[ "$(aba_cmd_for "$PWD" install)" = "aba -d ocp install" ] || exit 1
) && _pass "aba_cmd uses -d only when ABA_TARGET_DIR is set" \
	|| _fail "aba_cmd spelling is wrong"
rm -rf "$_cmd_td"

echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
