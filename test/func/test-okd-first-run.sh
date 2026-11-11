#!/bin/bash
# Test: the first-run flow of ./aba on OKD (unit-ish, mocked: curl is a shim, the version lists come
# from pre-seeded caches, so nothing leaves the host and no Red Hat account is involved):
#   - connectivity failure names the OKD sites, not Red Hat's
#   - no pull secret and no operators -> the OKD placeholder is used, no console.redhat.com text
#   - operators selected and no pull secret -> clear message, no console.redhat.com text
#   - a real pull secret is accepted as it is (and not overwritten)
# The run happens in a throw-away copy of the tree with its own HOME.

cd "$(dirname "$0")/../.." || exit 1
REPO_ROOT="$PWD"

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }
_eq() { if [[ "$2" == "$3" ]]; then _pass "$1"; else _fail "$1: expected [$2] got [$3]"; fi; }
_has() { if grep -qE -- "$2" <<< "$3"; then _pass "$1"; else _fail "$1: /$2/ not in [$3]"; fi; }
_hasnt() { if grep -qE -- "$2" <<< "$3"; then _fail "$1: /$2/ unexpectedly in [$3]"; else _pass "$1"; fi; }

T=$(mktemp -d "${TMPDIR:-/tmp}/okd-first.XXXXXX")
trap 'rm -rf "$T"' EXIT
R="$T/aba"
cp -a --reflink=auto "$REPO_ROOT" "$R" || { echo "cannot copy the tree"; exit 1; }
cd "$R" || exit 1
rm -f aba.conf .aba.conf.seen

mkdir -p "$T/shim" "$T/home/.aba/cache"
cat > "$T/shim/curl" <<'EOF'
#!/bin/bash
echo "$*" >> "${CURL_LOG:?}"
[ -n "${CURL_FAIL:-}" ] && [[ "$*" =~ $CURL_FAIL ]] && { echo "curl: (6) Could not resolve host (shim)" >&2; exit 6; }
exit 0
EOF
# aba checks its required packages with rpm -q and would try to install missing ones: report everything installed
printf '#!/bin/bash\necho "$*" >> "${CURL_LOG:?}.rpm"\nexit 0\n' > "$T/shim/rpm"
chmod +x "$T/shim/curl" "$T/shim/rpm"
export CURL_LOG="$T/curl.log"

# Version lists the resolver reads from its caches (a fixture, as the real data would be fetched).
# The release list is cached one file per page (okd_releases_p<N>.json); a page of fewer than 100 is the last.
echo '[{"tag_name":"4.21.0-okd-scos.11","prerelease":false},{"tag_name":"4.20.0-okd-scos.3","prerelease":false}]' > "$T/home/.aba/cache/okd_releases_p1.json"
for c in stable candidate; do
	echo '{"nodes":[{"version":"4.21.0-okd-scos.11"}],"edges":[]}' > "$T/home/.aba/cache/graph_okd_${c}-4.21_amd64.json"
	echo '{"nodes":[{"version":"4.20.0-okd-scos.3"}],"edges":[]}' > "$T/home/.aba/cache/graph_okd_${c}-4.20_amd64.json"
done

PS="$T/ps.json"
OFFICIAL_FAKE='{"auths":{"fake":{"auth":"aWQ6cGFzcwo="}}}'

render_conf() {  # render_conf <ops>
	PATH=/usr/sbin:/usr/bin:/bin domain=example.com HOME="$T/home" scripts/j2 templates/aba.conf.j2 > aba.conf 2>/dev/null
	sed -i -e 's|^machine_network=.*|machine_network=10.0.0.0/20|' -e 's|^next_hop_address=.*|next_hop_address=10.0.0.1|' \
		-e 's|^dns_servers=.*|dns_servers=10.0.0.1|' -e 's|^ntp_servers=.*|ntp_servers=10.0.0.1|' \
		-e 's|^ocp_version=.*|ocp_version=4.21.0-okd-scos.11|' -e 's|^ocp_channel=.*|ocp_channel=stable|' \
		-e "s|^pull_secret_file=.*|pull_secret_file=$PS|" -e "s|^ops=.*|ops=$1|" -e 's|^distribution=.*|distribution=okd|' aba.conf
	grep -q '^distribution=okd' aba.conf || echo "distribution=okd" >> aba.conf
	touch .aba.conf.seen
}
run_aba() {  # run_aba <curl-fail-regex>; prints output and rc
	rm -rf "$T/home/.aba/runner"   # probe results are cached for minutes
	( HOME="$T/home" PATH="$T/shim:$PATH" CURL_FAIL="$1" timeout 120 ./aba </dev/null 2>&1; echo "rc=$?" ) | sed 's/\x1b\[[0-9;]*m//g'
}
rc_of() { sed -n 's/^rc=//p' <<< "$1" | tail -1; }

echo "=== okd: connectivity failure ==="
render_conf ""; rm -f "$PS"; : > "$CURL_LOG"
out=$(run_aba 'quay\.io')
_eq "aborts" "1" "$(rc_of "$out")"
_has "names the failed site" "Cannot access required sites: quay\.io" "$out"
_has "lists the OKD sites" "github\.com" "$out"
_has "lists updates.okd.io" "updates\.okd\.io" "$out"
_hasnt "no registry.redhat.io" "registry\.redhat\.io" "$out"
_hasnt "no console.redhat.com" "console\.redhat\.com" "$out"
_hasnt "no api.openshift.com" "api\.openshift\.com" "$out"
_hasnt "nothing probes registry.redhat.io" "registry\.redhat\.io" "$(cat "$CURL_LOG")"

echo ""
# (the background catalog prefetch of a first run may write the placeholder before this step does, so the
# result is checked on the file, not on a log line)
echo "=== okd: no pull secret, no operators -> placeholder ==="
render_conf ""; rm -f "$PS"; : > "$CURL_LOG"
out=$(run_aba "")
_eq "completes" "0" "$(rc_of "$out")"
_has "ready message" "Pull secret ready" "$out"
_hasnt "no Red Hat pull secret demand" "No Red Hat pull secret|console\.redhat\.com|registry\.redhat\.io" "$out"
_eq "placeholder is the official OKD value" "$OFFICIAL_FAKE" "$(tr -d '\n' < "$PS" 2>/dev/null)"
_hasnt "nothing probes registry.redhat.io" "registry\.redhat\.io" "$(cat "$CURL_LOG")"

echo ""
echo "=== okd: operators selected, no pull secret -> clear message ==="
render_conf "cert-manager"; rm -f "$PS"; : > "$CURL_LOG"
out=$(run_aba "")
_eq "aborts" "1" "$(rc_of "$out")"
_has "explains operators need a pull secret" "(ops|op_sets)" "$out"
_hasnt "no console.redhat.com" "console\.redhat\.com" "$out"
_hasnt "no registry.redhat.io" "registry\.redhat\.io" "$out"
[ ! -e "$PS" ] && _pass "no placeholder written" || _fail "placeholder written although operators are selected"

echo ""
echo "=== okd: a real pull secret is accepted as it is ==="
render_conf ""
echo '{"auths":{"registry.redhat.io":{"auth":"dXNlcjpwdw=="}}}' > "$PS"; cp "$PS" "$T/ps.orig"
out=$(run_aba "")
_eq "completes" "0" "$(rc_of "$out")"
_eq "file untouched" "$(cat "$T/ps.orig")" "$(cat "$PS")"

echo ""
echo "Passed: $pass  Failed: $fail"
[ "$fail" -eq 0 ]
