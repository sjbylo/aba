#!/bin/bash
# Unit tests for 'aba bundle --complete': assemble a site/ payload (configs +
# helm charts + day2 manifests) and embed it in the bundle tar so one archive
# crosses the air gap and can be re-applied with 'aba config import'.
#
#   - _assemble_site() (in make-bundle.sh) collects the current configs into a
#     site/ tree using the same layout 'aba config import' consumes.
#   - backup.sh includes aba/site/... in the tar when a site/ dir is present,
#     and leaves the tar unchanged when it is not (no regression).
#   - export -> import round-trips the configs byte-for-byte.
# No network, no oc; backup.sh runs against a minimal fixture with an isolated HOME.

cd "$(dirname "$0")/../.."
REPO_ROOT="$PWD"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass=0
fail=0
FAILURES=""

test_pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; pass=$(( pass + 1 )); }
test_fail() { echo -e "${RED}✗ FAIL${NC}: $1 -- $2"; fail=$(( fail + 1 )); FAILURES=1; }

_tmp=$(mktemp -d)
trap 'rm -rf "$_tmp"' EXIT

source scripts/include_all.sh dummy_arg 2>/dev/null

# Load _assemble_site from make-bundle.sh and config_import_apply from config-import.sh.
if grep -q '^_assemble_site() {' scripts/make-bundle.sh 2>/dev/null; then
	eval "$(sed -n '/^_assemble_site() {/,/^}/p' scripts/make-bundle.sh)"
fi
[ -f scripts/config-import.sh ] && eval "$(sed -n '/^config_import_apply() {/,/^}/p' scripts/config-import.sh)"

echo
echo "=== Testing: aba bundle --complete (site payload) ==="
echo

_cmp() { if cmp -s "$2" "$3"; then test_pass "$1"; else test_fail "$1" "content differs ($2 vs $3)"; fi; }

# --- build a representative aba tree (the connected/mirror side) ---------------
_root="$_tmp/aba"
mkdir -p "$_root/mirror/data" "$_root/mycluster/day2-custom-manifests/10-first" "$_root/helm" "$_root/scripts" "$_root/cli"
printf 'ocp_version=4.19.2\nocp_channel=stable\n'      > "$_root/aba.conf"
printf 'reg_host=registry.example.com\n'              > "$_root/mirror/mirror.conf"
printf 'kind: ImageSetConfiguration\n'                > "$_root/mirror/data/imageset-config.yaml"
printf 'name=mycluster\ntype=sno\n'                   > "$_root/mycluster/cluster.conf"
printf 'apiVersion: v1\nkind: InstallConfig\n'        > "$_root/mycluster/install-config.yaml"
printf 'apiVersion: v1alpha1\nkind: AgentConfig\n'    > "$_root/mycluster/agent-config.yaml"
printf '52:54:00:aa:bb:cc\n'                          > "$_root/mycluster/macs.conf"
printf 'apiVersion: v1\nkind: ConfigMap\n'            > "$_root/mycluster/day2-custom-manifests/10-first/app.yaml"
printf 'chart: demo\n'                                > "$_root/helm/Chart.yaml"
# noise: a non-cluster dir (no cluster.conf) must NOT be treated as a cluster
printf 'not a cluster\n'                              > "$_root/scripts/helper.sh"

# --- Test group 1: _assemble_site collects configs into the site/ layout ------
echo "--- _assemble_site layout ---"
if ! type _assemble_site >/dev/null 2>&1; then
	test_fail "_assemble_site exists" "make-bundle.sh has no _assemble_site() function yet (red)"
else
	_site="$_root/site"
	( _assemble_site "$_root" "$_site" ) >/dev/null 2>&1
	_cmp "site/aba.conf"                       "$_root/aba.conf"                     "$_site/aba.conf"
	_cmp "site/mirror/mirror.conf"             "$_root/mirror/mirror.conf"           "$_site/mirror/mirror.conf"
	_cmp "site/mirror/imageset-config.yaml"    "$_root/mirror/data/imageset-config.yaml" "$_site/mirror/imageset-config.yaml"
	_cmp "site/<cluster>/cluster.conf"         "$_root/mycluster/cluster.conf"       "$_site/mycluster/cluster.conf"
	_cmp "site/<cluster>/install-config.yaml"  "$_root/mycluster/install-config.yaml" "$_site/mycluster/install-config.yaml"
	_cmp "site/<cluster>/agent-config.yaml"    "$_root/mycluster/agent-config.yaml"  "$_site/mycluster/agent-config.yaml"
	_cmp "site/<cluster>/macs.conf"            "$_root/mycluster/macs.conf"          "$_site/mycluster/macs.conf"
	_cmp "site/<cluster>/day2 manifest"        "$_root/mycluster/day2-custom-manifests/10-first/app.yaml" "$_site/mycluster/day2-custom-manifests/10-first/app.yaml"
	_cmp "site/helm/Chart.yaml"                "$_root/helm/Chart.yaml"              "$_site/helm/Chart.yaml"
	if [ ! -e "$_site/scripts" ]; then
		test_pass "non-cluster dir (scripts/) not embedded as a cluster"
	else
		test_fail "cluster detection" "scripts/ wrongly embedded in site/"
	fi
fi

# --- Test group 2: export -> import round-trips byte-for-byte ------------------
echo "--- export -> import round-trip ---"
if type _assemble_site >/dev/null 2>&1 && type config_import_apply >/dev/null 2>&1; then
	_dest="$_tmp/dest"
	mkdir -p "$_dest"
	( config_import_apply "$_root/site" "$_dest" ) >/dev/null 2>&1
	_cmp "round-trip aba.conf"                 "$_root/aba.conf"                     "$_dest/aba.conf"
	_cmp "round-trip imageset-config.yaml"     "$_root/mirror/data/imageset-config.yaml" "$_dest/mirror/data/imageset-config.yaml"
	_cmp "round-trip install-config.yaml"      "$_root/mycluster/install-config.yaml" "$_dest/mycluster/install-config.yaml"
	_cmp "round-trip day2 manifest"            "$_root/mycluster/day2-custom-manifests/10-first/app.yaml" "$_dest/mycluster/day2-custom-manifests/10-first/app.yaml"
else
	test_fail "round-trip" "_assemble_site and/or config_import_apply unavailable (red)"
fi

# --- Test group 3: backup.sh embeds aba/site/... in the tar (real run) --------
echo "--- backup.sh tar inclusion ---"
_mk_repo() {			# $1 = fixture name  $2 = 1 to include a site/ payload
	local r="$_tmp/$1/aba"
	mkdir -p "$r/scripts"
	ln -s "$REPO_ROOT/scripts"/* "$r/scripts/" 2>/dev/null
	( cd "$r"
	  : > install; : > aba; : > aba.conf; : > Makefile; : > README.md; : > VERSION
	  : > CHANGELOG.md; : > LICENSE; : > Troubleshooting.md; : > .index
	  mkdir -p cli rpms others templates tui/v2 mirror )
	if [ "$2" = "1" ]; then
		mkdir -p "$r/site/mycluster"
		printf 'ocp_version=4.19.2\n' > "$r/site/aba.conf"
		printf 'name=mycluster\n'     > "$r/site/mycluster/cluster.conf"
	fi
	echo "$r"
}
_run_backup() {			# $1 = repo root ; echoes tar path
	local r="$1" out="$_tmp/$(basename "$(dirname "$1")").tar" home="$_tmp/home"
	mkdir -p "$home"
	( cd "$r" && HOME="$home" bash "$REPO_ROOT/scripts/backup.sh" "$out" ) >/dev/null 2>&1
	echo "$out"
}

_r_site="$(_mk_repo withsite 1)"; _t_site="$(_run_backup "$_r_site")"
if tar tf "$_t_site" 2>/dev/null | grep -q '^aba/site/'; then
	test_pass "backup.sh embeds aba/site/... when a site/ payload exists"
else
	test_fail "site in tar" "aba/site/ not found in bundle tar"
fi

_r_none="$(_mk_repo nosite 0)"; _t_none="$(_run_backup "$_r_none")"
if tar tf "$_t_none" 2>/dev/null | grep -q '^aba/site/'; then
	test_fail "no-regression" "aba/site/ present in tar without a site/ payload"
else
	test_pass "no site/ payload -> tar has no aba/site/ (no regression)"
fi

# --- Test group 4: make-bundle.sh flag wiring ---------------------------------
echo "--- --complete flag wiring ---"
grep -qE '\-\-complete\)' scripts/make-bundle.sh \
	&& test_pass "make-bundle.sh parses --complete" \
	|| test_fail "flag parse" "--complete not handled in make-bundle.sh"
grep -q '_assemble_site' scripts/make-bundle.sh \
	&& test_pass "make-bundle.sh calls _assemble_site" \
	|| test_fail "assembly call" "_assemble_site not invoked in make-bundle.sh"
grep -q '\${repo_dir}/site' scripts/backup.sh \
	&& test_pass "backup.sh conditionally includes \${repo_dir}/site" \
	|| test_fail "backup site path" "backup.sh does not reference repo_dir/site"

echo
echo "=== Results: $pass passed, $fail failed ==="
echo

[ -z "$FAILURES" ] && exit 0 || exit 1
