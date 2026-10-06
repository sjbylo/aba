#!/bin/bash
# reg_generate_password for every registry vendor.
# quay and quay-ng keep the login stored with the data directory.
# docker accepts a new password because it rewrites htpasswd.
# existing is not installed by ABA, so a supplied password is left as-is.
# auto is resolved to quay or docker before this function runs.

cd "$(dirname "$0")/../.."

unset _REG_COMMON_LOADED
source scripts/reg-common.sh

pass=0
fail=0
test_pass() { echo "PASS: $1"; pass=$(( pass + 1 )); }
test_fail() { echo "FAIL: $1 -- $2"; fail=$(( fail + 1 )); }

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# check <title> <want-user> <want-pw>
check() {
	local title="$1" want_user="$2" want_pw="$3"
	reg_generate_password
	if [ "$reg_user" = "$want_user" ] && [ "$reg_pw" = "$want_pw" ]; then
		test_pass "$title"
	else
		test_fail "$title" "user=$reg_user pw=$reg_pw"
	fi
}

# check_generated <title> <not-this-password>
check_generated() {
	local title="$1" banned="$2"
	reg_generate_password
	if [ -n "$reg_pw" ] && [ "$reg_pw" != "$banned" ]; then
		test_pass "$title"
	else
		test_fail "$title" "pw=$reg_pw"
	fi
}

# --- quay --------------------------------------------------------------------
reg_root="$WORKDIR/quay"
mkdir -p "$reg_root/sqlite-storage"
touch "$reg_root/sqlite-storage/quay_sqlite.db"
printf "reg_user='%s'\nreg_pw='%s'\n" 'init' 'classic-pw' > "$reg_root/.aba-reuse-creds"

reg_user=other
reg_pw=
check "quay: empty password reuses the saved login" init classic-pw

reg_user=other
reg_pw='brand-new'
check "quay: a different password reuses the saved login" init classic-pw

reg_root="$WORKDIR/quay-first"
mkdir -p "$reg_root"
reg_user=init
reg_pw='chosen-pw'
check "quay: first install keeps an explicit password" init chosen-pw

reg_user=init
reg_pw=
check_generated "quay: first install generates a password" chosen-pw

# --- quay-ng -----------------------------------------------------------------
reg_root="$WORKDIR/quay-ng"
mkdir -p "$reg_root/auth"
printf '%s' 'stored-ng' > "$reg_root/auth/admin-password"

reg_user=admin
reg_pw=
check "quay-ng: empty password uses the stored password" admin stored-ng

printf "reg_user='%s'\nreg_pw='%s'\n" 'keptuser' 'creds-pw' > "$reg_root/.aba-reuse-creds"
reg_user=other
reg_pw='brand-new'
check "quay-ng: stored password wins over mirror.conf and the creds file" keptuser stored-ng

reg_root="$WORKDIR/quay-ng-first"
mkdir -p "$reg_root"
reg_user=admin
reg_pw='chosen-ng'
check "quay-ng: first install keeps an explicit password" admin chosen-ng

reg_user=admin
reg_pw=
check_generated "quay-ng: first install generates a password" chosen-ng

# --- docker ------------------------------------------------------------------
reg_root="$WORKDIR/docker"
mkdir -p "$reg_root"
printf "reg_user='%s'\nreg_pw='%s'\n" 'dock' 'saved-dock' > "$reg_root/.aba-reuse-creds"

reg_user=other
reg_pw=
check "docker: empty password reuses the saved login" dock saved-dock

reg_user=other
reg_pw='explicit'
check "docker: an explicit password replaces the saved login" other explicit

reg_root="$WORKDIR/docker-first"
mkdir -p "$reg_root"
reg_user=dock
reg_pw='chosen-dock'
check "docker: first install keeps an explicit password" dock chosen-dock

reg_user=dock
reg_pw=
check_generated "docker: first install generates a password" chosen-dock

# --- existing ----------------------------------------------------------------
# Registered registries are not installed here. No vendor file is consulted,
# and a password the user already set is not replaced.
reg_root="$WORKDIR/existing"
mkdir -p "$reg_root"
reg_user=imported
reg_pw='imported-pw'
check "existing: a supplied password is left unchanged" imported imported-pw

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
