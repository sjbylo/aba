#!/bin/bash
# Test: macs_* helpers in include_all.sh (shared MAC completeness intelligence)
# Regression for: DRY macs status — TUI/core must agree on expected count

cd "$(dirname "$0")/../.." || exit 1
export PATH="$PWD/scripts:$PATH"
# shellcheck disable=SC1091
source scripts/include_all.sh dummy_arg 2>/dev/null

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }

echo "=== macs_* helpers ==="

# --- expected count ---
_exp=$(macs_expected_count 1 0 ens1f0)
[ "$_exp" = "1" ] && _pass "sno × 1 port → 1" || _fail "sno × 1 port → 1 (got $_exp)"

_exp=$(macs_expected_count 3 0 "ens1f0,ens1f1")
[ "$_exp" = "6" ] && _pass "compact × 2 ports → 6" || _fail "compact × 2 ports → 6 (got $_exp)"

_exp=$(macs_expected_count 3 2 ens1f0)
[ "$_exp" = "5" ] && _pass "standard 3+2 × 1 port → 5" || _fail "standard 3+2 × 1 (got $_exp)"

# --- type mapping ---
read -r _nm _nw <<<"$(macs_nodes_from_type sno)"
[ "$_nm" = "1" ] && [ "$_nw" = "0" ] && _pass "type sno → 1 0" || _fail "type sno → 1 0"

read -r _nm _nw <<<"$(macs_nodes_from_type standard 4)"
[ "$_nm" = "3" ] && [ "$_nw" = "4" ] && _pass "type standard 4 → 3 4" || _fail "type standard 4"

# --- extract / count from text ---
_txt=$'00:50:56:1a:2b:01 junk\nblah 00:50:56:1a:2b:02'
_list=$(macs_list_from_text "$_txt")
_cnt=$(echo "$_list" | wc -l); _cnt=${_cnt// /}
[ "$_cnt" = "2" ] && _pass "macs_list_from_text extracts 2" || _fail "macs_list_from_text (got $_cnt)"

# --- status complete / incomplete ---
eval "$(macs_status --text "00:50:56:1a:2b:01" --type sno --ports ens1f0)"
[ "$mac_complete" = "1" ] && [ "$mac_count" = "1" ] && [ "$mac_expected" = "1" ] \
	&& _pass "macs_status sno complete" || _fail "macs_status sno complete ($mac_count/$mac_expected complete=$mac_complete)"

eval "$(macs_status --text "" --type compact --ports ens1f0)"
[ "$mac_complete" = "0" ] && [ "$mac_expected" = "3" ] \
	&& _pass "macs_status compact empty incomplete" || _fail "macs_status compact empty"

eval "$(macs_status --text $'aa:bb:cc:dd:ee:01\naa:bb:cc:dd:ee:02' --masters 3 --workers 0 --ports ens1f0)"
[ "$mac_complete" = "0" ] && [ "$mac_count" = "2" ] && [ "$mac_expected" = "3" ] \
	&& _pass "macs_status partial incomplete" || _fail "macs_status partial"

macs_is_complete --text "00:11:22:33:44:55" --type sno --ports eno1 \
	&& _pass "macs_is_complete true" || _fail "macs_is_complete true"

macs_is_complete --text "" --type sno --ports eno1 \
	&& _fail "macs_is_complete false should fail" || _pass "macs_is_complete false"

# --- file path ---
_td=$(mktemp -d)
trap 'rm -rf "$_td"' EXIT
printf '00:50:56:00:00:01\n00:50:56:00:00:02\n00:50:56:00:00:03\n' > "$_td/macs.conf"
eval "$(macs_status --file "$_td/macs.conf" --type compact --ports ens1f0)"
[ "$mac_complete" = "1" ] && [ "$mac_count" = "3" ] \
	&& _pass "macs_status from file complete" || _fail "macs_status from file"

# --- _valid_mac ---
_valid_mac "00:50:56:ab:cd:ef" && _pass "_valid_mac good" || _fail "_valid_mac good"
_valid_mac "bad" && _fail "_valid_mac bad should fail" || _pass "_valid_mac bad"

# --- macs_should_apply (mtime + completeness) ---
_ag="$_td/agent-config.yaml"
touch "$_ag"
sleep 1
# complete macs newer than agent → apply
printf '00:50:56:00:00:01\n00:50:56:00:00:02\n00:50:56:00:00:03\n' > "$_td/macs.conf"
macs_should_apply --type compact --ports ens1f0 "$_td/macs.conf" "$_ag" \
	&& _pass "macs_should_apply: complete+newer → yes" \
	|| _fail "macs_should_apply: complete+newer → yes"
# agent newer → ignore macs
sleep 1
touch "$_ag"
macs_should_apply --type compact --ports ens1f0 "$_td/macs.conf" "$_ag" \
	&& _fail "macs_should_apply: older macs must not win" \
	|| _pass "macs_should_apply: older macs → no"
# empty macs → no
rm -f "$_td/macs.conf"
macs_should_apply --type compact --ports ens1f0 "$_td/macs.conf" "$_ag" \
	&& _fail "macs_should_apply: empty must not win" \
	|| _pass "macs_should_apply: empty → no"
# complete macs, no agent file → yes
printf '00:50:56:00:00:01\n' > "$_td/macs-sno.conf"
macs_should_apply --type sno --ports ens1f0 "$_td/macs-sno.conf" "$_td/missing-agent.yaml" \
	&& _pass "macs_should_apply: no agent-config → yes" \
	|| _fail "macs_should_apply: no agent-config → yes"
# unique but short + newer than agent → still apply (placeholders fill the rest)
sleep 1
printf '00:50:56:00:00:01\n00:50:56:00:00:02\n' > "$_td/macs.conf"
macs_should_apply --type compact --ports ens1f0 "$_td/macs.conf" "$_ag" \
	&& _pass "macs_should_apply: unique partial+newer → yes" \
	|| _fail "macs_should_apply: unique partial+newer → yes"

# --- cluster.conf outranks a kept YAML (macs.conf mtime does not veto) ---
_cc="$_td/cluster.conf"
touch "$_cc" "$_ag"
cluster_conf_outranks_agent "$_cc" "$_ag" \
	&& _fail "cluster_conf_outranks_agent: same mtime must not win" \
	|| _pass "cluster_conf_outranks_agent: YAML not older → no"
sleep 1
touch "$_cc"
cluster_conf_outranks_agent "$_cc" "$_ag" \
	&& _pass "cluster_conf_outranks_agent: cluster.conf newer → yes" \
	|| _fail "cluster_conf_outranks_agent: cluster.conf newer → yes"
# older macs still must not apply; cluster.conf is a separate gate
macs_should_apply --type compact --ports ens1f0 "$_td/macs.conf" "$_ag" \
	&& _fail "macs_should_apply stays no when only cluster.conf is newer" \
	|| _pass "macs_should_apply stays no when only cluster.conf is newer"

# --- macs_report (human ask/log summary) ---
_rpt=$(macs_report --file "$_td/missing-macs.conf" --type sno --ports ens1f0)
echo "$_rpt" | grep -q 'missing/empty — NOT READY' \
	&& _pass "macs_report: missing" || _fail "macs_report: missing"

printf '00:11:22:33:44:55\n' > "$_td/macs-sno.conf"
_rpt=$(macs_report --file "$_td/macs-sno.conf" --type sno --ports ens1f0 --agent "$_td/no-agent.yaml")
echo "$_rpt" | grep -q 'READY (1/1)' && echo "$_rpt" | grep -q '00:11:22:33:44:55' \
	&& _pass "macs_report: ready + content" || _fail "macs_report: ready + content (got: $_rpt)"

printf 'aa:bb:cc:dd:ee:01\naa:bb:cc:dd:ee:02\n' > "$_td/macs-partial.conf"
_rpt=$(macs_report --file "$_td/macs-partial.conf" --type compact --ports ens1f0 --agent "$_td/no-agent.yaml")
echo "$_rpt" | grep -q 'PARTIAL' && echo "$_rpt" | grep -q 'WARN: too few' \
	&& _pass "macs_report: too few is a warning (partial list still used)" || _fail "macs_report: too few (got: $_rpt)"

printf 'aa:bb:cc:dd:ee:01\naa:bb:cc:dd:ee:01\naa:bb:cc:dd:ee:02\n' > "$_td/macs-dup.conf"
_rpt=$(macs_report --file "$_td/macs-dup.conf" --type compact --ports ens1f0 --agent "$_td/no-agent.yaml")
echo "$_rpt" | grep -q 'ERROR: duplicate' \
	&& _pass "macs_report: duplicate ERROR" || _fail "macs_report: duplicate (got: $_rpt)"

# Case-insensitive duplicate, and whitespace is not an error.
_rpt=$(macs_report --text $'  AA:BB:CC:DD:EE:01  \n\naa:bb:cc:dd:ee:01\n' --type sno --ports ens1f0)
echo "$_rpt" | grep -q 'ERROR: duplicate' \
	&& _pass "macs_report: case-insensitive duplicate" || _fail "macs_report: case-insensitive duplicate (got: $_rpt)"

_canon=$(macs_canonicalize_text $'\n  00:11:22:33:44:55  \n\n')
[ "$_canon" = "00:11:22:33:44:55" ] \
	&& _pass "canonicalize trims blank lines and surrounding spaces" \
	|| _fail "canonicalize trim (got: $_canon)"

_rpt=$(macs_report --text $'\n  00:11:22:33:44:55  \n\n' --type sno --ports ens1f0)
if echo "$_rpt" | grep -q 'READY (1/1' && ! grep -q 'ERROR:' <<<"$_rpt"; then
	_pass "macs_report: padded MAC is ready"
else
	_fail "macs_report: padded MAC (got: $_rpt)"
fi

_rpt=$(macs_report --text $'   \n\n' --type sno --ports ens1f0)
echo "$_rpt" | grep -q 'missing/empty — NOT READY' \
	&& _pass "macs_report: whitespace-only is empty" || _fail "macs_report: whitespace-only (got: $_rpt)"

_rpt=$(macs_report --text $'00:zz:zz:zz:zz:zz' --type sno --ports ens1f0)
echo "$_rpt" | grep -q 'ERROR: not hex: 00:zz:zz:zz:zz:zz' \
	&& _pass "macs_report: not hex" || _fail "macs_report: not hex (got: $_rpt)"

_rpt=$(macs_report --text $'not-a-mac' --type sno --ports ens1f0)
echo "$_rpt" | grep -q 'ERROR: not a MAC address: not-a-mac' \
	&& _pass "macs_report: not a MAC address" || _fail "macs_report: not a MAC address (got: $_rpt)"

echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
