#!/bin/bash
# Unit tests for config-import: copy site/ configs VERBATIM into an aba tree and
# pin regeneration guards so aba never re-templates over the imported files.
#
# Guards under test (verified against the real code):
#   - imageset-config.yaml must be STRICTLY newer than mirror/data/.created
#     (reg-create-imageset-config.sh skips regen when ISC -nt .created).
#   - install-config.yaml / agent-config.yaml must be STRICTLY newer than their
#     Make prerequisites cluster.conf and mirror.conf (Makefile.cluster) so make
#     treats them as up-to-date and does not regenerate them.
# Pure filesystem: no oc, no make, no network.

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

# Load the function under test (config-import.sh guards main behind a source
# check, but extracting the function keeps the test focused and fast).
if [ ! -f scripts/config-import.sh ]; then
	echo "FATAL: scripts/config-import.sh does not exist yet (red)" >&2
	echo "=== Results: 0 passed, 1 failed ==="
	exit 1
fi
eval "$(sed -n '/^config_import_apply() {/,/^}/p' scripts/config-import.sh)"
if ! type config_import_apply >/dev/null 2>&1; then
	echo "FATAL: could not extract config_import_apply() from scripts/config-import.sh" >&2
	exit 1
fi

echo
echo "=== Testing: config_import_apply() ==="
echo

# --- build a representative site/ fixture -------------------------------------
_site="$_tmp/site"
mkdir -p "$_site/mirror" "$_site/mycluster/day2-custom-manifests/10-first"
printf 'ocp_version=4.19.2\nocp_channel=stable\n'          > "$_site/aba.conf"
printf 'reg_host=registry.example.com\nreg_port=8443\n'    > "$_site/mirror/mirror.conf"
printf 'kind: ImageSetConfiguration\napiVersion: v1\n'     > "$_site/mirror/imageset-config.yaml"
printf 'name=mycluster\ntype=sno\n'                        > "$_site/mycluster/cluster.conf"
printf 'apiVersion: v1\nkind: InstallConfig\n'             > "$_site/mycluster/install-config.yaml"
printf 'apiVersion: v1alpha1\nkind: AgentConfig\n'         > "$_site/mycluster/agent-config.yaml"
printf '52:54:00:aa:bb:cc\n'                               > "$_site/mycluster/macs.conf"
printf 'apiVersion: v1\nkind: ConfigMap\n'                 > "$_site/mycluster/day2-custom-manifests/10-first/app.yaml"

_dest="$_tmp/aba"
mkdir -p "$_dest"
( config_import_apply "$_site" "$_dest" ) >/dev/null 2>&1
_import_rc=$?

# --- Test group 1: files copied byte-for-byte ---------------------------------
echo "--- verbatim copy (cmp) ---"
_cmp() {			# name  src  dest
	if cmp -s "$2" "$3"; then test_pass "$1"; else test_fail "$1" "content differs (src=$2 dest=$3)"; fi
}
_cmp "aba.conf copied verbatim"            "$_site/aba.conf"                       "$_dest/aba.conf"
_cmp "mirror.conf copied verbatim"         "$_site/mirror/mirror.conf"             "$_dest/mirror/mirror.conf"
_cmp "imageset-config.yaml copied verbatim" "$_site/mirror/imageset-config.yaml"   "$_dest/mirror/data/imageset-config.yaml"
_cmp "cluster.conf copied verbatim"        "$_site/mycluster/cluster.conf"         "$_dest/mycluster/cluster.conf"
_cmp "install-config.yaml copied verbatim" "$_site/mycluster/install-config.yaml"  "$_dest/mycluster/install-config.yaml"
_cmp "agent-config.yaml copied verbatim"   "$_site/mycluster/agent-config.yaml"    "$_dest/mycluster/agent-config.yaml"
_cmp "macs.conf copied verbatim"           "$_site/mycluster/macs.conf"            "$_dest/mycluster/macs.conf"
_cmp "day2 wave manifest copied verbatim"  "$_site/mycluster/day2-custom-manifests/10-first/app.yaml" "$_dest/mycluster/day2-custom-manifests/10-first/app.yaml"

# --- Test group 2: regeneration guards (mtime ordering) -----------------------
echo "--- regeneration guards (strict mtime) ---"
if [ "$_dest/mirror/data/imageset-config.yaml" -nt "$_dest/mirror/data/.created" ]; then
	test_pass "imageset-config.yaml is strictly newer than mirror/data/.created (ISC pinned)"
else
	test_fail "ISC pin" "imageset-config.yaml is not newer than .created"
fi
if [ "$_dest/mycluster/install-config.yaml" -nt "$_dest/mycluster/cluster.conf" ]; then
	test_pass "install-config.yaml newer than cluster.conf (no make regen)"
else
	test_fail "install-config vs cluster.conf" "not newer"
fi
if [ "$_dest/mycluster/install-config.yaml" -nt "$_dest/mirror/mirror.conf" ]; then
	test_pass "install-config.yaml newer than mirror.conf (no make regen)"
else
	test_fail "install-config vs mirror.conf" "not newer"
fi
if [ "$_dest/mycluster/agent-config.yaml" -nt "$_dest/mycluster/cluster.conf" ]; then
	test_pass "agent-config.yaml newer than cluster.conf (no make regen)"
else
	test_fail "agent-config vs cluster.conf" "not newer"
fi
if [ "$_dest/mycluster/agent-config.yaml" -nt "$_dest/mirror/mirror.conf" ]; then
	test_pass "agent-config.yaml newer than mirror.conf (no make regen)"
else
	test_fail "agent-config vs mirror.conf" "not newer"
fi

# --- Test group 3: overall success + existing-file backup ---------------------
echo "--- success + backup ---"
[ "$_import_rc" -eq 0 ] && test_pass "config_import_apply returns 0 on a valid site" \
	|| test_fail "import rc" "expected 0 got $_import_rc"

# Re-import over an existing tree: previous install-config should be backed up.
printf 'apiVersion: v1\nkind: InstallConfig\nCHANGED: yes\n' > "$_site/mycluster/install-config.yaml"
( config_import_apply "$_site" "$_dest" ) >/dev/null 2>&1
if [ -f "$_dest/mycluster/install-config.yaml.backup" ]; then
	test_pass "existing install-config.yaml backed up to .backup on re-import"
else
	test_fail "backup on re-import" "no .backup file created"
fi
_cmp "re-import overwrites with new content" "$_site/mycluster/install-config.yaml" "$_dest/mycluster/install-config.yaml"

# --- Test group 4: error handling ---------------------------------------------
echo "--- error handling ---"
( config_import_apply "$_tmp/does-not-exist" "$_dest" ) >/dev/null 2>&1
[ $? -ne 0 ] && test_pass "missing source directory aborts (non-zero)" \
	|| test_fail "missing source" "expected non-zero exit"

_empty="$_tmp/empty-site"
mkdir -p "$_empty"
( config_import_apply "$_empty" "$_dest" ) >/dev/null 2>&1
[ $? -ne 0 ] && test_pass "source with no recognized configs aborts (non-zero)" \
	|| test_fail "empty source" "expected non-zero exit"

# --- Test group 6: directory payloads are backed up on re-import (no data loss)
echo "--- directory payload backup ---"
printf 'PRECIOUS\n' > "$_dest/mycluster/day2-custom-manifests/10-first/precious.yaml"
printf 'apiVersion: v1\nkind: ConfigMap\nchanged: yes\n' > "$_site/mycluster/day2-custom-manifests/10-first/app.yaml"
( config_import_apply "$_site" "$_dest" ) >/dev/null 2>&1
if [ -f "$_dest/mycluster/day2-custom-manifests.backup/10-first/precious.yaml" ]; then
	test_pass "existing day2-custom-manifests backed up to .backup on re-import"
else
	test_fail "day2 dir backup" "precious.yaml not preserved in .backup"
fi

# --- Test group 7: pin never creates empty trigger files or touches other clusters
echo "--- pin no-create + scoping ---"
_dest2="$_tmp/aba2"
_site2="$_tmp/site2"
mkdir -p "$_dest2" "$_site2/c1"
printf 'name=c1\n'                              > "$_site2/c1/cluster.conf"
printf 'apiVersion: v1\nkind: InstallConfig\n'  > "$_site2/c1/install-config.yaml"
( config_import_apply "$_site2" "$_dest2" ) >/dev/null 2>&1
if [ ! -e "$_dest2/mirror/mirror.conf" ]; then
	test_pass "pin does not inject an empty mirror/mirror.conf when the payload has none"
else
	test_fail "no-create mirror.conf" "empty mirror.conf injected"
fi
# a pre-existing UNRELATED cluster must not be re-stamped when importing c1
mkdir -p "$_dest2/prod"
printf 'name=prod\n'  > "$_dest2/prod/cluster.conf"
printf 'IC\n'        > "$_dest2/prod/install-config.yaml"
touch -d '2 minutes ago' "$_dest2/prod/install-config.yaml"
_bm=$(stat -c %Y "$_dest2/prod/install-config.yaml")
( config_import_apply "$_site2" "$_dest2" ) >/dev/null 2>&1
_am=$(stat -c %Y "$_dest2/prod/install-config.yaml")
[ "$_bm" = "$_am" ] && test_pass "importing c1 does not re-stamp the unrelated cluster prod/" \
	|| test_fail "pin scoping" "prod/install-config.yaml mtime changed ($_bm -> $_am)"

# --- Test group 5: CLI dispatch wiring (aba config import <dir>) --------------
echo "--- dispatch wiring ---"
grep -q '|config|' scripts/aba.sh \
	&& test_pass "'config' is in the aba direct-dispatch allow-list" \
	|| test_fail "allow-list" "config missing from aba.sh direct-dispatch list"
grep -qE '^[[:space:]]*config\)' scripts/aba.sh \
	&& test_pass "aba.sh has a 'config)' dispatch arm" \
	|| test_fail "dispatch arm" "no config) arm in aba.sh"
grep -q 'scripts/config-import.sh' scripts/aba.sh \
	&& test_pass "config) arm invokes config-import.sh" \
	|| test_fail "arm target" "config) does not call config-import.sh"
grep -q 'subcmd_args' scripts/aba.sh \
	&& test_pass "config positional args routed via subcmd_args (not BUILD_COMMAND)" \
	|| test_fail "arg routing" "subcmd_args not wired in aba.sh"
grep -q 'aba config import' others/help-aba.txt \
	&& test_pass "help-aba.txt documents 'aba config import'" \
	|| test_fail "help text" "config import not documented in help-aba.txt"

echo
echo "=== Results: $pass passed, $fail failed ==="
echo

[ -z "$FAILURES" ] && exit 0 || exit 1
