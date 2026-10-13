#!/bin/bash
# Disk verdicts for save, sync, and load.
# Fake df, du, and ssh. The size number comes from estimate-isc-size.sh.
# Plenty: free space is at least 30% above the need.
# Tight: free space covers the need, but by less than 30%.
# Short: free space is below the need.

set -u
cd "$(dirname "$0")/../.."

fail=0
check() {
	local name=$1 got=$2 want=$3
	if [ "$got" = "$want" ]; then
		echo "  PASS: $name"
	else
		echo "  FAIL: $name"
		echo "    got  [$got]"
		echo "    want [$want]"
		fail=$((fail + 1))
	fi
}

# Same rounding as mirror-status.sh: next whole GB, or MB under 1 GB.
disk_amt() {
	local n=${1:-0}
	local gb=$((1024 * 1024 * 1024))
	local mb=$((1024 * 1024))
	if [ "$n" -le 0 ]; then
		echo "0 MB"
		return
	fi
	if [ "$n" -ge "$gb" ]; then
		echo "$(( (n + gb - 1) / gb )) GB"
	else
		echo "$(( (n + mb - 1) / mb )) MB"
	fi
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

MIRROR=$tmp/disktest
CACHE=$tmp/cache
REGDIR=$tmp/regdata
ARCH=$MIRROR/data
REG=$REGDIR/quay-install
MAP=$tmp/df.map
GIB=$((1024 * 1024 * 1024))

mkdir -p "$tmp/bin" "$tmp/home" "$ARCH" "$CACHE" "$REG"
ln -s "$PWD/scripts" "$MIRROR/scripts"
touch "$tmp/id_rsa"

cat > "$tmp/bin/df" << 'EOF'
#!/bin/bash
mode=p
path=""
for a in "$@"; do
	case "$a" in
		-B1|--output=avail) mode=avail ;;
		-P) mode=p ;;
		-*) ;;
		*) path=$a ;;
	esac
done
line=""
while IFS='|' read -r p dev mnt avail; do
	[ "$p" = "$path" ] && line="$dev|$mnt|$avail"
done < "${FAKE_DF_MAP:?}"
if [ -z "$line" ]; then
	echo "fake df: unmapped [$path]" >&2
	exit 1
fi
dev=${line%%|*}
rest=${line#*|}
mnt=${rest%%|*}
avail=${rest#*|}
if [ "$mode" = avail ]; then
	printf 'Avail\n%s\n' "$avail"
else
	printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n%s 1 1 1 1%% %s\n' "$dev" "$mnt"
fi
EOF

cat > "$tmp/bin/du" << 'EOF'
#!/bin/bash
dir=""
for a in "$@"; do
	case "$a" in
		-*) ;;
		*) dir=$a ;;
	esac
done
printf '%s\t%s\n' "${FAKE_DU_BYTES:-0}" "$dir"
EOF

cat > "$tmp/bin/ssh" << 'EOF'
#!/bin/bash
if [ "${FAKE_SSH_FAIL:-}" = 1 ]; then
	exit 1
fi
printf 'Avail\n%s\n' "${FAKE_REMOTE_AVAIL:-0}"
EOF
chmod +x "$tmp/bin/df" "$tmp/bin/du" "$tmp/bin/ssh"

cat > "$ARCH/imageset-config.yaml" << 'EOF'
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  platform:
    channels:
    - name: stable-4.22
      minVersion: 4.22.15
      maxVersion: 4.22.15
EOF

export HOME=$tmp/home
export PATH="$tmp/bin:$PATH"
export OC_MIRROR_CACHE=$CACHE
export FAKE_DF_MAP=$MAP
export FAKE_DU_BYTES=0
export FAKE_REMOTE_AVAIL=0
export FAKE_SSH_FAIL=""

# shellcheck disable=SC1090
eval "$(scripts/estimate-isc-size.sh --shell --isc "$ARCH/imageset-config.yaml")"
content=$estimate_bytes
free80=$((80 * GIB))
free55=$((55 * GIB))
free40=$((40 * GIB))
free30=$((30 * GIB))
free10=$((10 * GIB))
free1=$((1 * GIB))
bar=$((content * 13 / 10))

write_state() {
	mkdir -p "$HOME/.aba/mirror/disktest"
	printf 'reg_vendor=%s\n' "$1" > "$HOME/.aba/mirror/disktest/state.sh"
}

write_local_conf() {
	cat > "$MIRROR/mirror.conf" << EOF
reg_host=reg.example.com
reg_port=8443
reg_ssh_user=mirror
data_dir=$REGDIR
reg_vendor=quay
EOF
	write_state quay
}

write_remote_conf() {
	cat > "$MIRROR/mirror.conf" << EOF
reg_host=reg.example.com
reg_port=8443
reg_ssh_user=mirror
reg_ssh_key=$tmp/id_rsa
data_dir=~
reg_vendor=quay
EOF
	write_state quay
}

write_existing_conf() {
	cat > "$MIRROR/mirror.conf" << EOF
reg_host=reg.example.com
reg_port=8443
reg_ssh_user=mirror
data_dir=$REGDIR
reg_vendor=existing
EOF
	write_state existing
}

set_df() {
	: > "$MAP"
	while [ $# -ge 4 ]; do
		printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" >> "$MAP"
		shift 4
	done
}

clear_cache() {
	rm -rf "$CACHE/.oc-mirror"
	FAKE_DU_BYTES=0
}

fill_cache() {
	mkdir -p "$CACHE/.oc-mirror/.cache"
	FAKE_DU_BYTES=$content
}

disk_save_summary=""
disk_save_short=""
disk_save_level=""
disk_sync_summary=""
disk_sync_short=""
disk_sync_level=""
disk_load_summary=""
disk_load_short=""
disk_load_level=""

load_shell() {
	local err=$tmp/err rc=0
	shell_out=$(cd "$MIRROR" && scripts/mirror-status.sh --shell 2>"$err") || rc=$?
	if [ "$rc" -ne 0 ]; then
		echo "  FAIL: mirror-status --shell exited $rc"
		cat "$err" >&2
		fail=$((fail + 1))
		return 1
	fi
	# shellcheck disable=SC1090
	eval "$shell_out"
}

echo "=== plenty of room on one volume ==="
write_local_conf
clear_cache
set_df \
	"$ARCH" dev-home /home "$free80" \
	"$CACHE" dev-home /home "$free80" \
	"$REG" dev-data /data "$free80"
load_shell
check "save is plenty" "$disk_save_level" "ok"
check "sync is plenty" "$disk_sync_level" "ok"
check "load is plenty" "$disk_load_level" "ok"
check "save stays quiet when space looks fine" "$disk_save_summary" ""
check "sync stays quiet when space looks fine" "$disk_sync_summary" ""
check "load stays quiet when space looks fine" "$disk_load_summary" ""
check "save is not a warning" "$disk_save_short" "false"

echo "=== save is tight when archive and cache share a volume ==="
set_df \
	"$ARCH" dev-home /home "$free55" \
	"$CACHE" dev-home /home "$free55" \
	"$REG" dev-data /data "$free80"
load_shell
check "save is tight" "$disk_save_level" "tight"
check "save names the combined size" "$disk_save_summary" \
	"Estimate: this save may need about $(disk_amt $((content + content))) more on /home ($(disk_amt "$free55") free)."
check "sync stays plenty" "$disk_sync_level" "ok"
check "tight save is not a warning flag" "$disk_save_short" "false"

echo "=== save is short on that shared volume ==="
set_df \
	"$ARCH" dev-home /home "$free40" \
	"$CACHE" dev-home /home "$free40" \
	"$REG" dev-data /data "$free80"
load_shell
check "save is short" "$disk_save_level" "short"
check "save warning names the combined size" "$disk_save_summary" \
	"DISK SPACE WARNING. Estimate: this save may need about $(disk_amt $((content + content))) more on /home ($(disk_amt "$free40") free)."
check "save warning flag" "$disk_save_short" "true"
check "sync still plenty" "$disk_sync_level" "ok"

echo "=== root filesystem is named ==="
set_df \
	"$ARCH" dev-root / "$free40" \
	"$CACHE" dev-root / "$free40" \
	"$REG" dev-data /data "$free80"
load_shell
check "root mount is named" "$disk_save_summary" \
	"DISK SPACE WARNING. Estimate: this save may need about $(disk_amt $((content + content))) more on / (root) ($(disk_amt "$free40") free)."

echo "=== cache already filled is not counted again ==="
fill_cache
set_df \
	"$ARCH" dev-home /home "$free30" \
	"$CACHE" dev-home /home "$free30" \
	"$REG" dev-data /data "$free80"
load_shell
check "filled cache leaves save tight, not short" "$disk_save_level" "tight"
check "save counts only the archive" "$disk_save_summary" \
	"Estimate: this save may need about $(disk_amt "$content") more on /home ($(disk_amt "$free30") free)."
clear_cache

echo "=== cache volume is short while the archive volume is fine ==="
set_df \
	"$ARCH" dev-home /home "$free80" \
	"$CACHE" dev-var /var "$free10" \
	"$REG" dev-data /data "$free80"
load_shell
check "save warns on the cache volume" "$disk_save_level" "short"
check "save names only the short volume" "$disk_save_summary" \
	"DISK SPACE WARNING. Estimate: this save may need about $(disk_amt "$content") more on /var ($(disk_amt "$free10") free)."
check "sync on the registry volume is plenty" "$disk_sync_level" "ok"

echo "=== registry volume is short while this machine is fine ==="
set_df \
	"$ARCH" dev-home /home "$free80" \
	"$CACHE" dev-home /home "$free80" \
	"$REG" dev-data /data "$free1"
load_shell
check "save ignores the registry disk" "$disk_save_level" "ok"
check "sync warns on the registry volume" "$disk_sync_level" "short"
check "sync names the registry mount" "$disk_sync_summary" \
	"DISK SPACE WARNING. Estimate: this sync may need up to $(disk_amt "$content") more on /data ($(disk_amt "$free1") free)."
check "load warns on the registry and not the cache" "$disk_load_summary" \
	"DISK SPACE WARNING. Estimate: this load may need up to $(disk_amt "$content") more on /data ($(disk_amt "$free1") free)."

echo "=== 30% boundary ==="
set_df \
	"$ARCH" dev-home /home "$free80" \
	"$CACHE" dev-home /home "$free80" \
	"$REG" dev-data /data "$bar"
load_shell
check "free exactly 30% above is plenty" "$disk_sync_level" "ok"
set_df \
	"$ARCH" dev-home /home "$free80" \
	"$CACHE" dev-home /home "$free80" \
	"$REG" dev-data /data "$((bar - 1))"
load_shell
check "one byte under 30% is tight" "$disk_sync_level" "tight"
check "tight sync is not a warning" "$disk_sync_short" "false"
check "save stays plenty at the boundary" "$disk_save_level" "ok"

echo "=== remote registry ==="
write_remote_conf
FAKE_SSH_FAIL=""
FAKE_REMOTE_AVAIL=$free1
set_df \
	"$ARCH" dev-home /home "$free80" \
	"$CACHE" dev-home /home "$free80"
load_shell
check "remote save stays on this machine" "$disk_save_level" "ok"
check "remote sync reads the host" "$disk_sync_summary" \
	"DISK SPACE WARNING. Estimate: this sync may need up to $(disk_amt "$content") more on reg.example.com:~/quay-install ($(disk_amt "$free1") free)."
check "remote load names the host and not the local cache" "$disk_load_summary" \
	"DISK SPACE WARNING. Estimate: this load may need up to $(disk_amt "$content") more on reg.example.com:~/quay-install ($(disk_amt "$free1") free)."

echo "=== remote free space cannot be read ==="
FAKE_SSH_FAIL=1
load_shell
check "unread remote sync is not a warning" "$disk_sync_level" "unknown"
check "unread remote sync does not say enough" "$disk_sync_summary" \
	"Estimate: this sync may need up to $(disk_amt "$content") more on reg.example.com:~/quay-install. Free space could not be read from reg.example.com."
check "unread remote load does not say enough" "$disk_load_summary" \
	"Estimate: this load may need up to $(disk_amt "$content") more on reg.example.com:~/quay-install. Free space could not be read from reg.example.com."
check "unread remote is not the warning flag" "$disk_sync_short" "false"
FAKE_SSH_FAIL=""

echo "=== registered registry has no known disk ==="
write_existing_conf
set_df \
	"$ARCH" dev-home /home "$free80" \
	"$CACHE" dev-home /home "$free80"
load_shell
check "existing registry sync is not a warning" "$disk_sync_level" "unknown"
check "existing registry does not claim the host was unreachable" "$disk_sync_summary" \
	"Estimate: this sync may need up to $(disk_amt "$content") more on the mirror registry (reg.example.com:8443). The registry data directory is not known, so free space was not checked."
check "existing registry save can still be plenty" "$disk_save_level" "ok"

echo "=== local registry uses mirror.conf when install state is missing ==="
cat > "$MIRROR/mirror.conf" << EOF
reg_host=bastion.example.com
reg_port=8443
data_dir=$REGDIR
reg_vendor=docker
EOF
rm -f "$HOME/.aba/mirror/disktest/state.sh"
mkdir -p "$REGDIR/docker-reg"
set_df \
	"$ARCH" dev-home /home "$free80" \
	"$CACHE" dev-home /home "$free80" \
	"$REGDIR/docker-reg" dev-home /home "$free80"
load_shell
check "local sync reads this host" "$disk_sync_level" "ok"
check "local sync does not say bastion could not be read" "$disk_sync_summary" ""

echo "=== default status omits disk lines; --disk and op= show them ==="
write_local_conf
clear_cache
set_df \
	"$ARCH" dev-home /home "$free80" \
	"$CACHE" dev-home /home "$free80" \
	"$REG" dev-data /data "$free80"
human=$(cd "$MIRROR" && scripts/mirror-status.sh 2>&1) || true
if echo "$human" | grep -Eq 'enough disk space|DISK SPACE WARNING|Estimate:'; then
	echo "  FAIL: default status printed a disk line"
	echo "$human"
	fail=$((fail + 1))
else
	echo "  PASS: default status has no disk line"
fi
disk=$(cd "$MIRROR" && scripts/mirror-status.sh --disk 2>&1) || true
if echo "$disk" | grep -Eq 'enough disk space|Estimate:|DISK SPACE WARNING'; then
	echo "  FAIL: --disk spoke when space looks fine"
	echo "$disk"
	fail=$((fail + 1))
else
	echo "  PASS: --disk stays quiet when space looks fine"
fi
set_df \
	"$ARCH" dev-home /home "$free40" \
	"$CACHE" dev-home /home "$free40" \
	"$REG" dev-data /data "$free80"
op=$(cd "$MIRROR" && scripts/mirror-status.sh op=save 2>&1) || true
if echo "$op" | grep -q 'DISK SPACE WARNING. Estimate: this save may need about'; then
	echo "  PASS: save prints the warning"
else
	echo "  FAIL: save did not print the warning"
	echo "$op"
	fail=$((fail + 1))
fi

if [ "$fail" -eq 0 ]; then
	echo
	echo "ALL PASSED"
	exit 0
fi
echo
echo "$fail FAILED"
exit 1
