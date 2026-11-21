#!/bin/bash
# Test: aba options write the setting they claim, and nowhere else.
#
# Every run uses a throwaway repo and a throwaway HOME. Bastion aba.conf,
# mirror/mirror.conf, and ~/bin/aba are hashed first and must be unchanged
# at the end. A flag that needs a mirror or a cluster is pointed at a
# directory inside the throwaway repo.
#
# -v 1.1.1 does not write ocp_version: aba refuses a version the channel
# graph does not list. --upgrade-to 1.1.1 does write mirror.conf, because
# that flag only checks the version shape.
# -v with no value prints the aba version and does not touch aba.conf.
# -v <configured version> writes that version. The graph is read from a
# copy of the cache, so this does not download.

cd "$(dirname "$0")/../.." || exit 1
ROOT=$PWD

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
_fail() { fail=$(( fail + 1 )); printf '  \033[31mFAIL\033[0m  %s\n' "$*"; }

ORIG_HOME=$HOME
WORK=$(mktemp -d /tmp/aba-flag-effects.XXXXXX)
SANDBOX_HOME=$WORK/home
REPO=$WORK/repo
SECRET=$WORK/pull-secret.json
KEY1=$WORK/id_rsa
KEY2=$WORK/id_rsa2
VMW=$WORK/vmware.src
KVM=$WORK/kvm.src

_val() {
	local file=$1 key=$2
	grep -E "^${key}=" "$file" 2>/dev/null | head -1 | sed 's/[[:space:]]*#.*//' | cut -d= -f2-
}

_hash() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

H_ABA=$(_hash "$ROOT/aba.conf")
H_MIRROR=$(_hash "$ROOT/mirror/mirror.conf")
H_BIN=$(_hash "$ORIG_HOME/bin/aba")

cleanup() {
	# Put bastion files back if a flag escaped the sandbox.
	if [ -n "$H_ABA" ] && [ "$(_hash "$ROOT/aba.conf")" != "$H_ABA" ]; then
		cp -f "$WORK/guard/aba.conf" "$ROOT/aba.conf"
	fi
	if [ -n "$H_MIRROR" ] && [ -f "$ROOT/mirror/mirror.conf" ] && [ "$(_hash "$ROOT/mirror/mirror.conf")" != "$H_MIRROR" ]; then
		cp -f "$WORK/guard/mirror.conf" "$ROOT/mirror/mirror.conf"
	fi
	if [ -n "$H_BIN" ] && [ "$(_hash "$ORIG_HOME/bin/aba")" != "$H_BIN" ]; then
		cp -f "$WORK/guard/bin-aba" "$ORIG_HOME/bin/aba"
		chmod 755 "$ORIG_HOME/bin/aba"
	fi
	rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$WORK/guard" "$SANDBOX_HOME/.aba" "$REPO/mirror" "$REPO/cluster" "$REPO/cli" "$WORK/regdata"
[ -f "$ROOT/aba.conf" ] && cp -f "$ROOT/aba.conf" "$WORK/guard/aba.conf"
[ -f "$ROOT/mirror/mirror.conf" ] && cp -f "$ROOT/mirror/mirror.conf" "$WORK/guard/mirror.conf"
[ -f "$ORIG_HOME/bin/aba" ] && cp -f "$ORIG_HOME/bin/aba" "$WORK/guard/bin-aba"

# Real script bodies, so `pwd -P` inside aba stays in the sandbox.
cp -a "$ROOT/scripts" "$REPO/scripts"
cp -f "$ROOT/Makefile" "$REPO/Makefile"
cp -f "$ROOT/VERSION" "$REPO/VERSION"
ln -s "$ROOT/others" "$REPO/others"
ln -s "$ROOT/templates" "$REPO/templates"
ln -s "$ROOT/tui" "$REPO/tui"
ln -s "$ROOT/tools" "$REPO/tools"
ln -s "$ROOT/cli/Makefile" "$REPO/cli/Makefile"
ln -s "$ROOT/templates/Makefile.mirror" "$REPO/mirror/Makefile"
ln -s "$ROOT/templates/Makefile.cluster" "$REPO/cluster/Makefile"

if [ -f "$ROOT/aba.conf" ]; then
	cp -f "$ROOT/aba.conf" "$REPO/aba.conf"
else
	printf '%s\n' 'ocp_channel=fast' 'ocp_version=4.22.22' 'ask=false' 'editor=vi' >"$REPO/aba.conf"
fi
# Flag writes under test are OpenShift (--upgrade-to, --to X.Y.Z).
# A checkout aba.conf may set distribution=okd, which rejects both, and
# its version string is not a valid OpenShift version.
if grep -q '^distribution=' "$REPO/aba.conf"; then
	sed -i 's/^distribution=.*/distribution=ocp/' "$REPO/aba.conf"
else
	printf 'distribution=ocp\n' >>"$REPO/aba.conf"
fi
if grep -q '^ocp_version=' "$REPO/aba.conf"; then
	sed -i 's/^ocp_version=.*/ocp_version=4.22.22/' "$REPO/aba.conf"
else
	echo 'ocp_version=4.22.22' >>"$REPO/aba.conf"
fi

cat >"$REPO/mirror/mirror.conf" << 'EOF'
reg_host=registry.example.com
reg_port=8443
reg_path=
reg_user=init
reg_pw=initpw
reg_vendor=docker
data_dir=/var/tmp/aba-flag-data
reg_ssh_key=
reg_ssh_user=
ocp_upgrade_to=
EOF
printf '%s\n' '# sandbox cluster' >"$REPO/cluster/cluster.conf"
touch -d '2 minutes ago' "$REPO/mirror/.init"
touch "$REPO/mirror/mirror.conf"

printf '%s\n' '{"auths":{}}' >"$SECRET"
: >"$KEY1"
: >"$KEY2"
printf '%s\n' 'vmware-flag-test' >"$VMW"
printf '%s\n' 'kvm-flag-test' >"$KVM"

# Reuse the bastion graph cache and completed download tasks so -v does
# not fetch Cincinnati or start catalog downloads.
if [ -d "$ORIG_HOME/.aba/cache" ]; then
	cp -a "$ORIG_HOME/.aba/cache" "$SANDBOX_HOME/.aba/cache"
fi
if [ -d "$ORIG_HOME/.aba/runner" ]; then
	cp -a "$ORIG_HOME/.aba/runner" "$SANDBOX_HOME/.aba/runner"
	find "$SANDBOX_HOME/.aba/runner" -name exit -exec touch {} +
fi

SNAP_ABA=$WORK/snap-aba.conf
SNAP_MIRROR=$WORK/snap-mirror.conf
SNAP_CLUSTER=$WORK/snap-cluster.conf
cp -f "$REPO/aba.conf" "$SNAP_ABA"
cp -f "$REPO/mirror/mirror.conf" "$SNAP_MIRROR"
cp -f "$REPO/cluster/cluster.conf" "$SNAP_CLUSTER"
: >"$WORK/covered"

VER=$(_val "$SNAP_ABA" ocp_version)
ABA_VER=$(sed -n 's/^ABA_VERSION=//p' "$REPO/scripts/aba.sh" | head -1)

_reset() {
	cp -f "$SNAP_ABA" "$REPO/aba.conf"
	cp -f "$SNAP_MIRROR" "$REPO/mirror/mirror.conf"
	cp -f "$SNAP_CLUSTER" "$REPO/cluster/cluster.conf"
	rm -f "$REPO/vmware.conf" "$REPO/kvm.conf" "$REPO/cluster/vmware.conf" "$REPO/cluster/kvm.conf"
}

_prep=
_ask_true() { sed -i -E 's/^ask=.*/ask=true/' "$REPO/aba.conf"; }

_invoke() {
	local _a
	_reset
	if [ -n "${_prep:-}" ]; then
		"$_prep"
		_prep=
	fi
	(
		cd "$REPO" || exit 97
		env -u ABA_ROOT \
			HOME="$SANDBOX_HOME" \
			ABA_DO_NOT_UPDATE=1 \
			ABA_CACHE_TTL=10000h \
			timeout 40 "$REPO/scripts/aba.sh" "$@"
	) >"$WORK/out" 2>"$WORK/err"
	printf '%s\n' "$?" >"$WORK/rc"
	for _a in "$@"; do
		case "$_a" in
			--*|-[A-Za-z]) printf '%s\n' "$_a" >>"$WORK/covered" ;;
		esac
	done
}

_rc() { cat "$WORK/rc"; }

_show_err() { sed -n '1,10p' "$WORK/err" | sed 's/^/    /'; }

_run() {
	local desc=$1
	shift
	_invoke "$@"
	if [ "$(_rc)" -ne 0 ]; then
		_fail "$desc (exit $(_rc))"
		_show_err
		return 1
	fi
	return 0
}

_expect() {
	local file=$1 key=$2 exp=$3 got
	got=$(_val "$file" "$key")
	if [ "$got" = "$exp" ]; then
		_pass "$key=$exp"
	else
		_fail "$key expected [$exp] got [$got]"
	fi
}

_unchanged() {
	local desc=$1
	if cmp -s "$SNAP_ABA" "$REPO/aba.conf" \
		&& cmp -s "$SNAP_MIRROR" "$REPO/mirror/mirror.conf" \
		&& cmp -s "$SNAP_CLUSTER" "$REPO/cluster/cluster.conf" \
		&& [ ! -f "$REPO/vmware.conf" ] && [ ! -f "$REPO/kvm.conf" ]; then
		_pass "$desc leaves config unchanged"
	else
		_fail "$desc changed a config file"
	fi
}

_same() {
	local desc=$1
	shift
	if _run "$desc" "$@"; then
		_unchanged "$desc"
	fi
}

echo "=== aba flag effects (sandbox) ==="

# --- version ---------------------------------------------------------------
if _run "--aba-version" --aba-version; then
	if grep -q "version $ABA_VER" "$WORK/out"; then
		_pass "--aba-version prints $ABA_VER"
	else
		_fail "--aba-version output did not contain version $ABA_VER"
	fi
	_unchanged "--aba-version"
fi

if _run "-v alone" -v; then
	if grep -q "aba $ABA_VER" "$WORK/out"; then
		_pass "-v alone prints aba $ABA_VER"
	else
		_fail "-v alone output did not contain aba $ABA_VER"
	fi
	_unchanged "-v alone"
fi

_invoke -v 1.1.1 --help
if [ "$(_rc)" -ne 0 ] && [ "$(_val "$REPO/aba.conf" ocp_version)" = "$VER" ]; then
	_pass "-v 1.1.1 is rejected and ocp_version stays $VER"
else
	_fail "-v 1.1.1 should be rejected without writing ocp_version (exit $(_rc))"
	_show_err
fi

if [ -n "$VER" ]; then
	if _run "--version $VER" --version "$VER" --help; then
		_expect "$REPO/aba.conf" ocp_version "$VER"
	fi
else
	_fail "aba.conf has no ocp_version to round-trip"
fi

# --- aba.conf --------------------------------------------------------------
if _run "aba.conf long flags" \
	--channel candidate \
	--base-domain Lab.Example \
	--machine-network 10.8.0.0/16 \
	--dns 10.1.0.8 10.1.0.9 \
	--ntp time.example.com \
	--gateway 10.8.0.1 \
	--platform kvm \
	--op-sets virt \
	--ops local-storage-operator \
	--verify off \
	--excl-platform true \
	--editor vi \
	--pull-secret "$SECRET" \
	--ask \
	--help
then
	_expect "$REPO/aba.conf" ocp_channel candidate
	_expect "$REPO/aba.conf" domain lab.example
	_expect "$REPO/aba.conf" machine_network 10.8.0.0/16
	_expect "$REPO/aba.conf" dns_servers 10.1.0.8,10.1.0.9
	_expect "$REPO/aba.conf" ntp_servers time.example.com
	_expect "$REPO/aba.conf" next_hop_address 10.8.0.1
	_expect "$REPO/aba.conf" platform kvm
	_expect "$REPO/aba.conf" op_sets virt
	_expect "$REPO/aba.conf" ops local-storage-operator
	_expect "$REPO/aba.conf" verify_conf off
	_expect "$REPO/aba.conf" excl_platform true
	_expect "$REPO/aba.conf" editor vi
	_expect "$REPO/aba.conf" pull_secret_file "$SECRET"
	_expect "$REPO/aba.conf" ask true
fi

if _run "aba.conf short flags" \
	-c stable \
	-b Example.ORG \
	-M 10.9.0.0/20 \
	-N 10.2.0.8 \
	-T 10.2.0.9 \
	--gateway-ip 10.9.0.1 \
	-g 10.4.0.1 \
	-p bm \
	-P all \
	-O quay-operator \
	--verify conf \
	--excl-platform false \
	-e vi \
	-S "$SECRET" \
	-a \
	--domain example.com \
	--help
then
	_expect "$REPO/aba.conf" ocp_channel stable
	_expect "$REPO/aba.conf" domain example.com
	_expect "$REPO/aba.conf" machine_network 10.9.0.0/20
	_expect "$REPO/aba.conf" dns_servers 10.2.0.8
	_expect "$REPO/aba.conf" ntp_servers 10.2.0.9
	_expect "$REPO/aba.conf" next_hop_address 10.4.0.1
	_expect "$REPO/aba.conf" platform bm
	_expect "$REPO/aba.conf" op_sets all
	_expect "$REPO/aba.conf" ops quay-operator
	_expect "$REPO/aba.conf" verify_conf conf
	_expect "$REPO/aba.conf" excl_platform false
	_expect "$REPO/aba.conf" ask true
fi

if _run "--interactive" --interactive --help; then
	_expect "$REPO/aba.conf" ask true
fi

_prep=_ask_true
if _run "--noask" --noask --help; then
	_expect "$REPO/aba.conf" ask false
fi

_prep=_ask_true
if _run "--yes-permanent" --yes-permanent --help; then
	_expect "$REPO/aba.conf" ask false
fi

_prep=_ask_true
if _run "-Y" -Y --help; then
	_expect "$REPO/aba.conf" ask false
fi

# --- mirror.conf -----------------------------------------------------------
if _run "mirror.conf long flags" --dir mirror \
	--reg-user flaguser \
	--reg-port 8445 \
	--vendor docker \
	--data-dir "$WORK/regdata" \
	--reg-host registry.example.com \
	--reg-ssh-key "$KEY1" \
	--reg-ssh-user flagssh \
	--reg-path mirrorpath \
	--reg-password 'FlagPass.1' \
	--upgrade-to 1.1.1 \
	--help
then
	_expect "$REPO/mirror/mirror.conf" reg_user flaguser
	_expect "$REPO/mirror/mirror.conf" reg_port 8445
	_expect "$REPO/mirror/mirror.conf" reg_vendor docker
	_expect "$REPO/mirror/mirror.conf" data_dir "$WORK/regdata"
	_expect "$REPO/mirror/mirror.conf" reg_host registry.example.com
	_expect "$REPO/mirror/mirror.conf" reg_ssh_key "$KEY1"
	_expect "$REPO/mirror/mirror.conf" reg_ssh_user flagssh
	_expect "$REPO/mirror/mirror.conf" reg_path /mirrorpath
	_expect "$REPO/mirror/mirror.conf" reg_pw "'FlagPass.1'"
	_expect "$REPO/mirror/mirror.conf" ocp_upgrade_to 1.1.1
fi

if _run "mirror.conf short flags" -d mirror \
	-u aliasuser \
	-H mirror.example.com \
	-k "$KEY2" \
	-U aliasssh \
	--help
then
	_expect "$REPO/mirror/mirror.conf" reg_user aliasuser
	_expect "$REPO/mirror/mirror.conf" reg_host mirror.example.com
	_expect "$REPO/mirror/mirror.conf" reg_ssh_key "$KEY2"
	_expect "$REPO/mirror/mirror.conf" reg_ssh_user aliasssh
fi

if _run "--mirror-hostname" --dir mirror --mirror-hostname host3.example.com --help; then
	_expect "$REPO/mirror/mirror.conf" reg_host host3.example.com
fi

_invoke --reg-port 9 --help
if [ "$(_rc)" -ne 0 ]; then
	_pass "--reg-port outside a mirror directory is rejected"
	_unchanged "--reg-port outside a mirror directory"
else
	_fail "--reg-port outside a mirror directory was accepted"
fi

_invoke --dir mirror --data-dir relative --help
if [ "$(_rc)" -ne 0 ] && cmp -s "$SNAP_MIRROR" "$REPO/mirror/mirror.conf"; then
	_pass "--data-dir relative is rejected"
else
	_fail "--data-dir relative should be rejected without writing mirror.conf"
fi

# --- cluster.conf ----------------------------------------------------------
if _run "cluster.conf long flags" --dir cluster \
	--mcpu 8 \
	--mmem 16 \
	--wcpu 4 \
	--wmem 32 \
	--api-vip 10.0.0.8 \
	--ingress-vip 10.0.0.9 \
	--starting-ip 10.0.0.20 \
	--ports eth0 \
	--vlan 100 \
	--mac-prefix '52:54:00:xx:xx:' \
	--host-prefix 24 \
	--master-prefix mst \
	--worker-prefix wrk \
	--ssh-key "$KEY1" \
	--image-source proxy \
	--num-workers 5 \
	--num-masters 3 \
	--disk-hint /dev/sda \
	--bond-mode active-backup \
	--data-disk 100 \
	--help
then
	C=$REPO/cluster/cluster.conf
	_expect "$C" master_cpu_count 8
	_expect "$C" master_mem 16
	_expect "$C" worker_cpu_count 4
	_expect "$C" worker_mem 32
	_expect "$C" api_vip 10.0.0.8
	_expect "$C" ingress_vip 10.0.0.9
	_expect "$C" starting_ip 10.0.0.20
	_expect "$C" ports eth0
	_expect "$C" vlan 100
	_expect "$C" mac_prefix '52:54:00:xx:xx:'
	_expect "$C" hostPrefix 24
	_expect "$C" master_prefix mst
	_expect "$C" worker_prefix wrk
	_expect "$C" ssh_key_file "$KEY1"
	_expect "$C" image_source proxy
	_expect "$C" num_workers 5
	_expect "$C" num_masters 3
	_expect "$C" disk_hint /dev/sda
	_expect "$C" bond_mode active-backup
	_expect "$C" data_disk 100
fi

if _run "cluster.conf short and alias flags" --dir cluster \
	--master-cpu 9 \
	--master-memory 17 \
	--worker-cpu 5 \
	--worker-memory 33 \
	-A 10.0.0.08 \
	-G 10.0.0.19 \
	-i 10.0.0.21 \
	--disk-hint-master /dev/nvme0n1 \
	--disk-hint-worker /dev/sdb \
	--bond-mode-master 802.3ad \
	--bond-mode-worker balance-xor \
	--data-disk-gb 110 \
	-W 6 \
	--help
then
	C=$REPO/cluster/cluster.conf
	_expect "$C" master_cpu_count 9
	_expect "$C" master_mem 17
	_expect "$C" worker_cpu_count 5
	_expect "$C" worker_mem 33
	_expect "$C" api_vip 10.0.0.8
	_expect "$C" ingress_vip 10.0.0.19
	_expect "$C" starting_ip 10.0.0.21
	_expect "$C" disk_hint_master /dev/nvme0n1
	_expect "$C" disk_hint_worker /dev/sdb
	_expect "$C" bond_mode_master 802.3ad
	_expect "$C" bond_mode_worker balance-xor
	_expect "$C" data_disk 110
	_expect "$C" num_workers 6
fi

if _run "--mirror-name" --dir cluster --mirror-name enclave1 --help; then
	_expect "$REPO/cluster/cluster.conf" image_source enclave1
fi
if _run "--int-connection default" --dir cluster --int-connection --help; then
	_expect "$REPO/cluster/cluster.conf" image_source mirror
fi
if _run "-I p" --dir cluster -I p --help; then
	_expect "$REPO/cluster/cluster.conf" image_source proxy
fi

if _run "--vmware" --vmware "$VMW" --help; then
	cmp -s "$VMW" "$REPO/vmware.conf" && _pass "--vmware copies the file" || _fail "--vmware file mismatch"
fi
if _run "--vmw" --vmw "$VMW" --help; then
	cmp -s "$VMW" "$REPO/vmware.conf" && _pass "--vmw copies the file" || _fail "--vmw file mismatch"
fi
if _run "-V" -V "$VMW" --help; then
	cmp -s "$VMW" "$REPO/vmware.conf" && _pass "-V copies the file" || _fail "-V file mismatch"
fi
if _run "--kvm" --kvm "$KVM" --help; then
	cmp -s "$KVM" "$REPO/kvm.conf" && _pass "--kvm copies the file" || _fail "--kvm file mismatch"
fi
if _run "-K" -K "$KVM" --help; then
	cmp -s "$KVM" "$REPO/kvm.conf" && _pass "-K copies the file" || _fail "-K file mismatch"
fi

# Flags that only select make behaviour. --help exits before make runs,
# so the effect we can see is: accepted, and no config file changes.
_same "behaviour switches" \
	--quiet --info --debug --light --lite --delete-data \
	--yes --shell --force --wait --workers --masters --start \
	--dry-run --validate --skip-day2 --allow-not-recommended \
	--primed --all --retry 2 --help

_same "short behaviour switches" -q -D -f -w -y -r 4 -h

_same "make arguments" \
	--out "$WORK/bundleout" \
	-o "$WORK/bundleout" \
	--cmd get \
	--to 1.2.3 \
	--pull-secret-mirror "$SECRET" \
	--ca-cert "$SECRET" \
	cluster --name flagcl -n flagcl2 -t sno --type compact --step save -s save \
	--help

_invoke --pull-secret-mirror "$WORK/no-such-secret" --help
if [ "$(_rc)" -ne 0 ]; then
	_pass "--pull-secret-mirror missing file is rejected"
else
	_fail "--pull-secret-mirror missing file was accepted"
fi

_invoke --ca-cert "$WORK/no-such-ca" --help
if [ "$(_rc)" -ne 0 ]; then
	_pass "--ca-cert missing file is rejected"
else
	_fail "--ca-cert missing file was accepted"
fi

# A missing -d name with a state backup is recreated at that path.
mkdir -p "$SANDBOX_HOME/.aba/clusters/ghost.example.com/backup"
printf '%s\n' 'cluster_name=ghost' 'base_domain=example.com' >"$SANDBOX_HOME/.aba/clusters/ghost.example.com/state.sh"
printf '%s\n' 'cluster_name=ghost' >"$SANDBOX_HOME/.aba/clusters/ghost.example.com/backup/cluster.conf"
_invoke --dir ghost info
if [ -s "$REPO/ghost/cluster.conf" ] && grep -qx 'cluster_name=ghost' "$REPO/ghost/cluster.conf"; then
	_pass "--dir missing cluster is recreated from its state backup"
else
	_fail "--dir missing cluster was not recreated from state"
	_show_err
fi
_invoke --dir no-such-cluster-name info
if [ "$(_rc)" -ne 0 ] && [ ! -d "$REPO/no-such-cluster-name" ]; then
	_pass "--dir missing name with no backup aborts"
else
	_fail "--dir missing name with no backup rc=$(_rc)"
fi
# From a mirror dir the same backup must not create mirror/<name>.
mkdir -p "$SANDBOX_HOME/.aba/clusters/sidecluster.example.com/backup"
printf '%s\n' 'cluster_name=sidecluster' 'base_domain=example.com' >"$SANDBOX_HOME/.aba/clusters/sidecluster.example.com/state.sh"
printf '%s\n' 'cluster_name=sidecluster' >"$SANDBOX_HOME/.aba/clusters/sidecluster.example.com/backup/cluster.conf"
(
	cd "$REPO/mirror" || exit 97
	env -u ABA_ROOT HOME="$SANDBOX_HOME" ABA_DO_NOT_UPDATE=1 ABA_CACHE_TTL=10000h \
		timeout 40 "$REPO/scripts/aba.sh" --dir sidecluster info
) >"$WORK/out" 2>"$WORK/err"
printf '%s\n' "$?" >"$WORK/rc"
if [ "$(_rc)" -ne 0 ] && [ ! -d "$REPO/mirror/sidecluster" ] && [ ! -d "$REPO/sidecluster" ]; then
	_pass "--dir from a mirror dir does not recreate a cluster there"
else
	_fail "--dir from a mirror dir rc=$(_rc) mirror/sidecluster=$(test -d "$REPO/mirror/sidecluster" && echo yes || echo no)"
	_show_err
fi

# image add: repo root writes the repo file. A mirror directory writes its own.
_invoke image add registry.redhat.io/ubi9/ubi:latest
if [ "$(_rc)" -eq 0 ] && grep -qxF 'registry.redhat.io/ubi9/ubi:latest' "$REPO/images.conf"; then
	_pass "image add from the repo root writes images.conf"
else
	_fail "image add from the repo root did not write images.conf"
fi
(
	cd "$REPO/mirror" || exit 97
	env -u ABA_ROOT HOME="$SANDBOX_HOME" ABA_DO_NOT_UPDATE=1 ABA_CACHE_TTL=10000h \
		timeout 40 "$REPO/scripts/aba.sh" image add docker.io/library/nginx:latest
) >"$WORK/out" 2>"$WORK/err"
printf '%s\n' "$?" >"$WORK/rc"
if [ "$(_rc)" -eq 0 ] && grep -qxF 'docker.io/library/nginx:latest' "$REPO/mirror/images.conf" \
	&& ! grep -qxF 'docker.io/library/nginx:latest' "$REPO/images.conf"; then
	_pass "image add inside a mirror dir writes that images.conf"
else
	_fail "image add inside a mirror dir wrote the wrong images.conf"
	_show_err
fi
(
	cd "$REPO/mirror" || exit 97
	env -u ABA_ROOT HOME="$SANDBOX_HOME" ABA_DO_NOT_UPDATE=1 ABA_CACHE_TTL=10000h \
		timeout 40 "$REPO/scripts/aba.sh" -d mirror image add docker.io/library/nginx:latest
) >"$WORK/out" 2>"$WORK/err"
printf '%s\n' "$?" >"$WORK/rc"
if [ "$(_rc)" -ne 0 ]; then
	_pass "-d mirror from inside the mirror dir is rejected"
else
	_fail "-d mirror from inside the mirror dir was accepted"
fi

# --- every parser flag was exercised ---------------------------------------
grep -oE '"-{1,2}[A-Za-z][A-Za-z0-9-]*"' "$REPO/scripts/aba.sh" | tr -d '"' | sort -u >"$WORK/parser"
sort -u "$WORK/covered" >"$WORK/covered.u"
missing=$(comm -23 "$WORK/parser" "$WORK/covered.u")
if [ -z "$missing" ]; then
	_pass "every flag named in scripts/aba.sh was exercised"
else
	_fail "flags never passed to aba:"
	printf '    %s\n' $missing
fi

# --- bastion files ---------------------------------------------------------
if [ -n "$H_ABA" ]; then
	if [ "$(_hash "$ROOT/aba.conf")" = "$H_ABA" ]; then
		_pass "bastion aba.conf unchanged"
	else
		_fail "bastion aba.conf was modified"
	fi
fi
if [ -n "$H_MIRROR" ]; then
	if [ "$(_hash "$ROOT/mirror/mirror.conf")" = "$H_MIRROR" ]; then
		_pass "bastion mirror.conf unchanged"
	else
		_fail "bastion mirror.conf was modified"
	fi
fi
if [ -n "$H_BIN" ]; then
	if [ "$(_hash "$ORIG_HOME/bin/aba")" = "$H_BIN" ]; then
		_pass "bastion ~/bin/aba unchanged"
	else
		_fail "bastion ~/bin/aba was modified"
	fi
fi

echo
echo "Results: $pass passed, $fail failed"
exit "$fail"
