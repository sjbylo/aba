#!/bin/bash
# check-pull-secret.sh rejects a bad file and reports a pull when curl says so.
# No network. A fake curl stands in for the registries.

set -eo pipefail

cd "$(dirname "$0")/../.."
tool=$PWD/tools/check-pull-secret.sh

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf '  PASS  %s\n' "$*"; }
_fail() { fail=$(( fail + 1 )); printf '  FAIL  %s\n' "$*"; }

out=$(mktemp -d)
chmod 700 "$out"
trap 'rm -rf "$out"' EXIT

# Fake curl. URL is the last argument. -o and -D name the body and header files.
cat > "$out/curl" <<'EOF'
#!/bin/bash
out=""
hdr=""
prev=""
url=""
for arg in "$@"; do
	if [ "$prev" = "-o" ]; then
		out=$arg
	elif [ "$prev" = "-D" ]; then
		hdr=$arg
	fi
	prev=$arg
	url=$arg
done
mkdir -p "$(dirname "$out")"
case "$url" in
	https://*/v2/)
		printf '%s\n' 'HTTP/1.1 401 Unauthorized' \
			'WWW-Authenticate: Bearer realm="https://reg.example/v2/auth",service="reg"' \
			> "$hdr"
		printf '401'
		;;
	https://reg.example/v2/auth)
		if [ "${FAKE_REJECT:-}" = "1" ]; then
			printf '%s\n' '{}' > "$out"
			printf '401'
		else
			printf '%s\n' '{"token":"t"}' > "$out"
			printf '200'
		fi
		;;
	https://*/tags/list)
		printf '%s\n' '{"tags":["latest"]}' > "$out"
		printf '200'
		;;
	https://catalog.redhat.com/*)
		printf '%s\n' '{"data":[{"repository":"example/image"}]}' > "$out"
		printf '200'
		;;
	*)
		printf '000'
		;;
esac
EOF
chmod 700 "$out/curl"

help=$(PATH="$out:$PATH" "$tool" --help 2>&1) || true
if printf '%s\n' "$help" | grep -q 'check-pull-secret.sh'; then
	_pass "help names the command"
else
	_fail "help names the command: $help"
fi

rc=0
miss=$("$tool" "$out/missing.json" 2>"$out/miss.err") || rc=$?
if [ "$rc" -ne 0 ] && grep -q 'not found' "$out/miss.err"; then
	_pass "missing file is an error"
else
	_fail "missing file is an error: rc=$rc"
fi

printf 'not json\n' > "$out/bad.json"
rc=0
"$tool" "$out/bad.json" >/dev/null 2>"$out/bad.err" || rc=$?
if [ "$rc" -ne 0 ] && grep -q 'not a JSON' "$out/bad.err"; then
	_pass "invalid json is an error"
else
	_fail "invalid json is an error: rc=$rc $(cat "$out/bad.err")"
fi

# Same auth bytes for cloud.openshift.com and quay.io. The image name is the
# stand-in repository the fake registry returns.
python3 - "$out/secret.json" <<'PY'
import json, sys
auth = "dXNlcjpzM2NyZXQtdG9rZW4="  # user:s3cret-token
json.dump({"auths": {
    "cloud.openshift.com": {"auth": auth, "email": "a@b.c"},
    "quay.io": {"auth": auth, "email": "a@b.c"},
    "registry.connect.redhat.com": {"auth": auth, "email": "a@b.c"},
    "registry.redhat.io": {"auth": auth, "email": "a@b.c"},
}}, open(sys.argv[1], "w"))
PY

rc=0
PATH="$out:$PATH" "$tool" "$out/secret.json" >"$out/ok.out" 2>"$out/ok.err" || rc=$?
ok=$(cat "$out/ok.out")
if [ "$rc" -eq 0 ] \
	&& printf '%s\n' "$ok" | grep -Eq '^OK[[:space:]]+quay.io[[:space:]]+pulled openshift-release-dev/ocp-release$' \
	&& printf '%s\n' "$ok" | grep -Eq '^OK[[:space:]]+registry.redhat.io[[:space:]]+pulled ubi9/ubi$' \
	&& printf '%s\n' "$ok" | grep -Eq '^OK[[:space:]]+registry.connect.redhat.com[[:space:]]+pulled example/image$' \
	&& printf '%s\n' "$ok" | grep -Eq '^SKIP[[:space:]]+cloud.openshift.com[[:space:]]+not an image registry \(same credential as quay.io\)$' \
	&& ! grep -q 's3cret-token' "$out/ok.out" "$out/ok.err"; then
	_pass "a valid secret is ok and the secret is not printed"
else
	_fail "a valid secret is ok and the secret is not printed: rc=$rc"
	cat "$out/ok.out" "$out/ok.err"
fi

FAKE_REJECT=1
rc=0
PATH="$out:$PATH" FAKE_REJECT=1 "$tool" "$out/secret.json" >"$out/badpull.out" 2>"$out/badpull.err" || rc=$?
if [ "$rc" -ne 0 ] \
	&& grep -Eq '^FAIL[[:space:]]+quay.io[[:space:]]+credential rejected$' "$out/badpull.out" \
	&& grep -q 'credential rejected' "$out/badpull.out" \
	&& ! grep -q 's3cret-token' "$out/badpull.out" "$out/badpull.err"; then
	_pass "a rejected credential fails"
else
	_fail "a rejected credential fails: rc=$rc"
	cat "$out/badpull.out" "$out/badpull.err"
fi

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
