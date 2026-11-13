#!/bin/bash
# Test: sigstore (registries.d) configuration per distribution.
#   - the OCP template is the one deployed today (RH signatures on, registry.redhat.io scope kept)
#   - the OKD template keeps the global default off, adds quay.io/okd: off and has no registry.redhat.io scope
#   - ensure_sigstore_distribution_config switches the per-user file only when it is still an untouched stock file
# Offline, HOME is a temp dir.

cd "$(dirname "$0")/../.." || exit 1
REPO=$PWD
source scripts/include_all.sh 2>/dev/null
trap - ERR

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }
_eq() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1: expected [$2] got [$3]"; fi; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

OCPT=templates/aba-sigstore-config.yaml
OKDT=templates/aba-sigstore-config-okd.yaml

# value of a key in the parsed template, "-" if absent
_get() { yaml2json < "$1" | jq -r "($2) | if . == null then \"-\" else . end"; }

echo "=== templates ==="
[ -s "$OCPT" ] && _pass "OCP template present" || _fail "OCP template missing"
[ -s "$OKDT" ] && _pass "OKD template present" || _fail "OKD template missing"
_eq "ocp: default-docker sigstore off" false "$(_get $OCPT '.["default-docker"]["use-sigstore-attachments"]')"
_eq "ocp: openshift-release-dev on" true "$(_get $OCPT '.docker["quay.io/openshift-release-dev"]["use-sigstore-attachments"]')"
_eq "ocp: registry.redhat.io on" true "$(_get $OCPT '.docker["registry.redhat.io"]["use-sigstore-attachments"]')"
_eq "ocp: no quay.io/okd scope" - "$(_get $OCPT '.docker["quay.io/okd"]')"
_eq "okd: default-docker sigstore off" false "$(_get $OKDT '.["default-docker"]["use-sigstore-attachments"]')"
_eq "okd: quay.io/okd off (no cosign attachments there)" false "$(_get $OKDT '.docker["quay.io/okd"]["use-sigstore-attachments"]')"
_eq "okd: no registry.redhat.io scope (never contacted)" - "$(_get $OKDT '.docker["registry.redhat.io"]')"
_eq "okd: registry.access.redhat.com lookaside kept (anonymous community content)" \
	"https://access.redhat.com/webassets/docker/content/sigstore" "$(_get $OKDT '.docker["registry.access.redhat.com"].lookaside')"
_eq "okd: no scope other than the expected ones" \
	"quay.io/okd,quay.io/openshift-release-dev,registry.access.redhat.com" \
	"$(yaml2json < $OKDT | jq -r '.docker | keys | join(",")')"
# no internal ids in shipped text
if grep -Eq 'ABA-[0-9]|DEC-[0-9]|EP-[0-9]|TDD' $OKDT $OCPT; then _fail "templates: internal ids in text"; else _pass "templates: no internal ids in text"; fi

echo ""
echo "=== ensure_sigstore_distribution_config ==="
if ! declare -F ensure_sigstore_distribution_config >/dev/null; then _fail "ensure_sigstore_distribution_config is not defined"; fi
D=$T/home/.config/containers/registries.d
_run() { # dist  -> runs the function with HOME=$T/home, from the repo root; prints stderr+stdout
	( export HOME=$T/home INFO_ABA=1; export distribution="$1"; [ "$1" = UNSET ] && unset distribution
	  ensure_sigstore_distribution_config 2>&1 )
}
_reset() { rm -rf "$T/home"; mkdir -p "$D"; }

_reset
out=$(_run okd); [ ! -e "$D/aba-sigstore.yaml" ] && [ -z "$out" ] && _pass "no per-user file: nothing created, nothing said (okd)" || _fail "okd with no per-user file: created a file or spoke [$out]"
out=$(_run ocp); [ ! -e "$D/aba-sigstore.yaml" ] && [ -z "$out" ] && _pass "no per-user file: nothing created, nothing said (ocp)" || _fail "ocp with no per-user file: created a file or spoke [$out]"

_reset; cp $OCPT "$D/aba-sigstore.yaml"
out=$(_run okd)
cmp -s $OKDT "$D/aba-sigstore.yaml" && _pass "okd + stock OCP file -> OKD file" || _fail "okd + stock OCP file not switched"
[ -n "$out" ] && _pass "okd switch says so ($out)" || _fail "okd switch is silent"
out=$(_run okd); cmp -s $OKDT "$D/aba-sigstore.yaml" && [ -z "$out" ] && _pass "okd again: unchanged and silent" || _fail "okd again: changed or noisy [$out]"
out=$(_run ocp)
cmp -s $OCPT "$D/aba-sigstore.yaml" && _pass "back to ocp: stock OCP file restored" || _fail "back to ocp: file not restored"
out=$(_run ocp); cmp -s $OCPT "$D/aba-sigstore.yaml" && [ -z "$out" ] && _pass "ocp again: unchanged and silent" || _fail "ocp again: changed or noisy [$out]"

# a pure OCP user: the function never writes (mtime and inode stay)
_reset; cp $OCPT "$D/aba-sigstore.yaml"; touch -d '2020-01-01' "$D/aba-sigstore.yaml"; before=$(stat -c '%i %Y' "$D/aba-sigstore.yaml")
_run ocp >/dev/null; _run "" >/dev/null; _run UNSET >/dev/null
_eq "ocp / empty / unset: file not rewritten" "$before" "$(stat -c '%i %Y' "$D/aba-sigstore.yaml")"

# user edits are never overwritten
_reset; { cat $OCPT; printf '    quay.io/mine:\n        use-sigstore-attachments: true\n'; } > "$D/aba-sigstore.yaml"; cp "$D/aba-sigstore.yaml" "$T/mine"
out=$(_run okd)
cmp -s "$T/mine" "$D/aba-sigstore.yaml" && _pass "okd + edited file: left alone" || _fail "okd overwrote an edited file"
if grep -qi 'quay.io/okd' <<<"$out"; then _pass "okd + edited file: tells what to add"; else _fail "okd + edited file: no hint [$out]"; fi
out=$(_run ocp); cmp -s "$T/mine" "$D/aba-sigstore.yaml" && _pass "ocp + edited file: left alone" || _fail "ocp overwrote an edited file"
# nothing to say about an edited file on OCP, nor when it already carries the OKD scope
_reset; { cat $OCPT; printf '    quay.io/mine:\n        use-sigstore-attachments: true\n'; } > "$D/aba-sigstore.yaml"
out=$(_run ocp); [ -z "$out" ] && _pass "ocp + edited file: silent" || _fail "ocp + edited file: noisy [$out]"
out=$(_run UNSET); [ -z "$out" ] && _pass "no distribution + edited file: silent" || _fail "no distribution + edited file: noisy [$out]"
_reset; { cat $OCPT; printf '    quay.io/okd:\n        use-sigstore-attachments: false\n'; } > "$D/aba-sigstore.yaml"
out=$(_run okd); [ -z "$out" ] && _pass "okd + edited file that already has the quay.io/okd scope: silent" || _fail "okd + edited file with the scope: noisy [$out]"
# an edited OKD file stays too
_reset; { cat $OKDT; printf '    quay.io/mine:\n        use-sigstore-attachments: true\n'; } > "$D/aba-sigstore.yaml"; cp "$D/aba-sigstore.yaml" "$T/mine2"
_run ocp >/dev/null; cmp -s "$T/mine2" "$D/aba-sigstore.yaml" && _pass "ocp + edited OKD file: left alone" || _fail "ocp overwrote an edited OKD file"

# run where there is no templates/ (the function reads the stock files from there): nothing happens, nothing is said
for d in okd ocp; do
	_reset; cp $OCPT "$D/aba-sigstore.yaml"; cp "$D/aba-sigstore.yaml" "$T/stock-before"
	out=$( cd "$T" && export HOME=$T/home INFO_ABA=1 distribution=$d && ensure_sigstore_distribution_config 2>&1 ); rc=$?
	if [ "$rc" -eq 0 ] && [ -z "$out" ] && cmp -s "$T/stock-before" "$D/aba-sigstore.yaml"; then _pass "$d without templates/: no-op"; else _fail "$d without templates/: rc=$rc out=[$out]"; fi
done

# per-mirror drop-ins written by ensure_sigstore_mirror_config are not touched
_reset; cp $OCPT "$D/aba-sigstore.yaml"; printf 'docker:\n    reg.example.com:8443:\n        use-sigstore-attachments: true\n' > "$D/aba-sigstore-mirror-reg.example.com-8443.yaml"
cp "$D/aba-sigstore-mirror-reg.example.com-8443.yaml" "$T/mirror-dropin"
_run okd >/dev/null; cmp -s "$T/mirror-dropin" "$D/aba-sigstore-mirror-reg.example.com-8443.yaml" && _pass "mirror drop-in untouched" || _fail "mirror drop-in changed"

echo ""
echo "=== callers ==="
# the oc-mirror steps (save, sync, load) apply it before they run oc-mirror
for s in reg-save reg-sync reg-load; do
	if grep -q 'ensure_sigstore_distribution_config' scripts/$s.sh; then _pass "$s.sh calls ensure_sigstore_distribution_config"; else _fail "$s.sh does not call ensure_sigstore_distribution_config"; fi
done

echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
