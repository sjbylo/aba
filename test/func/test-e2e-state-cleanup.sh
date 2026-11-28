#!/bin/bash
# ssh.conf is rewritten when the shared script loads, and the e2e state
# reset deletes the leftovers it claims to delete without touching the
# long-lived aba.conf or .index directory.

cd "$(dirname "$0")/../.." || exit 1

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }

WORK=$(mktemp -d /tmp/aba-state-cleanup.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

echo "=== ensure_ssh_conf from a cluster directory ==="

mkdir -p "$WORK/home" "$WORK/repo/cluster"
ln -s "$PWD/scripts" "$WORK/repo/scripts"
ln -s ../scripts "$WORK/repo/cluster/scripts"
real_ssh="$HOME/.aba/ssh.conf"
real_mtime=
[ -f "$real_ssh" ] && real_mtime=$(stat -c %Y "$real_ssh")

out=$(
	export HOME="$WORK/home"
	cd "$WORK/repo/cluster" || exit 1
	source scripts/include_all.sh
	source scripts/include_all.sh
	echo STDOUT_DONE
) || {
	_fail "sourcing include_all.sh from a cluster directory failed"
	echo "$out"
	exit 1
}

if [ "$out" = "STDOUT_DONE" ]; then
	_pass "include_all.sh stays quiet on stdout"
else
	_fail "include_all.sh wrote to stdout"
	printf '%s\n' "$out"
fi

expected=$(cat <<'END'
StrictHostKeyChecking no
UserKnownHostsFile=/dev/null
ConnectTimeout=15
ServerAliveInterval=30
ServerAliveCountMax=10
BatchMode=yes
LogLevel=ERROR
END
)
if [ "$(cat "$WORK/home/.aba/ssh.conf")" = "$expected" ]; then
	_pass "ssh.conf has the seven install lines"
else
	_fail "ssh.conf contents differ"
	cat "$WORK/home/.aba/ssh.conf"
fi

if [ -n "$real_mtime" ] && [ "$(stat -c %Y "$real_ssh")" = "$real_mtime" ]; then
	_pass "the real ssh.conf was not rewritten"
else
	_fail "the real ssh.conf changed"
fi

echo "=== backup stamp path ==="

if grep -q '~/.aba/\.previous\.backup' scripts/backup.sh \
	&& ! grep -q 'newer ~/.aba\.previous\.backup' scripts/backup.sh \
	&& grep -q 'rm -f ~/.aba\.previous\.backup' scripts/backup.sh; then
	_pass "backup.sh uses the hidden stamp and drops the old path"
else
	_fail "backup.sh still depends on the old stamp path"
fi

echo "=== state reset ==="

# shellcheck disable=SC1091
source test/e2e/lib/pool-cleanup.sh

base=$WORK/homes
for u in root steve testy; do
	h="$base/$u"
	mkdir -p "$h/.oc-mirror" "$h/.cache/agent/x" "$h/tmp" \
		"$h/aba/mirror/data/.oc-mirror" "$h/aba/.index" \
		"$h/aba/scripts" "$h/.aba/runner/task" "$h/.aba/cache" \
		"$h/.docker" "$h/.containers" "$h/.config/containers" "$h/.ssh" "$h/bin"
	echo keep > "$h/aba/aba.conf"
	echo idx > "$h/aba/.index/keep"
	echo old > "$h/.aba.previous.backup"
	echo new > "$h/.aba/.previous.backup"
	echo bin > "$h/bin/oc"
	echo keep > "$h/bin/notify.sh"
	echo auth > "$h/.docker/config.json"
	echo q > "$h/.ssh/quay_installer_key"
	echo ssh > "$h/.aba/ssh.conf"
	echo run > "$h/.aba/runner/task/exit"
	echo c > "$h/.aba/cache/x"
	echo deep > "$h/aba/mirror/data/.oc-mirror/blob"
done
# steve's tree can rewrite ssh.conf. root's tree is old and cannot.
touch "$base/steve/aba/scripts/ensure-ssh-conf.sh"
# testy has no aba scripts directory: the file should still go.
rm -rf "$base/testy/aba/scripts"

export E2E_STATE_BASE="$base"
if ! _e2e_state_reset_run "caches backup bins auth sshconf runner abacache" >"$WORK/reset.out"; then
	_fail "state reset script failed"
	cat "$WORK/reset.out"
else
	_pass "state reset script ran"
fi

ok=1
for u in root steve testy; do
	h="$base/$u"
	[ ! -e "$h/.oc-mirror" ] || ok=
	[ ! -e "$h/.cache/agent" ] || ok=
	[ ! -e "$h/tmp" ] || ok=
	[ ! -e "$h/aba/mirror/data/.oc-mirror" ] || ok=
	[ -f "$h/aba/aba.conf" ] || ok=
	[ -d "$h/aba/.index" ] || ok=
	[ -f "$h/aba/.index/keep" ] || ok=
	[ ! -e "$h/.aba.previous.backup" ] || ok=
	[ ! -e "$h/.aba/.previous.backup" ] || ok=
	[ ! -e "$h/bin/oc" ] || ok=
	[ -f "$h/bin/notify.sh" ] || ok=
	[ ! -e "$h/.docker/config.json" ] || ok=
	[ ! -e "$h/.ssh/quay_installer_key" ] || ok=
	[ ! -d "$h/.aba/runner" ] || ok=
	[ ! -d "$h/.aba/cache" ] || ok=
	[ -d "$h/.aba" ] || ok=
done
if [ -n "$ok" ]; then
	_pass "caches, bins, auth, runner, and cache went; aba.conf and .index stayed"
else
	_fail "state reset removed the wrong files"
	find "$base" -print | sort
fi

if [ ! -e "$base/steve/.aba/ssh.conf" ] && [ ! -e "$base/testy/.aba/ssh.conf" ] \
	&& [ -f "$base/root/.aba/ssh.conf" ]; then
	_pass "ssh.conf is dropped only when this aba can write it back"
else
	_fail "ssh.conf keep/drop did not follow the helper file"
fi

# A keep list still drops the old stamp, and leaves the new one.
echo new2 > "$base/steve/.aba/.previous.backup"
echo old2 > "$base/steve/.aba.previous.backup"
if _e2e_state_reset_run "" >/dev/null \
	&& [ ! -e "$base/steve/.aba.previous.backup" ] \
	&& [ -f "$base/steve/.aba/.previous.backup" ]; then
	_pass "the old stamp is always removed and the new one follows its own draw"
else
	_fail "backup stamp draw did not match"
fi

echo "=== ABA DNS glob ==="

mkdir -p "$WORK/dns"
echo a > "$WORK/dns/aba-upstream.conf"
echo m > "$WORK/dns/aba-mirror.conf"
echo p > "$WORK/dns/e2e-pool.conf"
export E2E_DNS_DIR="$WORK/dns"
if _e2e_dns_reset_run \
	&& [ -f "$WORK/dns/aba-upstream.conf" ] \
	&& [ ! -e "$WORK/dns/aba-mirror.conf" ] \
	&& [ -f "$WORK/dns/e2e-pool.conf" ]; then
	_pass "ABA DNS records are removed and the setup-dns marker stays"
else
	_fail "DNS reset touched the wrong file"
fi
unset E2E_DNS_DIR

if grep -q 'pool-registry' test/e2e/lib/pool-cleanup.sh \
	&& grep -q 'volume prune' test/e2e/lib/pool-cleanup.sh \
	&& ! grep -q 'aba remove dns -y' test/e2e/runner.sh; then
	_pass "podman prune skips a pool registry, and runner does not call aba remove dns"
else
	_fail "pool registry skip or aba remove dns check failed"
fi

_script=$(_e2e_state_reset_script)
_kill=$(printf '%s\n' "$_script" | awk '/run_once -G/ {print NR; exit}')
_rm=$(printf '%s\n' "$_script" | awk '/rm -rf "\$h\/\.aba\/runner"/ {print NR; exit}')
if [ -n "$_kill" ] && [ -n "$_rm" ] && [ "$_kill" -lt "$_rm" ]; then
	_pass "run_once -G runs before the runner directory is removed"
else
	_fail "runner delete does not kill jobs first (kill=$_kill rm=$_rm)"
fi

if grep -q 'mkdir -p ~/.aba' install && ! grep -q 'ensure-ssh-conf.sh' install; then
	_pass "install only creates ~/.aba; include_all.sh writes ssh.conf"
else
	_fail "install still calls ensure_ssh_conf itself"
fi

echo "=== pool folder ==="

if _e2e_vc_folder_allowed /Datacenter/vm/aba-e2e/pool1 \
	&& _e2e_vc_folder_allowed /Datacenter/vm/aba-e2e/pool4 \
	&& ! _e2e_vc_folder_allowed /Datacenter/vm/abatesting \
	&& ! _e2e_vc_folder_allowed /Datacenter/vm/aba-e2e \
	&& ! _e2e_vc_folder_allowed /Datacenter/vm/aba-e2e/pool1/extra; then
	_pass "only /Datacenter/vm/aba-e2e/poolN is an e2e folder"
else
	_fail "pool folder allow-list is wrong"
fi

mkdir -p "$WORK/vmware"
printf 'VC_FOLDER=/Datacenter/vm/abatesting\t\t# production\n' > "$WORK/vmware/export.conf"
printf 'export VC_FOLDER=/Datacenter/vm/abatesting\n' > "$WORK/vmware/plain.conf"
: > "$WORK/vmware/empty.conf"
if _e2e_rewrite_vc_file "$WORK/vmware/export.conf" /Datacenter/vm/aba-e2e/pool2 Datastore4-2 \
	&& _e2e_rewrite_vc_file "$WORK/vmware/plain.conf" /Datacenter/vm/aba-e2e/pool2 \
	&& _e2e_rewrite_vc_file "$WORK/vmware/empty.conf" /Datacenter/vm/aba-e2e/pool2 \
	&& [ "$(cat "$WORK/vmware/export.conf")" = "VC_FOLDER=/Datacenter/vm/aba-e2e/pool2" ] \
	&& [ "$(cat "$WORK/vmware/plain.conf")" = "VC_FOLDER=/Datacenter/vm/aba-e2e/pool2" ] \
	&& [ ! -s "$WORK/vmware/empty.conf" ] \
	&& ! grep -q abatesting "$WORK/vmware/export.conf" "$WORK/vmware/plain.conf"; then
	_pass "abatesting is rewritten to the pool folder, empty file stays empty"
else
	_fail "VC_FOLDER rewrite left the production folder"
	cat "$WORK/vmware/export.conf" "$WORK/vmware/plain.conf"
fi

_std1=/Datacenter/vm/abatesting/e2e-standard1/e2e-standard1-master1
if _e2e_abatesting_path_is_pool "$_std1" 1 \
	&& _e2e_abatesting_path_is_pool /Datacenter/vm/abatesting/e2e-sno-vlan1/vm 1 \
	&& ! _e2e_abatesting_path_is_pool "$_std1" 2 \
	&& ! _e2e_abatesting_path_is_pool /Datacenter/vm/abatesting/e2e-sno12/e2e-sno12 2 \
	&& ! _e2e_abatesting_path_is_pool /Datacenter/vm/abatesting/okd-vmw/okd-vmw 1 \
	&& ! _e2e_abatesting_path_is_pool "$_std1" ""; then
	_pass "only this pool's e2e folder under abatesting blocks the pool"
else
	_fail "abatesting path match is not limited to this pool"
fi

echo
echo "Passed: $pass  Failed: $fail"
[ "$fail" -eq 0 ]
