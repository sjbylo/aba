#!/bin/bash
# Test: a caller-owned ImageSet file skips catalog and version fetches.
# The ownership test itself is unchanged: the YAML must be newer than .created,
# and a missing .created is not user-managed.

_tmp=$(mktemp -d)
trap 'rm -rf "$_tmp"' EXIT

export ABA_CACHE_DIR="$_tmp/cache"
export RUN_ONCE_DIR="$_tmp/runner"
mkdir -p "$ABA_CACHE_DIR" "$RUN_ONCE_DIR"

cd "$(dirname "$0")/../.." || exit 1
_repo=$(pwd)
source scripts/include_all.sh 2>/dev/null

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }

echo "=== caller-owned ImageSet file ==="

_good="$_tmp/good.yaml"
cat > "$_good" <<'EOF'
mirror:
  platform:
    channels:
    - name: stable-4.18
      minVersion: 4.18.1
      maxVersion: 4.18.1
EOF
printf 'foo: 1\n' > "$_tmp/nokey.yaml"
printf 'mirror: [\n' > "$_tmp/bad.yaml"
: > "$_tmp/empty.yaml"

mkdir -p "$_tmp/repo/mirror/data"
printf '%s\n' '# Top level Makefile' > "$_tmp/repo/Makefile"
export ABA_ROOT="$_tmp/repo"
cd "$_tmp/repo"

cp "$_good" "$_tmp/repo/mirror/data/imageset-config.yaml"
rm -f "$_tmp/repo/mirror/data/.created"
if aba_isc_is_user_managed; then
	_fail "missing .created counted as user-managed"
else
	_pass "missing .created is not user-managed"
fi

touch "$_tmp/repo/mirror/data/imageset-config.yaml" "$_tmp/repo/mirror/data/.created"
if aba_isc_is_user_managed; then
	_fail "equal timestamps counted as user-managed"
else
	_pass "equal timestamps are not user-managed"
fi

aba_isc_install_user_file "$_good"
if aba_isc_is_user_managed \
	&& [ "$_tmp/repo/mirror/data/imageset-config.yaml" -nt "$_tmp/repo/mirror/data/.created" ]; then
	_pass "install from the repo root is user-managed"
else
	_fail "install from the repo root was not user-managed"
fi

# aba_abort sleeps, then exits 1. Keep that out of this shell.
(
	aba_isc_install_user_file "$_tmp/nokey.yaml"
) >/dev/null 2>&1
if [ $? -eq 1 ]; then
	_pass "a file with no mirror key is rejected"
else
	_fail "a file with no mirror key was accepted"
fi
(
	aba_isc_install_user_file "$_tmp/bad.yaml"
) >/dev/null 2>&1
if [ $? -eq 1 ]; then
	_pass "invalid YAML is rejected"
else
	_fail "invalid YAML was accepted"
fi
(
	aba_isc_install_user_file "$_tmp/empty.yaml"
) >/dev/null 2>&1
if [ $? -eq 1 ]; then
	_pass "an empty file is rejected"
else
	_fail "an empty file was accepted"
fi

mkdir -p "$_tmp/mdir"
printf '%s\n' '# Mirror Makefile  # DO NOT remove this line!' > "$_tmp/mdir/Makefile"
cd "$_tmp/mdir"
aba_isc_install_user_file "$_good"
if aba_isc_is_user_managed; then
	_fail "default ownership path changed inside a mirror directory"
else
	_pass "default ownership path is still mirror/data inside a mirror directory"
fi
if aba_isc_is_user_managed "$(_aba_isc_file)"; then
	_pass "the mirror directory file is user-managed"
else
	_fail "the mirror directory file was not user-managed"
fi

_nfiles() {
	find "$ABA_CACHE_DIR" "$RUN_ONCE_DIR" -type f 2>/dev/null | wc -l
}
_before=$(_nfiles)

_rc=0
download_all_catalogs "9.9" || _rc=$?
if [ "$_rc" -eq 0 ]; then
	_pass "download_all_catalogs returns 0"
else
	_fail "download_all_catalogs returned $_rc"
fi

_rc=0
timeout 8 bash -c 'cd "$1" && source "$2" && wait_for_all_catalogs 9.9' _ "$_tmp/mdir" "$_repo/scripts/include_all.sh" || _rc=$?
if [ "$_rc" -eq 0 ]; then
	_pass "wait_for_all_catalogs returns 0"
else
	_fail "wait_for_all_catalogs returned $_rc"
fi

ln -sfn "$_repo/scripts" "$_tmp/mdir/scripts"
_rc=0
( cd "$_tmp/mdir" && timeout 8 scripts/download-catalogs-wait.sh ) || _rc=$?
if [ "$_rc" -eq 0 ]; then
	_pass "catalog wait returns 0"
else
	_fail "catalog wait returned $_rc"
fi

_rc=0
timeout 8 bash -c 'cd "$1" && source "$2" && verify_release_version_exists 1.2.3 stable && verify_upgrade_path_exists 1.2.3 1.2.4 stable' _ "$_tmp/mdir" "$_repo/scripts/include_all.sh" || _rc=$?
if [ "$_rc" -eq 0 ]; then
	_pass "version checks return 0"
else
	_fail "version checks returned $_rc"
fi

_after=$(_nfiles)
if [ "$_after" -eq "$_before" ]; then
	_pass "no catalog task and no version cache were written"
else
	_fail "a fetch wrote files (before=$_before after=$_after)"
fi

echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
