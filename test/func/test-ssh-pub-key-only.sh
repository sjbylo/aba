#!/bin/bash
# Test: ssh_key_file may name only a public key.
# A user can hand over just <path>.pub (the private key stays with them). The
# installer needs only the public key, so install-config.yaml must use it and
# must not run ssh-keygen, which would overwrite <path>.pub with a new key.
# Without a private key file, 'aba ssh' runs ssh without -i (ssh-agent and the
# ~/.ssh default keys) and says so. The cluster state backup keeps a
# relative cluster-local .pub, so a recreated cluster dir keeps the same key.

set -e

cd "$(dirname "$0")/../.."

source scripts/include_all.sh 1

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass=0
fail=0

test_pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; pass=$((pass + 1)); }
test_fail() { echo -e "${RED}✗ FAIL${NC}: $1"; fail=$((fail + 1)); }

finish() {
	echo
	echo -e "=== Results: $pass pass, $fail fail ==="
	[ "$fail" -gt 0 ] && exit 1
	exit 0
}

CLUSTER_DIR="test-sshpub-$$"
KEY_DIR=$(mktemp -d)
# Own HOME for make: a synthetic pull secret, no host credentials, no host auth files.
TEST_HOME="$KEY_DIR/home"
REPO="$PWD"
# The fixture edits aba.conf (verify_conf, pull_secret_file) and aba cluster may
# write to it too. Put the operator's file back exactly on exit.
cp -p aba.conf "$KEY_DIR/aba.conf.orig"

cleanup() {
	cd "$REPO"
	rm -rf "$CLUSTER_DIR" "$CLUSTER_DIR-rec"
	cp -p "$KEY_DIR/aba.conf.orig" aba.conf
	rm -rf "$KEY_DIR"
}
trap cleanup EXIT

# Generate install-config.yaml with ssh_key_file=$1.
# The prerequisite markers are touched so make runs only verify-config.sh and
# create-install-config.sh: no CLI install (.cli), no VIP lookup, no dnsmasq
# change (.infra-dns).
gen_install_config() {
	replace-value-conf -q -n ssh_key_file -v "$1" -f cluster.conf
	touch .cli .resolve-vips .infra-dns
	rm -f install-config.yaml
	if make -n install-config.yaml 2>&1 | grep -qE 'cli-install-all|resolve-vips|infra-dns'; then
		echo "make would run a CLI install or DNS step"
		return 1
	fi
	HOME="$TEST_HOME" XDG_RUNTIME_DIR="$TEST_HOME/run" make -s install-config.yaml >/dev/null 2>&1
}

# True if install-config.yaml has the key line $1 as sshKey.
has_ssh_key() {
	[ -n "$1" ] && grep -A1 '^sshKey:' install-config.yaml | grep -qF "$1"
}

echo
echo "=== Test: public-key-only ssh_key_file ==="
echo

mkdir -p "$TEST_HOME"
mkdir -m 700 "$TEST_HOME/run"
printf '{"auths":{"registry.redhat.io":{"auth":"%s"}}}\n' "$(printf dummy:dummy | base64)" > "$TEST_HOME/.pull-secret.json"

# Every aba run uses TEST_HOME: the operator's ~/.aba (runner, cache) is not written.
# A copy of the finished download tasks and the graph cache keeps aba from
# starting the CLI downloads again (as test-cli-flag-effects.sh does).
mkdir -p "$TEST_HOME/.aba"
if [ -d "$HOME/.aba/cache" ]; then
	cp -a "$HOME/.aba/cache" "$TEST_HOME/.aba/cache"
fi
if [ -d "$HOME/.aba/runner" ]; then
	cp -a "$HOME/.aba/runner" "$TEST_HOME/.aba/runner"
	find "$TEST_HOME/.aba/runner" -name exit -exec touch {} +
fi
aba() { HOME="$TEST_HOME" XDG_RUNTIME_DIR="$TEST_HOME/run" command aba "$@"; }

# Test-only: the cluster names have no DNS records. verify_conf=off skips the
# checks; empty does not. The pull secret is the synthetic one, whatever path
# the operator configured. platform=bm: with vmw or kvm, make would build
# vmware.conf or kvm.conf and could reach a real hypervisor.
replace-value-conf -q -n verify_conf -v off -f aba.conf
replace-value-conf -q -n pull_secret_file -v "$TEST_HOME/.pull-secret.json" -f aba.conf
replace-value-conf -q -n platform -v bm -f aba.conf

# -y, not -Y: -Y writes ask=false into aba.conf.
if ! aba cluster --name "$CLUSTER_DIR" --type sno -y >/dev/null 2>&1; then
	test_fail "aba cluster failed to create $CLUSTER_DIR"
	finish
fi
cd "$CLUSTER_DIR"

replace-value-conf -q -n machine_network -v 10.0.1.0 -f cluster.conf
replace-value-conf -q -n prefix_length -v 24 -f cluster.conf
replace-value-conf -q -n next_hop_address -v 10.0.1.1 -f cluster.conf
replace-value-conf -q -n starting_ip -v 10.0.1.10 -f cluster.conf
replace-value-conf -q -n dns_servers -v 10.0.1.1 -f cluster.conf
# direct: no mirror credentials needed, only the (synthetic) public pull secret.
replace-value-conf -q -n image_source -v direct -f cluster.conf

# --- 1: absolute path, only <path>.pub ---
ssh-keygen -q -t ed25519 -N '' -C pub-only -f "$KEY_DIR/pubonly"
rm -f "$KEY_DIR/pubonly"
_pub=$(cat "$KEY_DIR/pubonly.pub")
_sum=$(sha256sum < "$KEY_DIR/pubonly.pub")
if ! gen_install_config "$KEY_DIR/pubonly"; then
	test_fail "absolute .pub only: make install-config.yaml failed"
	finish
fi
has_ssh_key "$_pub" && test_pass "absolute .pub only: sshKey is the .pub content" || test_fail "absolute .pub only: sshKey is not the .pub content"
[ ! -e "$KEY_DIR/pubonly" ] && test_pass "absolute .pub only: no private key generated" || test_fail "absolute .pub only: a private key was generated"
[ "$(sha256sum < "$KEY_DIR/pubonly.pub")" = "$_sum" ] && test_pass "absolute .pub only: .pub unchanged" || test_fail "absolute .pub only: .pub was changed"

# --- 1b: --ssh-key given the .pub path itself: stored as the key path without .pub ---
# Start from another value, so a flag that writes nothing cannot pass.
# --help stops aba after the flag is written to cluster.conf.
replace-value-conf -q -n ssh_key_file -v "$KEY_DIR/other" -f cluster.conf
if aba -d . --ssh-key "$KEY_DIR/pubonly.pub" --help >/dev/null 2>&1; then
	_k=$(fetch_value ssh_key_file cluster.conf) || true
	[ "$_k" = "$KEY_DIR/pubonly" ] && test_pass "--ssh-key <key>.pub: ssh_key_file is <key>" || test_fail "--ssh-key <key>.pub: ssh_key_file is [$_k]"
else
	_k=
	test_fail "--ssh-key <key>.pub: aba exited non-zero"
fi
if [ -n "$_k" ] && gen_install_config "$_k" && has_ssh_key "$_pub" && [ ! -e "$KEY_DIR/pubonly.pub.pub" ]; then
	test_pass "--ssh-key <key>.pub: sshKey is the .pub content, no .pub.pub"
else
	test_fail "--ssh-key <key>.pub: install-config.yaml failed or wrong, or .pub.pub created"
fi

# --ssh-key with a missing <key>.pub aborts and leaves cluster.conf as it was.
replace-value-conf -q -n ssh_key_file -v "$KEY_DIR/other" -f cluster.conf
_out=$(aba -d . --ssh-key "$KEY_DIR/nokey.pub" --help 2>&1) && _rc=0 || _rc=$?
if [ "$_rc" -ne 0 ] && grep -q "SSH public key file not found: $KEY_DIR/nokey.pub" <<< "$_out" \
	&& [ "$(fetch_value ssh_key_file cluster.conf)" = "$KEY_DIR/other" ]; then
	test_pass "--ssh-key <missing>.pub: aborts, cluster.conf unchanged"
else
	test_fail "--ssh-key <missing>.pub: unexpected result (rc=$_rc): $_out"
fi

# --- 1c: a .pub without public key material is refused, no key is generated ---
echo "not a public key" > "$KEY_DIR/junk.pub"
_sum=$(sha256sum < "$KEY_DIR/junk.pub")
if gen_install_config "$KEY_DIR/junk"; then
	test_fail "invalid .pub: make install-config.yaml succeeded"
else
	test_pass "invalid .pub: make install-config.yaml fails"
fi
[ ! -e "$KEY_DIR/junk" ] && [ "$(sha256sum < "$KEY_DIR/junk.pub")" = "$_sum" ] && test_pass "invalid .pub: no key generated, .pub unchanged" || test_fail "invalid .pub: a key was generated or .pub changed"

# A private key named <key>.pub: ssh-keygen -l accepts it, the check must not.
ssh-keygen -q -t ed25519 -N '' -C priv-as-pub -f "$KEY_DIR/privpub.pub"
rm -f "$KEY_DIR/privpub.pub.pub"
if gen_install_config "$KEY_DIR/privpub"; then
	test_fail "private key as .pub: make install-config.yaml succeeded"
else
	test_pass "private key as .pub: make install-config.yaml fails"
fi
[ ! -e install-config.yaml ] || ! grep -q 'PRIVATE KEY' install-config.yaml && test_pass "private key as .pub: not embedded" || test_fail "private key as .pub: embedded in install-config.yaml"

# An empty <key>.pub without a private key: refused, not overwritten by a new key.
: > "$KEY_DIR/empty.pub"
if gen_install_config "$KEY_DIR/empty"; then
	test_fail "empty .pub: make install-config.yaml succeeded"
else
	test_pass "empty .pub: make install-config.yaml fails"
fi
[ ! -e "$KEY_DIR/empty" ] && [ ! -s "$KEY_DIR/empty.pub" ] && test_pass "empty .pub: no key generated, .pub still empty" || test_fail "empty .pub: a key was generated"

# --- 2: relative path in the cluster dir, only ssh-key.pub ---
ssh-keygen -q -t ed25519 -N '' -C rel-pub-only -f ssh-key
rm -f ssh-key
_rel_pub=$(cat ssh-key.pub)
_sum=$(sha256sum < ssh-key.pub)
if ! gen_install_config ssh-key; then
	test_fail "relative .pub only: make install-config.yaml failed"
	finish
fi
has_ssh_key "$_rel_pub" && test_pass "relative .pub only: sshKey is the .pub content" || test_fail "relative .pub only: sshKey is not the .pub content"
[ ! -e ssh-key ] && test_pass "relative .pub only: no private key generated" || test_fail "relative .pub only: a private key was generated"
[ "$(sha256sum < ssh-key.pub)" = "$_sum" ] && test_pass "relative .pub only: .pub unchanged" || test_fail "relative .pub only: .pub was changed"

# 'aba ssh' without a private key goes on without -i and says so, the hint on
# its own line. It then stops at the missing rendezvousIP here.
for _k in ssh-key "$KEY_DIR/missing"; do
	replace-value-conf -q -n ssh_key_file -v "$_k" -f cluster.conf
	_out=$(aba -d . ssh 2>&1) && _rc=0 || _rc=$?
	if grep -q "No private SSH key at $_k: ssh tries ssh-agent" <<< "$_out" \
		&& grep "If that fails, run: aba" <<< "$_out" | grep -- "--ssh-key" | grep -vq "No private SSH key" \
		&& grep -q "rendezvousIP file missing" <<< "$_out"; then
		test_pass "aba ssh, no private key ($_k): goes on without -i, notice and hint"
	else
		test_fail "aba ssh, no private key ($_k): unexpected output (rc=$_rc): $_out"
	fi
done

# --- 3: neither file: unchanged behaviour, an rsa key pair is generated ---
if ! gen_install_config "$KEY_DIR/none"; then
	test_fail "no key files: make install-config.yaml failed"
	finish
fi
[ -s "$KEY_DIR/none" ] && [ -s "$KEY_DIR/none.pub" ] && test_pass "no key files: key pair generated" || test_fail "no key files: key pair not generated"
grep -q '^ssh-rsa ' "$KEY_DIR/none.pub" && test_pass "no key files: generated key is rsa" || test_fail "no key files: generated key is not rsa"
has_ssh_key "$(cat "$KEY_DIR/none.pub")" && test_pass "no key files: sshKey is the generated .pub" || test_fail "no key files: sshKey is not the generated .pub"

# --- 4: both files: unchanged behaviour, both are used as they are ---
ssh-keygen -q -t ed25519 -N '' -C both -f "$KEY_DIR/both"
_pub=$(cat "$KEY_DIR/both.pub")
_sum=$(cat "$KEY_DIR/both" "$KEY_DIR/both.pub" | sha256sum)
if ! gen_install_config "$KEY_DIR/both"; then
	test_fail "both key files: make install-config.yaml failed"
	finish
fi
has_ssh_key "$_pub" && test_pass "both key files: sshKey is the .pub content" || test_fail "both key files: sshKey is not the .pub content"
[ "$(cat "$KEY_DIR/both" "$KEY_DIR/both.pub" | sha256sum)" = "$_sum" ] && test_pass "both key files: unchanged" || test_fail "both key files: changed"

# --- cluster_ssh_id_opts (shared by aba ssh, aba rescue and the TUI) ---
ssh_id_opts=()	# set by cluster_ssh_id_opts
if cluster_ssh_id_opts "$KEY_DIR/both" && [ "${ssh_id_opts[*]}" = "-i $KEY_DIR/both" ]; then
	test_pass "cluster_ssh_id_opts: private key -> -i <key>"
else
	test_fail "cluster_ssh_id_opts: private key gave [${ssh_id_opts[*]}]"
fi
for _k in "$KEY_DIR/pubonly" "$KEY_DIR/missing"; do
	if ! cluster_ssh_id_opts "$_k" && [ "${#ssh_id_opts[@]}" -eq 0 ]; then
		test_pass "cluster_ssh_id_opts: no private key ($(basename "$_k")) -> returns 1, no -i"
	else
		test_fail "cluster_ssh_id_opts: no private key ($(basename "$_k")) gave [${ssh_id_opts[*]}]"
	fi
done

# --- 5: state backup keeps a .pub inside the cluster dir, never a private key ---
# Cluster state lives under $HOME/.aba/clusters: use TEST_HOME, never the real one.
_cn=$(fetch_value cluster_name cluster.conf)
_bd=$(fetch_value base_domain cluster.conf)
_state_dir="$TEST_HOME/.aba/clusters/$_cn.$_bd"
_backup="$_state_dir/backup"

# Save the cluster state with ssh_key_file=$1, under TEST_HOME.
backup_state() {
	replace-value-conf -q -n ssh_key_file -v "$1" -f cluster.conf
	( HOME="$TEST_HOME"; externalize_cluster_state ) >/dev/null 2>&1
}

# Outside the cluster dir: not copied.
backup_state "$KEY_DIR/pubonly" || test_fail "externalize_cluster_state failed (outside key)"
[ -z "$(find "$_backup" -name 'pubonly*' 2>/dev/null)" ] && test_pass "state backup: key outside the cluster dir not copied" || test_fail "state backup: key outside the cluster dir was copied"

# Absolute path, even inside the cluster dir: not copied (the operator's own key location).
mkdir -p keys
cp ssh-key.pub keys/abs-key.pub
backup_state "$PWD/keys/abs-key" || test_fail "externalize_cluster_state failed (absolute key)"
[ -z "$(find "$_backup" -name 'abs-key*' 2>/dev/null)" ] && test_pass "state backup: absolute key inside the cluster dir not copied" || test_fail "state backup: absolute key inside the cluster dir was copied"

# '..' inside a file name is not an escape.
cp ssh-key.pub site..key.pub
backup_state site..key || test_fail "externalize_cluster_state failed (site..key)"
[ "$(cat "$_backup/site..key.pub" 2>/dev/null)" = "$_rel_pub" ] && test_pass "state backup: site..key.pub copied" || test_fail "state backup: site..key.pub not copied"

# A link to another .pub in the cluster dir: stored as a file under the
# configured name, which is the name cluster.conf gives on restore.
ln -sfn keys/abs-key.pub team-link.pub
backup_state team-link || test_fail "externalize_cluster_state failed (team-link)"
if [ "$(cat "$_backup/team-link.pub" 2>/dev/null)" = "$_rel_pub" ] && [ ! -L "$_backup/team-link.pub" ]; then
	test_pass "state backup: linked .pub stored under the configured name"
else
	test_fail "state backup: linked .pub not stored as team-link.pub"
fi

# Relative key with a private key next to it: only the .pub is copied, and a
# recreated cluster dir gets the same .pub back.
echo "not-a-real-key" > ssh-key
backup_state ssh-key || test_fail "externalize_cluster_state failed (ssh-key)"
[ "$(cat "$_backup/ssh-key.pub" 2>/dev/null)" = "$_rel_pub" ] && test_pass "state backup: has ssh-key.pub" || test_fail "state backup: no ssh-key.pub"
[ ! -e "$_backup/ssh-key" ] && test_pass "state backup: no private key" || test_fail "state backup: private key was copied"
if ( HOME="$TEST_HOME"; _recreate_cluster_dir "$_cn" "$_bd" "$REPO/$CLUSTER_DIR-rec" ) >/dev/null 2>&1 \
	&& [ "$(cat "$REPO/$CLUSTER_DIR-rec/ssh-key.pub" 2>/dev/null)" = "$_rel_pub" ]; then
	test_pass "recreated cluster dir: same ssh-key.pub"
else
	test_fail "recreated cluster dir: ssh-key.pub missing or changed"
fi
[ ! -e "$HOME/.aba/clusters/$_cn.$_bd" ] && test_pass "real ~/.aba/clusters not touched" || test_fail "state was written to the real ~/.aba/clusters"

finish
