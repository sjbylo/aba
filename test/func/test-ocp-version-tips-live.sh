#!/bin/bash
# Test: Live Cincinnati/CDN invariants for OCP Latest/Previous/Older
# Integration tier: hits api.openshift.com + mirror.openshift.com.
#
# Asserts durable properties (not pinned z-streams) so the test keeps
# working as new versions ship:
#   stable/fast:
#     - tips are valid; Latest > Previous > Older
#     - CDN-lag peek: if next-major GA exists → Latest is it, Previous is CDN tip
#     - at CDN X.0, Previous comes from major-1
#   candidate (_candidate_offer, not CDN peek):
#     - Latest (+ Previous when offer has ≥2) are valid and ordered
#     - Older optional (only when offer has ≥3)

cd "$(dirname "$0")/../.." || exit 1
source scripts/include_all.sh 2>/dev/null
trap - ERR

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }

echo "=== OCP version tips (live) ==="

export ABA_CACHE_DIR
ABA_CACHE_DIR=$(mktemp -d)
trap 'rm -rf "$ABA_CACHE_DIR"' EXIT

# Connectivity gate — skip cleanly if offline
if ! curl -fsS --connect-timeout 5 -o /dev/null "$ABA_GRAPH_API?channel=stable-4.16&arch=${ARCH:-amd64}" 2>/dev/null; then
	echo "SKIPPED: Cincinnati unreachable"
	exit 0
fi

_assert_common_ladder() {
	local ch="$1" lat="$2" prev="$3" old="$4" older_required="${5:-1}"

	if _is_version_string "$lat"; then
		_pass "$ch Latest is a version ($lat)"
	else
		_fail "$ch Latest missing/invalid ('$lat')"
		return 1
	fi

	if _is_version_string "$prev"; then
		_pass "$ch Previous is a version ($prev)"
	else
		_fail "$ch Previous missing/invalid ('$prev')"
	fi

	if [[ -n "$old" ]]; then
		if _is_version_string "$old"; then
			_pass "$ch Older is a version ($old)"
		else
			_fail "$ch Older invalid ('$old')"
		fi
	elif [[ "$older_required" == "1" ]]; then
		_fail "$ch Older missing/invalid ('$old')"
	else
		_pass "$ch Older empty (offer has <3 tips — OK)"
	fi

	if [[ -n "$prev" && "$prev" == "$lat" ]]; then
		_fail "$ch Previous must differ from Latest"
	elif [[ -n "$prev" ]]; then
		_pass "$ch Previous ≠ Latest"
	fi

	if [[ -n "$old" && ( "$old" == "$lat" || "$old" == "$prev" ) ]]; then
		_fail "$ch Older must differ from Latest/Previous"
	elif [[ -n "$old" ]]; then
		_pass "$ch Older ≠ Latest/Previous"
	fi

	if [[ -n "$prev" ]] && is_version_greater "$lat" "$prev"; then
		_pass "$ch Latest > Previous"
	elif [[ -n "$prev" ]]; then
		_fail "$ch expected Latest ($lat) > Previous ($prev)"
	fi

	if [[ -n "$old" && -n "$prev" ]]; then
		if is_version_greater "$prev" "$old"; then
			_pass "$ch Previous > Older"
		else
			_fail "$ch expected Previous ($prev) > Older ($old)"
		fi
	fi
}

# --- stable / fast: CDN tip + next-major GA peek ---
for ch in stable fast; do
	echo ""
	echo "--- channel: $ch ---"
	lat=$(fetch_latest_version "$ch") || true
	prev=$(fetch_previous_version "$ch") || true
	old=$(fetch_older_version "$ch") || true
	echo "  Latest=$lat Previous=$prev Older=$old"

	_assert_common_ladder "$ch" "$lat" "$prev" "$old" 1 || continue

	# Peek invariant: if next-major GA exists above CDN tip, Latest must be it.
	cdn_minor=$(fetch_latest_minor_version "$ch") || true
	cdn_tip=$(fetch_all_versions "$ch" "$cdn_minor" | tail -n1) || true
	peek=$(_peek_next_major_ga "$ch" "$cdn_minor" "$cdn_tip") || true
	if [[ -n "$peek" ]]; then
		if [[ "$lat" == "$peek" ]]; then
			_pass "$ch Latest matches next-major GA peek ($peek)"
		else
			_fail "$ch Latest ($lat) should be peek ($peek)"
		fi
		if [[ "$prev" == "$cdn_tip" ]]; then
			_pass "$ch Previous is CDN tip while peeking ($cdn_tip)"
		else
			_fail "$ch Previous ($prev) should be CDN tip ($cdn_tip) while peeking"
		fi
	else
		_pass "$ch no next-major GA peek (CDN tip is channel head)"
	fi

	# Cross-major at X.0: if CDN minor is N.0, Previous major must be N-1
	cdn_y="${cdn_minor#*.}"
	cdn_x="${cdn_minor%%.*}"
	if [[ "$cdn_y" == "0" && -n "$prev" ]]; then
		prev_maj="${prev%%.*}"
		expect=$(( cdn_x - 1 ))
		if [[ "$prev_maj" == "$expect" ]]; then
			_pass "$ch at $cdn_minor Previous major is $expect ($prev)"
		else
			_fail "$ch at $cdn_minor Previous major should be $expect got $prev"
		fi
	fi
done

# --- candidate: _candidate_offer lines 1/2/3 (Older optional) ---
echo ""
echo "--- channel: candidate ---"
ch=candidate
lat=$(fetch_latest_version "$ch") || true
prev=$(fetch_previous_version "$ch") || true
old=$(fetch_older_version "$ch") || true
echo "  Latest=$lat Previous=$prev Older=$old"

_assert_common_ladder "$ch" "$lat" "$prev" "$old" 0

# Offer list is the source of truth for candidate tips.
mapfile -t _offer < <(_candidate_offer || true)
_offer_n=${#_offer[@]}
echo "  offer (${_offer_n}): ${_offer[*]:-}"

if [[ $_offer_n -ge 1 ]]; then
	if [[ "$lat" == "${_offer[0]}" ]]; then
		_pass "candidate Latest == offer[0] (${_offer[0]})"
	else
		_fail "candidate Latest ($lat) != offer[0] (${_offer[0]})"
	fi
fi
if [[ $_offer_n -ge 2 ]]; then
	if [[ "$prev" == "${_offer[1]}" ]]; then
		_pass "candidate Previous == offer[1] (${_offer[1]})"
	else
		_fail "candidate Previous ($prev) != offer[1] (${_offer[1]})"
	fi
fi
if [[ $_offer_n -ge 3 ]]; then
	if [[ "$old" == "${_offer[2]}" ]]; then
		_pass "candidate Older == offer[2] (${_offer[2]})"
	else
		_fail "candidate Older ($old) != offer[2] (${_offer[2]})"
	fi
elif [[ -z "$old" ]]; then
	_pass "candidate Older empty matches offer size $_offer_n"
elif [[ -n "$old" ]]; then
	_fail "candidate Older ($old) set but offer size is $_offer_n"
fi

echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
