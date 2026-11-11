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
# ========== Scenario K: distribution=okd (version checks, resolver stack) ==========
echo ""
echo "--- Scenario K: OKD resolvers, cache keys, task ids (HTTP mocked by a curl shim) ---"
_K_ROOT="$PWD"
_K_OUT=$(
	set +e
	K_FX=$(mktemp -d); K_BIN=$(mktemp -d); K_HOME=$(mktemp -d)
	export K_FX K_CURL_LOG="$K_HOME/curl.log"
	export ABA_CACHE_DIR="$K_HOME/cache" RUN_ONCE_DIR="$K_HOME/run_once"
	trap 'rm -rf "$K_FX" "$K_BIN" "$K_HOME"' EXIT

	# --- offline "internet": only the OKD lookup URLs (and two OCP ones for the isolation check) answer
	cat > "$K_BIN/curl" <<'EOS'
#!/usr/bin/bash
url=""; out=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2;; http*) url="$1"; shift;; *) shift;; esac; done
echo "$url" >> "$K_CURL_LOG"
f=""
case "$url" in
	https://api.github.com/repos/okd-project/okd/releases\?per_page=100\&page=[0-9]|https://api.github.com/repos/okd-project/okd/releases\?per_page=100\&page=[0-9][0-9])
		# only the exact query the resolver is meant to send is answered; anything else is logged UNEXPECTED and fails
		[ -z "${K_FAIL_GITHUB:-}" ] || exit 22
		p="${url##*page=}"; [ "$p" != "${K_FAIL_PAGE:-none}" ] || exit 22
		if [ "$p" = 1 ]; then f="$K_FX/releases.json"; else f="$K_FX/releases_p$p.json"; fi
		[ -f "$f" ] || f="$K_FX/releases_empty.json" ;;
	https://updates.okd.io/api/updates/graph\?channel=*\&arch=amd64)
		c="${url#*channel=}"; c="${c%%&*}"; f="$K_FX/graph_$c.json"; [ -f "$f" ] || f="$K_FX/graph_empty.json" ;;
	https://mirror.openshift.com/*/release.txt) f="$K_FX/ocp_release.txt" ;;
	https://api.openshift.com/api/upgrades_info/v1/graph\?*) f="$K_FX/ocp_graph.json" ;;
	*) echo "UNEXPECTED $url" >> "$K_CURL_LOG" ;;
esac
[ -n "$f" ] && [ -f "$f" ] || exit 22
cp "$f" "$out"
EOS
	chmod +x "$K_BIN/curl"
	export PATH="$K_BIN:$PATH"

	# spec: "tag" = GA release, "tag:pre" = GitHub pre-release, "tag:draft" = draft
	_mk_releases() {
		local out="$1" s; shift
		for s in "$@"; do
			case "$s" in
				*:bare)  jq -nc --arg t "${s%:bare}"  '{tag_name:$t}' ;;
				*:pre)   jq -nc --arg t "${s%:pre}"   '{tag_name:$t,name:$t,prerelease:true,draft:false}' ;;
				*:draft) jq -nc --arg t "${s%:draft}" '{tag_name:$t,name:$t,prerelease:false,draft:true}' ;;
				*)       jq -nc --arg t "$s"          '{tag_name:$t,name:$t,prerelease:false,draft:false}' ;;
			esac
		done | jq -sc '.' > "$out"
	}
	_mk_graph() {
		local out="$1"; shift
		jq -nc '{nodes: ($ARGS.positional | map({version: ., payload: ("quay.io/okd/scos-release@sha256:" + .)})), edges: []}' --args "$@" > "$out"
	}
	_reset() { rm -rf "$K_FX"/* "$ABA_CACHE_DIR" "$K_CURL_LOG"; : > "$K_CURL_LOG"
		printf '{"nodes":[],"edges":[]}\n' > "$K_FX/graph_empty.json"; printf '[]\n' > "$K_FX/releases_empty.json"
		printf 'Name: x\nVersion: 4.22.20\n' > "$K_FX/ocp_release.txt"
		_mk_graph "$K_FX/ocp_graph.json" 4.22.1 4.22.20; }
	_p() { echo "KPASS $*"; }
	_f() { echo "KFAIL $*"; }
	_chk() { [[ "$2" == "$3" ]] && _p "$1" || _f "$1: expected [$2] got [$3]"; }
	_rcchk() { local l="$1" want="$2"; shift 2; "$@" >/dev/null 2>&1; local got=$?; [[ $got -eq $want ]] && _p "$l" || _f "$l: expected rc=$want got rc=$got"; }

	source "$_K_ROOT/scripts/include_all.sh" 2>/dev/null   # restore the real functions (the mocks above are gone in here)
	trap - ERR
	export ARCH=amd64

	# ---------------- fixtures A: two minors with several builds, a 5.x tag, pre-release/draft/old-style noise
	_reset
	_mk_releases "$K_FX/releases.json" 5.0.0-okd-scos.5 4.22.0-okd-scos.4:pre 4.22.0-okd-scos.3 4.21.0-okd-scos.11 4.21.0-okd-scos.10 \
		4.21.0-okd-scos.ec.2:pre 4.21.0-0.okd-2025-01-01-000000 4.20.0-okd-scos.8 4.20.0-okd-scos.7 4.19.0-okd-scos.3:bare 4.19.0-okd-scos.9:bare 4.18.0-okd-scos.1:draft 5.7.0-0.okd-2099-01-01-000000
	_mk_graph "$K_FX/graph_stable-5.0.json" 5.0.0-okd-scos.5
	_mk_graph "$K_FX/graph_stable-4.22.json" 4.22.0-okd-scos.3
	_mk_graph "$K_FX/graph_stable-4.21.json" 4.21.0-okd-scos.11 4.21.0-okd-scos.2 4.21.0-okd-scos.10 4.21.1 4.21.0-okd-scos.ec.1 4.20.0-okd-scos.8
	_mk_graph "$K_FX/graph_stable-4.20.json" 4.20.0-okd-scos.7 4.20.0-okd-scos.8

	export distribution=okd
	_chk "A okd stable minor"          "5.0" "$(fetch_latest_minor_version stable)"
	_chk "A okd stable Latest"         "5.0.0-okd-scos.5"  "$(fetch_latest_version stable)"
	_chk "A okd stable Previous (cross-major)" "4.22.0-okd-scos.3" "$(fetch_previous_version stable)"
	_chk "A okd stable Older"          "4.21.0-okd-scos.11" "$(fetch_older_version stable)"
	_chk "A okd all versions sorted, noise filtered" \
		"4.21.0-okd-scos.2,4.21.0-okd-scos.10,4.21.0-okd-scos.11" "$(fetch_all_versions stable 4.21 | paste -sd,)"
	_chk "A okd x.y -> latest z"       "4.21.0-okd-scos.11" "$(fetch_latest_z_version stable 4.21)"
	_chk "A okd x.y (5.0) -> latest z" "5.0.0-okd-scos.5"  "$(fetch_latest_z_version stable 5.0)"
	_chk "A okd latest z without minor" "5.0.0-okd-scos.5" "$(fetch_latest_z_version stable)"
	_rcchk "A okd unknown minor fails" 1 fetch_latest_z_version stable 4.99
	_rcchk "A okd draft-only minor is not offered" 1 fetch_latest_z_version stable 4.18
	_chk "A okd all versions without a minor = head minor" "5.0.0-okd-scos.5" "$(fetch_all_versions stable | paste -sd,)"
	_chk "A okd build only on GitHub (no graph) via the GA tags, flags absent in the API object" "4.19.0-okd-scos.9" "$(fetch_latest_z_version stable 4.19)"
	_rcchk "A verify: GA exists"               0 verify_release_version_exists 4.21.0-okd-scos.11 stable
	_rcchk "A verify: unknown build"           1 verify_release_version_exists 4.21.0-okd-scos.99 stable
	_rcchk "A verify: candidate-only build not on stable" 1 verify_release_version_exists 4.22.0-okd-scos.4 stable
	_rcchk "A verify: 5.x"                     0 verify_release_version_exists 5.0.0-okd-scos.5 stable
	_rcchk "A verify: OCP-style number is not an OKD release" 1 verify_release_version_exists 4.22.1 stable

	_files=$(ls -1 "$ABA_CACHE_DIR" 2>/dev/null | sed -E 's/\.[A-Za-z0-9]{6}$//' | sort | paste -sd' ')
	[[ "$_files" == *"graph_okd_stable-5.0_amd64.json"* ]] && _p "A cache key: graph_okd_<chan>-<minor>_<ARCH>.json" || _f "A cache key graph file missing: $_files"
	[[ "$_files" == *"okd_releases_p1.json"* ]] && _p "A cache key: okd_releases_p<N>.json (one entry per page)" || _f "A releases cache missing: $_files"
	_n=$(ls -1 "$ABA_CACHE_DIR" | grep -c -E '^graph_(stable|candidate)-|^release_' || true)
	_chk "A okd never writes an OCP cache file name" "0" "$_n"
	_n=$(grep -c -E 'mirror\.openshift\.com|api\.openshift\.com|UNEXPECTED' "$K_CURL_LOG" || true)
	_chk "A okd contacted no OCP host / no unexpected URL" "0" "$_n"
	grep -q '^https://updates.okd.io/api/updates/graph?channel=stable-5.0&arch=amd64$' "$K_CURL_LOG" && _p "A okd graph URL = dist_graph_api + channel + arch" || _f "A okd graph URL not requested"
	grep -q '^https://api.github.com/repos/okd-project/okd/releases?per_page=100&page=1$' "$K_CURL_LOG" && _p "A okd releases URL = GitHub API, per_page=100, page=1" || _f "A okd GitHub releases URL not requested"

	# run_once-style fresh shell: no variable, only aba.conf in the cwd
	mkdir -p "$K_HOME/proj"; printf 'distribution=okd\n' > "$K_HOME/proj/aba.conf"
	_got=$(cd "$K_HOME/proj" && env -u distribution bash -c "source '$_K_ROOT/scripts/include_all.sh' 2>/dev/null; trap - ERR; fetch_latest_version stable" 2>/dev/null)
	_chk "A fresh shell (as run_once) resolves okd from aba.conf" "5.0.0-okd-scos.5" "$_got"

	# ---------------- fixtures B: different data -> different answers (nothing hard-coded); GitHub pre-release ignored
	_reset
	_mk_releases "$K_FX/releases.json" 1.0.0-okd-scos.1 0.9.0-okd-scos.1 4.23.0-okd-scos.1:pre 4.22.0-okd-scos.3 4.21.0-okd-scos.11 4.21.0-okd-scos.10 4.20.0-okd-scos.8 4.20.0-okd-scos.7
	_mk_graph "$K_FX/graph_stable-4.22.json" 4.22.0-okd-scos.3
	_mk_graph "$K_FX/graph_stable-4.21.json" 4.21.0-okd-scos.10 4.21.0-okd-scos.11
	_mk_graph "$K_FX/graph_stable-4.20.json" 4.20.0-okd-scos.7 4.20.0-okd-scos.8
	_chk "B okd stable minor (pre-release 4.23 ignored)" "4.22" "$(fetch_latest_minor_version stable)"
	_chk "B okd stable Latest"   "4.22.0-okd-scos.3"  "$(fetch_latest_version stable)"
	_chk "B okd stable Previous" "4.21.0-okd-scos.11" "$(fetch_previous_version stable)"
	_chk "B okd stable Older"    "4.20.0-okd-scos.8"  "$(fetch_older_version stable)"
	_rcchk "B okd candidate Latest fails: no candidate graph, a GA tag is not a candidate build" 1 fetch_latest_version candidate
	_chk   "B okd candidate Latest prints nothing" "" "$(fetch_latest_version candidate 2>/dev/null)"
	# candidate walk: gap after 4.22 -> one jump to the next major (5.0, 5.1 found), second gap stops (6.0 data ignored)
	# (same shape as the real candidate graphs: pre-release builds only)
	_mk_graph "$K_FX/graph_candidate-5.0.json" 5.0.0-okd-scos.ec.1
	_mk_graph "$K_FX/graph_candidate-5.1.json" 5.1.0-okd-scos.ec.1
	_mk_graph "$K_FX/graph_candidate-6.0.json" 6.0.0-okd-scos.ec.1
	rm -rf "$ABA_CACHE_DIR"
	_chk "B2 okd candidate walk jumps one major at most" "5.1" "$(fetch_latest_minor_version candidate)"
	_chk "B2 okd candidate Latest after the jump" "5.1.0-okd-scos.ec.1" "$(fetch_latest_version candidate)"
	# the minors before the head hold ec builds too: Previous and Older are the highest ec build of their minor
	_mk_graph "$K_FX/graph_candidate-4.22.json" 4.22.0-okd-scos.ec.3 4.22.0-okd-scos.ec.10 4.22.0-okd-scos.ec.9
	rm -rf "$ABA_CACHE_DIR"
	_chk "B2 okd candidate Previous (ec build)" "5.0.0-okd-scos.ec.1" "$(fetch_previous_version candidate)"
	_chk "B2 okd candidate Older (ec build, ec.10 after ec.9)" "4.22.0-okd-scos.ec.10" "$(fetch_older_version candidate)"
	_chk "B okd _okd_prev_minor stops below major 1" "" "$(_okd_prev_minor 1.0)"
	_chk "B okd _okd_prev_minor inside a major" "4.21" "$(_okd_prev_minor 4.22)"
	_chk "B okd _okd_prev_minor at X.0 = newest minor of the previous major" "4.22" "$(_okd_prev_minor 5.0)"

	# ---------------- no minor before the head: Previous/Older fail instead of repeating the head
	_reset
	_mk_releases "$K_FX/releases.json" 5.1.0-okd-scos.1 5.0.0-okd-scos.2
	_mk_graph "$K_FX/graph_stable-5.1.json" 5.1.0-okd-scos.1
	_mk_graph "$K_FX/graph_stable-5.0.json" 5.0.0-okd-scos.2
	_chk   "F okd Latest (head 5.1)"             "5.1.0-okd-scos.1" "$(fetch_latest_version stable)"
	_chk   "F okd Previous (5.0)"                "5.0.0-okd-scos.2" "$(fetch_previous_version stable)"
	_rcchk "F okd Older fails: no 4.x before 5.0" 1 fetch_older_version stable
	_rcchk "F okd x.y of a minor that never existed (4.0) fails, no head answer" 1 fetch_latest_z_version stable 4.0
	_chk   "F okd x.y of a minor that never existed (4.0) prints nothing" "" "$(fetch_latest_z_version stable 4.0 2>/dev/null)"
	_chk   "F okd Older prints nothing (not the head)" "" "$(fetch_older_version stable 2>/dev/null)"
	_reset
	_mk_releases "$K_FX/releases.json" 5.0.0-okd-scos.2
	_mk_graph "$K_FX/graph_stable-5.0.json" 5.0.0-okd-scos.2
	_rcchk "F okd Previous fails: nothing before the first minor" 1 fetch_previous_version stable
	_chk   "F okd Previous prints nothing (not the head)" "" "$(fetch_previous_version stable 2>/dev/null)"

	# ---------------- GitHub unreachable: no guess, no OCP fallback
	_reset
	export K_FAIL_GITHUB=1
	_rcchk "C GitHub unreachable: Latest fails" 1 fetch_latest_version stable
	_chk   "C GitHub unreachable: nothing printed" "" "$(fetch_latest_version stable 2>/dev/null)"
	_n=$(grep -c -E 'mirror\.openshift\.com|api\.openshift\.com' "$K_CURL_LOG" || true)
	_chk "C no OCP fallback on failure" "0" "$_n"
	unset K_FAIL_GITHUB

	# ---------------- ocp stays on the OCP hosts and OCP cache names
	_reset
	export distribution=ocp
	fetch_latest_minor_version stable >/dev/null 2>&1
	fetch_all_versions stable 4.22 >/dev/null 2>&1
	_n=$(grep -c -E 'updates\.okd\.io|api\.github\.com' "$K_CURL_LOG" || true)
	_chk "D ocp contacted no OKD host" "0" "$_n"
	[[ -f "$ABA_CACHE_DIR/graph_stable-4.22_amd64.json" ]] && _p "D ocp graph cache file name unchanged" || _f "D ocp graph cache file missing: $(ls "$ABA_CACHE_DIR")"
	unset distribution

	# ---------------- run_once task ids: okd-only prefix, ocp ids byte-identical
	run_once() { echo "RUN_ONCE $*"; }
	_o=$(distribution=ocp aba_version_fetch_channel stable | awk '{print $3}' | paste -sd' ')
	_chk "E ocp task ids unchanged" "ocp:stable:latest_version ocp:stable:latest_version_previous ocp:stable:latest_version_older" "$_o"
	_o=$(distribution=okd aba_version_fetch_channel stable | awk '{print $3}' | paste -sd' ')
	_chk "E okd task ids carry the distribution" "okd:stable:latest_version okd:stable:latest_version_previous okd:stable:latest_version_older" "$_o"
	_o=$(distribution=okd aba_version_fetch_channel stable | grep -c 'fetch_latest_version stable\|fetch_previous_version stable\|fetch_older_version stable' || true)
	_chk "E okd task commands are the same fetch_* calls" "3" "$_o"
	_o=$(distribution=ocp aba_version_fetch_start | awk '{print $3}' | cut -d: -f2 | sort -u | paste -sd' ')
	_chk "E ocp start: stable fast candidate" "candidate fast stable" "$_o"
	_o=$(distribution=okd aba_version_fetch_start | awk '{print $3}' | cut -d: -f1,2 | sort -u | paste -sd' ')
	_chk "E okd start: stable + candidate only (no fast)" "okd:candidate okd:stable" "$_o"
	_o=$(distribution=okd aba_version_fetch_wait stable -S | awk '{print $6}' | paste -sd' ')
	_chk "E okd wait ids" "okd:stable:latest_version okd:stable:latest_version_previous okd:stable:latest_version_older" "$_o"
	# wait: Latest and Previous are required, Older is best effort (same for both distributions)
	for d in ocp okd; do
		run_once() { [[ -n "$K_FAIL_ID" && "$*" == *"$K_FAIL_ID"* ]] && return 1; return 0; }
		export K_FAIL_ID=
		distribution=$d aba_version_fetch_wait stable >/dev/null 2>&1; _chk "E $d wait: nothing fails -> 0" "0" "$?"
		K_FAIL_ID=":stable:latest_version -"; distribution=$d aba_version_fetch_wait stable >/dev/null 2>&1; _chk "E $d wait: Latest fails -> 1" "1" "$?"
		K_FAIL_ID=":latest_version_previous"; distribution=$d aba_version_fetch_wait stable >/dev/null 2>&1; _chk "E $d wait: Previous fails -> 1" "1" "$?"
		K_FAIL_ID=":latest_version_older"; distribution=$d aba_version_fetch_wait stable >/dev/null 2>&1; _chk "E $d wait: Older fails -> 0" "0" "$?"
	done
	run_once() { echo "RUN_ONCE $*"; }
	_o=$(distribution=ocp aba_version_fetch_wait fast -S | awk '{print $6}' | paste -sd' ')
	_chk "E ocp wait ids unchanged" "ocp:fast:latest_version ocp:fast:latest_version_previous ocp:fast:latest_version_older" "$_o"

	# ================= M: REAL data (anonymous GETs of 2026-11-09, see test/func/fixtures/okd-real/README)
	# The shipped candidate graphs hold ONLY -okd-scos.ec.N builds; 27 of 71 GA tags are in no stable graph;
	# the GitHub list has 228 releases on 3 pages (100/100/28), GA 4.16-4.19 only on page 2.
	_RF="$_K_ROOT/test/func/fixtures/okd-real"
	_use_real() { _reset; cp "$_RF"/graph_*.json "$K_FX"/; cp "$_RF/releases_p1.json" "$K_FX/releases.json"; cp "$_RF"/releases_p[23].json "$K_FX"/; }
	_use_real
	export distribution=okd
	_chk "M stable minor"                 "5.0" "$(fetch_latest_minor_version stable)"
	_chk "M stable Latest"                "5.0.0-okd-scos.5"   "$(fetch_latest_version stable)"
	_chk "M stable Previous"              "4.22.0-okd-scos.10" "$(fetch_previous_version stable)"
	_chk "M stable Older"                 "4.21.0-okd-scos.11" "$(fetch_older_version stable)"
	_chk "M candidate minor (5.1 has only ec builds)" "5.1" "$(fetch_latest_minor_version candidate)"
	_chk "M candidate Latest = highest ec build of the head minor" "5.1.0-okd-scos.ec.2" "$(fetch_latest_version candidate)"
	_chk "M candidate Previous = highest ec build of the minor before" "5.0.0-okd-scos.ec.10" "$(fetch_previous_version candidate)"
	_rcchk "M candidate Older fails: candidate-4.22 lists nothing" 1 fetch_older_version candidate
	_chk   "M candidate Older prints nothing" "" "$(fetch_older_version candidate 2>/dev/null)"
	_chk "M candidate is not stable (Latest differs)" "1" "$([[ "$(fetch_latest_version candidate)" != "$(fetch_latest_version stable)" ]] && echo 1 || echo 0)"
	_chk "M candidate 5.0 list: only 5.0 builds, ec.10 after ec.9, ec.16 of 4.22 left out" \
		"5.0.0-okd-scos.ec.0,5.0.0-okd-scos.ec.1,5.0.0-okd-scos.ec.2,5.0.0-okd-scos.ec.3,5.0.0-okd-scos.ec.8,5.0.0-okd-scos.ec.9,5.0.0-okd-scos.ec.10" \
		"$(fetch_all_versions candidate 5.0 | paste -sd,)"
	_chk "M candidate 5.1 list" "5.1.0-okd-scos.ec.0,5.1.0-okd-scos.ec.1,5.1.0-okd-scos.ec.2" "$(fetch_all_versions candidate 5.1 | paste -sd,)"
	_chk "M candidate 4.22 list is empty" "" "$(fetch_all_versions candidate 4.22 | paste -sd,)"
	_chk "M stable 5.0 list: GA builds only (graph + GitHub agree)" \
		"5.0.0-okd-scos.0,5.0.0-okd-scos.1,5.0.0-okd-scos.2,5.0.0-okd-scos.3,5.0.0-okd-scos.4,5.0.0-okd-scos.5" "$(fetch_all_versions stable 5.0 | paste -sd,)"
	_chk "M stable 4.22 list = graph (0-5,9,10) + GA tags missing from the graph (6,7,8)" \
		"4.22.0-okd-scos.0,4.22.0-okd-scos.1,4.22.0-okd-scos.2,4.22.0-okd-scos.3,4.22.0-okd-scos.4,4.22.0-okd-scos.5,4.22.0-okd-scos.6,4.22.0-okd-scos.7,4.22.0-okd-scos.8,4.22.0-okd-scos.9,4.22.0-okd-scos.10" \
		"$(fetch_all_versions stable 4.22 | paste -sd,)"
	_chk "M stable 4.19: empty graph, 20 GA tags that live on GitHub page 2" "20" "$(fetch_all_versions stable 4.19 | wc -l)"
	_chk "M stable 4.19 list is numerically sorted" "4.19.0-okd-scos.0,4.19.0-okd-scos.1,4.19.0-okd-scos.2" "$(fetch_all_versions stable 4.19 | head -3 | paste -sd,)"
	_chk "M stable 4.19 last" "4.19.0-okd-scos.19" "$(fetch_all_versions stable 4.19 | tail -n1)"
	_chk "M latest z stable 5.0"          "5.0.0-okd-scos.5"    "$(fetch_latest_z_version stable 5.0)"
	_chk "M latest z stable 4.22"         "4.22.0-okd-scos.10"  "$(fetch_latest_z_version stable 4.22)"
	_chk "M latest z stable 4.19 (GitHub only, page 2)" "4.19.0-okd-scos.19" "$(fetch_latest_z_version stable 4.19)"
	_chk "M latest z candidate 5.1"       "5.1.0-okd-scos.ec.2" "$(fetch_latest_z_version candidate 5.1)"
	_chk "M latest z candidate 5.0"       "5.0.0-okd-scos.ec.10" "$(fetch_latest_z_version candidate 5.0)"
	_chk "M latest z candidate without minor = head minor" "5.1.0-okd-scos.ec.2" "$(fetch_latest_z_version candidate)"
	_rcchk "M latest z candidate 4.21 fails: nothing in any candidate graph below" 1 fetch_latest_z_version candidate 4.21
	# verify_release_version_exists
	_rcchk "M verify GA in the stable graph"                    0 verify_release_version_exists 4.21.0-okd-scos.11 stable
	_rcchk "M verify GA is not a candidate build"               1 verify_release_version_exists 4.21.0-okd-scos.11 candidate
	_rcchk "M verify GA 5.0.0-okd-scos.5 stable"                0 verify_release_version_exists 5.0.0-okd-scos.5 stable
	_rcchk "M verify GA 5.0.0-okd-scos.5 candidate"             1 verify_release_version_exists 5.0.0-okd-scos.5 candidate
	_rcchk "M verify ec build on candidate (5.1)"               0 verify_release_version_exists 5.1.0-okd-scos.ec.2 candidate
	_rcchk "M verify ec build on candidate (5.0)"               0 verify_release_version_exists 5.0.0-okd-scos.ec.9 candidate
	_rcchk "M verify ec build on candidate (ec.10)"             0 verify_release_version_exists 5.0.0-okd-scos.ec.10 candidate
	_rcchk "M verify ec build not on stable"                    1 verify_release_version_exists 5.1.0-okd-scos.ec.2 stable
	_rcchk "M verify unknown ec build on candidate"             1 verify_release_version_exists 5.0.0-okd-scos.ec.99 candidate
	_rcchk "M verify ec of a minor with no candidate graph"     1 verify_release_version_exists 4.20.0-okd-scos.ec.8 candidate
	_rcchk "M verify GitHub pre-release is not a stable build"  1 verify_release_version_exists 4.20.0-okd-scos.ec.8 stable
	_rcchk "M verify GA tag missing from the graph (4.22.0-okd-scos.7) on stable" 0 verify_release_version_exists 4.22.0-okd-scos.7 stable
	_rcchk "M verify GA tag missing from the graph (4.22.0-okd-scos.6) on stable" 0 verify_release_version_exists 4.22.0-okd-scos.6 stable
	_rcchk "M verify GA tag missing from the graph (4.22.0-okd-scos.8) on stable" 0 verify_release_version_exists 4.22.0-okd-scos.8 stable
	_rcchk "M verify GA tag missing from the graph (4.19.0-okd-scos.9, GitHub page 2)" 0 verify_release_version_exists 4.19.0-okd-scos.9 stable
	_rcchk "M verify GA tag missing from the graph (4.16.0-okd-scos.1, GitHub page 2)" 0 verify_release_version_exists 4.16.0-okd-scos.1 stable
	_rcchk "M verify GA tag missing from the graph is not a candidate build" 1 verify_release_version_exists 4.22.0-okd-scos.7 candidate
	_rcchk "M verify GA that does not exist"                    1 verify_release_version_exists 4.22.0-okd-scos.11 stable
	_rcchk "M verify OCP-style number"                          1 verify_release_version_exists 5.0.0 stable
	_rcchk "M verify OCP-style ec"                              1 verify_release_version_exists 5.0.0-ec.2 candidate
	_rcchk "M verify without a channel uses ocp_channel=stable"  0 env ocp_channel=stable distribution=okd bash -c "source '$_K_ROOT/scripts/include_all.sh' 2>/dev/null; trap - ERR; ARCH=amd64; verify_release_version_exists 4.22.0-okd-scos.7"
	_rcchk "M verify without a channel uses ocp_channel=candidate (ec)" 0 env ocp_channel=candidate distribution=okd bash -c "source '$_K_ROOT/scripts/include_all.sh' 2>/dev/null; trap - ERR; ARCH=amd64; verify_release_version_exists 5.1.0-okd-scos.ec.2"
	_rcchk "M verify without a channel uses ocp_channel=candidate (GA refused)" 1 env ocp_channel=candidate distribution=okd bash -c "source '$_K_ROOT/scripts/include_all.sh' 2>/dev/null; trap - ERR; ARCH=amd64; verify_release_version_exists 4.22.0-okd-scos.7"
	_rcchk "M verify empty version"                             1 verify_release_version_exists "" stable
	# a version that cannot belong to the channel is refused without asking anybody
	_n0=$(wc -l < "$K_CURL_LOG")
	verify_release_version_exists 9.9.9-okd-scos.ec.1 stable >/dev/null 2>&1; verify_release_version_exists garbage stable >/dev/null 2>&1; verify_release_version_exists 9.9.9-okd-scos.1x candidate >/dev/null 2>&1
	_chk "M verify: ec build on stable / malformed versions make no request" "0" "$(( $(wc -l < "$K_CURL_LOG") - _n0 ))"
	# the answers pass the format checks of their own channel
	_rcchk "M candidate Latest passes dist_version_is_valid on candidate" 0 dist_version_is_valid "$(fetch_latest_version candidate)" candidate
	_rcchk "M candidate Latest fails dist_version_is_valid on stable"     1 dist_version_is_valid "$(fetch_latest_version candidate)" stable
	_rcchk "M candidate Latest is a pre-release (warning stays)"         0 _is_prerelease "$(fetch_latest_version candidate)"
	_rcchk "M stable Latest is not a pre-release"                        1 _is_prerelease "$(fetch_latest_version stable)"
	# CLI URL helpers keep working with ec builds (asset names unchanged)
	_chk "M cli base url of an ec build" "https://github.com/okd-project/okd/releases/download/5.1.0-okd-scos.ec.2" "$(dist_cli_base_url 5.1.0-okd-scos.ec.2)"
	_chk "M cli sha256 url of an ec build" "https://github.com/okd-project/okd/releases/download/5.1.0-okd-scos.ec.2/sha256sum.txt" "$(dist_cli_sha256_url 5.1.0-okd-scos.ec.2)"
	# ---- the requests that went out (query strings asserted)
	_u=$(sort "$K_CURL_LOG")
	_chk "M no unexpected URL, no OCP host" "0" "$(grep -c -E 'UNEXPECTED|mirror\.openshift\.com|api\.openshift\.com' "$K_CURL_LOG" || true)"
	_chk "M GitHub: page 1, 2 and 3 of per_page=100, once each" \
		"https://api.github.com/repos/okd-project/okd/releases?per_page=100&page=1 https://api.github.com/repos/okd-project/okd/releases?per_page=100&page=2 https://api.github.com/repos/okd-project/okd/releases?per_page=100&page=3" \
		"$(grep '^https://api.github.com/' "$K_CURL_LOG" | sort -u | paste -sd' ')"
	_chk "M GitHub: no page 4 (page 3 is short)" "0" "$(grep -c 'page=4' "$K_CURL_LOG" || true)"
	_chk "M GitHub: 3 requests in all (cached per page)" "3" "$(grep -c '^https://api.github.com/' "$K_CURL_LOG" || true)"
	_chk "M graph: the candidate walk asks candidate-5.1, -5.2 and -6.0 with arch=amd64" \
		"https://updates.okd.io/api/updates/graph?channel=candidate-5.1&arch=amd64 https://updates.okd.io/api/updates/graph?channel=candidate-5.2&arch=amd64 https://updates.okd.io/api/updates/graph?channel=candidate-6.0&arch=amd64" \
		"$(grep '^https://updates.okd.io/.*channel=candidate-\(5\.[12]\|6\.0\)&' "$K_CURL_LOG" | sort -u | paste -sd' ')"
	_chk "M graph: stable queries carry channel=stable-<minor>" "1" "$(grep -c '^https://updates.okd.io/api/updates/graph?channel=stable-5.0&arch=amd64$' "$K_CURL_LOG" || true)"
	_chk "M graph: every graph URL is channel=(stable|candidate)-X.Y&arch=amd64" "0" \
		"$(grep '^https://updates.okd.io/' "$K_CURL_LOG" | grep -v -E '^https://updates\.okd\.io/api/updates/graph\?channel=(stable|candidate)-[0-9]+\.[0-9]+&arch=amd64$' | wc -l)"
	_chk "M graph: nothing is fetched twice" "0" "$(sort "$K_CURL_LOG" | uniq -d | wc -l)"
	_f1=$(ls -1 "$ABA_CACHE_DIR" | sed -E 's/\.[A-Za-z0-9]{6}$//' | grep '^okd_releases' | sort | paste -sd' ')
	_chk "M cache: one entry per releases page" "okd_releases_p1.json okd_releases_p2.json okd_releases_p3.json" "$_f1"

	# ================= P: releases pagination (synthetic pages, only the paging rules are under test)
	_pg() {   # <page-file> <first> <count>: <count> distinct GA tags 6.<i>.0-okd-scos.1 (i from <first>), a 5 KB body each
		local out="$1" first="$2" n="$3" b
		b=$(head -c 5000 /dev/zero | tr '\0' x)
		jq -nc --argjson f "$first" --argjson n "$n" --arg b "$b" '[range($f; $f + $n) | ("6." + tostring + ".0-okd-scos.1") as $t | {tag_name:$t,name:$t,prerelease:false,draft:false,body:$b,assets:[{name:"x"}]}]' > "$out"
	}
	_pages() { grep '^https://api.github.com/' "$K_CURL_LOG" | sed 's/.*page=//' | sort -nu | paste -sd' '; }
	_reset; _pg "$K_FX/releases.json" 0 100; _pg "$K_FX/releases_p2.json" 100 100; _mk_releases "$K_FX/releases_p3.json" 4.22.0-okd-scos.3
	_chk "P three pages (100/100/1): head minor is the highest over all pages" "6.199" "$(fetch_latest_minor_version stable)"
	_chk "P three pages: the GA tag on page 3 is found" "4.22.0-okd-scos.3" "$(_okd_ga_tags | grep '^4\.22\.')"
	_chk "P three pages: pages asked 1 2 3" "1 2 3" "$(_pages)"
	_chk "P three pages: 201 tags in all, sorted ascending" "6.0.0-okd-scos.1 6.199.0-okd-scos.1" "$(_okd_ga_tags | sed -n -e '2p' -e '$p' | paste -sd' ')"
	_chk "P three pages: cache entries are reduced (no body/assets)" "0" "$(cat "$ABA_CACHE_DIR"/okd_releases_p*.json | jq -r '.[] | keys[]' | grep -c -E 'body|assets' || true)"
	_chk "P three pages: cache entry keeps tag_name, prerelease, draft" '["draft","prerelease","tag_name"]' "$(jq -c '.[0] | keys' "$ABA_CACHE_DIR/okd_releases_p1.json")"
	_chk "P three pages: a 5 KB-per-release page is cached small" "1" "$([[ $(stat -c %s "$ABA_CACHE_DIR/okd_releases_p1.json") -lt 20000 ]] && echo 1 || echo 0)"
	_rcchk "P verify finds a tag that is only on page 3" 0 verify_release_version_exists 4.22.0-okd-scos.3 stable
	# an exactly full last page is followed by one more request, which ends the walk
	_reset; _pg "$K_FX/releases.json" 0 100; _pg "$K_FX/releases_p2.json" 100 100
	_chk "P full pages then an empty one: pages asked 1 2 3 (page 3 is empty)" "1 2 3" "$(_okd_ga_tags >/dev/null; _pages)"
	# short page 1: nothing more is requested
	_reset; _mk_releases "$K_FX/releases.json" 4.22.0-okd-scos.3
	_okd_ga_tags >/dev/null
	_chk "P short first page: only page 1 asked" "1" "$(_pages)"
	# empty page 1 (no releases at all)
	_reset; printf '[]\n' > "$K_FX/releases.json"
	_chk "P empty first page: no tags" "" "$(_okd_ga_tags)"
	_chk "P empty first page: only page 1 asked" "1" "$(_pages)"
	# hard cap: never more than 10 pages
	_reset; for _p in 1 2 3 4 5 6 7 8 9 10 11 12; do _pg "$K_FX/releases_p$_p.json" $(( (_p - 1) * 100 )) 100; done; cp "$K_FX/releases_p1.json" "$K_FX/releases.json"
	_n=$(_okd_ga_tags | wc -l)
	_chk "P hard cap: pages asked 1..10" "1 2 3 4 5 6 7 8 9 10" "$(_pages)"
	_chk "P hard cap: 1000 tags read" "1000" "$_n"
	# a failing page keeps what the earlier pages gave, a failing first page gives nothing
	_reset; _pg "$K_FX/releases.json" 0 100; _pg "$K_FX/releases_p2.json" 100 100; export K_FAIL_PAGE=2
	_chk "P page 2 unreachable: page 1 tags are still used" "6.99" "$(fetch_latest_minor_version stable)"
	_chk "P page 2 unreachable: walk stops after the failure" "1 2" "$(_pages)"
	export K_FAIL_PAGE=1; rm -rf "$ABA_CACHE_DIR"
	_chk "P page 1 unreachable: no tags" "" "$(_okd_ga_tags)"
	unset K_FAIL_PAGE
	# a JSON body that is not a list (rate-limit answer with HTTP 200) is not cached
	_reset; printf '{"message":"API rate limit exceeded"}\n' > "$K_FX/releases.json"
	_chk "P non-list answer: no tags" "" "$(_okd_ga_tags)"
	_chk "P non-list answer: not cached" "0" "$(ls "$ABA_CACHE_DIR" 2>/dev/null | grep -c '^okd_releases' || true)"
	_reset; printf '[{"tag_name":"4.22.0-okd-scos.3","prerelease":false,"draft":false},"x"]\n' > "$K_FX/releases.json"
	_chk "P list with a non-object element: not cached" "0" "$(_okd_ga_tags >/dev/null; ls "$ABA_CACHE_DIR" 2>/dev/null | grep -c '^okd_releases' || true)"
	# a graph body without a nodes list is not cached either
	_reset; _mk_releases "$K_FX/releases.json" 4.21.0-okd-scos.11; printf '{"message":"nope"}\n' > "$K_FX/graph_stable-4.21.json"
	_chk "P graph without nodes: not cached" "0" "$(fetch_all_versions stable 4.21 >/dev/null; ls "$ABA_CACHE_DIR" | grep -c '^graph_okd_stable-4.21' || true)"
	_reset; _mk_releases "$K_FX/releases.json" 4.21.0-okd-scos.11; printf '{"nodes":{"a":1}}\n' > "$K_FX/graph_stable-4.21.json"
	_chk "P graph with nodes that is not a list: not cached" "0" "$(fetch_all_versions stable 4.21 >/dev/null; ls "$ABA_CACHE_DIR" | grep -c '^graph_okd_stable-4.21' || true)"
	# minor prefix needs the dot: 4.2 must not read 4.22 builds
	_reset; _mk_releases "$K_FX/releases.json" 4.22.0-okd-scos.3 4.2.0-okd-scos.1
	_mk_graph "$K_FX/graph_stable-4.2.json" 4.2.0-okd-scos.1 4.22.0-okd-scos.3
	_chk "P graph minor filter: 4.2 does not list 4.22 builds" "4.2.0-okd-scos.1" "$(fetch_all_versions stable 4.2 | paste -sd,)"
	# a page of 60 is the last page (a page size below 100 means no more): page 2 is never asked
	_reset; _pg "$K_FX/releases.json" 0 60; _pg "$K_FX/releases_p2.json" 100 5
	_okd_ga_tags >/dev/null
	_chk "P a page of 60: only page 1 asked" "1" "$(_pages)"
	_chk "P a page of 60: the 5 tags of page 2 are not read" "60" "$(_okd_ga_tags | wc -l)"
	# a body that is a JSON object holding release-like objects is not a list
	_reset; printf '{"a":{"tag_name":"4.22.0-okd-scos.3","prerelease":false,"draft":false}}\n' > "$K_FX/releases.json"
	_chk "P object of releases (not a list): no tags" "" "$(_okd_ga_tags)"
	_chk "P object of releases (not a list): not cached" "0" "$(ls "$ABA_CACHE_DIR" 2>/dev/null | grep -c '^okd_releases' || true)"
	# an ec tag that GitHub does not flag as pre-release is still no GA tag
	_reset; _mk_releases "$K_FX/releases.json" 5.0.0-okd-scos.ec.7 5.0.0-okd-scos.2
	_chk "P ec tag flagged as a normal release: not a GA tag" "5.0.0-okd-scos.2" "$(_okd_ga_tags | paste -sd,)"
	# verification is an exact match, not a substring: ec.10 listed does not make ec.1 valid; GA .10 on GitHub does not make .1 valid
	_reset; _mk_releases "$K_FX/releases.json" 5.0.0-okd-scos.5; _mk_graph "$K_FX/graph_candidate-5.0.json" 5.0.0-okd-scos.ec.10
	_rcchk "P verify: ec.10 is listed" 0 verify_release_version_exists 5.0.0-okd-scos.ec.10 candidate
	_rcchk "P verify: ec.1 is not (substring of ec.10)" 1 verify_release_version_exists 5.0.0-okd-scos.ec.1 candidate
	_reset; _mk_releases "$K_FX/releases.json" 4.22.0-okd-scos.10
	_rcchk "P verify: GA .10 on GitHub is valid" 0 verify_release_version_exists 4.22.0-okd-scos.10 stable
	_rcchk "P verify: GA .1 is not (substring of .10)" 1 verify_release_version_exists 4.22.0-okd-scos.1 stable
	# the okd graph helper reports success when it printed a graph
	_reset; _mk_graph "$K_FX/graph_stable-4.22.json" 4.22.0-okd-scos.3
	_rcchk "P okd _fetch_graph_cached: rc 0 when a graph was printed" 0 _fetch_graph_cached stable 4.22
	# the order function itself: major, minor, patch, then pre-release builds before release builds, build numbers as numbers
	_chk "P _okd_sort order" \
		"4.9.5-okd-scos.1 4.22.0-okd-scos.10 5.0.0-okd-scos.ec.9 5.0.0-okd-scos.ec.10 5.0.0-okd-scos.2 5.0.1-okd-scos.ec.2 5.0.2-okd-scos.1 5.0.10-okd-scos.1" \
		"$(printf '%s\n' 5.0.1-okd-scos.ec.2 4.22.0-okd-scos.10 5.0.0-okd-scos.2 5.0.0-okd-scos.ec.10 4.9.5-okd-scos.1 5.0.0-okd-scos.ec.9 5.0.10-okd-scos.1 5.0.2-okd-scos.1 | _okd_sort | paste -sd' ')"
	# mixed candidate graph (synthetic): a GA build listed by the graph is accepted and sorts after the ec builds of its line
	_reset; _mk_releases "$K_FX/releases.json" 5.0.0-okd-scos.5
	_mk_graph "$K_FX/graph_candidate-5.0.json" 5.0.0-okd-scos.ec.10 5.0.0-okd-scos.1 5.0.0-okd-scos.ec.9 5.0.0-okd-scos.0 5.0.0-okd-scos.ec.2 5.0.0-okd-scos.10 5.0.0-okd-scos.2
	_chk "P candidate graph listing GA and ec builds: ec before GA, numeric order" \
		"5.0.0-okd-scos.ec.2,5.0.0-okd-scos.ec.9,5.0.0-okd-scos.ec.10,5.0.0-okd-scos.0,5.0.0-okd-scos.1,5.0.0-okd-scos.2,5.0.0-okd-scos.10" "$(fetch_all_versions candidate 5.0 | paste -sd,)"
	_chk "P candidate graph listing GA and ec builds: Latest = highest GA" "5.0.0-okd-scos.10" "$(fetch_latest_version candidate)"
	_rcchk "P candidate graph lists the GA build: verify accepts it" 0 verify_release_version_exists 5.0.0-okd-scos.10 candidate
	_chk "P stable never lists ec builds even if the stable graph carries them" "5.0.0-okd-scos.5" "$( _mk_graph "$K_FX/graph_stable-5.0.json" 5.0.0-okd-scos.ec.99 5.0.0-okd-scos.5; rm -rf "$ABA_CACHE_DIR"; fetch_all_versions stable 5.0 | tail -n1)"
	_rcchk "P stable verify refuses an ec build the stable graph carries" 1 verify_release_version_exists 5.0.0-okd-scos.ec.99 stable
	unset distribution
) 2>&1
echo "$_K_OUT" | grep -E '^KPASS|^KFAIL' | sed -e 's/^KPASS/  PASS /' -e 's/^KFAIL/  FAIL /'
_k_pass=$(echo "$_K_OUT" | grep -c '^KPASS' || true)
_k_fail=$(echo "$_K_OUT" | grep -c '^KFAIL' || true)
pass=$(( pass + _k_pass ))
fail=$(( fail + _k_fail ))
if [[ "$_k_pass" -eq 0 ]]; then
	_fail "K no OKD checks ran"
	echo "$_K_OUT" | tail -15
fi

# ========== Scenario L: _is_prerelease + entry points use the distribution-aware check ==========
echo ""
echo "--- Scenario L: OKD tags are releases, not pre-releases; entry points ---"
for v in 4.21.0-okd-scos.11 5.0.0-okd-scos.5 4.20.0-okd-scos.3; do
	_is_prerelease "$v" && _fail "L _is_prerelease($v) must be false (OKD release)" || _pass "L _is_prerelease($v) is false"
done
for v in 4.22.0-rc.1 5.0.0-ec.2 4.21.0-okd-scos.ec.2; do
	_is_prerelease "$v" && _pass "L _is_prerelease($v) still true" || _fail "L _is_prerelease($v) must stay true"
done
_is_prerelease 4.22.0 && _fail "L _is_prerelease(4.22.0) must be false" || _pass "L _is_prerelease(4.22.0) is false"

# The three aba.sh warning sites still call _is_prerelease; it now answers 'no' for OKD tags
_n=$(grep -c '_is_prerelease' scripts/aba.sh || true)
[[ "$_n" -eq 3 ]] && _pass "L aba.sh has its 3 pre-release warning sites ($_n)" || _fail "L aba.sh pre-release sites changed: $_n"
# CLI/TUI version entry points validate with dist_version_is_valid; --to (upgrade) is out of scope for OKD
_n=$(grep -c '_is_version_string' scripts/aba.sh || true)
[[ "$_n" -eq 1 ]] && _pass "L aba.sh: only the upgrade '--to' check still calls _is_version_string" || _fail "L aba.sh _is_version_string call sites: $_n (want 1)"
_n=$(grep -c 'dist_version_is_valid' scripts/aba.sh || true)
[[ "$_n" -ge 5 ]] && _pass "L aba.sh: --version/--upgrade-to/prompt use dist_version_is_valid ($_n)" || _fail "L aba.sh dist_version_is_valid sites: $_n (want >=5)"
# The interactive 'could not fetch versions' path (needs a tty) reads the error of the tasks that
# aba_version_fetch_start created, under the id of the distribution in effect. The block is run here
# with stubs for run_once / aba_abort / dist_of and the ids it asks for are recorded.
_ceq() { [[ "$2" == "$3" ]] && _pass "$1" || _fail "$1: expected [$2] got [$3]"; }
_blk=$(sed -n '/^\tif ! aba_version_fetch_wait "\$ocp_channel"; then$/,/^\tfi$/p' scripts/aba.sh)
_ids() {   # <distribution> <channel> <err1> -> "ids asked | abort text"
	local d="$1" c="$2" e="${3:-}"
	( local log; log=$(mktemp); trap 'rm -f "$log"' EXIT
	  dist_of() { echo "$d"; }; ocp_channel="$c"
	  run_once() { echo "$3" >> "$log"; [ "$3" = "$d:$c:latest_version" ] && printf '%s' "$e"; return 0; }
	  aba_abort() { echo "$(paste -sd' ' "$log") | $*"; exit 0; }
	  eval "${_blk/aba_version_fetch_wait \"\$ocp_channel\"/false}" )
}
_ceq "L aba.sh fetch-failure block found" 1 "$([[ -n "$_blk" ]] && echo 1 || echo 0)"
_ceq "L aba.sh fetch failure on okd/stable reads the okd tasks" 'okd:stable:latest_version | Failed to fetch OKD versions from updates.okd.io / github.com:\nboom\n\nPlease check network/DNS and try again.' "$(_ids okd stable boom)"
_ceq "L aba.sh fetch failure on okd/candidate falls back to the previous-version task" 'okd:candidate:latest_version okd:candidate:latest_version_previous | Failed to fetch OKD versions from updates.okd.io / github.com:\n\n\nPlease check network/DNS and try again.' "$(_ids okd candidate)"
_ceq "L aba.sh fetch failure on ocp keeps the ocp ids and the OCP message" 'ocp:fast:latest_version | Failed to fetch OCP versions from Cincinnati API:\nboom\n\nPlease check network/DNS and try again.' "$(_ids ocp fast boom)"
_ceq "L aba.sh fetch failure on ocp: previous-version task id unchanged" 'ocp:stable:latest_version ocp:stable:latest_version_previous | Failed to fetch OCP versions from Cincinnati API:\n\n\nPlease check network/DNS and try again.' "$(_ids ocp stable)"
[[ "$_blk" != *'"ocp:${ocp_channel}'* && "$_blk" != *'"okd:${ocp_channel}'* ]] && _pass "L aba.sh fetch-failure block has no hard-coded distribution id" || _fail "L aba.sh fetch-failure block still hard-codes an id"
for f in tui/v2/tui-direct.sh tui/v2/tui-lib.sh; do
	if grep -q 'dist_version_is_valid' "$f" && ! grep -q '_is_version_string' "$f"; then
		_pass "L $f uses dist_version_is_valid"
	else
		_fail "L $f still calls _is_version_string"
	fi
	# every call names the channel in effect (OKD pre-release builds are valid on candidate only)
	_n=$(grep -c 'dist_version_is_valid "\$_ver"' "$f" || true)
	_m=$(grep -c 'dist_version_is_valid "\$_ver" "\$_ch\(annel\)\?"' "$f" || true)
	[[ "$_n" -ge 1 && "$_n" -eq "$_m" ]] && _pass "L $f passes the channel to dist_version_is_valid ($_m of $_n calls)" || _fail "L $f: dist_version_is_valid calls without a channel ($_m of $_n)"
done
# every dist_version_is_valid call in aba.sh names the channel too
_n=$(grep -c 'dist_version_is_valid "' scripts/aba.sh || true)
_m=$(grep 'dist_version_is_valid "' scripts/aba.sh | grep -c 'dist_version_is_valid "[^"]*" \("\|\$\|candidate\)' || true)
[[ "$_n" -ge 6 && "$_n" -eq "$_m" ]] && _pass "L aba.sh passes the channel to dist_version_is_valid ($_m of $_n calls)" || _fail "L aba.sh: dist_version_is_valid calls without a channel ($_m of $_n)"
# reg-save / reg-sync verify with the channel of aba.conf (no explicit channel): the default must be ocp_channel
for f in scripts/reg-save.sh scripts/reg-sync.sh; do
	_n=$(grep -c 'verify_release_version_exists "\$ocp_version"' "$f" || true)
	[[ "$_n" -ge 1 ]] && _pass "L $f verifies ocp_version against the channel of aba.conf" || _fail "L $f no longer verifies ocp_version"
done
grep -q 'local channel="${2:-${ocp_channel:-stable}}"' scripts/include_all.sh && _pass "L verify_release_version_exists defaults to ocp_channel" || _fail "L verify_release_version_exists default channel changed"

# --- Summary ---
echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
