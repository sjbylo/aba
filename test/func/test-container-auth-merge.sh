#!/bin/bash
# Container auth merge keeps other registry logins and does not grow on repeat.
# Does not read or write the real ~/.docker or ~/.containers directories.

set -eo pipefail

cd "$(dirname "$0")/../.."
source scripts/include_all.sh
eval "$(awk '/^merge_container_auth\(\)/,/^}/' scripts/create-containers-auth.sh)"

d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT

secret=$d/secret.json
dest=$d/config.json
cat > "$secret" <<'EOF'
{"auths":{"mirror.example.com:8443":{"auth":"newmirror"},"registry.redhat.io":{"auth":"rh"}}}
EOF
cat > "$dest" <<'EOF'
{"credsStore":"osxkeychain","auths":{"ghcr.io":{"auth":"olduser"},"mirror.example.com:8443":{"auth":"oldmirror"}}}
EOF

merge_container_auth "$secret" "$dest"
merge_container_auth "$secret" "$dest"
cp "$dest" "$d/once.json"
merge_container_auth "$secret" "$dest"

fail=0
_got() { jq -r "$1" "$dest"; }

if [ "$(_got '.credsStore')" = "osxkeychain" ] \
	&& [ "$(_got '.auths["ghcr.io"].auth')" = "olduser" ] \
	&& [ "$(_got '.auths["mirror.example.com:8443"].auth')" = "newmirror" ] \
	&& [ "$(_got '.auths["registry.redhat.io"].auth')" = "rh" ]; then
	echo "PASS: other hosts kept, same host replaced"
else
	echo "FAIL: merged auth is unexpected"
	cat "$dest"
	fail=1
fi

if cmp -s "$dest" "$d/once.json"; then
	echo "PASS: second merge did not change the file"
else
	echo "FAIL: second merge changed the file"
	fail=1
fi

fresh=$d/fresh.json
merge_container_auth "$secret" "$fresh"
if cmp -s "$secret" "$fresh"; then
	echo "PASS: missing file is copied"
else
	echo "FAIL: missing file was not copied"
	fail=1
fi

exit "$fail"
