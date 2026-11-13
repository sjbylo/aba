#!/bin/bash
# Test: operator catalogs per distribution (unit, mocked: podman/curl/skopeo are shims).
#   okd: no catalog work when no operators are selected; only community-operator-index from
#        registry.access.redhat.com (anonymous) when operators are selected; redhat-/certified-
#        (registry.redhat.io, need an account) are rejected; the pickers list the community catalog only.
#   ocp: unchanged (three catalogs from registry.redhat.io, pickers list what they listed before).

cd "$(dirname "$0")/../.." || exit 1
REPO_ROOT="$PWD"

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }
_eq() { if [[ "$2" == "$3" ]]; then _pass "$1"; else _fail "$1: expected [$2] got [$3]"; fi; }
_has() { if grep -qE -- "$2" <<< "$3"; then _pass "$1"; else _fail "$1: /$2/ not in [$3]"; fi; }
_hasnt() { if grep -qE -- "$2" <<< "$3"; then _fail "$1: /$2/ unexpectedly in [$3]"; else _pass "$1"; fi; }

T=$(mktemp -d "${TMPDIR:-/tmp}/okd-cat.XXXXXX")
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"

# Shims. podman: logs, `pull` succeeds, everything else fails (the download script then stops at once).
mkdir -p "$T/shim"
cat > "$T/shim/podman" <<'EOF'
#!/bin/bash
echo "$*" >> "${PODMAN_LOG:?}"
case "$1" in pull|ps) exit 0 ;; esac
exit 1
EOF
cat > "$T/shim/curl" <<'EOF'
#!/bin/bash
echo "$*" >> "${CURL_LOG:?}"
exit 0
EOF
cat > "$T/shim/skopeo" <<'EOF'
#!/bin/bash
echo "$*" >> "${SKOPEO_LOG:-/dev/null}"
exit 1
EOF
chmod +x "$T"/shim/*
export PODMAN_LOG="$T/podman.log" CURL_LOG="$T/curl.log" SKOPEO_LOG="$T/skopeo.log"
export PATH="$T/shim:$PATH"
export _ABA_SKIP_AUTH=1

# A throw-away aba root with its own copy of scripts/ and templates/ (the download script cd's to its own root).
R="$T/root"; mkdir -p "$R/mirror" "$R/catalogs" "$R/.index"
cp -a --reflink=auto "$REPO_ROOT/scripts" "$R/scripts"
cp -a --reflink=auto "$REPO_ROOT/templates" "$R/templates"
( cd "$R" && PATH=/usr/sbin:/usr/bin:/bin domain=example.com scripts/j2 templates/aba.conf.j2 > aba.conf ) 2>/dev/null
[ -s "$R/aba.conf" ] || { echo "cannot render aba.conf"; exit 1; }
sedc() { sed -i -e "s|^$1=.*|$1=$2|" "$R/aba.conf"; }
sedc machine_network 10.0.0.0/20; sedc next_hop_address 10.0.0.1; sedc dns_servers 10.0.0.1; sedc ntp_servers 10.0.0.1
sedc ocp_channel stable; sedc op_sets ""; sedc ops ""
setdist() {  # setdist okd|ocp
	if [ "$1" = okd ]; then sedc ocp_version 4.21.0-okd-scos.11; else sedc ocp_version 4.21.0; fi
	grep -q '^distribution=' "$R/aba.conf" && sedc distribution "$1" || echo "distribution=$1" >> "$R/aba.conf"
}
( cd "$R/mirror" && ln -s ../scripts scripts && ln -s ../templates templates && ln -s ../aba.conf aba.conf && ln -s ../.index .index )
# Shipped catalog fixtures: acm lives in redhat only, nvidia in certified only, cert-manager in community only.
printf '%s\n' 'advanced-cluster-management Advanced Cluster Management release-2.14' 'multicluster-engine Multicluster Engine stable-2.9' 'dual-operator In both catalogs stable' > "$R/catalogs/redhat-operator-index-v4.21"
printf '%s\n' 'gpu-operator-certified NVIDIA GPU Operator v25.3' > "$R/catalogs/certified-operator-index-v4.21"
printf '%s\n' 'cert-manager cert-manager stable' 'argocd-operator Argo CD alpha' 'dual-operator In both catalogs stable' > "$R/catalogs/community-operator-index-v4.21"

n=0; RO="$T/runner-0"
newrunner() { n=$(( n + 1 )); RO="$T/runner-$n"; }
# runin <dir> <script> [args]  -> output + "rc=N"; uses the current runner dir $RO
runin() {
	local dir="$1"; shift
	( cd "$R/$dir" && RUN_ONCE_DIR="$RO" ABA_ROOT="$R" bash "$@" 2>&1 ); echo "rc=$?"
}
rc_of() { sed -n 's/^rc=//p' <<< "$1" | tail -1; }
reset_logs() { : > "$PODMAN_LOG"; : > "$CURL_LOG"; : > "$SKOPEO_LOG"; : > "$T/progress"; newrunner; }
tasks() { ls "$RO" 2>/dev/null | grep '^catalog:' | sort -u | tr '\n' ' '; }
export ABA_PROGRESS_FIFO="$T/progress"; : > "$ABA_PROGRESS_FIFO"

echo "=== helpers exist ==="
for fn in dist_catalogs dist_catalog_ref dist_catalog_index_files dist_catalog_reject_blocked_ops; do
	( source "$REPO_ROOT/scripts/include_all.sh" 2>/dev/null; declare -F "$fn" >/dev/null ) && _pass "defined: $fn" || _fail "missing: $fn"
done

echo ""
echo "=== dist_catalogs / dist_catalog_ref / dist_catalog_index_files ==="
h() { ( cd "$T" && distribution="$1" bash -c "source '$REPO_ROOT/scripts/include_all.sh' 2>/dev/null; trap - ERR; $2" ) 2>&1; }
_eq "ocp: three catalogs in priority order" "redhat-operator certified-operator community-operator" "$(h ocp 'echo $(dist_catalogs)')"
_eq "okd: community only" "community-operator" "$(h okd 'echo $(dist_catalogs)')"
_eq "ocp: ref host registry.redhat.io" "registry.redhat.io/redhat/redhat-operator-index:v4.21" "$(h ocp 'dist_catalog_ref redhat-operator 4.21')"
_eq "ocp: ref follows catalog and version" "registry.redhat.io/redhat/community-operator-index:v5.0" "$(h ocp 'dist_catalog_ref community-operator 5.0')"
_eq "okd: community ref is the anonymous host" "registry.access.redhat.com/redhat/community-operator-index:v4.21" "$(h okd 'dist_catalog_ref community-operator 4.21')"
_eq "okd: ref follows the version" "registry.access.redhat.com/redhat/community-operator-index:v5.0" "$(h okd 'dist_catalog_ref community-operator 5.0')"
_eq "okd: redhat-operator ref refused (rc 1)" "1" "$(h okd 'dist_catalog_ref redhat-operator 4.21 >/dev/null 2>&1; echo $?')"
_eq "okd: certified-operator ref refused (rc 1)" "1" "$(h okd 'dist_catalog_ref certified-operator 4.21 >/dev/null 2>&1; echo $?')"
_eq "ocp: index files, same order as before" "/x/.index/redhat-operator-index-v4.21 /x/.index/certified-operator-index-v4.21 /x/.index/community-operator-index-v4.21" "$(h ocp 'echo $(dist_catalog_index_files 4.21 /x/.index)')"
_eq "okd: index files, community only" "/x/.index/community-operator-index-v4.21" "$(h okd 'echo $(dist_catalog_index_files 4.21 /x/.index)')"
_eq "okd: default dir is .index of the aba root" "/y/.index/community-operator-index-v4.21" "$(h okd 'ABA_ROOT=/y; echo $(dist_catalog_index_files 4.21)')"
_eq "ocp: default dir is .index of the aba root" "/y/.index/redhat-operator-index-v4.21 /y/.index/certified-operator-index-v4.21 /y/.index/community-operator-index-v4.21" "$(h ocp 'ABA_ROOT=/y; echo $(dist_catalog_index_files 4.21)')"

echo ""
echo "=== okd, no operators: nothing to do ==="
setdist okd; sedc ops ""; sedc op_sets ""
reset_logs
out=$(runin mirror scripts/download-catalogs-start.sh)
_eq "start: exit 0" "0" "$(rc_of "$out")"
_eq "start: no podman call" "0" "$(wc -l < "$PODMAN_LOG")"
_eq "start: no catalog task" "" "$(tasks)"
_hasnt "start: no registry.redhat.io" "redhat\.io" "$(cat "$CURL_LOG") $out"
reset_logs
out=$(runin mirror scripts/download-catalogs-wait.sh)
_eq "wait: exit 0" "0" "$(rc_of "$out")"
_eq "wait: no podman call" "0" "$(wc -l < "$PODMAN_LOG")"
_hasnt "wait: does not wait for a catalog" "Waiting for|Failed to download" "$out"
_has "wait: reports the step as no-op" "^NOOP\|catalogs_dl" "$(cat "$ABA_PROGRESS_FIFO")"
_eq "wait: no catalog task" "" "$(tasks)"

echo ""
echo "=== okd, operators from the community catalog ==="
sedc ops cert-manager
reset_logs
out=$(runin mirror scripts/download-catalogs-start.sh)
_eq "start: exit 0" "0" "$(rc_of "$out")"
sleep 3   # background tasks
_eq "start: exactly the community catalog task" "catalog:4.21:community-operator" "$(tasks | sed 's/ $//')"
_has "start: pulls the anonymous community catalog" "pull .* registry\.access\.redhat\.com/redhat/community-operator-index:v4\.21" "$(cat "$PODMAN_LOG")"
_hasnt "start: no redhat-/certified- pull" "redhat-operator-index|certified-operator-index" "$(cat "$PODMAN_LOG")"
_hasnt "start: nothing is fetched from registry.redhat.io" "registry\.redhat\.io" "$(cat "$PODMAN_LOG") $(cat "$CURL_LOG")"
_has "start: catalog reachability probe uses the anonymous host" "registry\.access\.redhat\.com/v2" "$(cat "$CURL_LOG")"

# wait: community task done is enough; a redhat-/certified- task would be waited for (and missing) on ocp
newrunner
( cd "$R/mirror" && RUN_ONCE_DIR="$RO" bash -c "source scripts/include_all.sh 2>/dev/null; run_once -i catalog:4.21:community-operator -- true; run_once -w -q -i catalog:4.21:community-operator" ) >/dev/null 2>&1
cp "$R/catalogs/community-operator-index-v4.21" "$R/.index/community-operator-index-v4.21"
: > "$PODMAN_LOG"; : > "$CURL_LOG"
out=$(runin mirror scripts/download-catalogs-wait.sh)
_eq "wait: exit 0 with only the community catalog ready" "0" "$(rc_of "$out")"
_has "wait: success message" "All operator catalogs ready" "$out"
rm -f "$R/.index/"*

echo ""
echo "=== okd, catalogs that need a Red Hat account are rejected ==="
for case_ in "ops|advanced-cluster-management|redhat" "ops|gpu-operator-certified|certified" "op_sets|acm|redhat" "op_sets|all|redhat"; do
	IFS='|' read -r key val cat <<< "$case_"
	sedc ops ""; sedc op_sets ""; sedc "$key" "$val"
	for s in start wait; do
		reset_logs
		out=$(runin mirror scripts/download-catalogs-$s.sh)
		_eq "$s: $key=$val rejected" "1" "$(rc_of "$out")"
		_has "$s: $key=$val message mentions Red Hat account" "Red Hat account" "$out"
		_has "$s: $key=$val message names the $cat catalog" "$cat-operator" "$out"
		_has "$s: $key=$val message says community is what works" "community-operator" "$out"
		_eq "$s: $key=$val nothing pulled" "0" "$(wc -l < "$PODMAN_LOG")"
	done
done
sedc op_sets ""; sedc ops "dual-operator"
reset_logs
out=$(runin mirror scripts/download-catalogs-start.sh)
_eq "an operator that is also in the community catalog is not rejected" "0" "$(rc_of "$out")"
sedc op_sets ""; sedc ops "cert-manager,advanced-cluster-management"
reset_logs
out=$(runin mirror scripts/download-catalogs-start.sh)
_eq "mixed list rejected" "1" "$(rc_of "$out")"
_has "mixed list names the blocked operator" "advanced-cluster-management" "$out"
_hasnt "mixed list does not blame the community operator" "cert-manager" "$(grep -i 'Error' <<< "$out")"
sedc ops "no-such-operator-anywhere"
reset_logs
out=$(runin mirror scripts/download-catalogs-start.sh)
_eq "unknown operator is not this guard's business (still starts the community download)" "0" "$(rc_of "$out")"

echo ""
echo "=== download-catalog-index.sh ==="
sedc ops ""
setdist okd
reset_logs
out=$(runin . scripts/download-catalog-index.sh community-operator 4.21)
_has "okd: pulls registry.access.redhat.com community catalog" "pull .* registry\.access\.redhat\.com/redhat/community-operator-index:v4\.21" "$(cat "$PODMAN_LOG")"
_has "okd: connectivity probe goes to the anonymous host" "registry\.access\.redhat\.com/v2" "$(cat "$CURL_LOG")"
_hasnt "okd: never contacts registry.redhat.io" "registry\.redhat\.io" "$(cat "$PODMAN_LOG") $(cat "$CURL_LOG")"
reset_logs
out=$(runin . scripts/download-catalog-index.sh redhat-operator 4.21)
_eq "okd: redhat-operator refused" "1" "$(rc_of "$out")"
_has "okd: message says why" "Red Hat account" "$out"
_eq "okd: nothing pulled for redhat-operator" "0" "$(wc -l < "$PODMAN_LOG")"
out=$(runin . scripts/download-catalog-index.sh certified-operator 4.21)
_eq "okd: certified-operator refused" "1" "$(rc_of "$out")"
setdist ocp
reset_logs
out=$(runin . scripts/download-catalog-index.sh redhat-operator 4.21)
_has "ocp: pulls registry.redhat.io redhat catalog" "pull .* registry\.redhat\.io/redhat/redhat-operator-index:v4\.21" "$(cat "$PODMAN_LOG")"
_has "ocp: probe goes to registry.redhat.io" "registry\.redhat\.io/v2" "$(cat "$CURL_LOG")"

echo ""
echo "=== ocp: catalog scripts unchanged ==="
setdist ocp; sedc ops ""; sedc op_sets ""
reset_logs
out=$(runin mirror scripts/download-catalogs-start.sh)
sleep 3
_eq "ocp start: exit 0" "0" "$(rc_of "$out")"
_eq "ocp start: three catalog tasks" "catalog:4.21:certified-operator catalog:4.21:community-operator catalog:4.21:redhat-operator" "$(tasks | sed 's/ $//')"
_has "ocp start: pulls the redhat catalog from registry.redhat.io" "registry\.redhat\.io/redhat/redhat-operator-index:v4\.21" "$(cat "$PODMAN_LOG")"
sedc ops "advanced-cluster-management"
reset_logs
out=$(runin mirror scripts/download-catalogs-start.sh)
_eq "ocp: an operator that lives in the redhat catalog is not rejected" "0" "$(rc_of "$out")"
sedc ops ""; sedc op_sets "all"
reset_logs
out=$(runin mirror scripts/download-catalogs-start.sh)
_eq "ocp: op_sets=all is not rejected" "0" "$(rc_of "$out")"
sedc op_sets ""

echo ""
echo "=== pickers: show-ops lists the community catalog only on okd ==="
S() { ( cd "$R" && ABA_ROOT="$R" RUN_ONCE_DIR="${RO_SO:-$T/runner-so-$RANDOM}" INFO_ABA=1 bash scripts/show-ops.sh "$@" 2>"$T/so.err"; echo "rc=$?" ); }
setdist okd; rm -f "$R/.index/"*
out=$(S)
_eq "okd default: rc 0" "0" "$(rc_of "$out")"
_has "okd default: lists a community operator" "cert-manager" "$out"
_hasnt "okd default: no redhat operator" "advanced-cluster-management" "$out"
_has "okd default: says why" "Red Hat account" "$(cat "$T/so.err")"
for flag in --redhat --certified --all; do
	rm -f "$R/.index/"*
	out=$(S $flag)
	_hasnt "okd $flag: no redhat operator" "advanced-cluster-management|multicluster-engine" "$out"
	_hasnt "okd $flag: no certified operator" "gpu-operator-certified" "$out"
	_has "okd $flag: community operators still listed" "cert-manager" "$out"
	_has "okd $flag: says why" "Red Hat account" "$(cat "$T/so.err")"
done
out=$(S --community)
_has "okd --community: community listed" "argocd-operator" "$out"
_hasnt "okd --community: no Red Hat account notice needed" "Red Hat account" "$(cat "$T/so.err")"
_eq "okd: shipped indexes are still copied to .index (populate unchanged)" "yes" "$([ -s "$R/.index/redhat-operator-index-v4.21" ] && echo yes || echo no)"
setdist ocp; rm -f "$R/.index/"*
out=$(S)
_has "ocp default: lists redhat operators" "advanced-cluster-management" "$out"
_hasnt "ocp default: no community operator" "cert-manager" "$out"
_hasnt "ocp default: no okd notice" "Red Hat account" "$(cat "$T/so.err")"
out=$(S --all)
_has "ocp --all: redhat" "advanced-cluster-management" "$out"
_has "ocp --all: certified" "gpu-operator-certified" "$out"
_has "ocp --all: community" "cert-manager" "$out"

# --refresh downloads and waits through the shared helpers: on okd only the community task exists
setdist okd; rm -f "$R/.index/"*
RO_SO="$T/runner-refresh"
( cd "$R/mirror" && RUN_ONCE_DIR="$RO_SO" bash -c "source scripts/include_all.sh 2>/dev/null; run_once -i catalog:4.21:community-operator -- true; run_once -w -q -i catalog:4.21:community-operator" ) >/dev/null 2>&1
out=$(S --refresh)
_eq "okd --refresh: rc 0 with only the community catalog task" "0" "$(rc_of "$out")"
_has "okd --refresh: completes" "Catalog refresh complete" "$(cat "$T/so.err")"
_has "okd --refresh: lists the community operators" "cert-manager" "$out"
# a failed community download is reported, not swallowed
rm -f "$R/.index/"*
RO_SO="$T/runner-refresh-fail"
( cd "$R/mirror" && RUN_ONCE_DIR="$RO_SO" bash -c "source scripts/include_all.sh 2>/dev/null; run_once -i catalog:4.21:community-operator -- false; run_once -w -q -i catalog:4.21:community-operator" ) >/dev/null 2>&1
out=$(S --refresh)
_eq "okd --refresh: failed community download -> rc 1" "1" "$(rc_of "$out")"
_has "okd --refresh: names the community catalog" "community-operator" "$(cat "$T/so.err")"
RO_SO=

echo ""
echo "=== picker in the TUI mirror file uses the distribution's catalog list ==="
tm=tui/v2/tui-mirror.sh
_eq "no hard-coded redhat index path left in the search/selection greps" "0" "$(grep -c '\.index/redhat-operator-index-v\${version_short}' "$tm")"
_has "uses dist_catalog_index_files" "dist_catalog_index_files" "$(cat "$tm")"
_has "catalog counts loop uses dist_catalogs" "in \\\$\(dist_catalogs\)" "$(cat "$tm")"

echo ""
echo "=== TUI operator pickers (dialog calls recorded; the functions are taken from tui-mirror.sh) ==="
cp "$R/catalogs/"*-index-v4.21 "$R/.index/"   # every catalog's index is on disk, as after _populate_shipped_indexes
cat > "$T/tui-harness.sh" <<'EOF'
source scripts/include_all.sh 2>/dev/null; trap - ERR
source "$TUI/tui-strings2.sh"
for f in _operator_menu _operator_search _operator_view_basket; do
	eval "$(awk -v f="$f" '$0 ~ "^" f "\\(\\)" {p=1} p {print} p && /^}/ {exit}' "$TUI/tui-mirror.sh")"
done
ui_backtitle() { :; }
_with_basket_dirty_check() { "$@"; }
_TUI_TMP=$(mktemp)
dlg() {
	echo "DLG $*" >> "$DLG_LOG"
	local a
	for a in "$@"; do
		[ "$a" = --inputbox ] && { echo "$QUERY" > "$_TUI_TMP"; return 0; }
		[ "$a" = --msgbox ] && return 0
	done
	return 1   # Back / cancel on every list
}
declare -A OP_BASKET=([cert-manager]=1 [advanced-cluster-management]=1) OP_SET_ADDED=()
$FUNC 4.21
EOF
tui() {  # tui <dist> <function> <query>   (OP_BASKET holds cert-manager and advanced-cluster-management)
	: > "$T/dlg.log"
	( cd "$R" && ABA_ROOT="$R" distribution="$1" ocp_version=4.21.0 TUI="$REPO_ROOT/tui/v2" DLG_LOG="$T/dlg.log" QUERY="$3" FUNC="$2" RUN_ONCE_DIR="$T/runner-tui" bash "$T/tui-harness.sh" ) >"$T/tui.out" 2>&1
	cat "$T/dlg.log"
}
out=$(tui okd _operator_search cert)
_has "okd search: community operator offered, labelled community" "cert-manager .*\(community\)" "$out"
out=$(tui okd _operator_search advanced)
_has "okd search: a redhat-only operator is not offered" "No operators matching" "$out"
_hasnt "okd search: no checklist for it" "--checklist" "$out"
out=$(tui okd _operator_search dual)
_has "okd search: operator in both catalogs shows the community label" "dual-operator .*\(community\)" "$out"
_hasnt "okd search: never the redhat label" "\(redhat\)" "$out"
out=$(tui okd _operator_search argo)
_has "okd search: finds the second community operator" "argocd-operator" "$out"
out=$(tui ocp _operator_search advanced)
_has "ocp search: redhat operator offered with its label" "advanced-cluster-management .*\(redhat\)" "$out"
out=$(tui ocp _operator_search cert)
_has "ocp search: searches every catalog (community operator found)" "cert-manager .*\(community\)" "$out"
out=$(tui ocp _operator_search dual)
_has "ocp search: redhat wins for an operator in both catalogs" "dual-operator .*\(redhat\)" "$out"
out=$(tui okd _operator_view_basket "")
_has "okd selection view: community operator labelled" "cert-manager .*\(community\)" "$out"
_hasnt "okd selection view: no redhat label" "\(redhat\)" "$out"
out=$(tui ocp _operator_view_basket "")
_has "ocp selection view: community label" "cert-manager .*\(community\)" "$out"
_has "ocp selection view: redhat label" "advanced-cluster-management .*\(redhat\)" "$out"
out=$(tui okd _operator_menu "")
_has "okd menu: community catalog counted" "community-operators:" "$out"
_hasnt "okd menu: no redhat catalog line" "redhat-operators:" "$out"
_hasnt "okd menu: no certified catalog line" "certified-operators:" "$out"
_has "okd menu: says why" "Red Hat account" "$out"
out=$(tui ocp _operator_menu "")
_has "ocp menu: redhat catalog counted" "redhat-operators:" "$out"
_has "ocp menu: certified catalog counted" "certified-operators:" "$out"
_hasnt "ocp menu: no okd notice" "Red Hat account" "$out"
rm -f "$R/.index/"*

echo ""
echo "Passed: $pass  Failed: $fail"
[ "$fail" -eq 0 ]
