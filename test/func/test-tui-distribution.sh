#!/bin/bash
# Test: TUI distribution choice and the OKD restrictions (stub dialog: no terminal, no network).
#   The real functions are taken from tui/v2/*.sh and run with a scripted dlg(): every dialog call
#   is logged and answered from a queue, so the wizard is walked page by page without tmux.
#   okd: asked once (only when aba.conf has no answer), channels stable|candidate, no Red Hat
#        account text, no pull secret without operators, community catalog only, no ai set, no upgrade.
#   ocp: the same calls as before (golden dump with --dump <file>, compared against the unchanged tree).
# Not covered here: the real dialog rendering and key handling (see test-tui-wizard.sh, tmux).

cd "$(dirname "$0")/../.." || exit 1
REPO_ROOT="$PWD"

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }
_eq() { if [[ "$2" == "$3" ]]; then _pass "$1"; else _fail "$1: expected [$2] got [$3]"; fi; }
_has() { if grep -qE -- "$2" <<< "$3"; then _pass "$1"; else _fail "$1: /$2/ not in [$3]"; fi; }
_hasnt() { if grep -qE -- "$2" <<< "$3"; then _fail "$1: /$2/ unexpectedly in [$3]"; else _pass "$1"; fi; }

DUMP=
[[ "${1:-}" == "--dump" ]] && DUMP="$2"

T=$(mktemp -d "${TMPDIR:-/tmp}/tui-dist.XXXXXX")
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
mkdir -p "$HOME/.aba/logs"

# Nothing may leave the box: these shims log and fail
mkdir -p "$T/shim"
for c in curl wget skopeo podman oc oc-mirror openshift-install; do
	printf '#!/bin/bash\necho "%s $*" >> "%s/net.log"\nexit 1\n' "$c" "$T" > "$T/shim/$c"
	chmod +x "$T/shim/$c"
done
: > "$T/net.log"

# A throw-away aba root: real scripts and templates, stubs for what would leave the box.
R="$T/root"
mkdir -p "$R/mirror" "$R/.index" "$R/catalogs"
cp -a --reflink=auto "$REPO_ROOT/scripts" "$R/scripts"
cp -a --reflink=auto "$REPO_ROOT/templates" "$R/templates"
for s in create-containers-auth.sh cli-download-all.sh; do
	printf '#!/bin/bash\necho "%s $*" >> "$CALLS_LOG"\nexit 0\n' "$s" > "$R/scripts/$s"
	chmod +x "$R/scripts/$s"
done
( cd "$R" && PATH=/usr/sbin:/usr/bin:/bin domain=example.com scripts/j2 templates/aba.conf.j2 > "$T/aba.conf.base" ) 2>/dev/null
[ -s "$T/aba.conf.base" ] || { echo "cannot render aba.conf"; exit 1; }

# Catalog fixtures: acm lives in the redhat catalog only, cert-manager in the community one.
printf '%s\n' 'advanced-cluster-management Advanced Cluster Management release-2.14' 'multicluster-engine Multicluster Engine stable-2.9' > "$R/.index/redhat-operator-index-v9.8"
printf '%s\n' 'cert-manager cert-manager stable' 'argocd-operator Argo CD alpha' > "$R/.index/community-operator-index-v9.8"
cp "$R/.index/"*-v9.8 "$R/catalogs/"
printf '# Name: Hub\nadvanced-cluster-management\nmulticluster-engine\n' > "$R/templates/operator-set-fxhub"
printf '# Name: Tools\n\ncert-manager   # certificates\n  argocd-operator\n' > "$R/templates/operator-set-fxtools"

OKD_LATEST="9.8.7-okd-scos.6"; OKD_PREV="9.8.6-okd-scos.3"
OCP_LATEST="7.6.5";            OCP_PREV="7.6.4"

# conf <distribution-line|-> <channel> <version> [ops]   (a "-" leaves the key out, "" leaves it empty)
conf() {
	cp "$T/aba.conf.base" "$R/aba.conf"
	local sedc=(-i)
	sedc+=(-e "s|^ocp_channel=.*|ocp_channel=$2|" -e "s|^ocp_version=.*|ocp_version=$3|" -e "s|^ops=.*|ops=${4:-}|" -e "s|^op_sets=.*|op_sets=|")
	sedc+=(-e "s|^machine_network=.*|machine_network=10.0.0.0/20|" -e "s|^next_hop_address=.*|next_hop_address=10.0.0.1|")
	sedc+=(-e "s|^dns_servers=.*|dns_servers=10.0.0.1|" -e "s|^ntp_servers=.*|ntp_servers=10.0.0.1|")
	case "$1" in
		-) sedc+=(-e '/^distribution=/d') ;;
		*) sedc+=(-e "s|^distribution=[^ \t]*|distribution=$1|") ;;
	esac
	sed "${sedc[@]}" "$R/aba.conf"
}
confval() { ( cd "$R" && source scripts/include_all.sh 2>/dev/null; fetch_value "$1" aba.conf 2>/dev/null ); }

# The harness: functions are cut out of the real TUI files; everything else is a stub.
cat > "$T/h.sh" <<'EOF'
source scripts/include_all.sh 2>/dev/null; trap - ERR
source "$TUI/tui-strings2.sh"
for f in $FUNCS; do
	for src in tui-direct.sh tui-lib.sh tui-mirror.sh tui-disco.sh; do
		body=$(awk -v f="$f" '$0 ~ "^" f "\\(\\)" {p=1} p {print} p && /^}/ {exit}' "$TUI/$src")
		[ -n "$body" ] && { eval "$body"; break; }
	done
done
ui_backtitle() { echo bt; }
tui_log() { :; }
_TUI_TMP=$(mktemp); _TUI_LOG_FILE=/dev/null
dlg() {
	echo "DLG $*" >> "$DLG_LOG"
	local ans rc=1 out=""
	if [ -s "$DLG_ANS" ]; then
		ans=$(head -1 "$DLG_ANS"); sed -i 1d "$DLG_ANS"
		rc=${ans%%|*}; out=${ans#*|}
	fi
	printf '%s' "$out" > "$_TUI_TMP"
	return "$rc"
}
show_help() { echo "HELP $*" >> "$DLG_LOG"; }
run_once() {
	echo "RUN $*" >> "$RUN_LOG"
	local id="" mode="" a prev=""
	for a in "$@"; do [ "$prev" = -i ] && id=$a; prev=$a; done
	for a in "$@"; do case "$a" in -p) mode=p ;; -o) mode=o ;; esac; done
	local d; d=$(dist_of)
	case "$mode" in
		p) [[ "$id" == "$d:"* ]] ;;
		o) [[ "$id" == "$d:"* ]] || return 0
			case "$id" in
				*latest_version_previous) echo "$VER_PREV" ;;
				*latest_version_older) ;;
				*latest_version) echo "$VER_LATEST" ;;
			esac ;;
		*) return 0 ;;
	esac
}
aba_version_fetch_channel() { echo "FETCH_CH $*" >> "$RUN_LOG"; }
aba_version_fetch_wait() { echo "FETCH_WAIT $*" >> "$RUN_LOG"; }
tui_kick_isconf_regen() { :; }
fetch_latest_version() { echo "$VER_LATEST"; }
download_all_catalogs() { echo "download_all_catalogs $*" >> "$CALLS_LOG"; }
start_all_registry_downloads() { echo "start_all_registry_downloads" >> "$CALLS_LOG"; }
_require_podman() { return 0; }
[[ " $FUNCS " == *" tui_ensure_catalogs_ready "* ]] || tui_ensure_catalogs_ready() { echo "ensure_catalogs $*" >> "$CALLS_LOG"; return 0; }
mirror_select_operators() { echo "select_operators $*" >> "$CALLS_LOG"; return 0; }
verify_release_version_exists() { return 0; }
_resolve_minor_to_patch() { echo "$VER_LATEST"; }
image_set_dynamic_resolve() { echo "AI_RESOLVE" >> "$CALLS_LOG"; printf '4.1\t0\n'; }
confirm_quit() { return 0; }
check_internet_connectivity() { return 1; }
wait_for_all_catalogs() { echo "wait_for_all_catalogs $*" >> "$CALLS_LOG"; return 0; }
_populate_shipped_indexes() { :; }
image_set_companions_needed() { echo ai; }
setsid() { echo "setsid $*" >> "$CALLS_LOG"; }
aba_prefetch_catalogs() { :; }
get_domain() { echo example.com; }
# Startup code of abatui2.sh is not a function: cut the stretch out and run it
slice() {  # slice <first-line-regex> <last-line-regex (not included)>
	eval "$(awk -v a="$1" -v b="$2" '$0 ~ a {p=1} p && $0 ~ b {exit} p {print}' "$TUI/abatui2.sh")"
}
slice_firstrun() { slice '^_TUI_FIRST_RUN=""$' '^# Background CLI tool downloads'; echo "FIRST_RUN=${_TUI_FIRST_RUN:-}"; }
slice_guide() { slice '^\t\t\t_guide_ps=' '^\t\t\tshow_help'; echo "GUIDE=$_guide_ps"; }
slice_restore() { slice '^declare -gA OP_BASKET$' '^_tick "Loading config"$'; echo "BASKET=$(echo "${!OP_BASKET[@]}" | tr ' ' '\n' | sort | tr '\n' ' ')"; }
declare -gA OP_BASKET OP_SET_ADDED
_TUI_MODE="${MODE:-DIRECT}"
[ -f "$ABA_ROOT/aba.conf" ] && source <(cd "$ABA_ROOT" && normalize-aba-conf) 2>/dev/null
source "$T/pre.sh"
"$@"
rc=$?
echo
echo "rc=$rc"
echo "PENDING_CH=${_PENDING_CH:-}"
echo "DIST_VAR=${distribution:-}"
echo "EXIT_MESSAGE=${_TUI_EXIT_MESSAGE:-}"
EOF

# run <funcs> <function-and-args...>: answers come from $ANS (one "rc|text" per dialog call)
run() {
	local funcs="$1"; shift
	: > "$T/dlg.log"; : > "$T/run.log"; : > "$T/calls.log"; printf '%s' "$ANS" > "$T/ans"; printf '%s\n' "${PRE:-:}" > "$T/pre.sh"
	( cd "$R" && timeout 60 env -i HOME="$HOME" PATH="$T/shim:/usr/sbin:/usr/bin:/bin" ABA_ROOT="$R" TUI="$REPO_ROOT/tui/v2" FUNCS="$funcs" T="$T" \
		DLG_LOG="$T/dlg.log" DLG_ANS="$T/ans" RUN_LOG="$T/run.log" CALLS_LOG="$T/calls.log" MODE="${MODE:-DIRECT}" \
		VER_LATEST="$VER_LATEST" VER_PREV="$VER_PREV" RUN_ONCE_DIR="$T/runner" bash "$T/h.sh" "$@" ) > "$T/out" 2>&1
	OUT=$(cat "$T/out"); DLG=$(cat "$T/dlg.log"); RUN=$(cat "$T/run.log"); CALLS=$(cat "$T/calls.log")
}
WIZ="direct_wizard _direct_config_complete _direct_distribution_missing _direct_distribution _direct_set_distribution _direct_channel _direct_version _direct_pull_secret _print_pull_secret_instructions _direct_save_config _direct_platform _direct_operators_step"
nth() { sed -n "${1}p" <<< "$2"; }
VER_LATEST=$OKD_LATEST; VER_PREV=$OKD_PREV; MODE=DIRECT

D=$'\n'
if [ -n "$DUMP" ]; then
	# OCP golden dump: dialogs, run_once and helper calls, aba.conf, for an ocp conf that already has the key
	: > "$DUMP"
	VER_LATEST=$OCP_LATEST; VER_PREV=$OCP_PREV
	printf '{"auths":{"x":{"auth":"eA=="}}}\n' > "$HOME/.pull-secret.json"
	dumpit() { { echo "##### $1"; echo "$OUT" | sed "s|$T|<T>|g"; echo "-- dlg"; sed "s|$T|<T>|g" "$T/dlg.log"; echo "-- run"; sed "s|$T|<T>|g" "$T/run.log"; echo "-- calls"; sed "s|$T|<T>|g" "$T/calls.log"; echo "-- aba.conf"; grep -E '^(ocp_channel|ocp_version|platform|distribution)=' "$R/aba.conf" | sed 's/[[:space:]]*#.*//'; } >> "$DUMP"; }
	GOLD_WIZ="direct_wizard _direct_config_complete _direct_distribution_missing _direct_distribution _direct_set_distribution _direct_channel _direct_version _direct_pull_secret _print_pull_secret_instructions _direct_save_config _direct_platform _direct_operators_step tui_change_version tui_ensure_catalogs_ready _tui_catalog_error_hints _operator_sets _tui_image_set_checklist"
	conf ocp stable "" ; ANS="0|f${D}0|l${D}0|${D}0|K${D}"; run "$GOLD_WIZ" direct_wizard; dumpit "wizard direct, valid pull secret"
	conf ocp stable "" ; ANS="0|f${D}0|p${D}0|${D}0|V${D}0|"; MODE=CONNO run "$GOLD_WIZ" direct_wizard; dumpit "wizard conno"
	rm -f "$HOME/.pull-secret.json"
	conf ocp stable "" ; ANS="0|${D}1|"; run "$GOLD_WIZ" direct_wizard; dumpit "wizard, no pull secret, exit"
	printf '{"auths":{"x":{"auth":"eA=="}}}\n' > "$HOME/.pull-secret.json"
	conf ocp candidate 7.6.5 ; ANS="1|"; run "$GOLD_WIZ" direct_wizard; dumpit "wizard resume"
	for ch in stable fast candidate; do conf ocp $ch ""; ANS="2|${D}0|c${D}"; run "$GOLD_WIZ" _direct_channel; dumpit "channel $ch"; done
	conf ocp stable 7.6.5; ANS="0|m${D}0|bogus${D}0|7.6.5${D}"; run "$GOLD_WIZ" _direct_version; dumpit "version manual"
	conf ocp stable 7.6.5; ANS="1|"; run "$GOLD_WIZ" _tui_catalog_error_hints; dumpit "hints"
	conf ocp stable 7.6.5; ANS="0|${D}"; run "$GOLD_WIZ" tui_change_version; dumpit "change version"
	conf ocp stable 7.6.5; ANS="1|"; MODE=CONNO run "$GOLD_WIZ" _operator_sets 9.8; dumpit "operator sets"
	conf ocp stable 7.6.5; ANS="1|"; run "$GOLD_WIZ" _tui_image_set_checklist; dumpit "image sets"
	echo "dump written: $DUMP"
	exit 0
fi


echo "=== distribution item: asked once, only when aba.conf has no answer ==="
conf - stable "" ; rm -f "$HOME/.pull-secret.json"
ANS="0|K${D}0|s${D}0|l${D}0|${D}0|K${D}"
run "$WIZ" direct_wizard
_eq "key missing: wizard runs to the end" "rc=0" "$(grep '^rc=' <<< "$OUT")"
_has "key missing: the first dialog is the Distribution item" "^DLG .*--title Distribution " "$(nth 1 "$DLG")"
_eq "choosing OKD writes distribution=okd like platform" "okd" "$(confval distribution)"
_hasnt "okd: no pull secret dialog without operators" "Pull Secret" "$DLG"
_hasnt "okd: no pull secret file is created or asked for" "pull-secret" "$DLG"
_eq "okd: no container auth work started" "0" "$(grep -c 'create-containers-auth' <<< "$CALLS")"
_eq "okd: no redhat-operator catalog started" "0" "$(grep -c 'redhat-operator' <<< "$RUN$CALLS")"
_eq "okd: channel dialog is the second dialog" "1" "$(nth 2 "$DLG" | grep -c -- '--title OpenShift Channel')"
_has "okd: channel menu offers stable" '"s" stable|\bs stable' "$(nth 2 "$DLG")"
_has "okd: channel menu offers candidate" '\bc candidate' "$(nth 2 "$DLG")"
_hasnt "okd: channel menu does not offer fast" '\bf fast|fast  ' "$(nth 2 "$DLG")"
_eq "okd: channel is saved" "stable" "$(confval ocp_channel)"
_eq "okd: version comes from the okd tips" "$OKD_LATEST" "$(confval ocp_version)"
_has "okd: version ids carry the distribution" "okd:stable:latest_version" "$RUN"
_eq "okd: no ocp-prefixed run_once id" "0" "$(grep -c -- '-i ocp:' <<< "$RUN")"
_eq "okd: platform is saved" "kvm" "$(confval platform)"
_hasnt "okd: after the Distribution page no dialog mentions a pull secret, console.redhat.com or registry.redhat.io" "console\.redhat\.com|[Pp]ull [Ss]ecret|registry\.redhat\.io" "$(tail -n +2 <<< "$DLG")"

# Empty key (what a first run leaves) is the same as a missing one.
conf "" stable "" ; ANS="0|O${D}0|s${D}0|l${D}0|${D}0|M${D}"; : > "$HOME/.pull-secret.json"; echo '{"auths":{"x":{"auth":"eA=="}}}' > "$HOME/.pull-secret.json"
VER_LATEST=$OCP_LATEST; VER_PREV=$OCP_PREV
run "$WIZ" direct_wizard
_has "empty key: Distribution is asked" "^DLG .*--title Distribution " "$(nth 1 "$DLG")"
_eq "choosing OpenShift writes distribution=ocp" "ocp" "$(confval distribution)"
_has "ocp: channel menu still offers fast" '\bf fast' "$DLG"
_has "ocp: version ids keep the ocp prefix" "-i ocp:stable:latest_version" "$RUN"

# Key present: never asked.
for d in ocp okd; do
	conf $d stable "" ; ANS=""
	[ $d = okd ] && { VER_LATEST=$OKD_LATEST; VER_PREV=$OKD_PREV; } || { VER_LATEST=$OCP_LATEST; VER_PREV=$OCP_PREV; }
	run "$WIZ" direct_wizard
	_eq "distribution=$d present: Distribution is not asked" "0" "$(grep -c -- '--title Distribution ' <<< "$DLG")"
done

# Cancel on the first page leaves the key alone and ends the wizard.
conf - stable "" ; ANS="1|"
run "$WIZ" direct_wizard
_eq "cancel at Distribution: wizard returns 1" "rc=1" "$(grep '^rc=' <<< "$OUT")"
_eq "cancel at Distribution: nothing written" "" "$(confval distribution)"

# Help keeps the page.
conf - stable "" ; ANS="2|${D}1|"
run "$WIZ" direct_wizard
_eq "help on Distribution: page shown again" "2" "$(grep -c -- '--title Distribution ' <<< "$DLG")"

# Back from the channel page returns to the Distribution page when it was asked in this run.
conf - stable "" ; VER_LATEST=$OKD_LATEST; VER_PREV=$OKD_PREV
ANS="0|K${D}3|${D}0|O${D}1|"
run "$WIZ" direct_wizard
_eq "back from Channel: Distribution is shown again" "2" "$(grep -c -- '--title Distribution ' <<< "$DLG")"
_eq "back and OpenShift: key now ocp" "ocp" "$(confval distribution)"

# The OCP version that a first run wrote is not kept for OKD.
conf - stable 7.6.5 ; ANS="0|K${D}1|"
run "$WIZ" direct_wizard
_eq "choosing OKD drops an OCP-only version" "" "$(confval ocp_version)"
_eq "choosing OKD keeps a valid channel" "stable" "$(confval ocp_channel)"
_eq "no Resume dialog for the dropped version" "0" "$(grep -c 'Resume Configuration' <<< "$DLG")"

echo ""
echo "=== config complete: asked again only while the key is missing ==="
printf '{"auths":{"x":{"auth":"eA=="}}}\n' > "$HOME/.pull-secret.json"
chk() { run "$WIZ" _direct_config_complete; grep '^rc=' <<< "$OUT"; }
conf - stable 7.6.5;                 _eq "ocp conf without the key is not complete" "rc=1" "$(chk)"
conf ocp stable 7.6.5;               _eq "ocp conf with the key and a pull secret is complete" "rc=0" "$(chk)"
conf okd stable "$OKD_LATEST";       _eq "okd conf with the key is complete" "rc=0" "$(chk)"
rm -f "$HOME/.pull-secret.json"
conf ocp stable 7.6.5;               _eq "ocp: pull secret file is still required" "rc=1" "$(chk)"
conf okd stable "$OKD_LATEST";       _eq "okd without operators needs no pull secret file" "rc=0" "$(chk)"
conf okd stable "$OKD_LATEST" cert-manager; _eq "okd with operators needs the pull secret file" "rc=1" "$(chk)"

echo ""
echo "=== channel page ==="
for ch in stable fast candidate; do
	conf ocp $ch "" ; ANS="0|s${D}"; run "$WIZ" _direct_channel
	_eq "ocp channel page with $ch: three entries" "3" "$(grep -o -- '--menu .* 0 0 [0-9]' <<< "$DLG" | awk '{print $NF}')"
done
conf okd fast "" ; ANS="0|c${D}"; run "$WIZ" _direct_channel
_eq "okd channel page: two entries" "2" "$(grep -o -- '--menu .* 0 0 [0-9]' <<< "$DLG" | awk '{print $NF}')"
_has "okd channel page with a stale fast: default is stable" "--default-item s " "$DLG"
ANS="0|c${D}"; run "$WIZ" _direct_channel
_eq "okd candidate can be chosen" "PENDING_CH=candidate" "$(grep '^PENDING_CH=' <<< "$OUT")"
conf okd stable "" ; ANS="2|"; run "$WIZ" _direct_channel
HELPTXT=$(awk '/^HELP/ {p=1} p' <<< "$DLG")
_hasnt "okd channel help does not describe fast" "fast" "$HELPTXT"
_has "okd channel help describes candidate" "candidate" "$HELPTXT"

echo ""
echo "=== version page ==="
conf okd stable "" ; VER_LATEST=$OKD_LATEST; VER_PREV=$OKD_PREV; ANS="0|l${D}"; run "$WIZ" _direct_version
_has "okd version menu: latest from the okd tip" "Latest +\($OKD_LATEST\)" "$DLG"
_has "okd version menu: previous from the okd tip" "Previous +\($OKD_PREV\)" "$DLG"
conf okd stable "" ; ANS="0|m${D}0|9.8${D}0|${D}"; run "$WIZ" _direct_version
_has "okd manual entry names the okd format" "x\.y or x\.y\.z-okd-scos\.N" "$DLG"
conf okd stable "" ; ANS="0|m${D}0|bogus${D}0|9.8.7-okd-scos.6${D}"; run "$WIZ" _direct_version
_has "okd invalid format: message names the okd format" "Expected: x\.y or x\.y\.z-okd-scos\.N" "$DLG"
_hasnt "okd invalid format: no OCP example" "rc\.1" "$(grep -- '--msgbox' <<< "$DLG")"
conf ocp stable "" ; VER_LATEST=$OCP_LATEST; VER_PREV=$OCP_PREV; ANS="0|m${D}0|bogus${D}0|7.6.5${D}"; run "$WIZ" _direct_version
_has "ocp invalid format: unchanged message" "Expected: x\.y, x\.y\.z, or x\.y\.z-rc\.N" "$DLG"

echo ""
echo "=== pull secret text ==="
conf okd stable "$OKD_LATEST" cert-manager; rm -f "$HOME/.pull-secret.json"; ANS="0|${D}"; run "$WIZ" _direct_pull_secret
_hasnt "okd with operators: no console.redhat.com" "console\.redhat\.com" "$DLG"
_hasnt "okd with operators: no Red Hat account title" "Red Hat Pull Secret" "$DLG"
_has "okd with operators: says what the secret is for" "operator" "$DLG"
ANS="1|"; run "$WIZ" _direct_pull_secret
_hasnt "okd exit message: no console.redhat.com" "console\.redhat\.com" "$OUT"
_has "okd exit message: names the file" "pull-secret" "$OUT"
conf ocp stable 7.6.5; ANS="0|${D}1|"; run "$WIZ" _direct_pull_secret
_has "ocp: info dialog still points to console.redhat.com" "console\.redhat\.com" "$DLG"
_has "ocp: title is still Red Hat Pull Secret" "Red Hat Pull Secret" "$DLG"
ANS="1|"; run "$WIZ" _direct_pull_secret
_has "ocp: exit message still points to console.redhat.com" "console\.redhat\.com/openshift/downloads" "$OUT"

echo ""
echo "=== wizard with operators on okd: pull secret asked in OKD words, redhat catalog not started ==="
rm -f "$HOME/.pull-secret.json"; printf '{"auths":{"x":{"auth":"eA=="}}}\n' > "$T/ps.json"
conf okd stable "" cert-manager; VER_LATEST=$OKD_LATEST; VER_PREV=$OKD_PREV
ANS="0|${D}0|$T/ps.json${D}0|s${D}0|l${D}0|${D}0|M${D}"
run "$WIZ" direct_wizard
_eq "okd with operators: wizard completes" "rc=0" "$(grep '^rc=' <<< "$OUT")"
_has "okd with operators: the pull secret page is shown" "^DLG .*--title Pull Secret " "$DLG"
_hasnt "okd with operators: not titled Red Hat" "Red Hat" "$DLG"
_hasnt "okd with operators: no console.redhat.com" "console\.redhat\.com" "$DLG"
_has "okd with operators: container auth is prepared from the given secret" "create-containers-auth" "$CALLS"
_hasnt "okd with operators: no redhat-operator catalog task" "redhat-operator" "$RUN$CALLS"

echo ""
echo "=== catalog lists follow the distribution ==="
for d in okd ocp; do
	conf $d stable "" ; [ $d = okd ] && { VER_LATEST=$OKD_LATEST; VER_PREV=$OKD_PREV; ver=$OKD_LATEST; } || { VER_LATEST=$OCP_LATEST; VER_PREV=$OCP_PREV; ver=$OCP_LATEST; }
	printf '{"auths":{"x":{"auth":"eA=="}}}\n' > "$HOME/.pull-secret.json"
	ANS="0|s${D}0|l${D}0|${D}0|M${D}"; MODE=CONNO run "$WIZ" direct_wizard
	if [ $d = okd ]; then
		_eq "okd CONNO wizard: reset ids are the community catalog only" "1" "$(grep -c -- '-r -i catalog:.*:' <<< "$RUN")"
		_has "okd CONNO wizard: community catalog id" "-r -i catalog:9\.8:community-operator" "$RUN"
		_hasnt "okd CONNO wizard: no redhat/certified id" "redhat-operator|certified-operator" "$RUN"
	else
		_eq "ocp CONNO wizard: reset ids are the three catalogs" "3" "$(grep -c -- '-r -i catalog:7.6:' <<< "$RUN")"
	fi
done
MODE=DIRECT
rm -f "$HOME/.pull-secret.json"
echo ""
echo "=== static: no hard-coded ocp run_once ids or Red Hat sites left in the okd paths of the wizard ==="
_eq "no literal ocp: run_once id left in tui-direct.sh" "0" "$(grep -c '"ocp:' "$REPO_ROOT/tui/v2/tui-direct.sh")"
_eq "no hard-coded three-catalog loop left in tui-direct.sh" "0" "$(grep -c 'for _cat in redhat-operator certified-operator community-operator' "$REPO_ROOT/tui/v2/tui-direct.sh")"
_eq "no hard-coded three-catalog loop left in tui-lib.sh" "0" "$(grep -c 'for _cat in redhat-operator certified-operator community-operator' "$REPO_ROOT/tui/v2/tui-lib.sh")"


echo ""
echo "=== more of the wizard: back, defaults, stale values ==="
# Back from the channel page returns to the pull secret page when that one was shown (Distribution is not asked again)
rm -f "$HOME/.pull-secret.json"
conf - stable "" ; VER_LATEST=$OCP_LATEST; VER_PREV=$OCP_PREV
ANS="0|O${D}0|${D}0|$T/ps.json${D}3|${D}1|"
run "$WIZ" direct_wizard
_eq "back from Channel after the pull secret page: Distribution asked once" "1" "$(grep -c -- '--title Distribution ' <<< "$DLG")"
_eq "back from Channel after the pull secret page: the page, already answered, is not shown again" "1" "$(grep -c -- '--yesno A Red Hat pull secret is required' <<< "$DLG")"
_eq "back from Channel after the pull secret page: Channel shown twice" "2" "$(grep -c -- '--title OpenShift Channel ' <<< "$DLG")"
# Back from Channel to Distribution, then OpenShift without a pull secret file: that page is asked
conf - stable "" ; VER_LATEST=$OKD_LATEST; VER_PREV=$OKD_PREV
ANS="0|K${D}3|${D}0|O${D}1|"
run "$WIZ" direct_wizard
_has "back from Channel and OpenShift: the pull secret page is asked" "A Red Hat pull secret is required" "$DLG"
_has "second Distribution page starts on the earlier choice" "--title Distribution --default-item K " "$DLG"
# A channel of OpenShift only is not kept for OKD
conf - fast "" ; ANS="0|K${D}1|"
run "$WIZ" direct_wizard
_eq "choosing OKD drops a channel it does not publish" "" "$(confval ocp_channel)"
# No version tip: manual entry on the first page of the version step
conf okd stable "" ; VER_LATEST=""; ANS="0|bogus${D}0|${D}"
run "$WIZ" _direct_version
_has "okd without tips: manual entry names the okd format" "Enter OpenShift version \(x\.y or x\.y\.z-okd-scos\.N\)" "$DLG"
_has "okd without tips: invalid format names the okd format" "Expected: x\.y or x\.y\.z-okd-scos\.N" "$DLG"
VER_LATEST=$OKD_LATEST
# The channel page follows the helper, whatever the distribution offers
conf ocp stable "" ; ANS="1|"
PRE='dist_channel_is_valid() { [[ "$1" == stable ]]; }' run "$WIZ" _direct_channel
_eq "channel page follows dist_channel_is_valid (stable only)" "1" "$(grep -o -- '--menu .* 0 0 [0-9]' <<< "$DLG" | awk '{print $NF}')"

echo ""
echo "=== config file written by the wizard ==="
rm -f "$R/aba.conf"
VER_LATEST=$OKD_LATEST; VER_PREV=$OKD_PREV; ANS=""
PRE='distribution=okd; export distribution; ocp_channel=stable; ocp_version=9.8.7-okd-scos.6; platform=kvm' run "$WIZ" _direct_save_config
_eq "a new aba.conf made by the wizard carries the choice already made" "okd" "$(confval distribution)"
_eq "...and the platform" "kvm" "$(confval platform)"

echo ""
echo "=== catalogs: change of version, retry, and the wait for indexes ==="
conf okd stable "$OKD_LATEST" ; VER_LATEST=$OKD_LATEST; VER_PREV=$OKD_PREV
ANS="0|s${D}0|l${D}0|${D}"
run "$WIZ tui_change_version" tui_change_version
_has "okd change of version: community catalog task reset" "-r -i catalog:9\.8:community-operator" "$RUN"
_hasnt "okd change of version: no other catalog task" "redhat-operator|certified-operator" "$RUN"
conf ocp stable 7.6.5 ; VER_LATEST=$OCP_LATEST; VER_PREV=$OCP_PREV
ANS="0|s${D}0|l${D}0|${D}"
run "$WIZ tui_change_version" tui_change_version
_eq "ocp change of version: three catalog tasks reset" "3" "$(grep -c -- '-r -i catalog:7.6:' <<< "$RUN")"
# operator step: catalogs failed, user retries
for d in okd ocp; do
	conf $d stable "$([ $d = okd ] && echo "$OKD_LATEST" || echo 7.6.5)"
	ANS="0|${D}0|${D}"
	MODE=CONNO PRE='tui_ensure_catalogs_ready() { CATALOG_ERROR=boom; return 1; }' run "$WIZ _tui_catalog_error_hints" _direct_operators_step 9.8
	if [ $d = okd ]; then
		_has "okd operator step retry: community catalog task reset" "-r -i catalog:9\.8:community-operator" "$RUN"
		_hasnt "okd operator step retry: no redhat/certified task" "redhat-operator|certified-operator" "$RUN"
		_hasnt "okd operator step failure page: no registry.redhat.io or pull secret hint" "registry\.redhat\.io|[Pp]ull secret" "$DLG"
	else
		_eq "ocp operator step retry: three catalog tasks reset" "3" "$(grep -c -- '-r -i catalog:9.8:' <<< "$RUN")"
		_has "ocp operator step failure page: registry.redhat.io hint" "registry\.redhat\.io" "$DLG"
	fi
done
MODE=DIRECT
# Waiting for indexes: a shipped redhat index is no use on OKD
rm -f "$R/.index/"*
cp "$R/catalogs/redhat-operator-index-v9.8" "$R/.index/"
conf okd stable "$OKD_LATEST"; ANS=""
run "tui_ensure_catalogs_ready" tui_ensure_catalogs_ready 9.8
_has "okd with a redhat index only: waits for the community catalog" "wait_for_all_catalogs 9\.8" "$CALLS"
_has "okd with a redhat index only: infobox shown" "Downloading operator catalog indexes" "$DLG"
conf ocp stable "7.6.5"
run "tui_ensure_catalogs_ready" tui_ensure_catalogs_ready 9.8
_hasnt "ocp with a redhat index: proceeds at once" "wait_for_all_catalogs" "$CALLS"
cp "$R/catalogs/community-operator-index-v9.8" "$R/.index/"
conf okd stable "$OKD_LATEST"
run "tui_ensure_catalogs_ready" tui_ensure_catalogs_ready 9.8
_hasnt "okd with the community index: proceeds at once" "wait_for_all_catalogs" "$CALLS"
cp "$R/catalogs/redhat-operator-index-v9.8" "$R/.index/"

echo ""
echo "=== operators on okd: a reminder at the end of the section when no real pull secret is configured ==="
# _operator_menu is walked with its helpers stubbed; answer 3 = Done. The reminder text comes from dist_pull_secret_problem.
OPSTUB='_persist_operator_basket() { :; }; _with_basket_dirty_check() { "$@"; }; _tui_offer_companion_images() { :; }; _OP_BASKET_DIRTY=false'
OPFUNCS="_operator_menu _tui_okd_pull_secret_reminder"
opdone() {   # <dist> <ops> <pull-secret-state: none|placeholder|real|invalid>
	conf "$1" stable "$([ "$1" = okd ] && echo "$OKD_LATEST" || echo 7.6.5)" "$2"; rm -f "$HOME/.pull-secret.json"
	case "$3" in
		placeholder) printf '{"auths":{"fake":{"auth":"aWQ6cGFzcwo="}}}\n' > "$HOME/.pull-secret.json" ;;
		real) printf '{"auths":{"registry.example.com":{"auth":"eDp5Cg=="}}}\n' > "$HOME/.pull-secret.json" ;;
		invalid) printf 'not json\n' > "$HOME/.pull-secret.json" ;;
	esac
	ANS="3|${D}"
	PRE="$OPSTUB; OP_BASKET[${2:-x}]=1" run "$OPFUNCS" _operator_menu 9.8
}
opdone okd cert-manager none
_eq "okd, operators, no pull secret file: Done ends the section" "rc=0" "$(grep '^rc=' <<< "$OUT")"
_eq "okd, operators, no pull secret file: one reminder message box" "1" "$(grep -c -- '--msgbox' <<< "$DLG")"
_has "okd, operators, no pull secret file: it says the secret is missing for operators" "Reminder: No pull secret found at .* operators" "$(grep -- '--msgbox' <<< "$DLG")"
_eq "okd, operators, no pull secret file: the reminder is the last dialog" "1" "$(tail -n 1 <<< "$DLG" | grep -c -- '--msgbox')"
opdone okd cert-manager placeholder
_has "okd, operators, placeholder secret: reminder says the placeholder is not enough" "Reminder: Pull secret at .* is the OKD placeholder, but operators" "$(grep -- '--msgbox' <<< "$DLG")"
opdone okd cert-manager invalid
_has "okd, operators, unusable secret: reminder names the problem" "Reminder: Pull secret at .* has invalid JSON" "$(grep -- '--msgbox' <<< "$DLG")"
opdone okd cert-manager real
_eq "okd, operators, real pull secret: no reminder" "0" "$(grep -c -- '--msgbox' <<< "$DLG")"
_eq "okd, operators, real pull secret: Done still ends the section" "rc=0" "$(grep '^rc=' <<< "$OUT")"
conf okd stable "$OKD_LATEST" ""; rm -f "$HOME/.pull-secret.json"; ANS="3|${D}0|${D}"
PRE='_persist_operator_basket() { :; }; _with_basket_dirty_check() { "$@"; }; _tui_offer_companion_images() { :; }; _OP_BASKET_DIRTY=false' run "$OPFUNCS" _operator_menu 9.8
_eq "okd, no operators selected, no pull secret: no reminder" "0" "$(grep -c -- '--msgbox' <<< "$DLG")"
opdone ocp cert-manager none
_eq "ocp, operators, no pull secret: no reminder (unchanged)" "0" "$(grep -c -- '--msgbox' <<< "$DLG")"
_eq "ocp: Done ends the section as before" "rc=0" "$(grep '^rc=' <<< "$OUT")"
rm -f "$HOME/.pull-secret.json"

echo ""
echo "=== startup code of abatui2.sh ==="
rm -f "$R/aba.conf" "$HOME/.pull-secret.json"
ANS=""; VER_LATEST=$OCP_LATEST
run "" slice_firstrun
_has "first run: aba.conf is created" "FIRST_RUN=1" "$OUT"
_eq "first run: the distribution is left unanswered" "" "$(confval distribution)"
_eq "first run: ...but the key is there to be answered" "yes" "$(grep -q '^distribution=' "$R/aba.conf" && echo yes)"
_eq "first run: openshift defaults as before" "$OCP_LATEST" "$(confval ocp_version)"
_eq "first run: no prefetch without a pull secret (distribution not chosen yet)" "0" "$(grep -c setsid <<< "$CALLS")"
conf okd stable "$OKD_LATEST"
run "" slice_firstrun
_has "okd conf, no pull secret file, no operators: catalog prefetch starts" "setsid" "$CALLS"
conf okd stable "$OKD_LATEST" cert-manager
run "" slice_firstrun
_eq "okd conf with operators and no pull secret file: no prefetch" "0" "$(grep -c setsid <<< "$CALLS")"
conf ocp stable 7.6.5
run "" slice_firstrun
_eq "ocp conf, no pull secret file: no prefetch" "0" "$(grep -c setsid <<< "$CALLS")"
printf '{"auths":{"x":{"auth":"eA=="}}}\n' > "$HOME/.pull-secret.json"
run "" slice_firstrun
_has "ocp conf with a pull secret file: prefetch starts" "setsid" "$CALLS"
rm -f "$HOME/.pull-secret.json"
# operators restored from aba.conf are looked up in the catalogs the distribution offers
conf okd stable "$OKD_LATEST" "cert-manager,advanced-cluster-management"
run "" slice_restore
_eq "okd: only the community operator is restored into the selection" "BASKET=cert-manager" "$(grep '^BASKET=' <<< "$OUT" | sed 's/ $//')"
conf ocp stable 9.8.1 "cert-manager,advanced-cluster-management"
run "" slice_restore
_eq "ocp: both operators are restored" "BASKET=advanced-cluster-management cert-manager" "$(grep '^BASKET=' <<< "$OUT" | sed 's/ $//')"

echo ""
echo "=== other texts ==="
conf okd stable "$OKD_LATEST"; ANS="0|"
run "disco_reset" disco_reset CONNO
_has "disco switch with no internet, okd: names the okd sites" "github\.com" "$DLG"
_hasnt "disco switch with no internet, okd: no registry.redhat.io" "registry\.redhat\.io" "$DLG"
conf ocp stable 7.6.5; ANS="0|"
run "disco_reset" disco_reset CONNO
_has "disco switch with no internet, ocp: text unchanged" "Connected mode requires access to registry\.redhat\.io.nand other Red Hat sites\." "$DLG"
for d in okd ocp; do
	conf $d stable "$([ $d = okd ] && echo "$OKD_LATEST" || echo 7.6.5)"; ANS="2|${D}0|A${D}1|${D}1|"
	run "mirror_manage_images _read_images_conf" mirror_manage_images
	if [ $d = okd ]; then
		_has "okd additional images: help example is the anonymous host" "e\.g\. registry\.access\.redhat\.com/ubi9/ubi:latest" "$DLG"
		_hasnt "okd additional images: no registry.redhat.io example" "registry\.redhat\.io/ubi9" "$DLG"
		_has "okd additional images: input example is the anonymous host" "inputbox Enter container image reference.*registry\.access\.redhat\.com/ubi9" "$DLG"
	else
		_has "ocp additional images: help example unchanged" "e\.g\. registry\.redhat\.io/ubi9/ubi:latest" "$DLG"
		_has "ocp additional images: input example unchanged" "inputbox Enter container image reference:.n.n\(e\.g\. registry\.redhat\.io/ubi9/ubi:latest\)" "$DLG"
	fi
done
# companion images: the AI set is not one on OKD
for d in okd ocp; do
	conf $d stable "$([ $d = okd ] && echo "$OKD_LATEST" || echo 7.6.5)"; ANS="1|"
	MODE=CONNO PRE='OP_SET_ADDED[fxtools]=1' run "_tui_offer_companion_images" _tui_offer_companion_images ""
	if [ $d = okd ]; then
		_eq "okd companion images: ai is not resolved" "0" "$(grep -c AI_RESOLVE <<< "$CALLS")"
		_eq "okd companion images: nothing offered" "0" "$(grep -c '^DLG' <<< "$DLG")"
	else
		_has "ocp companion images: ai is resolved as before" "AI_RESOLVE" "$CALLS"
	fi
done
MODE=DIRECT


echo ""
echo "=== the unanswered test, page heights, and what a cancel or Back does ==="
# missing = no variable AND no key: one answer is enough
conf - stable "" ; PRE='unset distribution' run "_direct_distribution_missing" _direct_distribution_missing
_eq "no variable, no key: unanswered" "rc=0" "$(grep '^rc=' <<< "$OUT")"
conf - stable "" ; PRE='distribution=okd' run "_direct_distribution_missing" _direct_distribution_missing
_eq "variable set, no key: answered" "rc=1" "$(grep '^rc=' <<< "$OUT")"
conf ocp stable "" ; PRE='unset distribution' run "_direct_distribution_missing" _direct_distribution_missing
_eq "key set, no variable: answered" "rc=1" "$(grep '^rc=' <<< "$OUT")"
conf "" stable "" ; PRE='unset distribution' run "_direct_distribution_missing" _direct_distribution_missing
_eq "empty key, no variable: unanswered" "rc=0" "$(grep '^rc=' <<< "$OUT")"
# cancel on the first page ends the wizard at once
conf - stable "" ; ANS="1|"
run "$WIZ" direct_wizard
_eq "cancel at Distribution: that was the only dialog" "1" "$(grep -c '^DLG' <<< "$DLG")"
# Back to Distribution and cancel there ends the wizard
conf - stable "" ; VER_LATEST=$OKD_LATEST; VER_PREV=$OKD_PREV; ANS="0|K${D}3|${D}1|"
run "$WIZ" direct_wizard
_eq "cancel at Distribution after Back: wizard returns 1" "rc=1" "$(grep '^rc=' <<< "$OUT")"
_eq "cancel at Distribution after Back: Channel was shown once only" "1" "$(grep -c -- '--title OpenShift Channel ' <<< "$DLG")"
# Back to Distribution, OpenShift, pull secret page answered: Back from Channel returns to the pull secret page (shown once more only if it needs an answer)
rm -f "$HOME/.pull-secret.json"
conf - stable "" ; VER_LATEST=$OCP_LATEST; VER_PREV=$OCP_PREV
ANS="0|K${D}3|${D}0|O${D}0|${D}0|$T/ps.json${D}3|${D}1|"
run "$WIZ" direct_wizard
_eq "Back from Channel after a Back to Distribution: Distribution shown twice, not three times" "2" "$(grep -c -- '--title Distribution ' <<< "$DLG")"
_eq "Distribution page: two entries" "2" "$(grep -m1 -o -- '--title Distribution .* --menu .* 0 0 [0-9]' <<< "$DLG" | awk '{print $NF}')"
# the choice is visible to child processes at once, even before aba.conf exists
rm -f "$R/aba.conf"
PRE='probe() { _direct_set_distribution okd; bash -c "source scripts/include_all.sh 2>/dev/null; dist_of"; }' run "_direct_set_distribution" probe
_has "choice is exported to child processes" "^okd$" "$OUT"
# the shell variable drops a channel OKD does not publish, as aba.conf does
conf ocp fast ""
PRE='probe() { ocp_channel=fast; ocp_version=7.6.5; _direct_set_distribution okd; echo "CH=[${ocp_channel}] VER=[${ocp_version}]"; }' run "_direct_set_distribution" probe
_has "stale channel and version are dropped in the shell too" "CH=\[\] VER=\[\]" "$OUT"
# the exit message of a missing pull secret ends with a newline, like the OpenShift one
conf okd stable "$OKD_LATEST" cert-manager
PRE='probe() { _print_pull_secret_instructions /x/ps.json; printf "%s" "$_TUI_EXIT_MESSAGE" | tail -c 1 | od -An -c; }' run "_print_pull_secret_instructions" probe
_has "okd exit message ends with a newline" '\\n' "$OUT"
_has "okd exit message names the file" "/x/ps\.json" "$(cd "$R"; PRE='probe() { _print_pull_secret_instructions /x/ps.json; printf "%s" "$_TUI_EXIT_MESSAGE"; }' run "_print_pull_secret_instructions" probe; echo "$OUT")"
# quick guide line
conf okd stable "$OKD_LATEST"; run "" slice_guide
_has "okd quick guide: pull secret only for operator content" "GUIDE=Only for operator content" "$OUT"
conf ocp stable 7.6.5; run "" slice_guide
_has "ocp quick guide: Red Hat registry credentials as before" "GUIDE=Red Hat registry credentials" "$OUT"

# An aba.conf left with the distribution unanswered is an OpenShift one for every other tool
conf "" stable 7.6.5
PRE='probe() { source <(normalize-aba-conf); verify-aba-conf; echo "verify=$? dist=$(dist_of)"; }' run "_direct_distribution_missing" probe
_has "empty distribution key: verify-aba-conf accepts it and dist_of says ocp" "verify=0 dist=ocp" "$OUT"

echo ""
echo "=== static texts: sites, hints, startup ==="
SITES_OCP='Required sites:                    Other sites:\n  mirror.openshift.com               docker.io\n  api.openshift.com                  docker.com\n  registry.redhat.io                 hub.docker.com\n  quay.io and *.quay.io              index.docker.io\n  console.redhat.com\n  registry.access.redhat.com'
conf ocp stable 7.6.5
run "_tui_required_sites_text" _tui_required_sites_text
_eq "ocp: required sites text is the text it always was" "$SITES_OCP" "$(grep -v '^rc=\|^EXIT_MESSAGE=\|^PENDING_CH=\|^DIST_VAR=' <<< "$OUT")"
conf okd stable "$OKD_LATEST"
run "_tui_required_sites_text" _tui_required_sites_text
_has "okd: sites list github.com" "github\.com" "$OUT"
_has "okd: sites list quay.io" "quay\.io" "$OUT"
_has "okd: sites list updates.okd.io" "updates\.okd\.io" "$OUT"
_has "okd: sites list mirror.openshift.com" "mirror\.openshift\.com" "$OUT"
_has "okd: sites list the anonymous catalog host, for operators only" "registry\.access\.redhat\.com \(operators only\)" "$OUT"
_hasnt "okd: no Red Hat account sites" "registry\.redhat\.io|console\.redhat\.com|api\.openshift\.com" "$(grep -v '^rc=\|^EXIT_MESSAGE=\|^PENDING_CH=\|^DIST_VAR=' <<< "$OUT")"

HINT_OCP='To fix, check:\n  - Internet connectivity (can you reach registry.redhat.io?)\n  - Pull secret is valid and not expired\n  - Podman rootless setup (/etc/subuid, /etc/subgid)\n  - Sufficient disk space for container storage\n  - DNS resolution is working\n\nAfter fixing, retry the same action.'
conf ocp stable 7.6.5
run "_tui_catalog_error_hints" _tui_catalog_error_hints
_eq "ocp: catalog error hints unchanged" "$HINT_OCP" "$(grep -v '^rc=\|^EXIT_MESSAGE=\|^PENDING_CH=\|^DIST_VAR=' <<< "$OUT")"
conf okd stable "$OKD_LATEST"
run "_tui_catalog_error_hints" _tui_catalog_error_hints
_hasnt "okd: catalog error hints do not name registry.redhat.io or a pull secret" "registry\.redhat\.io|[Pp]ull secret" "$(grep -v '^rc=\|^EXIT_MESSAGE=\|^PENDING_CH=\|^DIST_VAR=' <<< "$OUT")"
_has "okd: catalog error hints name the anonymous host" "registry\.access\.redhat\.com" "$OUT"

# Startup: the catalog prefetch no longer needs ~/.pull-secret.json on okd without operators.
cp "$REPO_ROOT/scripts/prefetch-catalogs.sh" "$R/scripts/prefetch-catalogs.sh"
printf '#!/bin/bash\necho "create-containers-auth" >> "$CALLS_LOG"\nexit 1\n' > "$R/scripts/create-containers-auth.sh"; chmod +x "$R/scripts/create-containers-auth.sh"
pf() { : > "$T/calls.log"; ( cd "$R" && timeout 60 env -i HOME="$HOME" PATH="$T/shim:/usr/sbin:/usr/bin:/bin" CALLS_LOG="$T/calls.log" bash scripts/prefetch-catalogs.sh >/dev/null 2>&1 ); cat "$T/calls.log"; }
rm -f "$HOME/.pull-secret.json"
conf ocp stable 7.6.5;                       _eq "prefetch ocp without pull secret: stops before container auth" "" "$(pf)"
conf okd stable "$OKD_LATEST";               _eq "prefetch okd without operators and without pull secret: goes on" "create-containers-auth" "$(pf)"
conf okd stable "$OKD_LATEST" cert-manager;  _eq "prefetch okd with operators and without pull secret: stops" "" "$(pf)"
printf '#!/bin/bash\necho "%s $*" >> "$CALLS_LOG"\nexit 0\n' create-containers-auth.sh > "$R/scripts/create-containers-auth.sh"

# abatui2.sh startup code (not a function): the gate and the first-run key are checked in the source.
au="$REPO_ROOT/tui/v2/abatui2.sh"
_has "startup prefetch gate asks dist_pull_secret_required" 'dist_pull_secret_required' "$(grep -n '_ps_path' "$au"; grep -n 'dist_pull_secret_required' "$au")"
_has "startup: first-run aba.conf leaves the distribution unanswered" 'replace-value-conf -q -n distribution -v "" ' "$(cat "$au")"
_has "startup: required sites come from the helper" '_tui_required_sites_text' "$(cat "$au")"
_hasnt "startup: no literal console.redhat.com in the sites message" 'console\.redhat\.com' "$(grep -n 'Required sites' "$au")"

echo ""
echo "=== operator sets and image sets ==="
for d in okd ocp; do
	conf $d stable "$([ $d = okd ] && echo "$OKD_LATEST" || echo 7.6.5)"; MODE=CONNO; ANS="1|"
	run "_operator_sets" _operator_sets 9.8
	if [ $d = okd ]; then
		_has "okd operator sets: a community-only set is offered" "fxtools" "$DLG"
		_hasnt "okd operator sets: a set that needs a Red Hat account is not offered" "fxhub" "$DLG"
		_has "okd operator sets: says why" "Red Hat account" "$DLG"
		mv "$R/templates/operator-set-fxtools" "$T/fxtools.keep"
		run "_operator_sets" _operator_sets 9.8
		_has "okd operator sets: when none fits, a message says so" "No operator set fits the catalog OKD offers" "$DLG"
		_hasnt "okd operator sets: ...and no empty checklist" "--checklist" "$DLG"
		mv "$T/fxtools.keep" "$R/templates/operator-set-fxtools"
	else
		_has "ocp operator sets: community set offered" "fxtools" "$DLG"
		_has "ocp operator sets: redhat set offered" "fxhub" "$DLG"
		_hasnt "ocp operator sets: no okd notice" "Red Hat account" "$DLG"
	fi
done
MODE=DIRECT

# ai: image-sets.sh blocks it on okd; the wizard page must not even resolve it
printf '%s\n' 'registry.access.redhat.com/ubi9/ubi:latest' > "$R/templates/image-set-okd"
for d in okd ocp; do
	conf $d stable "$([ $d = okd ] && echo "$OKD_LATEST" || echo 7.6.5)"; ANS="1|"
	run "_tui_image_set_checklist" _tui_image_set_checklist
	if [ $d = okd ]; then
		_eq "okd image sets: ai is not resolved" "0" "$(grep -c AI_RESOLVE <<< "$CALLS")"
		_hasnt "okd image sets: ai is not listed" "Red Hat AI|^DLG.* ai " "$DLG"
	else
		_has "ocp image sets: ai is resolved as before" "AI_RESOLVE" "$CALLS"
	fi
done

echo ""
echo "=== upgrade on okd ==="
conf okd stable "$OKD_LATEST"; ANS="0|"
run "mirror_prep_upgrade _tui_okd_unsupported" mirror_prep_upgrade
_has "okd Prepare Upgrade: a message says it is unsupported" "unsupported for OKD in ABA" "$DLG"
_eq "okd Prepare Upgrade: only that one dialog" "1" "$(grep -c '^DLG' <<< "$DLG")"
_eq "okd Prepare Upgrade: nothing downloaded or fetched" "0" "$(grep -c 'cli-download-all\|FETCH' <<< "$CALLS$RUN")"
conf ocp stable 7.6.5
run "_tui_okd_unsupported" _tui_okd_unsupported "Preparing an upgrade"
_eq "ocp: the guard lets the function go on" "rc=1" "$(grep '^rc=' <<< "$OUT")"
_eq "ocp: no dialog from the guard" "0" "$(grep -c '^DLG' <<< "$DLG")"
# The cluster-side blocks of the day-2 page stay as they were (test-okd-lifecycle-guards.sh runs them).
_eq "day-2 upgrade/osus/virt keep their okd block (definition + 3 uses)" "4" "$(grep -c '_day2_okd_blocked' "$REPO_ROOT/tui/v2/tui-cluster.sh")"

echo ""
echo "=== nothing left the box ==="
_eq "no curl/skopeo/podman/oc call was attempted" "" "$(cat "$T/net.log")"

echo ""
echo "Passed: $pass  Failed: $fail"
[ "$fail" -eq 0 ]
