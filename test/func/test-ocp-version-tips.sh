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

# --- Summary ---
echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
