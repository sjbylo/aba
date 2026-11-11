#!/bin/bash
# Test: pull secret and connectivity checks per distribution (unit, mocked: curl/skopeo are shims,
# nothing leaves the host).
#   okd: no Red Hat account needed -- probes quay.io/github.com/updates.okd.io/mirror.openshift.com, never
#        registry.redhat.io; the official OKD placeholder pull secret is used when no operators are selected;
#        a mirror (sync) run must have a valid mirror secret.
#   ocp: probes and messages are unchanged.

cd "$(dirname "$0")/../.." || exit 1
REPO_ROOT="$PWD"

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }
_eq() { if [[ "$2" == "$3" ]]; then _pass "$1"; else _fail "$1: expected [$2] got [$3]"; fi; }
_has() { if grep -qE -- "$2" <<< "$3"; then _pass "$1"; else _fail "$1: /$2/ not in [$3]"; fi; }
_hasnt() { if grep -qE -- "$2" <<< "$3"; then _fail "$1: /$2/ unexpectedly in [$3]"; else _pass "$1"; fi; }

T=$(mktemp -d "${TMPDIR:-/tmp}/okd-ps.XXXXXX")
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"

# Shims: curl logs its arguments and fails when an argument matches $CURL_FAIL; skopeo logs and fails.
mkdir -p "$T/shim"
cat > "$T/shim/curl" <<'EOF'
#!/bin/bash
echo "$*" >> "${CURL_LOG:?}"
[ -n "${CURL_FAIL:-}" ] && [[ "$*" =~ $CURL_FAIL ]] && { echo "curl: (6) Could not resolve host (shim)" >&2; exit 6; }
exit 0
EOF
cat > "$T/shim/skopeo" <<'EOF'
#!/bin/bash
echo "$*" >> "${SKOPEO_LOG:?}"
echo "unauthorized: shim" >&2
exit 1
EOF
chmod +x "$T/shim/curl" "$T/shim/skopeo"
export CURL_LOG="$T/curl.log" SKOPEO_LOG="$T/skopeo.log"
export PATH="$T/shim:$PATH"
: > "$CURL_LOG"; : > "$SKOPEO_LOG"

# The README of github.com/okd-project/okd gives this value for installs that need no pull secret.
OFFICIAL_FAKE='{"auths":{"fake":{"auth":"aWQ6cGFzcwo="}}}'

# run <dist> <ops> <op_sets> <code>   -> runs <code> in a fresh shell in $T/work, prints "rc=<n>" last
run() {
	local dist="$1" ops="$2" ops_sets="$3" code="$4"
	mkdir -p "$T/work"
	# fresh run_once state per call: probe results are cached per task id
	( cd "$T/work" && distribution="$dist" ops="$ops" op_sets="$ops_sets" RUN_ONCE_DIR="$(mktemp -d "$T/runner.XXXXXX")" \
		bash -c "source '$REPO_ROOT/scripts/include_all.sh' 2>/dev/null; trap - ERR; $code" 2>&1 )
	echo "rc=$?"
}
rc_of() { sed -n 's/^rc=//p' <<< "$1" | tail -1; }

echo "=== helpers exist ==="
for fn in dist_pull_secret_ensure dist_pull_secret_hint; do
	( source "$REPO_ROOT/scripts/include_all.sh" 2>/dev/null; declare -F "$fn" >/dev/null ) && _pass "defined: $fn" || _fail "missing: $fn"
done

echo ""
echo "=== check_internet_connectivity: probes by distribution ==="
: > "$CURL_LOG"
out=$(run ocp "" "" 'check_internet_connectivity t quiet; echo "failed=[$FAILED_SITES]"')
_eq "ocp: all reachable -> rc 0" "0" "$(rc_of "$out")"
_has "ocp: probes api.openshift.com" "https://api.openshift.com/" "$(cat "$CURL_LOG")"
_has "ocp: probes mirror.openshift.com" "https://mirror.openshift.com/" "$(cat "$CURL_LOG")"
_has "ocp: probes registry.redhat.io" "https://registry.redhat.io/" "$(cat "$CURL_LOG")"
_eq "ocp: exactly 3 probes" "3" "$(wc -l < "$CURL_LOG")"

: > "$CURL_LOG"
out=$(run okd "" "" 'check_internet_connectivity t quiet; echo "failed=[$FAILED_SITES]"')
_eq "okd: all reachable -> rc 0" "0" "$(rc_of "$out")"
for h in github.com quay.io updates.okd.io mirror.openshift.com; do
	_has "okd: probes $h" "https://$h/" "$(cat "$CURL_LOG")"
done
_hasnt "okd: never probes registry.redhat.io" "redhat\.io" "$(cat "$CURL_LOG")"
_hasnt "okd: never probes api.openshift.com" "api\.openshift\.com" "$(cat "$CURL_LOG")"
_eq "okd: exactly 4 probes" "4" "$(wc -l < "$CURL_LOG")"

: > "$CURL_LOG"
out=$(CURL_FAIL='quay\.io' run okd "" "" 'check_internet_connectivity t quiet; r=$?; echo "failed=[$FAILED_SITES] details=[$ERROR_DETAILS] r=$r"')
_has "okd: unreachable quay.io reported in FAILED_SITES" "failed=\[quay\.io\]" "$out"
_has "okd: ERROR_DETAILS names the host" "details=\[ +quay\.io: " "$out"
_has "okd: function returns 1" "r=1" "$out"
out=$(CURL_FAIL='quay\.io|github\.com' run okd "" "" 'check_internet_connectivity t2 quiet; echo "failed=[$FAILED_SITES] detail-lines=$(echo "$ERROR_DETAILS" | wc -l)"')
_has "okd: two failures listed, comma separated" "failed=\[github\.com, quay\.io\]" "$out"
_has "okd: one detail line per failed site" "detail-lines=2" "$out"
_hasnt "okd: failures never mention registry.redhat.io" "registry\.redhat\.io" "$out"
out=$(CURL_FAIL='registry\.redhat\.io' run okd "" "" 'check_internet_connectivity t3 quiet; echo "failed=[$FAILED_SITES]"')
_has "okd: registry.redhat.io down does not matter" "failed=\[\]" "$out"
out=$(CURL_FAIL='registry\.redhat\.io' run ocp "" "" 'check_internet_connectivity t4 quiet; echo "failed=[$FAILED_SITES]"')
_has "ocp: registry.redhat.io down is still fatal" "failed=\[registry\.redhat\.io\]" "$out"

echo ""
echo "=== aba_inet_check_reset clears the per-site caches of the distribution ==="
out=$(run okd "" "" 'check_internet_connectivity aba quiet
for h in github.com quay.io updates.okd.io; do run_once -p -i "aba:check:$h" >/dev/null 2>&1; echo "before:$h=$?"; done
aba_inet_check_reset
for h in github.com quay.io updates.okd.io; do run_once -p -i "aba:check:$h" >/dev/null 2>&1; echo "after:$h=$?"; done')
for h in github.com quay.io updates.okd.io; do
	_has "okd: $h probe is cached before the reset" "before:$h=0" "$out"
	_has "okd: reset clears the $h probe" "after:$h=[1-9]" "$out"
done

echo ""
echo "=== dist_pull_secret_ensure (okd) ==="
PS="$T/ps/pull-secret.json"; mkdir -p "$T/ps"
rm -f "$PS"
out=$(run okd "" "" "dist_pull_secret_ensure '$PS'")
_eq "no file, no operators -> ok" "0" "$(rc_of "$out")"
_eq "placeholder written is the official OKD value" "$OFFICIAL_FAKE" "$(tr -d '\n' < "$PS")"
_eq "placeholder file mode 600" "600" "$(stat -c %a "$PS")"
rm -f "$PS"
out=$(run okd "" "" "umask 022; dist_pull_secret_ensure '$PS'")
_eq "placeholder file mode 600 whatever the caller's umask" "600" "$(stat -c %a "$PS")"
out=$(run okd "" "" "dist_pull_secret_ensure '$T/no-such-dir/ps.json'")
_eq "unwritable location -> problem" "1" "$(rc_of "$out")"
_has "unwritable location message" "Cannot write" "$out"
rm -f "$PS"
echo '{"auths":{"quay.io":{"auth":"dXNlcjpwdw=="}}}' > "$PS"; cp "$PS" "$T/ps/orig"
out=$(run okd "" "" "dist_pull_secret_ensure '$PS'")
_eq "existing valid secret -> ok" "0" "$(rc_of "$out")"
_eq "existing secret is not overwritten" "$(cat "$T/ps/orig")" "$(cat "$PS")"
echo '{"auths":{"registry.redhat.io":{"auth":"dXNlcjpwdw=="}}}' > "$PS"
out=$(run okd "" "" "dist_pull_secret_ensure '$PS'")
_eq "okd does not demand a registry.redhat.io entry" "0" "$(rc_of "$out")"
echo '{"auths":' > "$PS"
out=$(run okd "" "" "dist_pull_secret_ensure '$PS'")
_eq "invalid JSON -> problem" "1" "$(rc_of "$out")"
_has "invalid JSON message" "invalid JSON" "$out"
echo '{"auths":{}}' > "$PS"
out=$(run okd "" "" "dist_pull_secret_ensure '$PS'")
_eq "empty auths -> problem" "1" "$(rc_of "$out")"
echo '{}' > "$PS"
out=$(run okd "" "" "dist_pull_secret_ensure '$PS'")
_eq "no auths key -> problem" "1" "$(rc_of "$out")"
rm -f "$PS"
out=$(run okd "cert-manager" "" "dist_pull_secret_ensure '$PS'")
_eq "no file, ops set -> problem" "1" "$(rc_of "$out")"
_has "message says why" "(ops|op_sets)" "$out"
_hasnt "no console.redhat.com on okd" "console\.redhat\.com" "$out"
[ ! -e "$PS" ] && _pass "no placeholder written when operators are selected" || _fail "placeholder written although ops set"
out=$(run okd "" "acm" "dist_pull_secret_ensure '$PS'")
_eq "no file, op_sets set -> problem" "1" "$(rc_of "$out")"
echo "$OFFICIAL_FAKE" > "$PS"
out=$(run okd "cert-manager" "" "dist_pull_secret_ensure '$PS'")
_eq "placeholder + ops -> problem (operators need real credentials)" "1" "$(rc_of "$out")"
_has "placeholder message" "placeholder" "$out"
out=$(run okd "" "" "dist_pull_secret_ensure '$PS'")
_eq "placeholder without ops -> ok" "0" "$(rc_of "$out")"
out=$(run okd "" "" "dist_pull_secret_hint '$PS'")
_has "hint names the file" "$PS" "$out"
_hasnt "hint has no console.redhat.com" "console\.redhat\.com" "$out"

echo ""
echo "=== validate_pull_secret ==="
: > "$SKOPEO_LOG"
echo "$OFFICIAL_FAKE" > "$PS"
out=$(run okd "" "" "validate_pull_secret '$PS'")
_eq "okd: placeholder is valid" "0" "$(rc_of "$out")"
_eq "okd: skopeo (registry.redhat.io login) not called" "0" "$(wc -l < "$SKOPEO_LOG")"
_hasnt "okd: no registry.redhat.io in output" "registry\.redhat\.io" "$out"
echo '{"auths":{}}' > "$PS"
out=$(run okd "" "" "validate_pull_secret '$PS'")
_eq "okd: empty auths invalid" "1" "$(rc_of "$out")"
out=$(run okd "" "" "validate_pull_secret '$T/ps/none.json'")
_eq "okd: missing file invalid" "1" "$(rc_of "$out")"
: > "$PS"
out=$(run okd "" "" "validate_pull_secret '$PS'")
_eq "okd: empty file invalid" "1" "$(rc_of "$out")"
echo "$OFFICIAL_FAKE" > "$PS"
out=$(run okd "cert-manager" "" "validate_pull_secret '$PS'")
_eq "okd: placeholder with ops invalid" "1" "$(rc_of "$out")"
out=$(run ocp "" "" "validate_pull_secret '$PS'")
_eq "ocp: placeholder (no registry.redhat.io entry) still rejected" "1" "$(rc_of "$out")"
_has "ocp: unchanged message" "No registry.redhat.io entry in pull secret" "$out"

echo ""
echo "=== require_internet_and_pull_secret ==="
: > "$CURL_LOG"; : > "$SKOPEO_LOG"
rm -f "$PS"
out=$(run okd "" "" "pull_secret_file='$PS'; require_internet_and_pull_secret")
_eq "okd: no file, no operators -> passes" "0" "$(rc_of "$out")"
_eq "okd: placeholder created" "$OFFICIAL_FAKE" "$(tr -d '\n' < "$PS" 2>/dev/null)"
_has "okd: probes quay.io" "quay\.io" "$(cat "$CURL_LOG")"
_has "okd: probes github.com" "github\.com" "$(cat "$CURL_LOG")"
_hasnt "okd: never probes registry.redhat.io" "redhat\.io" "$(cat "$CURL_LOG")"

rm -f "$PS"
out=$(run okd "cert-manager" "" "pull_secret_file='$PS'; require_internet_and_pull_secret")
_eq "okd: ops but no pull secret -> abort" "1" "$(rc_of "$out")"
_has "okd: says a pull secret is needed for operators" "(ops|op_sets)" "$out"
_hasnt "okd: no console.redhat.com" "console\.redhat\.com" "$out"
_hasnt "okd: no registry.redhat.io" "registry\.redhat\.io" "$out"
_has "okd: says how to provide the pull secret" "Docker config JSON" "$out"

: > "$CURL_LOG"
out=$(CURL_FAIL='quay\.io|github\.com' run okd "" "" "pull_secret_file='$PS'; require_internet_and_pull_secret")
_has "okd: every unreachable host is named" "cannot reach quay\.io, github\.com" "$out"
out=$(CURL_FAIL='quay\.io' run okd "" "" "pull_secret_file='$PS'; require_internet_and_pull_secret")
_eq "okd: quay.io unreachable -> abort" "1" "$(rc_of "$out")"
_has "okd: names quay.io" "quay\.io" "$out"
_has "okd: save/sync need a connected host" "connected host" "$out"

# two problems at once are listed, numbered
rm -f "$PS"
out=$(CURL_FAIL='quay\.io' run okd "cert-manager" "" "pull_secret_file='$PS'; require_internet_and_pull_secret")
_has "okd: several problems -> numbered list" "  1\. No internet access" "$out"
_has "okd: second problem numbered 2" "  2\. No pull secret found" "$out"

# mirror mode (sync passes the mirror secret as fallback): it MUST be valid even when no global secret is needed
MS="$T/ps/pull-secret-mirror.json"
rm -f "$PS" "$MS"
out=$(run okd "" "" "pull_secret_file='$PS'; require_internet_and_pull_secret '$MS'")
_eq "okd mirror: mirror secret missing -> abort" "1" "$(rc_of "$out")"
_has "okd mirror: message names the mirror secret" "(irror)" "$out"
echo '{"auths":' > "$MS"
out=$(run okd "" "" "pull_secret_file='$PS'; require_internet_and_pull_secret '$MS'")
_eq "okd mirror: mirror secret invalid JSON -> abort" "1" "$(rc_of "$out")"
echo '{"auths":{}}' > "$MS"
out=$(run okd "" "" "pull_secret_file='$PS'; require_internet_and_pull_secret '$MS'")
_eq "okd mirror: mirror secret without credentials -> abort" "1" "$(rc_of "$out")"
echo '{"auths":{"mirror.example.com:8443":{"auth":"aW5pdDpwdw=="}}}' > "$MS"
rm -f "$PS"
out=$(run okd "" "" "pull_secret_file='$PS'; require_internet_and_pull_secret '$MS'")
_eq "okd mirror: valid mirror secret, no global secret -> passes" "0" "$(rc_of "$out")"
_eq "okd mirror: placeholder supplies the public side" "$OFFICIAL_FAKE" "$(tr -d '\n' < "$PS" 2>/dev/null)"

# ocp unchanged
: > "$CURL_LOG"
rm -f "$PS"
out=$(run ocp "" "" "pull_secret_file='$PS'; require_internet_and_pull_secret")
_eq "ocp: no pull secret -> abort" "1" "$(rc_of "$out")"
_has "ocp: still points at console.redhat.com" "console\.redhat\.com" "$out"
_has "ocp: probes registry.redhat.io/v2/" "https://registry\.redhat\.io/v2/" "$(cat "$CURL_LOG")"
[ ! -e "$PS" ] && _pass "ocp: nothing written" || _fail "ocp wrote a pull secret file"
echo "$OFFICIAL_FAKE" > "$PS"
out=$(run ocp "" "" "pull_secret_file='$PS'; require_internet_and_pull_secret")
_eq "ocp: placeholder is not a Red Hat pull secret -> abort" "1" "$(rc_of "$out")"
_has "ocp: unchanged message" "does not contain registry\.redhat\.io credentials" "$out"
echo '{"auths":{"registry.redhat.io":{"auth":"dXNlcjpwdw=="}}}' > "$PS"
out=$(run ocp "" "" "pull_secret_file='$PS'; require_internet_and_pull_secret")
_eq "ocp: Red Hat pull secret passes" "0" "$(rc_of "$out")"

echo ""
echo "=== install-pull-secret.sh ==="
# A throw-away aba root: aba.conf rendered from the template, scripts/ linked from the repo.
R="$T/root"; mkdir -p "$R"
for d in scripts templates; do ln -s "$REPO_ROOT/$d" "$R/$d"; done
( cd "$R" && PATH=/usr/sbin:/usr/bin:/bin domain=example.com scripts/j2 templates/aba.conf.j2 > aba.conf ) 2>/dev/null
if [ ! -s "$R/aba.conf" ]; then
	_fail "could not render aba.conf from templates/aba.conf.j2"
else
	sedc() { sed -i -e "s|^$1=.*|$1=$2|" "$R/aba.conf"; }
	sedc machine_network 10.0.0.0/20; sedc next_hop_address 10.0.0.1; sedc dns_servers 10.0.0.1; sedc ntp_servers 10.0.0.1
	sedc ocp_version 4.21.0-okd-scos.11; sedc ocp_channel stable; sedc pull_secret_file "$PS"
	grep -q '^distribution=' "$R/aba.conf" && sedc distribution okd || echo "distribution=okd" >> "$R/aba.conf"
	ips() { ( cd "$R" && RUN_ONCE_DIR="$T/runner-ips" bash scripts/install-pull-secret.sh 2>&1; echo "rc=$?" ); }
	rm -f "$PS"
	out=$(ips)
	_eq "okd: no file, no operators -> exit 0" "0" "$(rc_of "$out")"
	_eq "okd: official placeholder written" "$OFFICIAL_FAKE" "$(tr -d '\n' < "$PS" 2>/dev/null)"
	_hasnt "okd: no console.redhat.com" "console\.redhat\.com" "$out"
	echo '{"auths":{"quay.io":{"auth":"dXNlcjpwdw=="}}}' > "$PS"
	out=$(ips)
	_eq "okd: valid secret without registry.redhat.io -> exit 0" "0" "$(rc_of "$out")"
	echo '{"auths":' > "$PS"
	out=$(ips)
	_eq "okd: broken JSON -> exit 1" "1" "$(rc_of "$out")"
	_hasnt "okd: broken JSON message has no console.redhat.com" "console\.redhat\.com" "$out"
	rm -f "$PS"; sedc ops cert-manager
	out=$(ips)
	_eq "okd: ops, no file -> exit 1" "1" "$(rc_of "$out")"
	_hasnt "okd: ops message has no console.redhat.com" "console\.redhat\.com" "$out"
	sedc ops ""
	# ocp: unchanged
	sedc distribution ocp; sedc ocp_version 4.21.0
	rm -f "$PS"
	out=$(ips)
	_eq "ocp: no file -> exit 1" "1" "$(rc_of "$out")"
	_has "ocp: still points at console.redhat.com" "console\.redhat\.com" "$out"
	echo "$OFFICIAL_FAKE" > "$PS"
	out=$(ips)
	_eq "ocp: placeholder rejected" "1" "$(rc_of "$out")"
	_has "ocp: expected-string message unchanged" "Expected to see the string 'registry.redhat.io'" "$out"
fi

echo ""
echo "=== create-containers-auth.sh (reads the pull secret for save/sync) ==="
if [ -s "$R/aba.conf" ]; then
	cauth() {  # cauth <dist> <ops>
		( cd "$R" && sed -i -e "s|^ops=.*|ops=$2|" -e "s|^distribution=.*|distribution=$1|" aba.conf
		  HOME="$T/home" XDG_RUNTIME_DIR="$T/xdg" RUN_ONCE_DIR="$T/runner-ca" regcreds_dir="$T/regcreds" bash scripts/create-containers-auth.sh 2>&1; echo "rc=$?" )
	}
	mkdir -p "$T/xdg" "$T/regcreds"
	sedc ocp_version 4.21.0-okd-scos.11
	rm -f "$PS" "$T/home/.docker/config.json"
	out=$(cauth okd "")
	_eq "okd: no file, no operators -> exit 0" "0" "$(rc_of "$out")"
	_eq "okd: placeholder written" "$OFFICIAL_FAKE" "$(tr -d '\n' < "$PS" 2>/dev/null)"
	_has "okd: container auth carries the placeholder" '"fake"' "$(cat "$T/home/.docker/config.json" 2>/dev/null)"
	_hasnt "okd: no console.redhat.com" "console\.redhat\.com" "$out"
	rm -f "$PS"
	out=$(cauth okd "cert-manager")
	_eq "okd: no file, operators -> exit 1" "1" "$(rc_of "$out")"
	_hasnt "okd: operators message has no console.redhat.com" "console\.redhat\.com" "$out"
	[ ! -e "$PS" ] && _pass "okd: nothing written when operators are selected" || _fail "okd: placeholder written with operators"
	sedc ocp_version 4.21.0
	rm -f "$PS"
	out=$(cauth ocp "")
	_eq "ocp: no file -> exit 1" "1" "$(rc_of "$out")"
	_has "ocp: still points at console.redhat.com" "console\.redhat\.com" "$out"
fi

echo ""
echo "=== verify-aba-conf: pull_secret_file ==="
if [ -s "$R/aba.conf" ]; then
	vps() {  # vps <dist> <ops> <op_sets> <pull_secret_file value>
		sedc ops "$2"; sedc op_sets "$3"
		if [ "$1" = okd ]; then sedc ocp_version 4.21.0-okd-scos.11; else sedc ocp_version 4.21.0; fi
		sedc distribution "$1"
		( cd "$R" && HOME="$T/home" RUN_ONCE_DIR="$T/runner-vps" bash -c "source scripts/include_all.sh 2>/dev/null; trap - ERR; source <(normalize-aba-conf); pull_secret_file='$4'; verify-aba-conf; echo rc=\$? psf=[\$pull_secret_file]" 2>&1 )
	}
	out=$(vps okd "" "" "")
	_has "okd: no pull_secret_file and no operators -> valid" "rc=0" "$out"
	_has "okd: the template default is used for the placeholder" "psf=\[$T/home/\.pull-secret\.json\]" "$out"
	_hasnt "okd: no pull_secret_file error" "pull_secret_file missing" "$out"
	out=$(vps okd "" "" "$T/elsewhere.json")
	_has "okd: a configured pull_secret_file is kept" "psf=\[$T/elsewhere\.json\]" "$out"
	out=$(vps okd "cert-manager" "" "")
	_has "okd: operators (ops) need pull_secret_file" "pull_secret_file missing in aba.conf" "$out"
	_has "okd: ops without pull_secret_file -> invalid" "rc=1" "$out"
	out=$(vps okd "" "acm" "")
	_has "okd: operator sets (op_sets) need pull_secret_file" "pull_secret_file missing in aba.conf" "$out"
	out=$(vps ocp "" "" "")
	_has "ocp: pull_secret_file still required" "pull_secret_file missing in aba.conf" "$out"
	_has "ocp: invalid" "rc=1" "$out"
	_has "ocp: nothing assigned" "psf=\[\]" "$out"
	out=$(vps ocp "" "" "$T/elsewhere.json")
	_has "ocp: configured pull_secret_file accepted" "rc=0" "$out"
	sedc ops ""; sedc op_sets ""; sedc distribution ocp; sedc ocp_version 4.21.0
fi

echo ""
echo "=== create-install-config.sh: the OKD placeholder covers direct and proxy installs only ==="
cic=$(sed -n '/^# OKD: no Red Hat pull secret needed/,/^fi$/p' scripts/create-install-config.sh)
_has "okd + direct/proxy + no file calls dist_pull_secret_ensure" 'dist_pull_secret_ensure "\$pull_secret_file"' "$cic"
_has "limited to direct and proxy" 'image_source" = "direct" -o "\$image_source" = "proxy"' "$cic"
_has "a missing file stays missing for mirror installs (condition on the file)" '\[ ! -s "\$pull_secret_file" \]' "$cic"

echo ""
echo "=== product text carries no internal identifiers / OKD release literals ==="
_hasnt "include_all: no okd release literal in pull-secret code" "okd-scos\.[0-9]" "$(sed -n '/^dist_pull_secret_ensure()/,/^}/p' scripts/include_all.sh)"

echo ""
echo "Passed: $pass  Failed: $fail"
[ "$fail" -eq 0 ]
