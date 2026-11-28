#!/bin/bash
# backup.sh locks the ImageSet file inside the archive, then puts the
# source timestamps back. A caller-owned file stays newer than .created.
# An ABA-written file stays older than .created.

set -u
cd "$(dirname "$0")/../.." || exit 1

ROOT=$PWD
pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf '  PASS  %s\n' "$*"; }
_fail() { fail=$(( fail + 1 )); printf '  FAIL  %s\n' "$*"; }

WORK=$(mktemp -d /tmp/aba-backup-isc.XXXXXX)
_prev=$HOME/.aba/.previous.backup
_prev_mtime=
[ -f "$_prev" ] && _prev_mtime=$(stat -c %Y "$_prev")
_old=$HOME/.aba.previous.backup
_old_mtime=
[ -f "$_old" ] && _old_mtime=$(stat -c %Y "$_old")

cleanup() {
	rm -rf "$WORK"
	if [ -n "$_prev_mtime" ]; then
		touch -d "@$_prev_mtime" "$_prev"
	else
		rm -f "$_prev"
	fi
	if [ -n "$_old_mtime" ]; then
		touch -d "@$_old_mtime" "$_old"
	fi
}
trap cleanup EXIT

setup_repo() {
	local repo="$1"
	mkdir -p "$repo"/{scripts,mirror/data,templates,cli,rpms,others,tui/v2,.index,tools,catalogs}
	local f
	for f in install aba aba.conf Makefile README.md VERSION CHANGELOG.md LICENSE Troubleshooting.md; do
		printf 'x\n' > "$repo/$f"
	done
	cp "$ROOT/scripts/backup.sh" "$ROOT/scripts/include_all.sh" "$repo/scripts/"
}

run_backup() {
	local repo="$1" dest="$2"
	if ( cd "$repo" && bash scripts/backup.sh "$dest" ) >"$WORK/out" 2>"$WORK/err"; then
		return 0
	fi
	_fail "backup.sh failed for $(basename "$repo")"
	tail -n 40 "$WORK/err"
	return 1
}

# Caller-owned: the ImageSet file is newer than .created.
CALLER=$WORK/caller
setup_repo "$CALLER"
printf '%s\n' '# caller-owned-marker' > "$CALLER/mirror/data/imageset-config.yaml"
touch -d '2000-01-01 00:00:00' "$CALLER/mirror/data/.created"
touch "$CALLER/mirror/data/imageset-config.yaml"
cy=$(stat -c %Y "$CALLER/mirror/data/imageset-config.yaml")
cc=$(stat -c %Y "$CALLER/mirror/data/.created")
if run_backup "$CALLER" "$WORK/caller.tar"; then
	if [ "$(stat -c %Y "$CALLER/mirror/data/imageset-config.yaml")" = "$cy" ] \
		&& [ "$(stat -c %Y "$CALLER/mirror/data/.created")" = "$cc" ] \
		&& [ "$CALLER/mirror/data/imageset-config.yaml" -nt "$CALLER/mirror/data/.created" ]; then
		_pass "caller-owned source timestamps are unchanged"
	else
		_fail "caller-owned source timestamps changed"
	fi
	if [ ! -f "$CALLER/mirror/data/.isc-pinned" ]; then
		_pass "caller-owned source has no pin file"
	else
		_fail "caller-owned source kept .isc-pinned"
	fi
	mkdir -p "$WORK/caller-x"
	tar -xf "$WORK/caller.tar" -C "$WORK/caller-x"
	if [ "$WORK/caller-x/aba/mirror/data/imageset-config.yaml" -nt "$WORK/caller-x/aba/mirror/data/.created" ] \
		&& grep -q 'caller-owned-marker' "$WORK/caller-x/aba/mirror/data/imageset-config.yaml" \
		&& [ -f "$WORK/caller-x/aba/mirror/data/.isc-pinned" ]; then
		_pass "archive stores the caller-owned file as locked"
	else
		_fail "archive does not store the caller-owned file as locked"
	fi
fi

# ABA-written: .created is newer than the ImageSet file.
ABA=$WORK/aba-owned
setup_repo "$ABA"
printf '%s\n' '# aba-written' > "$ABA/mirror/data/imageset-config.yaml"
touch -d '2020-01-01 00:00:00' "$ABA/mirror/data/imageset-config.yaml"
touch -d '2020-01-02 00:00:00' "$ABA/mirror/data/.created"
ay=$(stat -c %Y "$ABA/mirror/data/imageset-config.yaml")
ac=$(stat -c %Y "$ABA/mirror/data/.created")
if run_backup "$ABA" "$WORK/aba.tar"; then
	if [ "$(stat -c %Y "$ABA/mirror/data/imageset-config.yaml")" = "$ay" ] \
		&& [ "$(stat -c %Y "$ABA/mirror/data/.created")" = "$ac" ] \
		&& [ "$ABA/mirror/data/.created" -nt "$ABA/mirror/data/imageset-config.yaml" ]; then
		_pass "ABA-written source stays unlocked"
	else
		_fail "ABA-written source timestamps changed"
	fi
	mkdir -p "$WORK/aba-x"
	tar -xf "$WORK/aba.tar" -C "$WORK/aba-x"
	if [ "$WORK/aba-x/aba/mirror/data/imageset-config.yaml" -nt "$WORK/aba-x/aba/mirror/data/.created" ] \
		&& [ ! -f "$WORK/aba-x/aba/mirror/data/.isc-pinned" ]; then
		_pass "archive stores the ABA-written file as locked and unpinned"
	else
		_fail "archive does not lock the ABA-written file"
	fi
fi

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
