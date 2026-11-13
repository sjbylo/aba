#!/bin/bash
# Test: curated image sets per distribution
#
# OKD has its own set (image-set-okd); the OpenShift and AI sets, and the guest
# RHEL images of the virtualization set, come from registry.redhat.io, which
# needs a Red Hat account, so they are not offered for OKD. OCP behaviour is
# checked byte for byte against the shipped templates.

cd "$(dirname "$0")/../.." || exit 1
source scripts/include_all.sh 2>/dev/null
trap - ERR

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }
_chk() { [[ "$2" == "$3" ]] && _pass "$1" || _fail "$1: expected [$2] got [$3]"; }

echo "=== image sets per distribution (unit) ==="

_ROOT="$PWD"
_T=$(mktemp -d)
trap 'rm -rf "$_T"' EXIT
export ABA_ROOT="$_T"
mkdir -p "$_T/templates"
cp -a "$_ROOT"/templates/image-set-* "$_ROOT/templates/images.conf" "$_T/templates/"
cd "$_T" || exit 1

# --- the okd set exists and is anonymous-only --------------------------------------------------
[ -f "$_ROOT/templates/image-set-okd" ] && _pass "templates/image-set-okd shipped" || _fail "templates/image-set-okd missing"
_okd_imgs=$(sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' "$_ROOT/templates/image-set-okd" 2>/dev/null)
echo "$_okd_imgs" | grep -q '^registry.access.redhat.com/ubi9/ubi:' && _pass "okd set: ubi9 from registry.access.redhat.com" || _fail "okd set: no ubi9 from registry.access.redhat.com"
echo "$_okd_imgs" | grep -q 'registry.redhat.io' && _fail "okd set: registry.redhat.io image present" || _pass "okd set: no registry.redhat.io image"
echo "$_okd_imgs" | grep -q 'support-tools' && _fail "okd set: support-tools present (401 without an account)" || _pass "okd set: no support-tools"
echo "$_okd_imgs" | grep -q 'rhel' && _fail "okd set: rhel image present" || _pass "okd set: no rhel image"
_bad=$(echo "$_okd_imgs" | grep -v -E '^(registry\.access\.redhat\.com|quay\.io)/' || true)
_chk "okd set: every image from an anonymous registry" "" "$_bad"
head -n1 "$_ROOT/templates/image-set-okd" 2>/dev/null | grep -q '^# Name: ' && _pass "okd set has a display name line" || _fail "okd set: first line is not '# Name: ...'"
grep -q -i 'oc debug' "$_ROOT/templates/image-set-okd" 2>/dev/null && _pass "okd set explains that oc debug uses the payload tools image" || _fail "okd set: no note about the payload tools image"

# --- OKD ------------------------------------------------------------------------------------------------
export distribution=okd
_list=$(image_set_list | cut -f1 | paste -sd,)
_chk "okd: sets offered" "okd,virt" "$_list"
_chk "okd: display name" "$(head -n1 "$_ROOT/templates/image-set-okd" | sed 's/^# *//; s/^Name: *//')" "$(_image_set_display_name okd)"
_chk "okd: virt keeps the containerdisks, loses the guest RHEL images" \
	"quay.io/containerdisks/centos-stream:10,quay.io/containerdisks/centos-stream:9,quay.io/containerdisks/fedora:latest" \
	"$(_image_set_static_images virt | paste -sd,)"
_chk "okd: okd set images = template images" "$_okd_imgs" "$(_image_set_static_images okd)"
rm -f images.conf
_c=$(image_set_add okd); _chk "okd: add okd set: rc" 0 $?
_chk "okd: add okd set: count" "$(echo "$_okd_imgs" | wc -l)" "$_c"
_c=$(image_set_add virt); _chk "okd: add virt set: count" 3 "$_c"
grep -q 'registry.redhat.io' images.conf && _fail "okd: images.conf got a registry.redhat.io image" || _pass "okd: images.conf has no registry.redhat.io image"
grep -q 'support-tools' images.conf && _fail "okd: images.conf got support-tools" || _pass "okd: images.conf has no support-tools"
_chk "okd: list shows the added sets" "okd:added,virt:added" "$(image_set_list | awk -F'\t' '{print $1 ":" $3}' | paste -sd,)"
image_set_add ocp >/dev/null 2>&1; _chk "okd: the OpenShift set is refused" 1 $?
image_set_add ai >/dev/null 2>&1; _chk "okd: the AI set is refused" 1 $?
grep -q 'image-set: ocp' images.conf && _fail "okd: ocp block written" || _pass "okd: no ocp block written"
image_set_remove okd >/dev/null 2>&1; _chk "okd: remove okd set" 0 $?
grep -q 'image-set: okd' images.conf && _fail "okd: okd block not removed" || _pass "okd: okd block removed"

# a set whose images are all dropped must not fire an ERR trap of a caller that uses one (grep -v exits 1 on no output)
( set -E; _trap=0; trap '_trap=1' ERR; _image_set_static_images ocp >/dev/null; trap - ERR; exit $_trap )
_chk "okd: filtering every image away does not trip a caller's ERR trap" 0 $?

# a second okd release does not change anything: no version in the set
_chk "okd: set has no version/digest literal" 0 "$(grep -c -E '[0-9]+\.[0-9]+\.[0-9]+|sha256:|okd-scos' "$_ROOT/templates/image-set-okd")"

# --- OCP: unchanged -----------------------------------------------------------------------------------------
export distribution=ocp
_chk "ocp: sets offered" "ai,ocp,virt" "$(image_set_list | cut -f1 | paste -sd,)"
_chk "ocp: virt images (guest RHEL kept)" \
	"registry.redhat.io/rhel9/rhel-guest-image:latest,registry.redhat.io/rhel10/rhel-guest-image:latest,quay.io/containerdisks/centos-stream:10,quay.io/containerdisks/centos-stream:9,quay.io/containerdisks/fedora:latest" \
	"$(_image_set_static_images virt | paste -sd,)"
_chk "ocp: ocp set images" \
	"registry.redhat.io/ubi9/ubi:latest,registry.redhat.io/ubi9/ubi-micro:latest,registry.redhat.io/rhel9/support-tools:latest" \
	"$(_image_set_static_images ocp | paste -sd,)"
rm -f images.conf
image_set_add okd >/dev/null 2>&1; _chk "ocp: the okd set is refused" 1 $?
[ -s images.conf ] && _fail "ocp: refused okd set wrote to images.conf" || _pass "ocp: refused okd set wrote nothing"
unset distribution
_chk "no distribution key = ocp: sets offered" "ai,ocp,virt" "$(image_set_list | cut -f1 | paste -sd,)"
_chk "no distribution key = ocp: virt count" 5 "$(_image_set_static_images virt | wc -l)"

echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
