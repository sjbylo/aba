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

# The planted host is not in the pull secret. A merge must leave it.
chaos=$d/chaos.json
printf '%s\n' '{"auths":{"e2e-chaos.invalid":{"auth":"planted"}}}' > "$chaos"
merge_container_auth "$secret" "$chaos"
if [ "$(jq -r '.auths["e2e-chaos.invalid"].auth' "$chaos")" = "planted" ] \
	&& [ "$(jq -r '.auths["mirror.example.com:8443"].auth' "$chaos")" = "newmirror" ]; then
	echo "PASS: merge keeps a login the pull secret does not have"
else
	echo "FAIL: merge dropped a login the pull secret does not have"
	jq -r '.auths | keys[]' "$chaos"
	fail=1
fi

# aba password logs in with --authfile. It must not log out of the default store.
if grep -E -q '^[[:space:]]*podman logout' scripts/reg-existing-create-pull-secret.sh; then
	echo "FAIL: aba password still runs podman logout"
	fail=1
else
	echo "PASS: aba password does not run podman logout"
fi

pw=$d/pw
mkdir -p "$pw/home/.docker" "$pw/home/.containers" "$pw/bin" "$pw/mirror"
ln -s "$PWD/scripts" "$pw/mirror/scripts"
ln -s "$PWD/templates" "$pw/mirror/templates"
printf '%s\n' 'ask=false' 'domain=example.com' > "$pw/mirror/aba.conf"
printf '%s\n' 'reg_host=mirror.example.com' 'reg_port=5000' > "$pw/mirror/mirror.conf"
printf '%s\n' '{"auths":{"e2e-chaos.invalid":{"auth":"planted"}}}' > "$pw/home/.docker/config.json"
cp "$pw/home/.docker/config.json" "$pw/home/.containers/auth.json"
cat > "$pw/bin/podman" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$PODMAN_LOG"
if [ "$1" = logout ]; then
	rm -f "$HOME/.docker/config.json" "$HOME/.containers/auth.json"
fi
exit 0
EOF
chmod 755 "$pw/bin/podman"
if (
	export HOME="$pw/home" PODMAN_LOG="$pw/podman.log" PATH="$pw/bin:$PATH"
	cd "$pw/mirror"
	printf 'init\nunused\n' | ./scripts/reg-existing-create-pull-secret.sh >"$pw/out" 2>&1
) && [ "$(jq -r '.auths["e2e-chaos.invalid"].auth' "$pw/home/.docker/config.json")" = "planted" ] \
	&& [ "$(jq -r '.auths["e2e-chaos.invalid"].auth' "$pw/home/.containers/auth.json")" = "planted" ] \
	&& [ -s "$pw/home/.aba/mirror/mirror/pull-secret-mirror.json" ] \
	&& ! grep -q '^logout' "$pw/podman.log"; then
	echo "PASS: aba password left the existing login in place"
else
	echo "FAIL: aba password changed the existing login"
	echo "podman: $(cat "$pw/podman.log" 2>/dev/null || true)"
	sed 's/unused/***/g' "$pw/out" 2>/dev/null || true
	fail=1
fi

# The suite check is only the user who ran aba, and a failed plant stops the suite.
if grep -E -q 'rm .*(~/.docker|~/.containers)' test/e2e/suites/suite-create-bundle-to-disk.sh; then
	echo "FAIL: create-bundle still deletes container auth directories"
	fail=1
else
	echo "PASS: create-bundle keeps container auth directories"
fi

if [ "$(grep -c 'if ! _e2e_maybe_reset_container_auth; then' test/e2e/runner.sh)" -eq 2 ]; then
	echo "PASS: a failed plant stops the suite"
else
	echo "FAIL: runner does not stop when the plant fails"
	fail=1
fi

if (
	export HOME="$d/suite-home"
	mkdir -p "$HOME"
	# shellcheck disable=SC1091
	source test/e2e/lib/pool-cleanup.sh
	_E2E_AUTH_DUMMY_MARKER=$d/marker
	E2E_LOG_DIR=$d/logs
	SUITE=auth-merge
	mkdir -p "$E2E_LOG_DIR"
	E2E_LOG_FILE=$E2E_LOG_DIR/auth-merge-latest.log
	: > "$E2E_LOG_FILE"
	_e2e_maybe_reset_container_auth >/dev/null
	merge_container_auth "$secret" "$HOME/.docker/config.json"
	merge_container_auth "$secret" "$HOME/.containers/auth.json"
	_e2e_assert_auth_dummy
	rm -f "$HOME/.docker/config.json"
	if _e2e_assert_auth_dummy; then
		exit 1
	fi
	grep -F -q "dummy missing from $HOME/.docker/config.json" "$E2E_LOG_FILE"
	rm -rf "$HOME/.docker" "$HOME/.containers"
	touch "$HOME/.docker"
	if _e2e_maybe_reset_container_auth >/dev/null; then
		exit 1
	fi
	[ ! -s "$_E2E_AUTH_DUMMY_MARKER" ]
); then
	echo "PASS: suite check is the aba user, and a failed plant does not count"
else
	echo "FAIL: suite auth check did not match the aba user"
	fail=1
fi

exit "$fail"
