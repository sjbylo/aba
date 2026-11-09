#!/bin/bash
# Test: callers derive ocp_major before rendering, and a failed render stops.
# Regression for: ADR-005 removed ocp_major from normalize output. The
# image-content-sources template then raised UndefinedError, the assignment
# kept the empty output, and install-config.yaml was reported as generated
# with no ImageDigestSources. mirror.conf.j2 silently wrote /ocp/openshift.

cd "$(dirname "$0")/../.." || exit 1

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }

echo "=== ocp_major is set by the render callers ==="

_load_renderer() {
	# shellcheck disable=SC1091
	source scripts/include_all.sh
	eval "$(awk '/^_render_image_content_sources\(\)/{p=1} p{print} p && /^}/{exit}' scripts/create-install-config.sh)"
}

_out=$(
	_load_renderer
	unset ocp_major
	ocp_version=4.19.5
	reg_host=registry.example.com
	reg_port=8443
	reg_path=/ocp4/openshift4
	_render_image_content_sources
	printf '%s\n' "MAJOR=$ocp_major"
	printf '%s\n' "$image_content_sources"
)
if echo "$_out" | grep -q '^MAJOR=4$' && echo "$_out" | grep -q 'ocp-v4.0-art-dev' \
	&& ! echo "$_out" | grep -q 'ocp-v5.0-art-dev'; then
	_pass "4.19.5 renders ocp-v4.0-art-dev"
else
	_fail "4.19.5 content sources"
	echo "$_out"
fi

_out=$(
	_load_renderer
	unset ocp_major
	ocp_version=5.0.3
	reg_host=registry.example.com
	reg_port=8443
	reg_path=/ocp5/openshift5
	_render_image_content_sources
	printf '%s\n' "$image_content_sources"
)
if echo "$_out" | grep -q 'ocp-v5.0-art-dev' && echo "$_out" | grep -q 'ocp-v4.0-art-dev'; then
	_pass "5.0.3 renders v5 and the v4 fallback source"
else
	_fail "5.0.3 content sources"
	echo "$_out"
fi

_err=$(
	{
		_load_renderer
		ocp_version=
		unset ocp_major
		_render_image_content_sources
	} 2>&1
) && _rc=0 || _rc=$?
if [ "$_rc" -ne 0 ] && echo "$_err" | grep -q "no major number"; then
	_pass "empty ocp_version stops the render"
else
	_fail "empty ocp_version must abort (rc=$_rc)"
	echo "$_err" | tail -20
fi

_td=$(mktemp -d)
mkdir -p "$_td/scripts"
printf '%s\n' '#!/bin/bash' 'echo boom >&2' 'exit 1' > "$_td/scripts/j2"
chmod +x "$_td/scripts/j2"
_err=$(
	{
		cd "$_td" || exit 1
		# shellcheck disable=SC1091
		source "$OLDPWD/scripts/include_all.sh"
		eval "$(awk '/^_render_image_content_sources\(\)/{p=1} p{print} p && /^}/{exit}' "$OLDPWD/scripts/create-install-config.sh")"
		ocp_version=4.19.5
		_render_image_content_sources
	} 2>&1
) && _rc=0 || _rc=$?
rm -rf "$_td"
if [ "$_rc" -ne 0 ] && echo "$_err" | grep -q "Could not render image content sources"; then
	_pass "a failed content-sources render stops the script"
else
	_fail "failed j2 must abort (rc=$_rc)"
	echo "$_err" | tail -20
fi

_td=$(mktemp -d)
ln -s "$PWD/scripts" "$_td/scripts"
ln -s "$PWD/templates" "$_td/templates"
cat > "$_td/aba.conf" <<'EOF'
ocp_version=4.19.5
domain=example.com
verify_conf=off
ask=false
editor=none
EOF
if ( cd "$_td" && bash scripts/create-mirror-conf.sh -f yes ) \
	&& grep -q '^reg_path=/ocp4/openshift4' "$_td/mirror.conf"; then
	_pass "new mirror.conf uses /ocp4/openshift4"
else
	_fail "mirror.conf reg_path must include the major"
	grep '^reg_path=' "$_td/mirror.conf" 2>/dev/null || true
fi
rm -rf "$_td/mirror.conf"
cat > "$_td/aba.conf" <<'EOF'
ocp_version=5.0.3
domain=example.com
verify_conf=off
ask=false
editor=none
EOF
if ( cd "$_td" && bash scripts/create-mirror-conf.sh -f yes ) \
	&& grep -q '^reg_path=/ocp5/openshift5' "$_td/mirror.conf"; then
	_pass "new mirror.conf uses /ocp5/openshift5"
else
	_fail "mirror.conf reg_path for 5.0.3"
	grep '^reg_path=' "$_td/mirror.conf" 2>/dev/null || true
fi
rm -rf "$_td"

echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
