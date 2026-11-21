# =============================================================================
# Code-update coverage — "all suites passed since last code update"
# =============================================================================
# After a source deploy (auto-deploy from origin/dev OR --dev dirty tarball),
# track suite PASSes that complete under that code stamp. When every real
# suite (all_suite_names) has PASSed under the stamp, notify:
#
#   All suites passed since last code update (…)
#
# The passed ledger is cleared after each successful notify so a later --loop
# round (or another full --all pass) can claim again — intentional repeat.
#
# State dir (override with E2E_CODE_COV_DIR for tests):
#   stamp   — "<checksum> <note>"
#   passed  — one suite name per line
# =============================================================================

E2E_CODE_COV_DIR="${E2E_CODE_COV_DIR:-/tmp/e2e-code-cov}"

_e2e_cov_stamp_file() { echo "${E2E_CODE_COV_DIR}/stamp"; }
_e2e_cov_passed_file() { echo "${E2E_CODE_COV_DIR}/passed"; }

# Ensure the state directory exists.
_e2e_cov_init() {
	mkdir -p "$E2E_CODE_COV_DIR" || return 1
}

# Current stamp checksum (first field), or empty.
_e2e_cov_current_stamp() {
	local f
	f=$(_e2e_cov_stamp_file)
	[ -f "$f" ] || { echo ""; return 0; }
	awk '{print $1; exit}' "$f" 2>/dev/null || echo ""
}

# Human note from stamp file (rest of line after checksum + date fields), or checksum short.
_e2e_cov_stamp_label() {
	local f _line _ck _note
	f=$(_e2e_cov_stamp_file)
	[ -f "$f" ] || { echo "unknown"; return 0; }
	_line=$(cat "$f" 2>/dev/null) || { echo "unknown"; return 0; }
	_ck=$(echo "$_line" | awk '{print $1}')
	# Format: "<cksum> <date> <time> [note...]"
	_note=$(echo "$_line" | awk '{for (i=4; i<=NF; i++) printf "%s%s", (i>4?" ":""), $i}')
	if [ -n "$_note" ]; then
		echo "$_note"
	else
		echo "$_ck" | head -c 12
	fi
}

# Reset coverage for a new code stamp. Called when deploy fingerprint changes.
# Usage: _e2e_cov_reset <checksum> [note]
_e2e_cov_reset() {
	local cksum="$1" note="${2:-}"
	_e2e_cov_init || return 1
	if [ -n "$note" ]; then
		echo "$cksum $(date '+%Y-%m-%d %H:%M:%S') $note" > "$(_e2e_cov_stamp_file)"
	else
		echo "$cksum $(date '+%Y-%m-%d %H:%M:%S')" > "$(_e2e_cov_stamp_file)"
	fi
	: > "$(_e2e_cov_passed_file)"
	echo "    CODE-COV: reset for new code update (${note:-$cksum})"
}

# Hook from _record_source_deploy: reset ledger only when checksum changes.
# Usage: _e2e_cov_on_deploy <checksum> [note]
_e2e_cov_on_deploy() {
	local cksum="$1" note="${2:-}"
	local _old
	[ -n "$cksum" ] || return 0
	_e2e_cov_init || return 0
	_old=$(_e2e_cov_current_stamp)
	if [ "$cksum" = "$_old" ]; then
		return 0
	fi
	_e2e_cov_reset "$cksum" "$note"
}

# Expected suite names for "all" (real suites; dummy-* excluded unless CLI_WITH_DUMMY).
# Prints one name per line.
_e2e_cov_expected_suites() {
	local _dir="${_RUN_DIR:-}"
	if [ -z "$_dir" ] && [ -n "${_ABA_ROOT:-}" ]; then
		_dir="$_ABA_ROOT/test/e2e"
	fi
	if [ -z "$_dir" ] || [ ! -d "$_dir/suites" ]; then
		return 1
	fi
	# Prefer all_suite_names when available (same --all filter).
	if declare -F all_suite_names >/dev/null 2>&1; then
		# shellcheck disable=SC2046
		printf '%s\n' $(all_suite_names "$_dir")
		return 0
	fi
	local f name
	for f in "$_dir/suites/"suite-*.sh; do
		[ -f "$f" ] || continue
		name="$(basename "$f" .sh)"
		name="${name#suite-}"
		if [ -z "${CLI_WITH_DUMMY:-}" ] && [[ "$name" == dummy-* ]]; then
			continue
		fi
		printf '%s\n' "$name"
	done
}

# True if every expected suite appears in the passed ledger.
_e2e_cov_is_complete() {
	local _exp _pfile _s _n=0
	_pfile=$(_e2e_cov_passed_file)
	[ -f "$(_e2e_cov_stamp_file)" ] || return 1
	[ -f "$_pfile" ] || return 1
	while IFS= read -r _s; do
		[ -n "$_s" ] || continue
		_n=$(( _n + 1 ))
		grep -qxF "$_s" "$_pfile" 2>/dev/null || return 1
	done < <(_e2e_cov_expected_suites)
	[ "$_n" -gt 0 ]
}

# Record a suite PASS under the current stamp. Notify (and clear ledger) when
# the full expected set is covered — clearing allows the claim to repeat.
# Usage: _e2e_cov_record_pass <suite_name>
_e2e_cov_record_pass() {
	local suite="$1"
	local _pfile _stamp
	[ -n "$suite" ] || return 0
	_e2e_cov_init || return 0
	_stamp=$(_e2e_cov_current_stamp)
	if [ -z "$_stamp" ]; then
		# No deploy stamp yet — nothing to attribute.
		return 0
	fi
	_pfile=$(_e2e_cov_passed_file)
	touch "$_pfile"
	if ! grep -qxF "$suite" "$_pfile" 2>/dev/null; then
		echo "$suite" >> "$_pfile"
	fi
	_e2e_cov_notify_if_complete
}

# If coverage is complete, notify and clear the passed ledger so a later full
# cycle can claim again (repeat is intentional).
_e2e_cov_notify_if_complete() {
	local _label _msg _n_exp _n_pass
	_e2e_cov_is_complete || return 0

	_label=$(_e2e_cov_stamp_label)
	_n_exp=$(_e2e_cov_expected_suites | grep -c . || echo 0)
	_n_pass=$(grep -c . "$(_e2e_cov_passed_file)" 2>/dev/null || echo 0)
	_msg="[e2e] All suites passed since last code update (${_label}, ${_n_pass}/${_n_exp})"

	echo "    CODE-COV: $_msg"
	if [ -n "${NOTIFY_CMD:-}" ]; then
		# shellcheck disable=SC2086
		$NOTIFY_CMD "$_msg" < /dev/null >/dev/null 2>&1 &
	fi

	# Clear so the next full green cycle can notify again.
	: > "$(_e2e_cov_passed_file)"
}
