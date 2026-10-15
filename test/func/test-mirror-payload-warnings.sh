#!/bin/bash
# Test: mirror-status.sh payload contradiction warnings
# Regression test for: dba6146d (warn when content configured but excluded)
# Verifies: warn_operators_excluded and warn_additional_excluded flags
#           fire correctly across all 18 config permutations.

cd "$(dirname "$0")/../.." || exit 1
source scripts/include_all.sh 2>/dev/null

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }

echo "=== mirror-status.sh payload contradiction warnings ==="

_repo=$(pwd)
_tmp=$(mktemp -d)
trap 'rm -rf "$_tmp"' EXIT

# Replicate the repo structure that mirror-status.sh expects
cp aba.conf "$_tmp/aba.conf"
mkdir -p "$_tmp/mirror/data"
cp mirror/mirror.conf "$_tmp/mirror/mirror.conf" 2>/dev/null || \
	echo "# minimal" > "$_tmp/mirror/mirror.conf"

# Symlinks that .init creates (mirror-status.sh sources scripts/include_all.sh from CWD)
ln -sfn "$_repo/scripts" "$_tmp/scripts"
ln -sfn "$_repo/cli" "$_tmp/cli"
ln -sfn "$_repo/scripts" "$_tmp/mirror/scripts"
ln -sfn "$_repo/cli" "$_tmp/mirror/cli"
ln -sf ../aba.conf "$_tmp/mirror/aba.conf"
ln -sfn . "$_tmp/mirror/mirror"

# Copy templates (not symlink) so test files don't pollute the repo
cp -a "$_repo/templates" "$_tmp/templates"
ln -sf "$_tmp/templates" "$_tmp/mirror/templates"

# Minimal ISC
cat > "$_tmp/mirror/data/imageset-config.yaml" <<'EOF'
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  platform:
    channels:
    - name: stable-4.22
      minVersion: "4.22.0"
      maxVersion: "4.22.0"
EOF

# Custom op_set file (safe — templates/ is a copy, not a symlink to repo)
mkdir -p "$_tmp/templates/operator-sets"
echo "local-storage-operator" > "$_tmp/templates/operator-sets/custom-test"

# Empty images.conf baseline
> "$_tmp/images.conf"
> "$_tmp/mirror/images.conf"

run_test() {
	local label="$1"
	local excl_p="$2" excl_o="$3" excl_a="$4"
	local ops_val="$5" imgs="$6"
	local exp_plat="$7" exp_ops="$8" exp_addl="$9"

	sed -i "s/^excl_platform=.*/excl_platform=$excl_p/" "$_tmp/aba.conf"
	sed -i "s/^excl_operators=.*/excl_operators=$excl_o/" "$_tmp/aba.conf"
	sed -i "s/^excl_additional=.*/excl_additional=$excl_a/" "$_tmp/aba.conf"
	sed -i "s/^op_sets=.*/op_sets=$ops_val/" "$_tmp/aba.conf"

	if [ "$imgs" = "yes" ]; then
		echo "registry.redhat.io/ubi9/ubi-micro:latest" > "$_tmp/images.conf"
	else
		> "$_tmp/images.conf"
	fi

	local out
	out=$(cd "$_tmp/mirror" && bash scripts/mirror-status.sh --shell 2>/dev/null) || true

	local got_plat got_ops got_addl
	got_plat=$(echo "$out" | grep "^excl_platform=" | cut -d= -f2)
	got_ops=$(echo "$out" | grep "^warn_operators_excluded=" | cut -d= -f2)
	got_addl=$(echo "$out" | grep "^warn_additional_excluded=" | cut -d= -f2)

	# Normalize: empty → false (normalize-aba-conf converts false→empty)
	[ -z "$got_plat" ] && got_plat="false" || got_plat="true"
	[ -z "$got_ops" ] && got_ops="false"
	[ -z "$got_addl" ] && got_addl="false"

	local ok=true
	[ "$got_plat" != "$exp_plat" ] && ok=false
	[ "$got_ops" != "$exp_ops" ] && ok=false
	[ "$got_addl" != "$exp_addl" ] && ok=false

	if [ "$ok" = "true" ]; then
		_pass "$label"
	else
		_fail "$label (plat=$got_plat/$exp_plat ops=$got_ops/$exp_ops addl=$got_addl/$exp_addl)"
	fi
}

# === Platform included (9 permutations) ===

run_test "All included, ops configured" \
	false false false custom-test no \
	false false false

run_test "All included, no ops" \
	false false false "" no \
	false false false

run_test "Ops excluded + configured (contradiction)" \
	false true false custom-test no \
	false true false

run_test "Ops excluded, none configured" \
	false true false "" no \
	false false false

run_test "Addl excluded + configured (contradiction)" \
	false false true "" yes \
	false false true

run_test "Addl excluded, no images" \
	false false true "" no \
	false false false

run_test "Ops + addl contradictions" \
	false true true custom-test yes \
	false true true

run_test "Ops contradiction + addl excluded no imgs" \
	false true true custom-test no \
	false true false

run_test "Ops excluded no ops + addl contradiction" \
	false true true "" yes \
	false false true

# === Platform excluded (9 permutations) ===

run_test "Platform excluded only" \
	true false false custom-test no \
	true false false

run_test "Platform + ops contradiction" \
	true true false custom-test no \
	true true false

run_test "Platform + ops excluded, no ops" \
	true true false "" no \
	true false false

run_test "Platform + addl contradiction" \
	true false true custom-test yes \
	true false true

run_test "Platform + addl excluded, no imgs" \
	true false true custom-test no \
	true false false

run_test "Triple warning" \
	true true true custom-test yes \
	true true true

run_test "All excluded, nothing configured" \
	true true true "" no \
	true false false

run_test "Platform + ops contradiction + addl no imgs" \
	true true true custom-test no \
	true true false

run_test "Platform + addl contradiction + ops no ops" \
	true true true "" yes \
	true false true

# --- Summary ---
echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
