#!/bin/bash
# Test: rough mirror duration from the imageset size estimate.
# Regression for: the fixed "5 to 20 minutes" line during save, sync, and load.

cd "$(dirname "$0")/../.." || exit 1
# shellcheck disable=SC1091
source scripts/include_all.sh 2>/dev/null
export INFO_ABA=1

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }

echo "=== mirror ETA ==="

GIB=$(( 1024 * 1024 * 1024 ))
# Fixed clock so the finish time does not depend on when the test runs.
export ABA_MIRROR_ETA_NOW=1760000000
_finish() {
	date -d "@$(( ABA_MIRROR_ETA_NOW + $1 * 60 ))" "+%b %-d %H:%M"
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# Do not read or write the real ~/.aba/mirror-rate.sh.
export ABA_MIRROR_RATE_FILE="$work/rate.sh"
unset ABA_MIRROR_ETA_BYTES

# No imageset in this directory, and no byte count: keep the old sentence.
out=$(cd "$work" && aba_mirror_eta save)
printf '%s\n' "$out" | grep -q '5 to 20 minutes or more' \
	&& _pass "missing estimate keeps the fixed sentence" \
	|| _fail "missing estimate (got: $out)"

bytes22=$(( 22 * GIB ))
finish40=$(_finish 40)
out=$(aba_mirror_eta save "$bytes22")
expect="[ABA] About 40 minutes for ~22 GB at a rate of 10MB/s, if the cache is empty. Rough finish: ${finish40}. Cached images finish sooner."
[ "$out" = "$expect" ] && _pass "save 22 GB is about 40 minutes" || _fail "save 22 GB (got: $out)"

out=$(aba_mirror_eta sync "$bytes22")
expect="[ABA] About 40 minutes for ~22 GB at a rate of 10MB/s. Rough finish: ${finish40}."
[ "$out" = "$expect" ] && _pass "sync 22 GB has no cache clause" || _fail "sync 22 GB (got: $out)"

finish10=$(_finish 10)
out=$(aba_mirror_eta load "$bytes22")
expect="[ABA] About 10 minutes to copy ~22 GB into the registry at a rate of 40MB/s. Rough finish: ${finish10}."
[ "$out" = "$expect" ] && _pass "load 22 GB is a short local copy" || _fail "load 22 GB (got: $out)"

out=$(aba_mirror_eta save $(( 1024 * 1024 )))
finish5=$(_finish 5)
expect="[ABA] About 5 minutes for ~1 MB at a rate of 10MB/s, if the cache is empty. Rough finish: ${finish5}. Cached images finish sooner."
[ "$out" = "$expect" ] && _pass "tiny save stays at 5 minutes" || _fail "tiny save (got: $out)"

bytes100=$(( 100 * GIB ))
out=$(aba_mirror_eta sync "$bytes100")
finish165=$(_finish 165)
expect="[ABA] About 165 minutes for ~100 GB at a rate of 10MB/s. Rough finish: ${finish165}."
[ "$out" = "$expect" ] && _pass "100 GB rounds to 15-minute steps" || _fail "100 GB (got: $out)"

out=$(aba_mirror_eta save 0)
printf '%s\n' "$out" | grep -q '5 to 20 minutes or more' \
	&& _pass "zero bytes keeps the fixed sentence" \
	|| _fail "zero bytes (got: $out)"

out=$(aba_mirror_eta bogus "$bytes22")
printf '%s\n' "$out" | grep -q '5 to 20 minutes or more' \
	&& _pass "unknown op keeps the fixed sentence" \
	|| _fail "unknown op (got: $out)"

# 1050 MB in 100s is exactly 10MB/s, and a few seconds of clock skew stays 10.
export ABA_MIRROR_ETA_BYTES=$(( 1050 * 1024 * 1024 ))
_ABA_MIRROR_T0=$(( $(date +%s) - 100 ))
aba_mirror_time_stop save
saved=$(sed -n 's/^network_mb_s=//p' "$ABA_MIRROR_RATE_FILE")
[ "$saved" = "10" ] && _pass "100s for 1050 MB records 10MB/s" || _fail "recorded rate (got: $saved)"
got=$(sed -n 's/^network_op=//p' "$ABA_MIRROR_RATE_FILE")
[ "$got" = "save" ] && _pass "save records the network op" || _fail "recorded op (got: $got)"

_ABA_MIRROR_T0=$(( $(date +%s) - 100 ))
aba_mirror_time_stop load
got=$(sed -n 's/^local_mb_s=//p' "$ABA_MIRROR_RATE_FILE")
[ "$got" = "10" ] && _pass "load records its own rate" || _fail "load rate (got: $got)"
got=$(sed -n 's/^local_op=//p' "$ABA_MIRROR_RATE_FILE")
[ "$got" = "load" ] && _pass "load records the local op" || _fail "local op (got: $got)"
got=$(sed -n 's/^network_mb_s=//p' "$ABA_MIRROR_RATE_FILE")
[ "$got" = "$saved" ] && _pass "load leaves the network rate alone" || _fail "network rate after load (got: $got)"

# A later sync replaces the network rate and leaves the load rate.
_ABA_MIRROR_T0=$(( $(date +%s) - 100 ))
aba_mirror_time_stop sync
got=$(sed -n 's/^network_op=//p' "$ABA_MIRROR_RATE_FILE")
[ "$got" = "sync" ] && _pass "sync replaces the network op" || _fail "network op after sync (got: $got)"
got=$(sed -n 's/^local_mb_s=//p' "$ABA_MIRROR_RATE_FILE")
[ "$got" = "10" ] && _pass "sync leaves the load rate alone" || _fail "load rate after sync (got: $got)"

unset ABA_MIRROR_ETA_BYTES
printf 'network_mb_s=20\nnetwork_op=sync\nlocal_mb_s=\nlocal_op=\n' > "$ABA_MIRROR_RATE_FILE"
out=$(aba_mirror_eta save "$bytes22")
finish20=$(_finish 20)
expect="[ABA] About 20 minutes for ~22 GB at a rate of 20MB/s (from the last sync), if the cache is empty. Rough finish: ${finish20}. Cached images finish sooner."
[ "$out" = "$expect" ] && _pass "next save uses the learned rate" || _fail "learned save (got: $out)"

printf 'network_mb_s=12\nnetwork_op=save\nlocal_mb_s=\nlocal_op=\n' > "$ABA_MIRROR_RATE_FILE"
out=$(aba_mirror_eta sync "$bytes22")
finish30=$(_finish 30)
expect="[ABA] About 30 minutes for ~22 GB at a rate of 12MB/s (from the last save). Rough finish: ${finish30}."
[ "$out" = "$expect" ] && _pass "next sync uses the learned rate" || _fail "learned sync (got: $out)"

# A load rate must not speed up the next download, and a download rate must not slow the next load.
printf 'network_mb_s=\nnetwork_op=\nlocal_mb_s=15\nlocal_op=load\n' > "$ABA_MIRROR_RATE_FILE"
out=$(aba_mirror_eta save "$bytes22")
expect="[ABA] About 40 minutes for ~22 GB at a rate of 10MB/s, if the cache is empty. Rough finish: ${finish40}. Cached images finish sooner."
[ "$out" = "$expect" ] && _pass "a load rate does not change save" || _fail "save ignored load rate (got: $out)"
out=$(aba_mirror_eta load "$bytes22")
finish25=$(_finish 25)
expect="[ABA] About 25 minutes to copy ~22 GB into the registry at a rate of 15MB/s (from the last load). Rough finish: ${finish25}."
[ "$out" = "$expect" ] && _pass "next load uses its own rate" || _fail "learned load (got: $out)"

printf 'network_mb_s=12\nnetwork_op=save\nlocal_mb_s=\nlocal_op=\n' > "$ABA_MIRROR_RATE_FILE"
out=$(aba_mirror_eta load "$bytes22")
expect="[ABA] About 10 minutes to copy ~22 GB into the registry at a rate of 40MB/s. Rough finish: ${finish10}."
[ "$out" = "$expect" ] && _pass "a save rate does not change load" || _fail "load ignored save rate (got: $out)"

# Junk in the rate file is ignored. It is not executed.
printf 'network_mb_s=fast\nnetwork_op=save\n' > "$ABA_MIRROR_RATE_FILE"
out=$(aba_mirror_eta save "$bytes22")
expect="[ABA] About 40 minutes for ~22 GB at a rate of 10MB/s, if the cache is empty. Rough finish: ${finish40}. Cached images finish sooner."
[ "$out" = "$expect" ] && _pass "a non-numeric rate falls back to 10MB/s" || _fail "junk rate (got: $out)"

printf 'network_mb_s=0\nnetwork_op=save\n' > "$ABA_MIRROR_RATE_FILE"
out=$(aba_mirror_eta sync "$bytes22")
expect="[ABA] About 40 minutes for ~22 GB at a rate of 10MB/s. Rough finish: ${finish40}."
[ "$out" = "$expect" ] && _pass "a zero rate falls back to 10MB/s" || _fail "zero rate (got: $out)"

printf 'network_mb_s=20\nnetwork_op=evil\n' > "$ABA_MIRROR_RATE_FILE"
out=$(aba_mirror_eta save "$bytes22")
expect="[ABA] About 20 minutes for ~22 GB at a rate of 20MB/s (from the last save), if the cache is empty. Rough finish: ${finish20}. Cached images finish sooner."
[ "$out" = "$expect" ] && _pass "a bad op name is not printed" || _fail "bad op (got: $out)"

# One byte per second is stored as 1MB/s. The duration still floors at 5 minutes for a tiny set,
# and a 22 GB set at that rate is 390 minutes.
rm -f "$ABA_MIRROR_RATE_FILE"
export ABA_MIRROR_ETA_BYTES=$(( 1024 * 1024 ))
_ABA_MIRROR_T0=$(( $(date +%s) - 100 ))
aba_mirror_time_stop save
got=$(sed -n 's/^network_mb_s=//p' "$ABA_MIRROR_RATE_FILE")
[ "$got" = "1" ] && _pass "a slow sample is stored as 1MB/s" || _fail "slow sample (got: $got)"
unset ABA_MIRROR_ETA_BYTES
out=$(aba_mirror_eta save "$bytes22")
finish390=$(_finish 390)
expect="[ABA] About 390 minutes for ~22 GB at a rate of 1MB/s (from the last save), if the cache is empty. Rough finish: ${finish390}. Cached images finish sooner."
[ "$out" = "$expect" ] && _pass "1MB/s stretches a 22 GB save to 390 minutes" || _fail "slow save (got: $out)"
out=$(aba_mirror_eta save $(( 1024 * 1024 )))
expect="[ABA] About 5 minutes for ~1 MB at a rate of 1MB/s (from the last save), if the cache is empty. Rough finish: ${finish5}. Cached images finish sooner."
[ "$out" = "$expect" ] && _pass "learned rate still floors at 5 minutes" || _fail "learned floor (got: $out)"

# Nothing to time, nothing to write, and a bad sample must not replace a good one.
printf 'network_mb_s=7\nnetwork_op=save\nlocal_mb_s=40\nlocal_op=load\n' > "$ABA_MIRROR_RATE_FILE"
cp "$ABA_MIRROR_RATE_FILE" "$work/good.sh"
unset _ABA_MIRROR_T0
aba_mirror_time_stop save
cmp -s "$ABA_MIRROR_RATE_FILE" "$work/good.sh" && _pass "stop without start writes nothing" || _fail "stop without start changed the file"

_ABA_MIRROR_T0=$(( $(date +%s) + 120 ))
aba_mirror_time_stop save
cmp -s "$ABA_MIRROR_RATE_FILE" "$work/good.sh" && _pass "a clock going backwards writes nothing" || _fail "future clock changed the file"

export ABA_MIRROR_ETA_BYTES=0
_ABA_MIRROR_T0=$(( $(date +%s) - 100 ))
aba_mirror_time_stop save
cmp -s "$ABA_MIRROR_RATE_FILE" "$work/good.sh" && _pass "a zero estimate writes nothing" || _fail "zero estimate changed the file"

export ABA_MIRROR_ETA_BYTES=abc
aba_mirror_time_stop save
cmp -s "$ABA_MIRROR_RATE_FILE" "$work/good.sh" && _pass "a bad estimate writes nothing" || _fail "bad estimate changed the file"

aba_mirror_time_stop nope
cmp -s "$ABA_MIRROR_RATE_FILE" "$work/good.sh" && _pass "an unknown op writes nothing" || _fail "unknown op changed the file"
unset ABA_MIRROR_ETA_BYTES

# A new start drops a stale clock, so the next stop cannot use the old interval.
_ABA_MIRROR_T0=$(( $(date +%s) - 5000 ))
aba_mirror_time_start
aba_mirror_time_stop save
cmp -s "$ABA_MIRROR_RATE_FILE" "$work/good.sh" && _pass "a fresh start drops a stale clock" || _fail "stale clock was recorded"

# The second stop has no clock left.
aba_mirror_time_stop save
cmp -s "$ABA_MIRROR_RATE_FILE" "$work/good.sh" && _pass "a second stop does not record again" || _fail "second stop changed the file"

# The imageset estimator is the byte source when no override is set.
# A platform-only set is 22 GiB plus 5%, which is ~23 GB and 86MB/s over 272s.
unset ABA_MIRROR_ETA_BYTES _ABA_MIRROR_T0
mkdir -p "$work/isc/data"
cat > "$work/isc/data/imageset-config.yaml" << 'EOF'
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  platform:
    channels:
    - name: stable-4.22
      type: ocp
EOF
rm -f "$ABA_MIRROR_RATE_FILE"
out=$(cd "$work/isc" && aba_mirror_eta save)
expect="[ABA] About 40 minutes for ~23 GB at a rate of 10MB/s, if the cache is empty. Rough finish: ${finish40}. Cached images finish sooner."
[ "$out" = "$expect" ] && _pass "a platform imageset is about 40 minutes" || _fail "imageset eta (got: $out)"
_ABA_MIRROR_T0=$(( $(date +%s) - 272 ))
( cd "$work/isc" && aba_mirror_time_stop sync )
got=$(sed -n 's/^network_mb_s=//p' "$ABA_MIRROR_RATE_FILE")
[ "$got" = "86" ] && _pass "stop uses the imageset estimate" || _fail "imageset rate (got: $got)"
got=$(sed -n 's/^network_op=//p' "$ABA_MIRROR_RATE_FILE")
[ "$got" = "sync" ] && _pass "imageset sample records sync" || _fail "imageset op (got: $got)"
unset _ABA_MIRROR_T0

# Missing imageset: do not invent a rate.
rm -f "$ABA_MIRROR_RATE_FILE"
_ABA_MIRROR_T0=$(( $(date +%s) - 100 ))
( cd "$work" && aba_mirror_time_stop save )
[ ! -f "$ABA_MIRROR_RATE_FILE" ] && _pass "no imageset writes nothing" || _fail "missing imageset wrote a rate"
unset _ABA_MIRROR_T0

# Parent directories of the rate file are created.
export ABA_MIRROR_RATE_FILE="$work/nested/rate.sh"
export ABA_MIRROR_ETA_BYTES=$(( 1050 * 1024 * 1024 ))
_ABA_MIRROR_T0=$(( $(date +%s) - 100 ))
aba_mirror_time_stop save
[ -f "$work/nested/rate.sh" ] && _pass "stop creates the rate directory" || _fail "nested rate file missing"
export ABA_MIRROR_RATE_FILE="$work/rate.sh"
unset ABA_MIRROR_ETA_BYTES _ABA_MIRROR_T0

# These early returns must not trip set -e or set -u.
(
	set -euo pipefail
	export ABA_MIRROR_RATE_FILE="$work/nounset.sh"
	unset ABA_MIRROR_ETA_BYTES _ABA_MIRROR_T0
	aba_mirror_time_start
	aba_mirror_time_stop save
	aba_mirror_time_stop
	aba_mirror_eta save "" >/dev/null
	aba_mirror_eta load "$bytes22" >/dev/null
) && _pass "start, stop, and eta survive set -e and set -u" || _fail "set -euo pipefail aborted a guess"

# The guess is printed before oc-mirror. The clock starts on every attempt
# and is stored only after that attempt exits 0.
save_eta=$(grep -n 'aba_mirror_eta save' scripts/reg-save.sh | head -1 | cut -d: -f1)
save_run=$(grep -n '_run_oc_mirror_with_retry "save"' scripts/reg-save.sh | head -1 | cut -d: -f1)
[ "$save_eta" -lt "$save_run" ] && _pass "save prints the guess before oc-mirror" || _fail "save call order"
sync_eta=$(grep -n 'aba_mirror_eta sync' scripts/reg-sync.sh | head -1 | cut -d: -f1)
sync_run=$(grep -n '_run_oc_mirror_with_retry "sync"' scripts/reg-sync.sh | head -1 | cut -d: -f1)
[ "$sync_eta" -lt "$sync_run" ] && _pass "sync prints the guess before oc-mirror" || _fail "sync call order"
load_eta=$(grep -n 'aba_mirror_eta load' scripts/reg-load.sh | head -1 | cut -d: -f1)
load_run=$(grep -n '_run_oc_mirror_with_retry "load"' scripts/reg-load.sh | head -1 | cut -d: -f1)
[ "$load_eta" -lt "$load_run" ] && _pass "load prints the guess before oc-mirror" || _fail "load call order"
awk '
	index($0, "aba_mirror_time_start") { s = NR }
	index($0, "eval \"$cmd\"") { e = NR }
	index($0, "if [ $ret -eq 0 ]") { k = NR }
	index($0, "aba_mirror_time_stop") { t = NR }
	END { exit !(s && e && k && t && s < e && e < k && k < t && t - k < 5) }
' scripts/include_all.sh \
	&& _pass "the clock stops only after exit 0" \
	|| _fail "timer is not wrapped around a successful oc-mirror"

# Drive the real retry function with a stand-in command. try_tot stays 1:
# a retry would kill whatever is listening on port 55000.
mkdir -p "$work/mirror/data"
cat > "$work/fake.sh" << 'EOF'
#!/bin/bash
sleep 2
exit 0
EOF
_wrap() {
	local rate=$1 action=$2 cmd=$3
	local rc
	(
		cd "$work/mirror" || exit 97
		export ABA_MIRROR_RATE_FILE="$rate"
		export ABA_MIRROR_ETA_BYTES=$(( 100 * 1024 * 1024 ))
		export OC_MIRROR_PIN_CATALOGS=0
		unset _ABA_MIRROR_T0
		_run_oc_mirror_with_retry "$action" 1 "$cmd"
	) >"$work/wrap.log" 2>&1
	rc=$?
	printf '%s\n' "$rc"
}
rm -f "$work/wrap-rate.sh"
rc=$(_wrap "$work/wrap-rate.sh" save "bash $work/missing.sh")
[ "$rc" -ne 0 ] && [ ! -f "$work/wrap-rate.sh" ] \
	&& _pass "a failed oc-mirror records nothing" \
	|| _fail "failed wrap rc=$rc file=$([ -f "$work/wrap-rate.sh" ] && echo yes || echo no)"

rc=$(_wrap "$work/wrap-rate.sh" save "bash $work/fake.sh")
got=$(sed -n 's/^network_mb_s=//p' "$work/wrap-rate.sh")
# 100 MB in about 2s. A slow machine can land anywhere in this band.
if [ "$rc" -eq 0 ] && [ "$got" -ge 20 ] && [ "$got" -le 50 ]; then
	_pass "a successful save records about 50MB/s"
else
	_fail "save wrap rc=$rc rate=${got:-missing}"
	tail -n 15 "$work/wrap.log"
fi
got=$(sed -n 's/^network_op=//p' "$work/wrap-rate.sh")
[ "$got" = "save" ] && _pass "the wrapper records save" || _fail "wrapper op (got: $got)"

rm -f "$work/wrap-rate.sh"
rc=$(_wrap "$work/wrap-rate.sh" load "bash $work/fake.sh")
got=$(sed -n 's/^local_mb_s=//p' "$work/wrap-rate.sh")
net=$(sed -n 's/^network_mb_s=//p' "$work/wrap-rate.sh")
if [ "$rc" -eq 0 ] && [ "$got" -ge 20 ] && [ "$got" -le 50 ] && [ -z "$net" ]; then
	_pass "a successful load records only the local rate"
else
	_fail "load wrap rc=$rc local=${got:-missing} network=${net:-empty}"
	tail -n 15 "$work/wrap.log"
fi

# A failing guess must not abort the caller.
set -e
aba_mirror_eta save "" >/dev/null
aba_mirror_time_start
aba_mirror_time_stop
aba_mirror_time_stop nope
set +e
_pass "empty bytes returns 0 under set -e"

echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
