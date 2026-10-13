#!/bin/bash
# The second auth backup must match the auth directory just written.
# Bug #1123: cp into an existing auth.backup nests a second auth/.
# This test does not build an ISO.

set -eo pipefail

cd "$(dirname "$0")/../.."
source scripts/generate-image.sh

d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT

mkdir -p "$d/auth"
echo first > "$d/auth/kubeadmin-password"
backup_auth_dir "$d/auth" "$d/auth.backup"
echo second > "$d/auth/kubeadmin-password"
backup_auth_dir "$d/auth" "$d/auth.backup"

got=$(cat "$d/auth.backup/kubeadmin-password")
if [ "$got" = "second" ] && [ ! -e "$d/auth.backup/auth" ]; then
	echo "PASS: second backup password is second"
	exit 0
fi

echo "FAIL: backup password is '$got'"
find "$d/auth.backup" -type f
exit 1
