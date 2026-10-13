# Redfish HTTP wrapper library for Phase 6 BMC-driven boot.
# Sourced (not executed): no shebang, not chmod +x.
# Dependencies: aba_* output primitives + normalize-bmc-conf (from scripts/include_all.sh).
#
# Public API:
#   _redfish_request <node> <verb> <path> [body_file]
#     - Owns every curl call Phase 6 makes. Transparent 202-async polling (D-03)
#       and ETag-on-PATCH (D-04) inside. Caller reads _REDFISH_LAST_CODE /
#       _REDFISH_LAST_BODY / _REDFISH_LAST_REASON.
#   bmc_session_login <node>   (D-09: POST /redfish/v1/SessionService/Sessions, capture X-Auth-Token)
#   bmc_session_logout <node>  (D-09: DELETE session URI, unset session globals)
#
# Private helpers:
#   _redfish_poll_task  _redfish_patch  _bm_build_auth  _bm_insecure_flag
#   _redfish_sanitize_reason  _redfish_redact
#
# Invariants:
#   - Every counter uses var=$(( var + 1 )) (never (( var++ )); Phase 5 D-11).
#   - Every curl sets --max-time; failures normalize to code="000".
#   - jq only after HTTP 200 gate (no non-JSON feed to jq).
#   - Never `2>/dev/null`; stderr captured via `2>&1` into a local var.
#   - Authorization header built in-process via _bm_build_auth (never `curl -u`).
#   - Every emitted error string passes through _redfish_redact (Basic <tok> masked).

_REDFISH_LAST_CODE=""
_REDFISH_LAST_BODY=""
_REDFISH_LAST_REASON=""
_bm_patch_if_match_required=false

_bm_build_auth() {
	# Credential construction for BMC Authorization header. Single grep-able audit surface.
	# Arg: node name (bmc_host_<node> suffix).
	# Stdout: base64(user:pass) with NO trailing newline and NO line wrap.
	# Return: 0 on success; 1 on missing user/pass (with aba_warning).
	#
	# D-06 invariants:
	# - Every password read uses ${!pass_var} indirection (grep-auditable).
	# - printf (not echo) avoids trailing newline in the base64 input.
	# - base64 -w0 (not default) avoids 76-char line wrap breaking Authorization header.
	# - The plaintext password is local to this function's frame; bash discards it on return.

	local node="$1"
	local user_var="bmc_user_${node}"
	local pass_var="bmc_password_${node}"
	local user pass
	user="${!user_var}"
	pass="${!pass_var}"
	if [ -z "$user" ] || [ -z "$pass" ]; then
		aba_warning "BMC: $node bmc_user_${node} or bmc_password_${node} not set in bmc.conf"
		_REDFISH_LAST_REASON="bmc_user_${node} or bmc_password_${node} not set in bmc.conf"
		return 1
	fi
	printf '%s:%s' "$user" "$pass" | base64 -w0
}

_bm_insecure_flag() {
	local node="$1"
	local insecure_var="bmc_insecure_${node}"
	local insecure="${!insecure_var}"
	case "$insecure" in
		1|true|True|TRUE|yes|YES) printf '%s' "-k" ;;
		*) printf '%s' "" ;;
	esac
}

_redfish_redact() {
	# Mask any "Basic <base64>" strings that may have leaked into a captured curl stderr.
	# Phase 5 D-08 invariant.
	sed -E 's/Basic [A-Za-z0-9+/=]+/Basic [REDACTED]/'
}

_redfish_sanitize_reason() {
	# Collapse to one line, squeeze whitespace, strip leading/trailing space, cap 200 chars.
	printf '%s' "$1" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' | head -c 200
}

_redfish_poll_task() {
	local node="$1" task_uri="$2"
	local host_var="bmc_host_${node}"
	local host="${!host_var}"
	local insecure_flag
	insecure_flag=$(_bm_insecure_flag "$node")
	local tok_var="SESSION_TOKEN_${node}"
	local token="${!tok_var}"

	local elapsed=0 interval=2 max=150
	local state http
	local poll_tmp
	poll_tmp=$(mktemp /tmp/bmc_task_${node}.XXXXXX)
	while [ "$elapsed" -lt "$max" ]; do
		http=$(curl -s $insecure_flag -m 5 \
			-H "X-Auth-Token: $token" \
			-H "Accept: application/json" \
			-o "$poll_tmp" \
			-w '%{http_code}' \
			"https://$host$task_uri") || http="000"
		if [ "$http" = "200" ]; then
			state=$(jq -r '.TaskState // empty' "$poll_tmp")
			case "$state" in
				Completed)
					# Replace _REDFISH_LAST_BODY with the terminal task body.
					rm -f "$_REDFISH_LAST_BODY"
					_REDFISH_LAST_BODY="$poll_tmp"
					_REDFISH_LAST_CODE="204"
					return 0
					;;
				Exception|Killed|Cancelled)
					rm -f "$_REDFISH_LAST_BODY"
					_REDFISH_LAST_BODY="$poll_tmp"
					_REDFISH_LAST_CODE="500"
					local task_status
					task_status=$(jq -r '.TaskStatus // "Critical"' "$poll_tmp")
					_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "task $state ($task_status)")
					return 0
					;;
			esac
		elif [ "$http" = "404" ]; then
			# DSP0266 permits treating a 404 on a task URI as success (task expired after completion).
			rm -f "$poll_tmp"
			_REDFISH_LAST_CODE="204"
			return 0
		fi
		# Still running or transport hiccup: sleep + continue.
		sleep "$interval"
		elapsed=$(( elapsed + interval ))
	done
	# 150s timeout exhausted.
	rm -f "$poll_tmp"
	_REDFISH_LAST_CODE="504"
	_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "task timeout (150s)")
	return 0
}

_redfish_retryable() {
	# Returns 0 if the response code warrants retry per D-02.
	# Retryable: HTTP 5xx (500/502/503/504), synthetic 504 from task-poll timeout, HTTP 429, transport failure (code=000).
	# Non-retryable: 2xx/3xx (success), explicit 4xx (400/401/403/404/409), pre-call guard "0".
	case "$1" in
		500|502|503|504|429|000) return 0 ;;
		*) return 1 ;;
	esac
}

_redfish_patch_inner() {
	# ETag-aware PATCH round-trip (Phase 6 D-04). Invoked by _redfish_patch retry wrapper
	# and by _redfish_inner_request for PATCH verbs routed via _redfish_request. Sets
	# _REDFISH_LAST_CODE / _REDFISH_LAST_BODY / _REDFISH_LAST_REASON on every terminal
	# outcome; returns 0 on all terminal cases. Phase 7 D-01: retry envelope lives in the
	# caller (_redfish_patch or _redfish_request), not here.
	local node="$1" path="$2" body_file="$3"
	local host_var="bmc_host_${node}"
	local host="${!host_var}"
	local insecure_flag
	insecure_flag=$(_bm_insecure_flag "$node")
	local tok_var="SESSION_TOKEN_${node}"
	local token="${!tok_var}"

	# Step 1: GET to harvest ETag.
	local hdr_tmp get_code etag=""
	hdr_tmp=$(mktemp /tmp/bmc_etag_${node}.XXXXXX)
	get_code=$(curl -s $insecure_flag -m 5 \
		-H "X-Auth-Token: $token" \
		-H "Accept: application/json" \
		-D "$hdr_tmp" \
		-o /dev/null \
		-w '%{http_code}' \
		"https://$host$path") || get_code="000"
	if [ "$get_code" = "200" ]; then
		etag=$(grep -i '^ETag:' "$hdr_tmp" | sed -E 's/^[Ee][Tt][Aa][Gg]:[[:space:]]*//' | tr -d '\r\n')
	fi
	rm -f "$hdr_tmp"

	if [ -z "$etag" ] && [ "${_bm_patch_if_match_required:-false}" = "true" ]; then
		_REDFISH_LAST_CODE="0"
		_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "ETag required but not returned by GET $path")
		return 0
	fi

	# Step 2: PATCH with If-Match iff ETag captured.
	local resp_tmp hdr2_tmp code
	resp_tmp=$(mktemp /tmp/bmc_patch_${node}.XXXXXX)
	hdr2_tmp=$(mktemp /tmp/bmc_patch_hdr_${node}.XXXXXX)
	local patch_header_args=(-H "X-Auth-Token: $token" -H "Accept: application/json" -H "Content-Type: application/json")
	if [ -n "$etag" ]; then
		patch_header_args+=(-H "If-Match: $etag")
	fi
	code=$(curl -s $insecure_flag -m 15 \
		"${patch_header_args[@]}" \
		-X PATCH \
		--data-binary "@$body_file" \
		-D "$hdr2_tmp" \
		-o "$resp_tmp" \
		-w '%{http_code}' \
		"https://$host$path") || code="000"

	_REDFISH_LAST_CODE="$code"
	rm -f "$_REDFISH_LAST_BODY"
	_REDFISH_LAST_BODY="$resp_tmp"

	# 202 handoff to task poll.
	if [ "$code" = "202" ]; then
		local task_uri
		task_uri=$(grep -i '^Location:' "$hdr2_tmp" | sed -E 's/^[Ll]ocation:[[:space:]]*//' | tr -d '\r\n')
		rm -f "$hdr2_tmp"
		if [ -z "$task_uri" ]; then
			_REDFISH_LAST_CODE="504"
			_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "task Location header missing on 202")
			return 0
		fi
		_redfish_poll_task "$node" "$task_uri"
		return 0
	fi
	rm -f "$hdr2_tmp"

	# Non-2xx/3xx: populate reason from curl exit + body signal.
	case "$code" in
		2??|3??) : ;;
		000)
			_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "transport failure on PATCH $path")
			;;
		*)
			_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "HTTP $code on PATCH $path")
			;;
	esac
	return 0
}

_redfish_patch() {
	# ERR-01 retry envelope (D-01 / D-02 / D-03) around _redfish_patch_inner.
	# 3 attempts, 10s/20s/40s backoff on retryable codes; transparent to callers.
	# Silent during retries (D-04); UX-02 exhaustion line is the caller's responsibility.
	local attempt=1 sleep_s=10
	while : ; do
		_redfish_patch_inner "$@"
		if [ "$attempt" -ge 3 ] || ! _redfish_retryable "$_REDFISH_LAST_CODE"; then
			return 0
		fi
		sleep "$sleep_s"
		attempt=$(( attempt + 1 ))
		sleep_s=$(( sleep_s * 2 ))
	done
}

_redfish_inner_request() {
	# Single curl round-trip for GET / POST / DELETE. Extracted from the pre-Phase-7
	# _redfish_request body so the retry envelope wraps exactly one code path. Sets
	# _REDFISH_LAST_CODE / _REDFISH_LAST_BODY / _REDFISH_LAST_REASON on every terminal
	# outcome; returns 0 on all success/failure paths; returns 1 only on the pre-call
	# "no active session" / "unsupported verb" guards (non-retryable by construction).
	# PATCH verbs are delegated to _redfish_patch_inner (retry lives in the outer _redfish_request
	# envelope; no double-wrapping amplifies 3x3).
	local node="$1" verb="$2" path="$3" body_file="${4:-}"
	local host_var="bmc_host_${node}"
	local host="${!host_var}"
	local insecure_flag
	insecure_flag=$(_bm_insecure_flag "$node")
	local tok_var="SESSION_TOKEN_${node}"
	local token="${!tok_var}"

	# Session-login is the only verb that may be called without a token; enforce elsewhere.
	if [ -z "$token" ] && [ "$verb" != "LOGIN" ]; then
		_REDFISH_LAST_CODE="0"
		_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "no active session for $node - bmc_session_login must succeed first")
		return 1
	fi

	# PATCH goes through ETag-aware helper's inner body (outer retry envelope supplied by _redfish_request).
	if [ "$verb" = "PATCH" ]; then
		_redfish_patch_inner "$node" "$path" "$body_file"
		return 0
	fi

	local resp_tmp hdr_tmp code
	resp_tmp=$(mktemp /tmp/bmc_resp_${node}.XXXXXX)
	hdr_tmp=$(mktemp /tmp/bmc_hdr_${node}.XXXXXX)
	local err_tmp
	err_tmp=$(mktemp /tmp/bmc_err_${node}.XXXXXX)

	local curl_args=(-s $insecure_flag -m 15 -H "X-Auth-Token: $token" -H "Accept: application/json")
	case "$verb" in
		GET)
			code=$(curl "${curl_args[@]}" \
				-D "$hdr_tmp" \
				-o "$resp_tmp" \
				-w '%{http_code}' \
				"https://$host$path" 2>"$err_tmp") || code="000"
			;;
		POST)
			curl_args+=(-H "Content-Type: application/json" -X POST)
			if [ -n "$body_file" ]; then
				curl_args+=(--data-binary "@$body_file")
			else
				curl_args+=(--data-binary "{}")
			fi
			code=$(curl "${curl_args[@]}" \
				-D "$hdr_tmp" \
				-o "$resp_tmp" \
				-w '%{http_code}' \
				"https://$host$path" 2>"$err_tmp") || code="000"
			;;
		DELETE)
			curl_args+=(-X DELETE)
			code=$(curl "${curl_args[@]}" \
				-D "$hdr_tmp" \
				-o "$resp_tmp" \
				-w '%{http_code}' \
				"https://$host$path" 2>"$err_tmp") || code="000"
			;;
		*)
			rm -f "$resp_tmp" "$hdr_tmp" "$err_tmp"
			_REDFISH_LAST_CODE="0"
			_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "unsupported verb $verb in _redfish_request")
			return 1
			;;
	esac

	_REDFISH_LAST_CODE="$code"
	rm -f "$_REDFISH_LAST_BODY"
	_REDFISH_LAST_BODY="$resp_tmp"

	# 202 handoff to task poll (inline, not via _redfish_patch).
	if [ "$code" = "202" ]; then
		local task_uri
		task_uri=$(grep -i '^Location:' "$hdr_tmp" | sed -E 's/^[Ll]ocation:[[:space:]]*//' | tr -d '\r\n')
		rm -f "$hdr_tmp" "$err_tmp"
		if [ -z "$task_uri" ]; then
			_REDFISH_LAST_CODE="504"
			_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "task Location header missing on 202")
			return 0
		fi
		_redfish_poll_task "$node" "$task_uri"
		return 0
	fi
	rm -f "$hdr_tmp"

	case "$code" in
		2??|3??)
			rm -f "$err_tmp"
			;;
		000)
			local err_txt
			err_txt=$(cat "$err_tmp" | _redfish_redact)
			rm -f "$err_tmp"
			_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "transport failure: $err_txt")
			;;
		*)
			rm -f "$err_tmp"
			_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "HTTP $code on $verb $path")
			;;
	esac
	return 0
}

_redfish_request() {
	# ERR-01 retry envelope: 3 attempts, 10s/20s/40s backoff on retryable codes (D-02/D-03).
	# Transparent to callers: _REDFISH_LAST_CODE/_BODY/_REASON reflect the final attempt only.
	# Silent during retries (D-04); UX-02 exhaustion line is the caller's responsibility.
	local attempt=1 sleep_s=10
	while : ; do
		_redfish_inner_request "$@"
		if [ "$attempt" -ge 3 ] || ! _redfish_retryable "$_REDFISH_LAST_CODE"; then
			return 0
		fi
		sleep "$sleep_s"
		attempt=$(( attempt + 1 ))
		sleep_s=$(( sleep_s * 2 ))
	done
}

_bm_delete_session() {
	# ERR-04 helper. Best-effort DELETE of a persisted Redfish session for <node>.
	# Reads .bmc-session.<node> (two lines: token, uri), issues DELETE with 10s timeout.
	# Narrow `>/dev/null 2>&1` is the sole CLAUDE.md exception class: cleanup-path curl
	# whose exit is reported via return code, not stderr (matches scripts/list-operators.sh:53 pattern).
	local node="$1" tok uri
	[ -f ".bmc-session.$node" ] || return 0
	{ read -r tok; read -r uri; } < ".bmc-session.$node"
	[ -n "$tok" ] && [ -n "$uri" ] || return 0
	local host_var="bmc_host_${node}"
	local host="${!host_var}"
	local insecure_flag
	insecure_flag=$(_bm_insecure_flag "$node")
	curl -s $insecure_flag -m 10 \
		-H "X-Auth-Token: $tok" \
		-X DELETE \
		-o /dev/null \
		-w '%{http_code}' \
		"https://$host$uri" >/dev/null 2>&1 || return 1
}

_bm_session_write_tempfile() {
	# ERR-04 helper. Atomically persist the live session for <node> to .bmc-session.<node>
	# with mode 0600. Content is two lines: X-Auth-Token, session URI.
	# Parent process sources include_all.sh which runs `umask 077` globally (line 259);
	# subshell umask 077 is belt-and-braces defense at the call-site.
	local node="$1"
	local tok_var="SESSION_TOKEN_${node}"
	local uri_var="SESSION_URI_${node}"
	local f=".bmc-session.${node}"
	( umask 077; printf '%s\n%s\n' "${!tok_var}" "${!uri_var}" > "${f}.new" && mv -f "${f}.new" "$f" )
}

bmc_session_login() {
	local node="$1"
	local host_var="bmc_host_${node}"
	local type_var="bmc_type_${node}"
	local user_var="bmc_user_${node}"
	local pass_var="bmc_password_${node}"
	local host="${!host_var}"
	local adapter="${!type_var}"
	local user="${!user_var}"
	local pass="${!pass_var}"

	# D-21: if a stale session tempfile exists from a crashed prior run, DELETE it best-effort
	# before we allocate a new session. Does NOT block login on DELETE failure (a dead session
	# returning 401 is the expected case; MaxSessions exhaustion is addressed by this cleanup).
	if [ -f ".bmc-session.$node" ]; then
		_bm_delete_session "$node" || aba_debug "BMC: $node stale session DELETE failed (session may have been invalid already)"
		rm -f ".bmc-session.$node"
	fi

	local auth
	auth=$(_bm_build_auth "$node") || {
		aba_warning "BMC: $node phase=session-login adapter=$adapter http=0 reason=\"$_REDFISH_LAST_REASON\""
		return 1
	}

	local insecure_flag
	insecure_flag=$(_bm_insecure_flag "$node")

	# Build body in a tempfile via jq --arg (no shell-quoting traps on passwords with special chars).
	local body_tmp hdr_tmp resp_tmp err_tmp code
	body_tmp=$(mktemp /tmp/bmc_login_body_${node}.XXXXXX)
	hdr_tmp=$(mktemp /tmp/bmc_login_hdr_${node}.XXXXXX)
	resp_tmp=$(mktemp /tmp/bmc_login_resp_${node}.XXXXXX)
	err_tmp=$(mktemp /tmp/bmc_login_err_${node}.XXXXXX)
	jq -n --arg u "$user" --arg p "$pass" '{UserName:$u, Password:$p}' > "$body_tmp"

	code=$(curl -s $insecure_flag -m 10 \
		-H "Authorization: Basic $auth" \
		-H "Content-Type: application/json" \
		-H "Accept: application/json" \
		--data-binary "@$body_tmp" \
		-D "$hdr_tmp" \
		-o "$resp_tmp" \
		-w '%{http_code}' \
		"https://$host/redfish/v1/SessionService/Sessions" 2>"$err_tmp") || code="000"

	# Wipe body tempfile immediately - it contains plaintext password.
	rm -f "$body_tmp"

	_REDFISH_LAST_CODE="$code"

	if [ "$code" != "201" ] && [ "$code" != "200" ]; then
		local reason
		case "$code" in
			401) reason="HTTP 401 Unauthorized" ;;
			403) reason="HTTP 403 Forbidden (Redfish role may be No Access)" ;;
			503) reason="HTTP 503 MaxSessions exceeded" ;;
			000)
				local err_txt
				err_txt=$(cat "$err_tmp" | _redfish_redact)
				if printf '%s' "$err_txt" | grep -qi 'ssl\|tls\|handshake\|certificate'; then
					reason="TLS handshake failed"
				else
					reason="connect timeout or transport error"
				fi
				;;
			*) reason="HTTP $code on session login" ;;
		esac
		_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "$reason")
		aba_warning "BMC: $node phase=session-login adapter=$adapter http=$code reason=\"$_REDFISH_LAST_REASON\""
		rm -f "$hdr_tmp" "$resp_tmp" "$err_tmp"
		return 1
	fi
	rm -f "$err_tmp"

	local token session_uri
	token=$(grep -i '^X-Auth-Token:' "$hdr_tmp" | sed -E 's/^[Xx]-[Aa][Uu][Tt][Hh]-[Tt][Oo][Kk][Ee][Nn]:[[:space:]]*//' | tr -d '\r\n')
	session_uri=$(grep -i '^Location:' "$hdr_tmp" | sed -E 's/^[Ll]ocation:[[:space:]]*//' | tr -d '\r\n')
	rm -f "$hdr_tmp" "$resp_tmp"

	if [ -z "$token" ] || [ -z "$session_uri" ]; then
		_REDFISH_LAST_REASON=$(_redfish_sanitize_reason "X-Auth-Token or Location header missing in 201 response")
		aba_warning "BMC: $node phase=session-login adapter=$adapter http=$code reason=\"$_REDFISH_LAST_REASON\""
		return 1
	fi

	printf -v "SESSION_TOKEN_${node}" '%s' "$token"
	printf -v "SESSION_URI_${node}" '%s' "$session_uri"
	_bm_session_write_tempfile "$node"
	aba_debug "BMC: $node session-login ok (http=$code)"
	return 0
}

bmc_session_logout() {
	local node="$1"
	local uri_var="SESSION_URI_${node}"
	local tok_var="SESSION_TOKEN_${node}"
	local session_uri="${!uri_var}"
	local token="${!tok_var}"
	[ -z "$session_uri" ] && return 0

	local host_var="bmc_host_${node}"
	local host="${!host_var}"
	local insecure_flag
	insecure_flag=$(_bm_insecure_flag "$node")

	local code
	code=$(curl -s $insecure_flag -m 5 \
		-H "X-Auth-Token: $token" \
		-X DELETE \
		-o /dev/null \
		-w '%{http_code}' \
		"https://$host$session_uri") || code="000"

	if [ "$code" = "204" ] || [ "$code" = "200" ] || [ "$code" = "404" ]; then
		aba_debug "BMC: $node session-logout ok (http=$code)"
	else
		aba_warning "BMC: $node session-logout failed (http=$code) - session may linger on BMC"
	fi
	rm -f ".bmc-session.$node"
	unset "SESSION_TOKEN_${node}" "SESSION_URI_${node}"
	return 0
}
