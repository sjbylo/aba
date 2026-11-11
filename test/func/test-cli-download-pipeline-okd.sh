#!/bin/bash
# Test: OKD CLI download pipeline (mocked, no network).
#
# cli/Makefile, cli-download-all.sh and cli-install-all.sh with distribution=okd:
#   - the oc / openshift-install tarballs and sha256sum.txt come from the OKD GitHub
#     release of ocp_version, with the same asset names as OCP; oc-mirror keeps the pin
#   - the sha256 check is the OCP one (bad sum / missing line / missing sum file fail)
#   - run_once ids, tarball names and the cli-install-all.sh version guard work with a
#     full "<x.y.z>-okd-scos.<n>" tag (and a 5.x tag) and are unchanged for OCP
#
# curl is replaced by a mock that serves files from a fixture tree and logs every URL,
# so the test also proves which hosts are contacted. Everything runs in a temp tree with
# its own $HOME: nothing under the real ~/bin or ~/.aba is read or written.
#
# Usage:  bash test/func/test-cli-download-pipeline-okd.sh
# Duration: ~30 seconds

set -o pipefail
cd "$(dirname "$0")/../.." || exit 1
REPO_ROOT="$PWD"

pass_count=0
fail_count=0
test_pass() { echo -e "  \033[0;32mPASS\033[0m: $1"; pass_count=$(( pass_count + 1 )); }
test_fail() { echo -e "  \033[0;31mFAIL\033[0m: $1"; fail_count=$(( fail_count + 1 )); }
section() { echo ""; echo "=== $1 ==="; }

# _eq <label> <expected> <actual>
_eq() {
	if [ "$2" = "$3" ]; then test_pass "$1"; else test_fail "$1: expected [$2] got [$3]"; fi
}
# _ok <label> <cmd...>  (cmd must succeed)
_ok() {
	local label="$1"; shift
	if "$@" >/dev/null 2>&1; then test_pass "$label"; else test_fail "$label"; fi
}
# _no <label> <cmd...>  (cmd must fail)
_no() {
	local label="$1"; shift
	if "$@" >/dev/null 2>&1; then test_fail "$label"; else test_pass "$label"; fi
}

# Fixture releases: two OKD minors, one 5.x tag, one OCP version (tags are test data only)
OKD_A=4.21.0-okd-scos.11
OKD_B=4.20.0-okd-scos.3
OKD_C=5.0.0-okd-scos.5
OKD_D=4.21.0-okd-scos.10     # same x.y.z as OKD_A, other release number
OCP_V=4.22.1

# Same name mapping as cli/Makefile: uname -m -> download arch
arch=$(uname -m)
case "$arch" in
	x86_64) ARCH=amd64 ;;
	aarch64) ARCH=arm64 ;;
	*) ARCH=$arch ;;
esac

W=$(mktemp -d "${TMPDIR:-/tmp}/aba-okd-cli.XXXXXX")
trap 'rm -rf "$W" /tmp/.aba-aba-test' EXIT
mkdir -p "$W/aba" "$W/home/bin" "$W/fx" "$W/mockbin"
cp -a scripts templates "$W/aba/"
mkdir -p "$W/aba/cli"
cp cli/Makefile "$W/aba/cli/Makefile"
export MOCK_FIX="$W/fx" MOCK_LOG="$W/curl.log"
: > "$MOCK_LOG"

# ---------------------------------------------------------------- mocks
cat > "$W/mockbin/curl" <<'EOF'
#!/bin/bash
# Mock curl: serves $MOCK_FIX/<host>/<path>, logs every URL, never uses the network.
url=""; out=""; head=0
while [ $# -gt 0 ]; do
	case "$1" in
		-o) out="$2"; shift 2 ;;
		--retry|--connect-timeout|--max-time|-w|-m) shift 2 ;;
		-[a-zA-Z]*I*) head=1; shift ;;
		http*) url="$1"; shift ;;
		*) shift ;;
	esac
done
if [ "$head" = 1 ]; then echo "HEAD $url" >> "$MOCK_LOG"; else echo "GET $url" >> "$MOCK_LOG"; fi
f="$MOCK_FIX/${url#*://}"
[ -f "$f" ] || exit 22
[ "$head" = 1 ] && exit 0
if [ -n "$out" ]; then cp "$f" "$out"; else cat "$f"; fi
EOF
# the download recipe sleeps 5s between retries
printf '#!/bin/sh\nexit 0\n' > "$W/mockbin/sleep"
chmod +x "$W/mockbin/curl" "$W/mockbin/sleep"

# mk_release <fixture-dir> <version>: fake oc/kubectl/openshift-install tarballs + sha256sum.txt
mk_release() {
	local d="$1" v="$2" t
	t=$(mktemp -d "$W/rel.XXXXXX")
	mkdir -p "$W/fx/$d"
	printf '#!/bin/sh\ncase "$1" in version) echo "Client Version: %s";; *) echo oc;; esac\n' "$v" > "$t/oc"
	printf '#!/bin/sh\necho kubectl\n' > "$t/kubectl"
	printf '#!/bin/sh\ncase "$1" in version) echo "openshift-install %s"; echo "built from commit 0123456789"; echo "release image example.invalid/release@sha256:00";; *) echo openshift-install;; esac\n' "$v" > "$t/openshift-install"
	chmod +x "$t/oc" "$t/kubectl" "$t/openshift-install"
	tar -C "$t" -czf "$W/fx/$d/openshift-client-linux-$ARCH-rhel9-$v.tar.gz" oc kubectl
	tar -C "$t" -czf "$W/fx/$d/openshift-client-linux-$ARCH-rhel8-$v.tar.gz" oc kubectl
	tar -C "$t" -czf "$W/fx/$d/openshift-install-linux-$v.tar.gz" openshift-install
	( cd "$W/fx/$d" && sha256sum openshift-client-linux-"$ARCH"-rhel9-"$v".tar.gz openshift-client-linux-"$ARCH"-rhel8-"$v".tar.gz openshift-install-linux-"$v".tar.gz > sha256sum.txt )
	rm -rf "$t"
}
okd_dir() { echo "github.com/okd-project/okd/releases/download/$1"; }
ocp_dir() { echo "mirror.openshift.com/pub/openshift-v${1%%.*}/$arch/clients/ocp/$1"; }

for v in $OKD_A $OKD_B $OKD_C $OKD_D; do mk_release "$(okd_dir "$v")" "$v"; done
mk_release "$(ocp_dir $OCP_V)" "$OCP_V"

# oc-mirror comes from the pinned OCP channel for every distribution
pin=$(grep '^oc_mirror_pin' cli/Makefile | head -1 | awk '{print $NF}')
[ -n "$pin" ] || { echo "FATAL: oc_mirror_pin not found in cli/Makefile"; exit 1; }
mirror_dir="mirror.openshift.com/pub/openshift-v4/$arch/clients/ocp/$pin"
mkdir -p "$W/fx/$mirror_dir"
t=$(mktemp -d "$W/om.XXXXXX")
printf '#!/bin/sh\necho oc-mirror\n' > "$t/oc-mirror"; chmod +x "$t/oc-mirror"
tar -C "$t" -czf "$W/fx/$mirror_dir/oc-mirror.rhel9.tar.gz" oc-mirror
tar -C "$t" -czf "$W/fx/$mirror_dir/oc-mirror.tar.gz" oc-mirror
( cd "$W/fx/$mirror_dir" && sha256sum oc-mirror.rhel9.tar.gz oc-mirror.tar.gz > sha256sum.txt )
rm -rf "$t"

conf() { # <distribution-line-or-empty> <version>
	{
		echo "ocp_version=$2"
		echo "platform=kvm"
		[ -n "$1" ] && printf '%b\n' "$1"
	} > "$W/aba/aba.conf"
}

# Run in the temp tree with the mock on PATH and a private $HOME
run_env() {
	( cd "$W/aba" && env -u distribution -u ocp_version HOME="$W/home" PATH="$W/mockbin:$PATH" \
		MOCK_FIX="$MOCK_FIX" MOCK_LOG="$MOCK_LOG" PLAIN_OUTPUT=1 USER=aba-test "$@" )
}
mk() { run_env make --no-print-directory -C cli "$@"; }

probe='probe-urls: ; @echo "rhel9=$(rhel9_oc_url)"; echo "rhel8=$(rhel8_oc_url)"; echo "install=$(openshift_install_url)/$(openshift_install_file)"; echo "sum=$(openshift_install_url)/sha256sum.txt"; echo "oc-mirror=$(oc_mirror_base_url)/oc-mirror.rhel9.tar.gz"; echo "oc-mirror-sum=$(oc_mirror_sha256sum)"; echo "tar=$(local_oc_tar_file)"'
urls() { mk --eval="$probe" probe-urls os_ver=9.5 "$@" 2>/dev/null; }
field() { sed -n "s/^$1=//p" | head -1; }

echo "OKD CLI download pipeline (mock curl, temp tree $W)"

# ================================================================ A. URL resolution
section "A. cli/Makefile URLs"
GH=https://github.com/okd-project/okd/releases/download
for v in $OKD_A $OKD_B $OKD_C; do
	conf "" "$v"
	u=$(urls ocp_version="$v" distribution=okd)
	_eq "okd $v: rhel9 oc url" "$GH/$v/openshift-client-linux-$ARCH-rhel9-$v.tar.gz" "$(field rhel9 <<<"$u")"
	_eq "okd $v: rhel8 oc url (same directory, same naming)" "$GH/$v/openshift-client-linux-$ARCH-rhel8-$v.tar.gz" "$(field rhel8 <<<"$u")"
	_eq "okd $v: openshift-install url" "$GH/$v/openshift-install-linux-$v.tar.gz" "$(field install <<<"$u")"
	_eq "okd $v: sha256sum.txt is next to the tarballs" "$GH/$v/sha256sum.txt" "$(field sum <<<"$u")"
	_eq "okd $v: oc-mirror keeps the OCP pin url" "https://mirror.openshift.com/pub/openshift-v4/$arch/clients/ocp/$pin/oc-mirror.rhel9.tar.gz" "$(field oc-mirror <<<"$u")"
	_eq "okd $v: oc-mirror sha256sum.txt is the pin one" "https://mirror.openshift.com/pub/openshift-v4/$arch/clients/ocp/$pin/sha256sum.txt" "$(field oc-mirror-sum <<<"$u")"
	_eq "okd $v: local tarball name unchanged" "openshift-client-linux-$ARCH-rhel9-$v.tar.gz" "$(field tar <<<"$u")"
done

# distribution comes from aba.conf too (comment and tabs after the value, as the template writes it)
conf 'distribution=okd\t\t# comment' "$OKD_A"
u=$(urls)
_eq "okd from aba.conf (value followed by a comment): install url" "$GH/$OKD_A/openshift-install-linux-$OKD_A.tar.gz" "$(field install <<<"$u")"
conf 'distribution=okd   ' "$OKD_B"
u=$(urls)
_eq "okd from aba.conf (trailing blanks): install url follows ocp_version" "$GH/$OKD_B/openshift-install-linux-$OKD_B.tar.gz" "$(field install <<<"$u")"

# Not okd -> the OCP url, whatever the version string looks like
for d in "" "distribution=ocp" "distribution=ocp\t# default" "#distribution=okd"; do
	conf "$d" "$OCP_V"
	u=$(urls)
	_eq "ocp [$d]: install url" "https://mirror.openshift.com/pub/openshift-v4/$arch/clients/ocp/$OCP_V/openshift-install-linux-$OCP_V.tar.gz" "$(field install <<<"$u")"
done
conf "" "$OKD_A"
u=$(urls)
_eq "ocp url is chosen by distribution, not by the shape of ocp_version" "https://mirror.openshift.com/pub/openshift-v4/$arch/clients/ocp/$OKD_A/openshift-install-linux-$OKD_A.tar.gz" "$(field install <<<"$u")"

# Same answer as the shell helper
for v in $OKD_A $OKD_C; do
	conf "" "$v"
	u=$(urls ocp_version="$v" distribution=okd)
	h=$(run_env env distribution=okd bash -c "source scripts/include_all.sh 2>/dev/null; trap - ERR; dist_cli_base_url '$v'")
	_eq "okd $v: Makefile base url == dist_cli_base_url" "$h/openshift-install-linux-$v.tar.gz" "$(field install <<<"$u")"
done

# No release literal in the CLI Makefile / CLI scripts
n=$(grep -c -E 'okd-scos\.[0-9]+' cli/Makefile scripts/cli-download-all.sh scripts/cli-install-all.sh | awk -F: '{s+=$2} END {print s+0}')
_eq "no OKD release tag literal in cli/Makefile, cli-download-all.sh, cli-install-all.sh" "0" "$n"

# ================================================================ B. download + sha256 + extract
section "B. make download + sha256 check (okd)"
conf "distribution=okd" "$OKD_A"
: > "$MOCK_LOG"
mk download-oc '~/bin/oc' '~/bin/openshift-install' ocp_version="$OKD_A" os_ver=9.5 >"$W/b1.out" 2>&1; rc=$?
_eq "make download-oc ~/bin/oc ~/bin/openshift-install rc" "0" "$rc"
[ "$rc" -eq 0 ] || sed 's/^/    | /' "$W/b1.out"
_ok "oc tarball (rhel9) downloaded and valid gzip" gzip -t "$W/aba/cli/openshift-client-linux-$ARCH-rhel9-$OKD_A.tar.gz"
_ok "oc tarball (rhel8) downloaded and valid gzip" gzip -t "$W/aba/cli/openshift-client-linux-$ARCH-rhel8-$OKD_A.tar.gz"
_ok "openshift-install tarball downloaded and valid gzip" gzip -t "$W/aba/cli/openshift-install-linux-$OKD_A.tar.gz"
_eq "checksum reported valid for all three tarballs" "3" "$(grep -c 'valid!' "$W/b1.out")"
_eq "oc reports the full tag" "Client Version: $OKD_A" "$(PATH="$W/home/bin:$PATH" HOME="$W/home" "$W/home/bin/oc" version 2>&1)"
_eq "openshift-install reports the full tag" "openshift-install $OKD_A" "$("$W/home/bin/openshift-install" version 2>&1 | head -1)"
_ok "requested the GitHub release assets" grep -qx "GET $GH/$OKD_A/openshift-install-linux-$OKD_A.tar.gz" "$MOCK_LOG"
_ok "requested sha256sum.txt of the same release" grep -qx "GET $GH/$OKD_A/sha256sum.txt" "$MOCK_LOG"
_eq "no request to mirror.openshift.com for oc / openshift-install" "0" "$(grep -c 'mirror.openshift.com' "$MOCK_LOG")"

# bad checksum -> hard failure, nothing installed, no tarball left behind
rm -rf "$W/home/bin"/* "$W/aba/cli"/*.tar.gz "$W/aba/cli/.init" "$W/aba/cli/scripts"
sed -i 's/^[0-9a-f]\{4\}/0000/' "$W/fx/$(okd_dir $OKD_A)/sha256sum.txt"
mk '~/bin/openshift-install' ocp_version="$OKD_A" os_ver=9.5 >"$W/b2.out" 2>&1; rc=$?
_no "wrong sha256 in sha256sum.txt: make fails" test "$rc" -eq 0
_ok "message says the checksum is invalid" grep -q 'Checksum INVALID' "$W/b2.out"
_no "no tarball is kept after a failed check" test -e "$W/aba/cli/openshift-install-linux-$OKD_A.tar.gz"
_no "openshift-install is not installed after a failed check" test -x "$W/home/bin/openshift-install"
mk_release "$(okd_dir $OKD_A)" "$OKD_A"

# asset missing from sha256sum.txt -> failure (same rule as OCP)
grep -v "openshift-install-linux" "$W/fx/$(okd_dir $OKD_A)/sha256sum.txt" > "$W/sum.tmp"; cp "$W/sum.tmp" "$W/fx/$(okd_dir $OKD_A)/sha256sum.txt"
mk '~/bin/openshift-install' ocp_version="$OKD_A" os_ver=9.5 >"$W/b3.out" 2>&1; rc=$?
_no "no sha256 line for the asset: make fails" test "$rc" -eq 0
_no "no tarball is kept when its sha256 line is missing" test -e "$W/aba/cli/openshift-install-linux-$OKD_A.tar.gz"
mk_release "$(okd_dir $OKD_A)" "$OKD_A"

# sha256sum.txt missing -> failure
rm -f "$W/fx/$(okd_dir $OKD_A)/sha256sum.txt"
mk '~/bin/openshift-install' ocp_version="$OKD_A" os_ver=9.5 >"$W/b4.out" 2>&1; rc=$?
_no "sha256sum.txt not found: make fails" test "$rc" -eq 0
_no "no tarball is kept when sha256sum.txt is missing" test -e "$W/aba/cli/openshift-install-linux-$OKD_A.tar.gz"
mk_release "$(okd_dir $OKD_A)" "$OKD_A"

# oc-mirror: OCP pin for okd, nothing from GitHub
rm -f "$W/aba/cli"/oc-mirror*.tar.gz; : > "$MOCK_LOG"
mk download-oc-mirror ocp_version="$OKD_A" os_ver=9.5 >"$W/b5.out" 2>&1; rc=$?
_eq "make download-oc-mirror (okd) rc" "0" "$rc"
_ok "oc-mirror.rhel9.tar.gz downloaded from the pinned OCP channel" grep -qx "GET https://mirror.openshift.com/pub/openshift-v4/$arch/clients/ocp/$pin/oc-mirror.rhel9.tar.gz" "$MOCK_LOG"
_eq "no GitHub request for oc-mirror" "0" "$(grep -c 'github.com' "$MOCK_LOG")"

# ocp: unchanged, same mock
section "B2. same pipeline for ocp (else branch unchanged)"
conf "distribution=ocp" "$OCP_V"
rm -rf "$W/home/bin"/* "$W/aba/cli"/*.tar.gz "$W/aba/cli/.init" "$W/aba/cli/scripts"; : > "$MOCK_LOG"
mk '~/bin/oc' '~/bin/openshift-install' ocp_version="$OCP_V" os_ver=9.5 >"$W/b6.out" 2>&1; rc=$?
_eq "ocp: make ~/bin/oc ~/bin/openshift-install rc" "0" "$rc"
_ok "ocp: tarball requested from mirror.openshift.com" grep -qx "GET https://mirror.openshift.com/pub/openshift-v4/$arch/clients/ocp/$OCP_V/openshift-install-linux-$OCP_V.tar.gz" "$MOCK_LOG"
_eq "ocp: no GitHub request" "0" "$(grep -c 'github.com' "$MOCK_LOG")"
_eq "ocp: oc reports its version" "Client Version: $OCP_V" "$("$W/home/bin/oc" version 2>&1)"

# ================================================================ C. orchestration
section "C. cli-download-all.sh / cli-install-all.sh / version guard (okd)"
reset_state() {
	rm -rf "$W/home/bin"/* "$W/home/.aba" "$W/aba/cli"/*.tar.gz "$W/aba/cli/.init" "$W/aba/cli/scripts"
}
reset_state
conf "distribution=okd" "$OKD_A"
_eq "out-download-all lists versioned items (run_once ids carry the full tag)" "oc:$OKD_A oc-mirror openshift-install:$OKD_A butane" "$(mk out-download-all ocp_version="$OKD_A" 2>/dev/null)"
_eq "task_dl_oc id == cli:download:<item of out-download-all>" "cli:download:oc:$OKD_A" "$(run_env env ocp_version="$OKD_A" bash -c "source scripts/include_all.sh 2>/dev/null; trap - ERR; task_dl_oc")"
_eq "task_dl_openshift_install id" "cli:download:openshift-install:$OKD_A" "$(run_env env ocp_version="$OKD_A" bash -c "source scripts/include_all.sh 2>/dev/null; trap - ERR; task_dl_openshift_install")"

: > "$MOCK_LOG"
run_env timeout 120 bash scripts/cli-download-all.sh --wait oc openshift-install >"$W/c1.out" 2>&1; rc=$?
_eq "cli-download-all.sh --wait oc openshift-install rc" "0" "$rc"
[ "$rc" -eq 0 ] || sed 's/^/    | /' "$W/c1.out"
_ok "oc tarball present" test -s "$W/aba/cli/openshift-client-linux-$ARCH-rhel9-$OKD_A.tar.gz"
_ok "openshift-install tarball present" test -s "$W/aba/cli/openshift-install-linux-$OKD_A.tar.gz"
_ok "run_once state recorded under the full-tag id (oc)" test -d "$W/home/.aba/runner/cli:download:oc:$OKD_A"
_ok "run_once state recorded under the full-tag id (openshift-install)" test -d "$W/home/.aba/runner/cli:download:openshift-install:$OKD_A"
_eq "download-all contacted no host but the OKD release" "0" "$(grep -c 'mirror.openshift.com' "$MOCK_LOG")"

run_env timeout 120 bash scripts/cli-install-all.sh --wait oc openshift-install >"$W/c2.out" 2>&1; rc=$?
_eq "cli-install-all.sh --wait oc openshift-install rc" "0" "$rc"
_eq "installed oc reports the full tag" "Client Version: $OKD_A" "$("$W/home/bin/oc" version 2>/dev/null)"
_eq "installed openshift-install reports the full tag" "openshift-install $OKD_A" "$("$W/home/bin/openshift-install" version 2>/dev/null | head -1)"

# Guard, same tag installed: binary is left alone (a marker line proves it was not re-extracted)
printf '#!/bin/sh\ncase "$1" in version) echo "Client Version: %s"; echo MARKER;; *) echo oc;; esac\n' "$OKD_A" > "$W/home/bin/oc"
chmod +x "$W/home/bin/oc"
run_env timeout 120 bash scripts/cli-install-all.sh --wait oc openshift-install >"$W/c3.out" 2>&1; rc=$?
_eq "guard, installed tag == ocp_version: rc" "0" "$rc"
_ok "guard matches the full tag: installed oc is kept (no re-extract)" grep -q MARKER < <("$W/home/bin/oc" version 2>/dev/null)
_ok "guard matches the full tag: mtime not backdated" test "$(stat -c %Y "$W/home/bin/oc")" -gt 1000000000

# Guard, same x.y.z but another release number (scos.11 installed, scos.10 wanted): the guard compares the whole tag
conf "distribution=okd" "$OKD_D"
run_env timeout 120 bash scripts/cli-install-all.sh --wait oc openshift-install >"$W/c3b.out" 2>&1; rc=$?
_eq "guard, same x.y.z other release number: rc" "0" "$rc"
_eq "oc was replaced by the wanted release (not kept because x.y.z matches)" "Client Version: $OKD_D" "$("$W/home/bin/oc" version 2>/dev/null)"
_eq "openshift-install was replaced by the wanted release" "openshift-install $OKD_D" "$("$W/home/bin/openshift-install" version 2>/dev/null | head -1)"

# Guard, other minor (scos.10 installed, 4.20 scos.3 wanted): re-extract the wanted one
conf "distribution=okd" "$OKD_B"
run_env timeout 120 bash scripts/cli-install-all.sh --wait oc openshift-install >"$W/c4.out" 2>&1; rc=$?
_eq "guard, ocp_version changed to another okd release: rc" "0" "$rc"
_eq "oc now reports the new tag" "Client Version: $OKD_B" "$("$W/home/bin/oc" version 2>/dev/null)"
_eq "openshift-install now reports the new tag" "openshift-install $OKD_B" "$("$W/home/bin/openshift-install" version 2>/dev/null | head -1)"
_ok "run_once id of the new release recorded" test -d "$W/home/.aba/runner/cli:download:oc:$OKD_B"

# Guard, 5.x tag
conf "distribution=okd" "$OKD_C"
run_env timeout 120 bash scripts/cli-install-all.sh --wait oc openshift-install >"$W/c5.out" 2>&1; rc=$?
_eq "guard, switch to a 5.x okd tag: rc" "0" "$rc"
_eq "oc reports the 5.x tag" "Client Version: $OKD_C" "$("$W/home/bin/oc" version 2>/dev/null)"
_eq "openshift-install reports the 5.x tag" "openshift-install $OKD_C" "$("$W/home/bin/openshift-install" version 2>/dev/null | head -1)"
_eq "the 5.x tarball came from GitHub (release dir == tag)" "1" "$(grep -c -x "GET $GH/$OKD_C/openshift-install-linux-$OKD_C.tar.gz" "$MOCK_LOG")"

# Guard, downgrade to a release whose tarball is still cached: the installed binary is newer than that tarball,
# so Make alone would keep it; only the guard (backdating the binary) makes Make extract again
conf "distribution=okd" "$OKD_A"
run_env timeout 120 bash scripts/cli-install-all.sh --wait oc openshift-install >"$W/c6.out" 2>&1; rc=$?
_eq "guard, back to a cached older release: rc" "0" "$rc"
_eq "oc is the cached older release again" "Client Version: $OKD_A" "$("$W/home/bin/oc" version 2>/dev/null)"
_eq "openshift-install is the cached older release again" "openshift-install $OKD_A" "$("$W/home/bin/openshift-install" version 2>/dev/null | head -1)"

# ================================================================ D. installed-version parsing in aba.sh
section "D. aba.sh: version of the installed openshift-install"
# The two lines that read the installed version must return the whole tag for okd and
# keep returning x.y.z for ocp.
lines=$(grep 'openshift-install version | grep ^openshift-install | grep -E -o' scripts/aba.sh | sed -E 's/.*&& (os_inst|cur_ver)=/\1=/; s/^(.*\)).*/\1/')
_eq "aba.sh has the two installed-version lookups" "2" "$(printf '%s\n' "$lines" | grep -c .)"
installed_ver() { # <expr> <openshift-install version output>
	local out="$2"
	( os_inst=""; cur_ver=""; openshift-install() { printf '%s\n' "$out"; }; eval "$1"; echo "$os_inst$cur_ver" )
}
while IFS= read -r e; do
	[ -n "$e" ] || continue
	for v in $OKD_A $OKD_B $OKD_C; do
		_eq "[${e%%=*}] okd $v -> whole tag" "$v" "$(installed_ver "$e" "$(printf 'openshift-install %s\nbuilt from commit 0123' "$v")")"
	done
	_eq "[${e%%=*}] ocp 4.21.14 -> 4.21.14" "4.21.14" "$(installed_ver "$e" "$(printf 'openshift-install 4.21.14\nbuilt from commit 0123')")"
	_eq "[${e%%=*}] ocp rc -> x.y.z only (unchanged)" "4.22.0" "$(installed_ver "$e" "$(printf 'openshift-install 4.22.0-rc.1\nbuilt from commit 0123')")"
	_eq "[${e%%=*}] ocp ec -> x.y.z only (unchanged)" "5.0.0" "$(installed_ver "$e" "$(printf 'openshift-install 5.0.0-ec.2\nbuilt from commit 0123')")"
	_eq "[${e%%=*}] no openshift-install line -> empty" "" "$(installed_ver "$e" "garbage 4.21.14")"
done <<< "$lines"

echo ""
echo "========================================"
echo "=== Results: $pass_count passed, $fail_count failed ==="
echo "========================================"
[ "$fail_count" -eq 0 ]
