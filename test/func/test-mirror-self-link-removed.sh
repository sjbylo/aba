#!/bin/bash
# Test: mirror dirs have no mirror -> . self-link
# Regression test for: scp -r, WinSCP and cp -rL loop on the self-link
# Verifies:
#   1. Nothing in templates/ or scripts/ creates the self-link
#   2. CMD_*_REG and check-image run the mirror Makefile from the repo root,
#      a mirror dir, a named mirror dir and a cluster dir (mirror -> ../<name>)
#   3. Any make in an old mirror dir removes the stale self-link and forgets
#      only the old-style run_once tasks saved from that dir or from a dir with
#      no mirror entry, unless run_once is replaying one of them (task lock held)

cd "$(dirname "$0")/../.." || exit 1
source scripts/include_all.sh 2>/dev/null
trap - ERR

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }

_repo=$(pwd)
_tmp=$(mktemp -d)
trap 'rm -rf "$_tmp"' EXIT

echo "=== mirror -> . self-link removed ==="

# --- 1. Nothing creates the link ---
if grep -rnE 'ln +-[a-z]+ +\. +mirror *$' templates scripts; then
	_fail "templates/ or scripts/ still create the mirror -> . self-link"
else
	_pass "nothing in templates/ or scripts/ creates the mirror -> . self-link"
fi

# --- 2. CMD_*_REG pick the mirror dir at run time ---
mkdir -p "$_tmp/pick/mirror" "$_tmp/pick/m2" "$_tmp/pick/c1"
printf '# Top level Makefile\nall:\n\t@true\n' > "$_tmp/pick/Makefile"
printf '# Cluster Makefile\nall:\n\t@true\n' > "$_tmp/pick/c1/Makefile"
for d in mirror m2; do
	printf '# Mirror Makefile  # DO NOT remove this line!\ndownload-quay-tarball check-image:\n\t@pwd -P > ran-in\n' > "$_tmp/pick/$d/Makefile"
done
ln -s ../m2 "$_tmp/pick/c1/mirror"

# Run CMD_DL_QUAY_REG from <cwd>; expect the recipe to run in <expected dir>
check_pick() {
	local cwd="$1" expected="$2"
	rm -f "$_tmp"/pick/*/ran-in
	( cd "$_tmp/pick/$cwd" && "${CMD_DL_QUAY_REG[@]}" ) >/dev/null 2>&1
	if [ "$(cat "$_tmp/pick/$expected/ran-in" 2>/dev/null)" = "$(cd "$_tmp/pick/$expected" && pwd -P)" ]; then
		_pass "from '$cwd' runs the Makefile in '$expected'"
	else
		_fail "from '$cwd' did not run the Makefile in '$expected'"
	fi
}
check_pick . mirror
check_pick mirror mirror
check_pick m2 m2
check_pick c1 m2

# check-image with ABA_ROOT unset (plain make -C <mirror> uninstall -> reg-uninstall.sh)
rm -f "$_tmp"/pick/*/ran-in
(
	export RUN_ONCE_DIR="$_tmp/runner-pick"
	unset ABA_ROOT
	cd "$_tmp/pick/m2" && aba_mirror_verify_start && run_once -q -w -i "aba:mirror:check-image"
) >/dev/null 2>&1
if [ -f "$_tmp/pick/m2/ran-in" ] && [ ! -f "$_tmp/pick/mirror/ran-in" ]; then
	_pass "check-image from 'm2' with ABA_ROOT unset runs the Makefile in 'm2'"
else
	_fail "check-image from 'm2' with ABA_ROOT unset did not run the Makefile in 'm2'"
fi

# --- 3. Stale link cleanup in an old mirror dir ---
_root="$_tmp/old"
mkdir -p "$_root/mirror"
ln -s "$_repo/scripts" "$_root/scripts"
ln -s "$_repo/templates" "$_root/templates"
ln -s "$_repo/others" "$_root/others"
ln -s ../templates/Makefile.mirror "$_root/mirror/Makefile"
ln -s . "$_root/mirror/mirror"

# Fake finished run_once task: <id suffix> <saved cwd> <saved command>
export RUN_ONCE_DIR="$_tmp/runner"
OLD_CMD='declare -a command=([0]="make" [1]="-sC" [2]="mirror" [3]="x")'
NEW_CMD='declare -a command=([0]="bash" [1]="-c" [2]="d=mirror; x" [3]="_" [4]="x")'
fake_task() {
	local s="$RUN_ONCE_DIR/mirror:reg:$1"
	mkdir -p "$s"
	echo "$2" > "$s/cwd"
	echo "$3" > "$s/cmd.sh"
	echo 0 > "$s/exit"
}
fake_task install "$_root/mirror" "$OLD_CMD"        # old, needs the link: forget
fake_task download:quay "$_root" "$OLD_CMD"         # old, saved from the root: still valid
fake_task download:docker "$_root/mirror" "$NEW_CMD" # new command from the mirror dir: keep

make -C "$_root/mirror" help >/dev/null 2>&1

if [ -L "$_root/mirror/mirror" ] || [ -e "$_root/mirror/mirror" ]; then
	_fail "stale mirror -> . self-link not removed"
else
	_pass "stale mirror -> . self-link removed"
fi
if [ -f "$RUN_ONCE_DIR/mirror:reg:install/cmd.sh" ] || [ -f "$RUN_ONCE_DIR/mirror:reg:install/exit" ]; then
	_fail "old task saved from the mirror dir not forgotten"
else
	_pass "old task saved from the mirror dir forgotten"
fi
if [ -f "$RUN_ONCE_DIR/mirror:reg:download:quay/exit" ]; then
	_pass "old task saved from the repo root kept"
else
	_fail "old task saved from the repo root was forgotten"
fi
if [ -f "$RUN_ONCE_DIR/mirror:reg:download:docker/exit" ]; then
	_pass "new task saved from the mirror dir kept"
else
	_fail "new task saved from the mirror dir was forgotten"
fi

# Old 'clean' removed the link but left old tasks: they must still be forgotten
fake_task download:omr "$_root/mirror" "$OLD_CMD"
make -C "$_root/mirror" help >/dev/null 2>&1
if [ -f "$RUN_ONCE_DIR/mirror:reg:download:omr/exit" ]; then
	_fail "no link: old task saved from the mirror dir not forgotten"
else
	_pass "no link: old task saved from the mirror dir forgotten"
fi

# Task ids are global: an old task saved in a deleted aba dir would replay here
fake_task download:omr "$_tmp/gone/aba/mirror" "$OLD_CMD"
# An old task saved in another old aba dir that still has its link replays fine there
mkdir -p "$_tmp/other/mirror"
ln -s . "$_tmp/other/mirror/mirror"
fake_task download:docker "$_tmp/other/mirror" "$OLD_CMD"
make -C "$_root/mirror" help >/dev/null 2>&1
if [ -f "$RUN_ONCE_DIR/mirror:reg:download:omr/exit" ]; then
	_fail "old task saved in a deleted dir not forgotten"
else
	_pass "old task saved in a deleted dir forgotten"
fi
if [ -f "$RUN_ONCE_DIR/mirror:reg:download:docker/exit" ]; then
	_pass "old task saved in another dir with its link kept"
else
	_fail "old task saved in another dir with its link was forgotten"
fi

# run_once validation replays an old task through the link while it holds the task lock
ln -s . "$_root/mirror/mirror"
fake_task install "$_root/mirror" "$OLD_CMD"
(
	exec 8>>"$RUN_ONCE_DIR/mirror:reg:install/lock"
	flock -n 8 || exit 1
	make -C "$_root/mirror" help >/dev/null 2>&1
)
if [ -f "$RUN_ONCE_DIR/mirror:reg:install/cmd.sh" ] && [ -L "$_root/mirror/mirror" ]; then
	_pass "locked: old task and self-link kept while run_once replays it"
else
	_fail "locked: old task or self-link removed while run_once replays it"
fi
make -C "$_root/mirror" help >/dev/null 2>&1
if [ ! -f "$RUN_ONCE_DIR/mirror:reg:install/cmd.sh" ] && [ ! -L "$_root/mirror/mirror" ]; then
	_pass "unlocked: old task forgotten and self-link removed on the next make"
else
	_fail "unlocked: old task or self-link left after the next make"
fi

# --- Summary ---
echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
