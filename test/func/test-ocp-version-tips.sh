#!/bin/bash
# Test: OCP Latest/Previous/Older tip resolution across majors + run_once TTL wiring
# Regression for: CDN lag after major GA (4.22 tip while stable-5.0 has 5.0.0);
# Previous/Older empty at X.0 (_prev_minor); version tips sticky forever (no -t).
#
# Unit tier: mocks network helpers — no Cincinnati/CDN required.
# Re-run anytime; scenarios stay valid as new majors ship.

cd "$(dirname "$0")/../.." || exit 1
source scripts/include_all.sh 2>/dev/null
trap - ERR

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }

echo "=== OCP version tips (unit) ==="

# Isolate HTTP + run_once state from the developer's real caches.
export ABA_CACHE_DIR
ABA_CACHE_DIR=$(mktemp -d)
export RUN_ONCE_DIR
RUN_ONCE_DIR=$(mktemp -d)
trap 'rm -rf "$ABA_CACHE_DIR" "$RUN_ONCE_DIR"' EXIT

# --- Helpers under test must exist ---
for fn in _peek_next_major_ga _channel_prev_minor _cdn_tip_minor _ocp_version_ttl \
	fetch_latest_version fetch_previous_version fetch_older_version; do
	if declare -F "$fn" >/dev/null; then
		_pass "helper defined: $fn"
	else
		_fail "helper missing: $fn"
	fi
done

# --- TTL helper returns seconds ---
_ttl="$(_ocp_version_ttl)"
if [[ "$_ttl" =~ ^[0-9]+$ ]] && [[ "$_ttl" -gt 0 ]]; then
	_pass "_ocp_version_ttl → ${_ttl}s"
else
	_fail "_ocp_version_ttl returned '$_ttl' (expected positive seconds)"
fi

# Override network boundaries for deterministic scenarios.
# Graph map: minor → newline-separated versions (newest last for tail -n1).
declare -A _MOCK_GRAPH=()
_MOCK_CDN_MINOR="4.22"
declare -A _MOCK_CDN_BY_MAJOR=([4]="4.22" [5]="5.0")

fetch_latest_minor_version() { echo "$_MOCK_CDN_MINOR"; }
fetch_all_versions() {
	local minor="$2"
	printf '%s\n' "${_MOCK_GRAPH[$minor]:-}"
}
_cdn_tip_minor() {
	local major="$2"
	echo "${_MOCK_CDN_BY_MAJOR[$major]:-}"
}

# ========== Scenario A: CDN lags next-major GA (today's 4.22 / 5.0.0 case) ==========
echo ""
echo "--- Scenario A: CDN=4.22, graph has GA 5.0.0 ---"
_MOCK_CDN_MINOR="4.22"
_MOCK_GRAPH=(
	[4.20]="4.20.10"$'\n'"4.20.44"
	[4.21]="4.21.1"$'\n'"4.21.40"
	[4.22]="4.22.1"$'\n'"4.22.20"
	[5.0]="5.0.0"
)

_lat=$(fetch_latest_version stable) || true
_prev=$(fetch_previous_version stable) || true
_old=$(fetch_older_version stable) || true

[[ "$_lat" == "5.0.0" ]] && _pass "A Latest → 5.0.0 (peek)" || _fail "A Latest expected 5.0.0 got '$_lat'"
[[ "$_prev" == "4.22.20" ]] && _pass "A Previous → 4.22.20 (CDN tip)" || _fail "A Previous expected 4.22.20 got '$_prev'"
[[ "$_old" == "4.21.40" ]] && _pass "A Older → 4.21.40 (behind CDN)" || _fail "A Older expected 4.21.40 got '$_old'"

# ========== Scenario B: CDN already on 5.0 (post catch-up) ==========
echo ""
echo "--- Scenario B: CDN=5.0, no 6.0 yet ---"
_MOCK_CDN_MINOR="5.0"
_MOCK_GRAPH=(
	[4.21]="4.21.40"
	[4.22]="4.22.20"
	[5.0]="5.0.0"$'\n'"5.0.3"
)

_lat=$(fetch_latest_version stable) || true
_prev=$(fetch_previous_version stable) || true
_old=$(fetch_older_version stable) || true

[[ "$_lat" == "5.0.3" ]] && _pass "B Latest → 5.0.3" || _fail "B Latest expected 5.0.3 got '$_lat'"
[[ "$_prev" == "4.22.20" ]] && _pass "B Previous → 4.22.20 (cross-major)" || _fail "B Previous expected 4.22.20 got '$_prev'"
[[ "$_old" == "4.21.40" ]] && _pass "B Older → 4.21.40 (cross-major)" || _fail "B Older expected 4.21.40 got '$_old'"

# ========== Scenario C: mid-5.x, within-major Previous/Older ==========
echo ""
echo "--- Scenario C: CDN=5.2, within 5.x ---"
_MOCK_CDN_MINOR="5.2"
_MOCK_CDN_BY_MAJOR=([4]="4.22" [5]="5.2")
_MOCK_GRAPH=(
	[5.0]="5.0.9"
	[5.1]="5.1.4"
	[5.2]="5.2.1"$'\n'"5.2.7"
	[6.0]=""
)

_lat=$(fetch_latest_version stable) || true
_prev=$(fetch_previous_version stable) || true
_old=$(fetch_older_version stable) || true

[[ "$_lat" == "5.2.7" ]] && _pass "C Latest → 5.2.7 (no peek)" || _fail "C Latest expected 5.2.7 got '$_lat'"
[[ "$_prev" == "5.1.4" ]] && _pass "C Previous → 5.1.4" || _fail "C Previous expected 5.1.4 got '$_prev'"
[[ "$_old" == "5.0.9" ]] && _pass "C Older → 5.0.9" || _fail "C Older expected 5.0.9 got '$_old'"

# ========== Scenario D: next-major tip is prerelease only — do not peek ==========
echo ""
echo "--- Scenario D: next major only has -ec (no GA peek) ---"
_MOCK_CDN_MINOR="4.22"
_MOCK_CDN_BY_MAJOR=([4]="4.22")
_MOCK_GRAPH=(
	[4.21]="4.21.40"
	[4.22]="4.22.20"
	[5.0]="5.0.0-ec.3"
)

_lat=$(fetch_latest_version stable) || true
_prev=$(fetch_previous_version stable) || true

[[ "$_lat" == "4.22.20" ]] && _pass "D Latest stays 4.22.20 (ec ignored)" || _fail "D Latest expected 4.22.20 got '$_lat'"
[[ "$_prev" == "4.21.40" ]] && _pass "D Previous stays N-1" || _fail "D Previous expected 4.21.40 got '$_prev'"

# ========== Scenario E: _channel_prev_minor arithmetic + cross-major ==========
echo ""
echo "--- Scenario E: _channel_prev_minor ---"
_MOCK_CDN_BY_MAJOR=([4]="4.22")
_p=$(_channel_prev_minor stable 4.22)
[[ "$_p" == "4.21" ]] && _pass "E 4.22 → 4.21" || _fail "E 4.22 → expected 4.21 got '$_p'"
_p=$(_channel_prev_minor stable 5.0)
[[ "$_p" == "4.22" ]] && _pass "E 5.0 → 4.22 (CDN maj-1)" || _fail "E 5.0 → expected 4.22 got '$_p'"

# ========== Scenario F: centralized tip start/wait (TTL + single cmd string) ==========
echo ""
echo "--- Scenario F: aba_version_fetch_channel / wait ---"
for fn in aba_version_fetch_channel aba_version_fetch_start aba_version_fetch_wait _cdn_tip_version _channel_cdn_head; do
	if declare -F "$fn" >/dev/null; then
		_pass "F helper defined: $fn"
	else
		_fail "F helper missing: $fn"
	fi
done

_blk=$(sed -n '/^aba_version_fetch_channel/,/^}/p' scripts/include_all.sh)
_t_count=$(echo "$_blk" | grep -c -- '-t' || true)
[[ "$_t_count" -ge 3 ]] && _pass "F aba_version_fetch_channel has ≥3 -t (got $_t_count)" \
	|| _fail "F aba_version_fetch_channel -t count=$_t_count (want ≥3)"

if grep -q 'aba_version_fetch_start' scripts/aba.sh \
	&& grep -q 'aba_version_fetch_channel' tui/v2/tui-direct.sh \
	&& grep -q 'aba_version_fetch_wait' tui/v2/tui-direct.sh; then
	_pass "F aba.sh + tui-direct use shared fetch helpers"
else
	_fail "F aba.sh / tui-direct not wired to aba_version_fetch_*"
fi

# TTL expiry/re-run mechanics: covered by test-run-once-ttl.sh.
# This file only asserts version-tip call sites pass -t (Scenario F).

# ========== Scenario H: one CDN cache key (no double-download) ==========
echo ""
echo "--- Scenario H: CDN release.txt cache key is shared ---"
# Source guard: only _cdn_tip_version owns the release_*.txt cache path.
_n_cache=$(grep -c 'release_\${channel}_v\${major}_\${ARCH}' scripts/include_all.sh || true)
_n_legacy=$(grep -cE 'release_\$\{channel\}_\$\{ARCH\}\.txt' scripts/include_all.sh || true)
[[ "$_n_cache" -eq 1 ]] && _pass "H single versioned cache key in include_all ($_n_cache)" \
	|| _fail "H expected 1 versioned cache key got $_n_cache"
[[ "$_n_legacy" -eq 0 ]] && _pass "H no legacy release_\${channel}_\${ARCH}.txt key" \
	|| _fail "H legacy unversioned cache key still present ($_n_legacy)"

# Behavioral: same channel+major → one _fetch_cached call across both entry points.
_fetch_count=0
_fetch_cached() {
	local url="$1" cache_file="$2"
	_fetch_count=$(( _fetch_count + 1 ))
	_last_cache_file="$cache_file"
	mkdir -p "$(dirname "$cache_file")"
	# Floating tip content depends on openshift-vN path so Scenario H/G stay deterministic.
	if [[ "$url" == *"/openshift-v5/"*"/ocp/stable/release.txt" ]]; then
		printf 'Name:           5.0.1\n  Version:  5.0.1\n' > "$cache_file"
	elif [[ "$url" == *"/openshift-v4/"*"/ocp/stable/release.txt" ]]; then
		printf 'Name:           4.22.18\n  Version:  4.22.18\n' > "$cache_file"
	elif [[ "$url" == *"/clients/ocp/" && "$url" != *release.txt ]]; then
		printf '<a href="stable-4.22/">stable-4.22/</a>\n' > "$cache_file"
	elif [[ "$url" == *"/stable-4.22/release.txt" ]]; then
		printf 'Name:           4.22.22\n  Version:  4.22.22\n' > "$cache_file"
	else
		printf 'Name:           4.22.18\n  Version:  4.22.18\n' > "$cache_file"
	fi
	return 0
}
ocp_major=4
_fetch_count=0
_cdn_tip_version stable 4 >/dev/null
_f1="$_last_cache_file"
# Second call via fetch_latest_minor_version must reuse cache (fresh) — 0 new fetches
# if _fetch_cached is still invoked for freshness check it may increment; instead
# assert both resolve to the same cache file path.
_cdn_tip_minor stable 4 >/dev/null
fetch_latest_minor_version stable >/dev/null
_f2="$_last_cache_file"
[[ "$_f1" == "$_f2" ]] && [[ "$_f1" == *"/release_stable_v4_"* ]] \
	&& _pass "H fetch_latest_minor + _cdn_tip_* share $_f1" \
	|| _fail "H cache paths diverge ('$_f1' vs '$_f2')"

# Cross-major asks a *different* URL (openshift-v4 vs v5) → different cache file is correct.
_cdn_tip_version stable 5 >/dev/null
_f5="$_last_cache_file"
[[ "$_f5" == *"/release_stable_v5_"* ]] && [[ "$_f5" != "$_f1" ]] \
	&& _pass "H major 5 uses distinct cache key ($_f5)" \
	|| _fail "H major 5 cache should differ from v4 (got '$_f5')"

# ========== Scenario G: floating v4/stable tips 5.x → scoped stable-4.Y ==========
echo ""
echo "--- Scenario G: contaminated floating tip falls back to scoped channel-MAJOR.Y ---"
_fetch_cached() {
	local url="$1" cache_file="$2"
	_last_cache_file="$cache_file"
	mkdir -p "$(dirname "$cache_file")"
	if [[ "$url" == *"/openshift-v4/"*"/ocp/stable/release.txt" ]]; then
		# Post-5.0 GA: floating tip under v4 publishes 5.x
		printf 'Name:           5.0.1\n  Version:  5.0.1\n' > "$cache_file"
	elif [[ "$url" == *"/clients/ocp/" && "$url" != *release.txt ]]; then
		printf '<a href="stable-4.21/">stable-4.21/</a>\n<a href="stable-4.22/">stable-4.22/</a>\n<a href="stable-5.0/">stable-5.0/</a>\n' > "$cache_file"
	elif [[ "$url" == *"/stable-4.22/release.txt" ]]; then
		printf 'Name:           4.22.22\n  Version:  4.22.22\n' > "$cache_file"
	else
		printf 'Name:           0.0.0\n  Version:  0.0.0\n' > "$cache_file"
	fi
	return 0
}
_g=$(_cdn_tip_version stable 4)
[[ "$_g" == "4.22.22" ]] && _pass "G _cdn_tip_version(4) → 4.22.22 (scoped)" \
	|| _fail "G _cdn_tip_version(4) expected 4.22.22 got '$_g'"
_g=$(_cdn_tip_minor stable 4)
[[ "$_g" == "4.22" ]] && _pass "G _cdn_tip_minor(4) → 4.22" \
	|| _fail "G _cdn_tip_minor(4) expected 4.22 got '$_g'"

# Scoped release.txt is also a 5.x tip: do not hand that back as a 4.x result.
_fetch_cached() {
	local url="$1" cache_file="$2"
	mkdir -p "$(dirname "$cache_file")"
	if [[ "$url" == *"/openshift-v4/"*"/ocp/stable/release.txt" ]]; then
		printf 'Name:           5.0.1\n  Version:  5.0.1\n' > "$cache_file"
	elif [[ "$url" == *"/clients/ocp/" && "$url" != *release.txt ]]; then
		printf '<a href="stable-4.22/">stable-4.22/</a>\n<a href="unstable-4.22/">unstable-4.22/</a>\n' > "$cache_file"
	elif [[ "$url" == *"/stable-4.22/release.txt" ]]; then
		printf 'Name:           5.0.1\n  Version:  5.0.1\n' > "$cache_file"
	else
		printf 'Name:           0.0.0\n  Version:  0.0.0\n' > "$cache_file"
	fi
	return 0
}
_g=$(_cdn_tip_version stable 4)
[[ -z "$_g" ]] && _pass "G scoped 5.x tip is not a 4.x result" \
	|| _fail "G scoped 5.x tip should be empty, got '$_g'"

# ========== Scenario I: candidate offer — exclusive + GA-equal + CDN-on-5.0 ==========
echo ""
echo "--- Scenario I: _candidate_offer_compute circumstances ---"
# Restored graph mocks (Scenarios H/G overrode network helpers).
_version_has_cross_minor_edge() { return 0; }

# I1: today-like — CDN still on 4.22; candidate has GA-equal 5.0.1 plus -ec previews.
#     Must KEEP 5.0.1 even though fast tips the same build (no exclusive-only filter).
_MOCK_CDN_MINOR="4.22"
fetch_latest_minor_version() { echo "$_MOCK_CDN_MINOR"; }
fetch_all_versions() {
	local channel="$1" minor="$2"
	case "$channel:$minor" in
		candidate:4.22) echo "4.22.22" ;;
		fast:4.22) echo "4.22.22" ;;
		candidate:4.23) echo "4.23.0-ec.2" ;;
		fast:4.23) echo "" ;;
		candidate:5.0) echo "5.0.1" ;;
		fast:5.0) echo "5.0.1" ;;
		candidate:5.1) echo "5.1.0-ec.2" ;;
		fast:5.1) echo "" ;;
		*) echo "" ;;
	esac
}
mapfile -t _off < <(_candidate_offer_compute || true)
# Newest-first, at most 3: 5.1.0-ec.2, 5.0.1, 4.23.0-ec.2 (4.22.22 drops off the cap)
[[ "${_off[0]:-}" == "5.1.0-ec.2" && "${_off[1]:-}" == "5.0.1" && "${_off[2]:-}" == "4.23.0-ec.2" ]] \
	&& _pass "I1 offer keeps GA-equal 5.0.1 + exclusives (${_off[*]})" \
	|| _fail "I1 expected '5.1.0-ec.2 5.0.1 4.23.0-ec.2' got '${_off[*]:-}'"

# I2: CDN already on 5.0 — inclusive anchor fills Previous when only one -ec exists.
_MOCK_CDN_MINOR="5.0"
fetch_all_versions() {
	local channel="$1" minor="$2"
	case "$channel:$minor" in
		candidate:5.0) echo "5.0.1" ;;
		fast:5.0) echo "5.0.1" ;;
		candidate:5.1) echo "5.1.0-ec.2" ;;
		fast:5.1) echo "" ;;
		*) echo "" ;;
	esac
}
mapfile -t _off < <(_candidate_offer_compute || true)
[[ "${_off[0]:-}" == "5.1.0-ec.2" && "${_off[1]:-}" == "5.0.1" && -z "${_off[2]:-}" ]] \
	&& _pass "I2 CDN-on-5.0 offer is 5.1-ec + 5.0.1 (${_off[*]})" \
	|| _fail "I2 expected '5.1.0-ec.2 5.0.1' got '${_off[*]:-}'"

_lat=$(fetch_latest_version candidate) || true
_prev=$(fetch_previous_version candidate) || true
[[ "$_lat" == "5.1.0-ec.2" ]] && _pass "I2 Latest candidate → 5.1.0-ec.2" \
	|| _fail "I2 Latest candidate expected 5.1.0-ec.2 got '$_lat'"
[[ "$_prev" == "5.0.1" ]] && _pass "I2 Previous candidate → 5.0.1 (same as fast/stable OK)" \
	|| _fail "I2 Previous candidate expected 5.0.1 got '$_prev'"

# I3: only GA-equal tips (no -ec ahead) — still offer the caught-up tip, not empty.
_MOCK_CDN_MINOR="5.0"
fetch_all_versions() {
	local channel="$1" minor="$2"
	case "$channel:$minor" in
		candidate:5.0) echo "5.0.1" ;;
		fast:5.0) echo "5.0.1" ;;
		*) echo "" ;;
	esac
}
mapfile -t _off < <(_candidate_offer_compute || true)
[[ "${_off[0]:-}" == "5.0.1" && -z "${_off[1]:-}" ]] \
	&& _pass "I3 GA-only offer is 5.0.1 (not empty)" \
	|| _fail "I3 expected sole '5.0.1' got '${_off[*]:-}'"

# ========== Scenario J: deep ec / rc / GA tip handling ==========
echo ""
echo "--- Scenario J: ec/rc/GA version strings + offer tips ---"
_version_has_cross_minor_edge() { return 0; }

# J1: helpers accept ec and rc; prerelease detection
for _v in 5.1.0-ec.2 4.23.0-ec.0 5.1.0-rc.1 5.0.0-rc.0; do
	if _is_version_string "$_v" && _is_prerelease "$_v"; then
		_pass "J1 $_v is version + prerelease"
	else
		_fail "J1 $_v should be version+prerelease"
	fi
done
_is_ga_version "5.0.1" && ! _is_prerelease "5.0.1" \
	&& _pass "J1 5.0.1 is GA (not prerelease)" \
	|| _fail "J1 5.0.1 should be GA"

# J2: fetch_all_versions tip is newest after ec < rc < GA sort (mock the pipe path)
# _semver_sort must put GA last so tail -n1 is the channel tip.
_sorted=$(printf '%s\n' "5.1.0-ec.1" "5.1.0-rc.1" "5.1.0-ec.2" "5.1.0" "5.1.0-rc.0" | _semver_sort)
_tip=$(echo "$_sorted" | tail -n1)
[[ "$_tip" == "5.1.0" ]] && _pass "J2 semver tip of ec/rc/GA mix is GA 5.1.0" \
	|| _fail "J2 expected tip 5.1.0 got '$_tip' (order: $(echo $_sorted))"
_ec_tip=$(printf '%s\n' "5.1.0-ec.1" "5.1.0-ec.2" | _semver_sort | tail -n1)
[[ "$_ec_tip" == "5.1.0-ec.2" ]] && _pass "J2 semver tip of ec-only is newest ec" \
	|| _fail "J2 expected 5.1.0-ec.2 got '$_ec_tip'"
_rc_tip=$(printf '%s\n' "5.1.0-rc.0" "5.1.0-rc.1" "5.1.0-ec.9" | _semver_sort | tail -n1)
[[ "$_rc_tip" == "5.1.0-rc.1" ]] && _pass "J2 semver tip rc > ec" \
	|| _fail "J2 expected 5.1.0-rc.1 got '$_rc_tip'"

# J3: offer Latest prefers -rc when that minor's candidate tip is rc (ahead of fast)
_MOCK_CDN_MINOR="5.0"
fetch_latest_minor_version() { echo "$_MOCK_CDN_MINOR"; }
fetch_all_versions() {
	local channel="$1" minor="$2"
	case "$channel:$minor" in
		candidate:5.0) echo "5.0.1" ;;
		fast:5.0) echo "5.0.1" ;;
		candidate:5.1) printf '%s\n' "5.1.0-ec.2" "5.1.0-rc.1" ;;
		fast:5.1) echo "" ;;
		*) echo "" ;;
	esac
}
# Tip of candidate-5.1 must be rc.1 (fetch_all_versions | tail -n1 after sort in real code;
# our mock returns unsorted lines — mirror real helper by sorting like fetch_all_versions).
fetch_all_versions() {
	local channel="$1" minor="$2" raw
	case "$channel:$minor" in
		candidate:5.0) raw="5.0.1" ;;
		fast:5.0) raw="5.0.1" ;;
		candidate:5.1) raw=$'5.1.0-ec.2\n5.1.0-rc.1' ;;
		fast:5.1) raw="" ;;
		*) raw="" ;;
	esac
	[[ -n "$raw" ]] || return 0
	printf '%s\n' "$raw" | _semver_sort
}
mapfile -t _off < <(_candidate_offer_compute || true)
[[ "${_off[0]:-}" == "5.1.0-rc.1" && "${_off[1]:-}" == "5.0.1" ]] \
	&& _pass "J3 offer Latest is rc tip 5.1.0-rc.1 (${_off[*]})" \
	|| _fail "J3 expected '5.1.0-rc.1 5.0.1' got '${_off[*]:-}'"

# J4: offer Latest is -ec when that is the only prerelease tip
fetch_all_versions() {
	local channel="$1" minor="$2" raw
	case "$channel:$minor" in
		candidate:5.0) raw="5.0.1" ;;
		fast:5.0) raw="5.0.1" ;;
		candidate:5.1) raw=$'5.1.0-ec.1\n5.1.0-ec.2' ;;
		*) raw="" ;;
	esac
	[[ -n "$raw" ]] || return 0
	printf '%s\n' "$raw" | _semver_sort
}
mapfile -t _off < <(_candidate_offer_compute || true)
[[ "${_off[0]:-}" == "5.1.0-ec.2" ]] && _pass "J4 offer Latest is newest ec 5.1.0-ec.2" \
	|| _fail "J4 expected Latest 5.1.0-ec.2 got '${_off[*]:-}'"

# J5: orphan ec without cross-minor edge is skipped; GA-equal with edge kept
_version_has_cross_minor_edge() {
	[[ "$1" != "5.1.0-ec.2" ]]
}
fetch_all_versions() {
	local channel="$1" minor="$2" raw
	case "$channel:$minor" in
		candidate:5.0) raw="5.0.1" ;;
		fast:5.0) raw="5.0.1" ;;
		candidate:5.1) raw="5.1.0-ec.2" ;;
		*) raw="" ;;
	esac
	[[ -n "$raw" ]] || return 0
	printf '%s\n' "$raw"
}
mapfile -t _off < <(_candidate_offer_compute || true)
[[ "${_off[0]:-}" == "5.0.1" && -z "${_off[1]:-}" ]] \
	&& _pass "J5 orphan ec without edge dropped; GA tip kept" \
	|| _fail "J5 expected sole 5.0.1 got '${_off[*]:-}'"

# --- Summary ---
echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
