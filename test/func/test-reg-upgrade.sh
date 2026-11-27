#!/bin/bash
# aba -d mirror upgrade: registry upgrade with a renewed Quay leaf cert.
#
# Pure unit tests. No registry, no network, no sudo. aba.sh and the
# dispatcher run in a throwaway repo with a throwaway HOME, so the real
# ~/.aba state and ~/bin/aba are not touched. make and the vendor scripts
# are stubs there.

cd "$(dirname "$0")/../.." || exit 1
ROOT=$PWD

pass=0
fail=0
_ok() { pass=$((pass + 1)); printf '  PASS  %s\n' "$*"; }
_fail() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$*"; }

WORK=$(mktemp -d /tmp/aba-reg-upgrade.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

unset _REG_COMMON_LOADED
# shellcheck disable=SC1091
source scripts/reg-common.sh
INFO_ABA=

echo "=== reg_leaf_days ==="

now=1800000000
day=86400

if reg_leaf_days $(( now + 10 * day )) "$now" >/dev/null; then
	_fail "CA with 10 days left is accepted"
else
	_ok "CA with 10 days left stops"
fi

out=$(reg_leaf_days $(( now + 3650 * day )) "$now")
if [ "$out" = 365 ]; then _ok "CA with 3650 days left gives a 365 day leaf"; else _fail "3650 days gave [$out]"; fi

out=$(reg_leaf_days $(( now + 200 * day )) "$now")
if [ "$out" = 199 ]; then _ok "CA with 200 days left gives a 199 day leaf"; else _fail "200 days gave [$out]"; fi

echo "=== reg_quay_check_ca / reg_quay_issue_leaf ==="

# A Quay-shaped CA tree: reg_root/quay-rootCA/rootCA.{pem,key}
_make_ca() {
	local dir="$1" days="$2"
	mkdir -p "$dir/quay-rootCA"
	openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days "$days" -subj '/CN=test-ca' \
		-keyout "$dir/quay-rootCA/rootCA.key" -out "$dir/quay-rootCA/rootCA.pem" >/dev/null 2>&1
}

reg_host=registry.example.com

# _leaf_suite <label> <ssh_cmd>
_leaf_suite() {
	local label="$1" ssh_cmd="$2"
	local ca_sha leaf text serial1 serial2 out rc

	reg_root="$WORK/$label/quay-install"
	_make_ca "$reg_root" 3650
	ca_sha=$(sha256sum "$reg_root/quay-rootCA/rootCA.pem" "$reg_root/quay-rootCA/rootCA.key")

	rm -f "$WORK/days"
	( reg_quay_check_ca "$ssh_cmd" && echo "$leaf_days" > "$WORK/days" ) 2>/dev/null
	if [ "$(cat "$WORK/days" 2>/dev/null)" = 365 ]; then _ok "$label: 10 year CA gives leaf_days=365"; else _fail "$label: leaf_days=[$(cat "$WORK/days" 2>/dev/null)]"; fi

	leaf="$WORK/$label/leaf"
	if reg_quay_issue_leaf "$ssh_cmd" 365 "$leaf" >/dev/null 2>&1; then
		_ok "$label: leaf issued"
	else
		_fail "$label: reg_quay_issue_leaf failed"
	fi
	if openssl verify -CAfile "$reg_root/quay-rootCA/rootCA.pem" "$leaf/ssl.cert" >/dev/null 2>&1; then
		_ok "$label: leaf verifies against the existing CA"
	else
		_fail "$label: leaf does not verify against the CA"
	fi
	text=$(openssl x509 -in "$leaf/ssl.cert" -noout -text 2>/dev/null)
	if printf '%s\n' "$text" | grep -q "DNS:$reg_host" \
		&& printf '%s\n' "$text" | grep -q 'TLS Web Server Authentication' \
		&& printf '%s\n' "$text" | grep -q 'CA:FALSE'; then
		_ok "$label: leaf has SAN, serverAuth and CA:FALSE"
	else
		_fail "$label: leaf extensions are wrong"
	fi
	if [ "$(ls -A "$leaf" | tr '\n' ' ')" = "ssl.cert ssl.key " ] && [ "$(stat -c '%a' "$leaf/ssl.key")" = 600 ]; then
		_ok "$label: out dir holds only ssl.cert and ssl.key (0600)"
	else
		_fail "$label: out dir: [$(ls -A "$leaf" | tr '\n' ' ')] key mode $(stat -c '%a' "$leaf/ssl.key" 2>/dev/null)"
	fi
	if [ "$ca_sha" = "$(sha256sum "$reg_root/quay-rootCA/rootCA.pem" "$reg_root/quay-rootCA/rootCA.key")" ] \
		&& [ ! -e "$reg_root/quay-rootCA/rootCA.srl" ]; then
		_ok "$label: CA dir is unchanged (no .srl)"
	else
		_fail "$label: CA dir was changed"
	fi
	serial1=$(openssl x509 -in "$leaf/ssl.cert" -noout -serial 2>/dev/null)
	reg_quay_issue_leaf "$ssh_cmd" 365 "$WORK/$label/leaf2" >/dev/null 2>&1
	serial2=$(openssl x509 -in "$WORK/$label/leaf2/ssl.cert" -noout -serial 2>/dev/null)
	if [ -n "$serial2" ] && [ "$serial1" != "$serial2" ]; then _ok "$label: each leaf gets a new serial"; else _fail "$label: serial repeated [$serial1]"; fi

	reg_root="$WORK/$label/quay-short"
	_make_ca "$reg_root" 10
	out=$( ( reg_quay_check_ca "$ssh_cmd" ) 2>&1 )
	rc=$?
	if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'Quay CA expires on'; then
		_ok "$label: CA with 10 days left stops with the expiry message"
	else
		_fail "$label: short CA: rc=$rc out=[$out]"
	fi
}

_leaf_suite local ""

echo "=== reg_quay_installer_key (throwaway HOME) ==="

khome="$WORK/keyhome"
mkdir -p "$khome"
( HOME="$khome"; reg_quay_installer_key; reg_quay_installer_key ) >/dev/null 2>&1
if [ -s "$khome/.ssh/quay_installer" ] && [ "$(grep -c . "$khome/.ssh/authorized_keys" 2>/dev/null)" = 1 ] \
	&& [ "$(stat -c '%a' "$khome/.ssh")" = 700 ]; then
	_ok "quay_installer key created once and authorized"
else
	_fail "installer key: [$(ls -la "$khome/.ssh" 2>&1 | tr '\n' ' ')]"
fi

echo "=== _reg_fetch_ca / reg_post_upgrade ==="

regcreds_dir="$WORK/regcreds"
mkdir -p "$regcreds_dir"
echo 'OLD-CA' > "$regcreds_dir/rootCA.pem"
FSTUBS=$WORK/fetch-stubs
mkdir -p "$FSTUBS"
printf '#!/bin/bash\nexit 255\n' > "$FSTUBS/ssh"
chmod +x "$FSTUBS/ssh"
out=$( (PATH="$FSTUBS:$PATH" _reg_fetch_ca "u@h:/x/rootCA.pem" --ssh) 2>&1 )
rc=$?
if [ "$rc" -ne 0 ] && [ "$(cat "$regcreds_dir/rootCA.pem")" = OLD-CA ] && [ ! -e "$regcreds_dir/rootCA.pem.tmp" ]; then
	_ok "a failed CA fetch keeps the current rootCA.pem"
else
	_fail "failed fetch: rc=$rc ca=[$(cat "$regcreds_dir/rootCA.pem")] out=[$out]"
fi

printf '%s\n' reg_status=installed reg_vendor=quay reg_running=false last_action=load \
	"last_action_at='2026-01-02 03:04:05'" "reg_installed_at='2026-01-01 00:00:00'" > "$regcreds_dir/state.sh"
echo 'NEW-CA' > "$WORK/ca-src.pem"
(
	trust_root_ca() { echo "TRUST:$1" > "$WORK/trust.log"; }
	reg_post_upgrade "$WORK/ca-src.pem"
) >/dev/null 2>&1
if grep -qx 'reg_running=true' "$regcreds_dir/state.sh" \
	&& grep -qx 'last_action=load' "$regcreds_dir/state.sh" \
	&& grep -qx "last_action_at='2026-01-02 03:04:05'" "$regcreds_dir/state.sh" \
	&& grep -qx "reg_installed_at='2026-01-01 00:00:00'" "$regcreds_dir/state.sh" \
	&& [ "$(grep -c . "$regcreds_dir/state.sh")" = 6 ]; then
	_ok "post_upgrade sets reg_running=true and keeps last_action and reg_installed_at"
else
	_fail "post_upgrade state: [$(tr '\n' ' ' < "$regcreds_dir/state.sh")]"
fi
if [ "$(cat "$regcreds_dir/rootCA.pem")" = NEW-CA ] && grep -qx "TRUST:$regcreds_dir/rootCA.pem" "$WORK/trust.log"; then
	_ok "post_upgrade stores and trusts the CA"
else
	_fail "post_upgrade CA: [$(cat "$regcreds_dir/rootCA.pem")] trust=[$(cat "$WORK/trust.log" 2>/dev/null)]"
fi

echo "=== reg_quay_prepare_tarball ==="

tb="mirror-registry-$ARCH.tar.gz"

# make and run_once are stubbed: the download fails, as on a disconnected host.
# make logs whether the pin check runs for any reg_vendor.
_prep() {
	(
		cd "$1" || exit 97
		run_once() { return 1; }
		make() { echo "PIN=${QUAY_PIN_ANY_VENDOR:-} $*" >> make.log; return 2; }
		reg_quay_prepare_tarball
	) 2>&1
}

mkdir -p "$WORK/tb-missing"
out=$(_prep "$WORK/tb-missing")
rc=$?
if [ "$ARCH" = arm64 ]; then
	want='no Quay mirror-registry for aarch64'
else
	want="Copy $tb from the connected host"
fi
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qi "$want"; then
	_ok "missing tarball stops with the copy message"
else
	_fail "missing tarball: rc=$rc out=[$out]"
fi
if grep -qx 'PIN=1 --no-print-directory download-quay-tarball' "$WORK/tb-missing/make.log"; then
	_ok "download runs with QUAY_PIN_ANY_VENDOR=1"
else
	_fail "make call: [$(cat "$WORK/tb-missing/make.log" 2>/dev/null)]"
fi

if [ "$ARCH" != arm64 ]; then
	mkdir -p "$WORK/tb-src3" "$WORK/tb-v3"
	echo omr > "$WORK/tb-src3/mirror-registry"
	tar czf "$WORK/tb-v3/$tb" -C "$WORK/tb-src3" mirror-registry
	out=$(_prep "$WORK/tb-v3")
	rc=$?
	if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'not the pinned 2.x'; then
		_ok "tarball without execution-environment.tar stops"
	else
		_fail "3.x tarball: rc=$rc out=[$out]"
	fi

	mkdir -p "$WORK/tb-src2" "$WORK/tb-v2"
	echo new > "$WORK/tb-src2/mirror-registry"
	echo ee > "$WORK/tb-src2/execution-environment.tar"
	tar czf "$WORK/tb-v2/$tb" -C "$WORK/tb-src2" mirror-registry execution-environment.tar
	echo old > "$WORK/tb-v2/mirror-registry"
	out=$(_prep "$WORK/tb-v2")
	rc=$?
	if [ "$rc" -eq 0 ] && [ "$(cat "$WORK/tb-v2/mirror-registry")" = old ]; then
		_ok "2.x tarball passes, and the helper does not extract it"
	else
		_fail "2.x tarball: rc=$rc out=[$out]"
	fi
fi

echo "=== sandbox repo (dispatcher and aba.sh routing) ==="

REPO=$WORK/repo
SB_HOME=$WORK/home
STUBS=$WORK/stubs
mkdir -p "$REPO" "$SB_HOME/.aba" "$STUBS"
cp -a "$ROOT/scripts" "$REPO/scripts"
cp -f "$ROOT/Makefile" "$REPO/Makefile"
cp -f "$ROOT/VERSION" "$REPO/VERSION" 2>/dev/null
for d in templates others tui tools; do ln -s "$ROOT/$d" "$REPO/$d"; done
printf '%s\n' 'distribution=ocp' 'ocp_channel=stable' 'ocp_version=' 'ask=false' 'editor=none' > "$REPO/aba.conf"

# Stub vendor scripts: print which one ran.
for s in reg-upgrade-quay reg-upgrade-quay-remote cluster-upgrade; do
	printf '#!/bin/bash\necho "STUB:%s"\n' "$s" > "$REPO/scripts/$s.sh"
	chmod +x "$REPO/scripts/$s.sh"
done

# Stub make: log the directory and the arguments, do nothing.
cat > "$STUBS/make" <<EOF
#!/bin/bash
echo "\$PWD|\$*" >> "$WORK/make.log"
exit 0
EOF
chmod +x "$STUBS/make"

MIRROR=$REPO/mirror
mkdir -p "$MIRROR"
echo '# Mirror Makefile  # DO NOT remove this line!' > "$MIRROR/Makefile"
ln -s ../scripts "$MIRROR/scripts"
STATE=$SB_HOME/.aba/mirror/mirror/state.sh

_dispatch() {
	(
		cd "$MIRROR" || exit 97
		env HOME="$SB_HOME" timeout 20 scripts/reg-upgrade.sh
	) 2>&1
}

_state() {
	mkdir -p "$(dirname "$STATE")"
	printf '%s\n' "$@" > "$STATE"
}

rm -f "$STATE"
out=$(_dispatch)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qi 'not installed'; then _ok "no state.sh stops: not installed"; else _fail "no state: rc=$rc out=[$out]"; fi

_state reg_status=installing reg_vendor=quay reg_ssh_key=
out=$(_dispatch)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qi 'not installed'; then _ok "reg_status=installing stops"; else _fail "installing: rc=$rc out=[$out]"; fi

_state reg_vendor=existing reg_host=r.example.com
out=$(_dispatch)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qi 'not installed by ABA'; then _ok "existing registry stops"; else _fail "existing: rc=$rc out=[$out]"; fi

for v in omr docker; do
	_state reg_status=installed "reg_vendor=$v" reg_ssh_key=
	out=$(_dispatch)
	rc=$?
	if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'not supported yet'; then _ok "$v stops: not supported yet"; else _fail "$v: rc=$rc out=[$out]"; fi
done

_state reg_status=installed reg_vendor=quay reg_ssh_key= reg_root_opts=
out=$(_dispatch)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'no reg_root_opts'; then _ok "quay without reg_root_opts stops"; else _fail "no root opts: rc=$rc out=[$out]"; fi

_state reg_status=installed reg_vendor=quay reg_ssh_key= reg_root_opts=x
out=$(_dispatch)
if printf '%s\n' "$out" | grep -qx 'STUB:reg-upgrade-quay'; then _ok "local quay runs reg-upgrade-quay.sh"; else _fail "local quay: [$out]"; fi

_state reg_status=installed reg_vendor=quay reg_ssh_key=/home/u/.ssh/id_rsa reg_root_opts=x
out=$(_dispatch)
if printf '%s\n' "$out" | grep -qx 'STUB:reg-upgrade-quay-remote'; then _ok "remote quay runs reg-upgrade-quay-remote.sh"; else _fail "remote quay: [$out]"; fi

_aba_raw() {
	(
		cd "$REPO" || exit 97
		env -u ABA_ROOT HOME="$SB_HOME" PATH="$STUBS:$PATH" ABA_DO_NOT_UPDATE=1 \
			timeout 40 "$REPO/scripts/aba.sh" "$@" < /dev/null
	)
}
_aba() { _aba_raw "$@" 2>&1; }
# stdout only: help text is compared byte for byte.
_aba_stdout() { _aba_raw "$@" 2>/dev/null; }

: > "$WORK/make.log"
out=$(_aba -d mirror upgrade)
if grep -qx "$MIRROR|-s upgrade" "$WORK/make.log" && ! printf '%s\n' "$out" | grep -q 'STUB:cluster-upgrade'; then
	_ok "aba -d mirror upgrade runs make upgrade in the mirror dir"
else
	_fail "mirror upgrade: make.log=[$(cat "$WORK/make.log")] out=[$(printf '%s\n' "$out" | tail -3)]"
fi

: > "$WORK/make.log"
out=$(_aba -d mirror upgrade --dry-run)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'apply to cluster upgrade only' \
	&& ! cut -d'|' -f2 "$WORK/make.log" | grep -qw 'upgrade'; then
	_ok "aba -d mirror upgrade --dry-run stops: cluster upgrade flag"
else
	_fail "mirror upgrade --dry-run: rc=$rc make.log=[$(cat "$WORK/make.log")] out=[$(printf '%s\n' "$out" | tail -3)]"
fi

CLUSTER=$REPO/sno
mkdir -p "$CLUSTER"
echo '# Cluster Makefile' > "$CLUSTER/Makefile"
printf '%s\n' 'cluster_name=sno' 'base_domain=example.com' > "$CLUSTER/cluster.conf"
: > "$WORK/make.log"
out=$(_aba -d sno upgrade)
if printf '%s\n' "$out" | grep -qx 'STUB:cluster-upgrade' && ! cut -d'|' -f2 "$WORK/make.log" | grep -qw 'upgrade'; then
	_ok "aba -d <cluster> upgrade still runs cluster-upgrade.sh"
else
	_fail "cluster upgrade: make.log=[$(cat "$WORK/make.log")] out=[$(printf '%s\n' "$out" | tail -3)]"
fi

if [ "$(_aba_stdout -d mirror upgrade --help)" = "$(cat others/help-mirror.txt)" ]; then
	_ok "aba -d mirror upgrade --help prints help-mirror.txt"
else
	_fail "mirror upgrade --help did not print help-mirror.txt"
fi
if [ "$(_aba_stdout -d sno upgrade --help)" = "$(cat others/help-cluster.txt)" ]; then
	_ok "aba -d <cluster> upgrade --help still prints help-cluster.txt"
else
	_fail "cluster upgrade --help did not print help-cluster.txt"
fi

mkdir -p "$REPO/other"
out=$(_aba -d other upgrade)
if printf '%s\n' "$out" | grep -q 'Not in a cluster directory'; then
	_ok "a dir that is neither mirror nor cluster still gets the cluster guard"
else
	_fail "other dir: [$(printf '%s\n' "$out" | tail -3)]"
fi

echo "=== Makefile and help ==="

if grep -q '^upgrade:.*\.init' templates/Makefile.mirror && grep -q 'reg-upgrade.sh' templates/Makefile.mirror \
	&& grep -q 'progress-plan.sh upgrade' templates/Makefile.mirror; then
	_ok "Makefile.mirror has upgrade: .init -> progress plan -> reg-upgrade.sh"
else
	_fail "Makefile.mirror upgrade target missing"
fi
if grep -q 'aba \[-d mirror\] upgrade' others/help-mirror.txt && grep -q 'aba -d mirror upgrade' others/help-aba.txt; then
	_ok "help documents aba -d mirror upgrade"
else
	_fail "help does not document the mirror upgrade"
fi

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
