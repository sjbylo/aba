#!/bin/bash
# INTENT:      BM-only gate before ISO: review/edit agent-config / macs.conf.
#
#   | Condition                                      | Action                              |
#   |------------------------------------------------|-------------------------------------|
#   | cluster.conf newer than agent-config.yaml     | Rebuild YAML (cluster.conf wins)   |
#   | macs_should_apply (≥1 MAC, no YAML or newer)  | Write agent-config from those MACs  |
#   | short unique macs                              | Use them; pad with BM_MAC_PLACEHOLDER |
#   | macs empty, or YAML newer than both            | Keep agent-config.yaml              |
#   | this file was already asked (.bm-config-asked) | Stop (no ask) — user re-ran unfixed |
#   | YAML not asked yet, or just rewritten         | ask() so the user can edit, then Yes |
#
#   macs.conf is a shortcut. agent-config.yaml is always created for review.
#   Missing BM MACs are $BM_MAC_PLACEHOLDER, not invented addresses.
#   macs.conf does NOT always win — see macs_should_apply() in include_all.sh.
#
#   Make builds agent-config.yaml before this script (review prerequisite),
#   so the file is already there to edit. This script still regenerates when
#   it is run directly, or when cluster.conf / macs.conf changed during the
#   pause. A file not yet asked about gets ask(). The same file asked once
#   and still containing placeholders stops. Yes with placeholders still in
#   the file also stops, so a bad ISO is not built.
#
# CALLED BY:   Makefile.cluster (.bm-config-reviewed)
# CWD:         Cluster directory
# RE-RUN:      No stops this run only; fix macs/YAML, then re-run the same
#              `aba … install` (Make resumes; safe to repeat).

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

# Cluster dirs symlink aba.conf → ../aba.conf
source <(normalize-aba-conf)
source <(normalize-cluster-conf)
platform=${platform:-bm}

# VMware/KVM and primed bundles skip this gate
if [ "$platform" != "bm" ] || [ -f .primed ]; then
	aba_debug "bm-ask-edit: skip (platform=$platform primed=$([ -f .primed ] && echo yes || echo no))"
	exit 0
fi

aba_progress "START|ci_config"

# shellcheck disable=SC2086
eval "$(macs_status)"

_do_regen=0
# Placeholders already on disk mean a previous run was not finished.
# A file we write in this run is not that case — the user still gets ask().
_placeholders_before=0
if [ -f agent-config.yaml ] && grep -F -q "$BM_MAC_PLACEHOLDER" agent-config.yaml 2>/dev/null; then
	_placeholders_before=1
fi
_generated_now=0
# .bm-config-asked is touched when the question is shown. Make may have just
# written agent-config.yaml as a prerequisite; that file has not been asked
# about yet, so it must not take the re-run stop.
_asked_already=0
if [ -f .bm-config-asked ] && [ -f agent-config.yaml ] && ! [ agent-config.yaml -nt .bm-config-asked ]; then
	_asked_already=1
fi

# Always have agent-config.yaml before the ask (real MACs, or $BM_MAC_PLACEHOLDER).
# Regen when the YAML is missing, macs.conf should apply, or cluster.conf is
# newer than the YAML. cluster.conf wins over an older macs.conf.
if [ ! -f .primed ]; then
	if [ ! -f agent-config.yaml ] || macs_should_apply || cluster_conf_outranks_agent; then
		aba_info "Generating agent-config.yaml for review (cluster.conf + MACs from macs.conf, or placeholders) ..."
		scripts/create-agent-config.sh || {
			aba_progress "FAIL|ci_config"
			aba_abort "Failed to generate agent-config.yaml for review"
		}
		_generated_now=1
	fi
fi

# shellcheck disable=SC2086
eval "$(macs_status)"
_mac_rpt=$(macs_report)

# Fix steps for the current UI. One copy of each sentence.
# TUI preferred = cluster install wizard. CLI preferred = macs.conf.
# Prints lines on stdout (for ask / aba_abort).
# $2 = next → also emit TUI NEXT events (only on a stop/abort, not while building the ask).
# $1 = placeholders | missing | declined
_bm_fix_text() {
	local _why=$1 _next=${2:-}
	if [ -n "${ABA_PROGRESS_FIFO:-}" ]; then
		if [ -n "$_next" ]; then
			aba_progress "NEXT|Go back to the cluster install wizard and add the MACs (preferred), then Retry"
			case "$_why" in
				placeholders)
					aba_progress "NEXT|Or edit macs.conf, then Retry"
					aba_progress "NEXT|Or replace ${BM_MAC_PLACEHOLDER} in agent-config.yaml, then Retry"
					;;
				missing)
					aba_progress "NEXT|Or edit macs.conf, or create agent-config.yaml, then Retry"
					;;
			esac
		fi
		case "$_why" in
			placeholders)
				printf '%s\n' \
					"Go back to the cluster install wizard and add the MACs (preferred), then Retry." \
					"Or edit macs.conf, or replace ${BM_MAC_PLACEHOLDER} in agent-config.yaml, then Retry."
				;;
			missing)
				printf '%s\n' \
					"Go back to the cluster install wizard and add the MACs (preferred), then Retry." \
					"Or edit macs.conf, or create agent-config.yaml, then Retry."
				;;
			*)
				printf '%s\n' \
					"Go back to the cluster install wizard and add the MACs (preferred), then Retry. Or edit macs.conf or agent-config.yaml, then Retry."
				;;
		esac
	else
		case "$_why" in
			placeholders)
				printf '%s\n' \
					"Fix, then re-run the SAME command:" \
					"    $(aba_cmd install)" \
					"  - add the missing MACs to macs.conf (preferred), or" \
					"  - replace ${BM_MAC_PLACEHOLDER} in agent-config.yaml" \
					"(Quit or Ctrl-C, edit, and re-run does the same.)"
				;;
			missing)
				printf '%s\n' \
					"Add MACs to macs.conf (preferred), or create agent-config.yaml, then re-run the SAME command:" \
					"    $(aba_cmd install)"
				;;
			*)
				printf '%s\n' \
					"Edit macs.conf (preferred) or agent-config.yaml, then re-run" \
					"    the SAME command (Quit or Ctrl-C and re-run does the same):" \
					"    $(aba_cmd install)"
				;;
		esac
	fi
}

# Placeholders mean the ISO must not be built. One stop block, no Yes/No.
# TUI progress dialog shows ERROR + NEXT (Retry is already a button).
_bm_stop_if_placeholders() {
	[ -f agent-config.yaml ] || return 0
	grep -F -q "$BM_MAC_PLACEHOLDER" agent-config.yaml 2>/dev/null || return 0
	local -a _fix=() _rpt=()
	local _line=
	mapfile -t _fix < <(_bm_fix_text placeholders next)
	# One argument per line. aba_abort prefixes each argument, same as aba_info -m.
	if [ -n "$_mac_rpt" ]; then
		while IFS= read -r _line; do
			_rpt+=("$_line")
		done <<< "$_mac_rpt"
	fi
	aba_progress "FAIL|ci_config"
	aba_progress "DETAIL|Have ${mac_count:-0} of ${mac_expected:-?} MAC(s) in macs.conf."
	aba_progress "DETAIL|macs.conf: $PWD/macs.conf"
	aba_progress "DETAIL|agent-config.yaml: $PWD/agent-config.yaml"
	aba_info "======== Bare-metal MAC check ========"
	aba_abort "Stopped: agent-config.yaml still contains placeholder MAC(s) ${BM_MAC_PLACEHOLDER}." \
		"Have ${mac_count:-0} of ${mac_expected:-?} MAC(s) (${mac_nodes:-?} nodes × ${mac_ports:-?} port)." \
		"macs.conf:         $PWD/macs.conf" \
		"agent-config.yaml: $PWD/agent-config.yaml" \
		"${_rpt[@]}" \
		"${_fix[@]}"
}

# Same file, already asked, still placeholders: abort. A file Make or this
# script just wrote has not been asked about yet: ask below.
if [ "$_placeholders_before" -eq 1 ] && [ "$_generated_now" -eq 0 ] && [ "$_asked_already" -eq 1 ]; then
	_bm_stop_if_placeholders
fi

if [ ! -f agent-config.yaml ]; then
	mapfile -t _fix < <(_bm_fix_text missing next)
	aba_progress "FAIL|ci_config"
	aba_info "======== Bare-metal MAC check ========"
	aba_abort "Stopped: agent-config.yaml was not created." "${_fix[@]}"
fi

# Real MACs: confirm and build. Fresh placeholders: pause so the user can edit first.
# Preferred fix differs: TUI = cluster install wizard; CLI = macs.conf.
_no_help=$( _bm_fix_text declined )
_yes_help="Yes: build the agent ISO."
if grep -F -q "$BM_MAC_PLACEHOLDER" agent-config.yaml 2>/dev/null; then
	_yes_help="Placeholder MAC(s) ${BM_MAC_PLACEHOLDER} were just written.
Edit macs.conf or agent-config.yaml now, then Yes.
Yes: re-check. Continue only if the placeholders are gone."
fi
# Record the question before it is shown. No does not return to the Makefile,
# so .bm-config-reviewed is not touched on that path.
touch .bm-config-asked
if ! ask -y --always "======== Bare-metal MAC check ========

$_mac_rpt

agent-config.yaml: $PWD/agent-config.yaml
macs.conf:         $PWD/macs.conf

${_yes_help}
No: stop this run. ${_no_help}"; then
	aba_progress "FAIL|ci_config"
	mapfile -t _fix < <(_bm_fix_text declined next)
	aba_abort "Aborted. ${_fix[*]}"
fi

# Re-check after the pause — user may have edited macs.conf or the YAML.
# shellcheck disable=SC2086
eval "$(macs_status)"
_mac_rpt=$(macs_report)
if macs_should_apply || cluster_conf_outranks_agent; then
	aba_info "Updating agent-config.yaml from cluster.conf and macs.conf"
	_do_regen=1
else
	_do_regen=0
	aba_info "Keeping agent-config.yaml."
fi

if [ "$_do_regen" -eq 1 ] && [ ! -f .primed ]; then
	aba_info "Regenerating agent-config.yaml from cluster.conf / macs.conf ..."
	scripts/create-agent-config.sh || {
		aba_progress "FAIL|ci_config"
		aba_abort "Failed to regenerate agent-config.yaml"
	}
	# shellcheck disable=SC2086
	eval "$(macs_status)"
	_mac_rpt=$(macs_report)
fi

# A pause edit can put placeholders back. Stop before the ISO if so.
_bm_stop_if_placeholders

# Final guarantee: review gate always leaves a YAML for ISO/preflight
if [ ! -f agent-config.yaml ] && [ ! -f .primed ]; then
	aba_progress "FAIL|ci_config"
	aba_abort "agent-config.yaml missing after config review"
fi

aba_progress "DONE|ci_config"
exit 0
