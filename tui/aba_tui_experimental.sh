#!/usr/bin/env bash
# ABA TUI – Wizard Prototype (Bash + dialog)
#
# Wizard flow:
#   Channel  <->  Version  <->  Operators  <->  Summary / Apply

set -eo pipefail

# -----------------------------------------------------------------------------
# Sanity checks
# -----------------------------------------------------------------------------
if ! command -v dialog >/dev/null 2>&1; then
	echo "ERROR: dialog is required (dnf install dialog)" >&2
	exit 1
fi

# -----------------------------------------------------------------------------
# Aba runtime init (required for run_once)
# -----------------------------------------------------------------------------
WORK_DIR=~/.aba/runner
export WORK_DIR

WORK_ID="tui-$(date +%Y%m%d%H%M%S)-$$"
export WORK_ID

# shellcheck disable=SC1091
source scripts/include_all.sh

# Aba repo root (best-effort). If ABA_ROOT isn’t set, derive it from this script path.
# This script lives under tui/, so default ABA_ROOT to the parent dir.
if [[ -z "${ABA_ROOT:-}" ]]; then
	ABA_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
	export ABA_ROOT
fi

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

# Terminal-aware sizing (use more of the available screen)
read -r TERM_ROWS TERM_COLS < <(stty size 2>/dev/null || echo "24 80")
DLG_H=$((TERM_ROWS-6))
DLG_W=$((TERM_COLS-10))
((DLG_H<12)) && DLG_H=12
((DLG_W<60)) && DLG_W=60

ui_backtitle() {
	echo "ABA TUI  |  channel: ${OCP_CHANNEL:-?}  version: ${OCP_VERSION:-?}"
}

# -----------------------------------------------------------------------------
# UI helpers
# -----------------------------------------------------------------------------
ui_header() {
	dialog --clear --backtitle "$(ui_backtitle)" --title "ABA – OpenShift Installer" --msgbox \
"Install & manage air-gapped OpenShift quickly with Aba.

Press <OK> to continue." 10 70
}

# -----------------------------------------------------------------------------
# Resume from aba.conf (best-effort)
# -----------------------------------------------------------------------------
resume_from_conf() {
	# Load existing config if present
	if [[ -f aba.conf ]]; then
		# shellcheck disable=SC1091
		source ./aba.conf || true
	fi

	# Prefer aba.conf keys if present
	OCP_CHANNEL=${ocp_channel:-${OCP_CHANNEL:-}}
	OCP_VERSION=${ocp_version:-${OCP_VERSION:-}}

	# Restore operator basket from ops (comma-separated)
	# This is the ONLY basket we maintain.
	declare -gA OP_BASKET
	OP_BASKET=()
	if [[ -n "${ops:-}" ]]; then
		IFS=',' read -r -a _ops_arr <<<"$ops"
		for op in "${_ops_arr[@]}"; do
			op=${op##[[:space:]]}
			op=${op%%[[:space:]]}
			[[ -n "$op" ]] && OP_BASKET["$op"]=1
		done
	fi

	# Track which operator sets have been ADDED (never removed)
	declare -gA OP_SET_ADDED
	OP_SET_ADDED=()
	if [[ -n "${op_sets:-}" ]]; then
		IFS=',' read -r -a _set_arr <<<"$op_sets"
		for s in "${_set_arr[@]}"; do
			s=${s##[[:space:]]}
			s=${s%%[[:space:]]}
			[[ -n "$s" ]] && OP_SET_ADDED["$s"]=1
		done
	fi

	# Track explicitly removed operators so they don't get re-added by later set additions
	declare -gA OP_REMOVED
	OP_REMOVED=()
}


# -----------------------------------------------------------------------------
# Step 1: Select OpenShift channel
# -----------------------------------------------------------------------------
select_ocp_channel() {
	DIALOG_RC=""

	# Prefetch versions for ALL channels (aba.sh style)
	run_once -i "ocp:stable:latest_version"             -- bash -lc 'source ./scripts/include_all.sh; fetch_latest_version stable'
	run_once -i "ocp:stable:latest_version_previous"    -- bash -lc 'source ./scripts/include_all.sh; fetch_previous_version stable'

	run_once -i "ocp:fast:latest_version"               -- bash -lc 'source ./scripts/include_all.sh; fetch_latest_version fast'
	run_once -i "ocp:fast:latest_version_previous"      -- bash -lc 'source ./scripts/include_all.sh; fetch_previous_version fast'

	run_once -i "ocp:candidate:latest_version"          -- bash -lc 'source ./scripts/include_all.sh; fetch_latest_version candidate'
	run_once -i "ocp:candidate:latest_version_previous" -- bash -lc 'source ./scripts/include_all.sh; fetch_previous_version candidate'

	# Preselect based on resumed value
	local c_state="off" f_state="off" s_state="off"
	case "${OCP_CHANNEL:-stable}" in
		candidate) c_state="on" ;;
		fast) f_state="on" ;;
		stable|"") s_state="on" ;;
	esac

	dialog --clear --backtitle "$(ui_backtitle)" --title "OpenShift Channel" \
		--extra-button --extra-label "<BACK>" \
		--radiolist "Choose the OpenShift update channel:" $DLG_H $DLG_W 7 \
		c "candidate  – Preview" "$c_state" \
		f "fast       – Latest GA" "$f_state" \
		s "stable     – Recommended" "$s_state" \
		2>"$TMP"

	rc=$?
	case "$rc" in
		0) DIALOG_RC="next" ;;
		3|1) DIALOG_RC="back"; return ;;  # treat Cancel like Back
		*) DIALOG_RC="back"; return ;;
	esac

	choice=$(<"$TMP")
	case "$choice" in
		c) OCP_CHANNEL="candidate" ;;
		f) OCP_CHANNEL="fast" ;;
		s|"") OCP_CHANNEL="stable" ;;
		*) OCP_CHANNEL="stable" ;;
	esac

	DIALOG_RC="next"
}

# -----------------------------------------------------------------------------
# Step 2: Select OpenShift version
# -----------------------------------------------------------------------------
select_ocp_version() {
	DIALOG_RC=""

	# Ensure we have a channel
	[[ -z "${OCP_CHANNEL:-}" ]] && OCP_CHANNEL="stable"

	dialog --backtitle "$(ui_backtitle)" --infobox "Please wait… preparing version list for channel '$OCP_CHANNEL'" 5 80
	run_once -w -i "ocp:${OCP_CHANNEL}:latest_version"
	run_once -w -i "ocp:${OCP_CHANNEL}:latest_version_previous"

	latest=$(fetch_latest_version "$OCP_CHANNEL")
	previous=$(fetch_previous_version "$OCP_CHANNEL")

	dialog --clear --backtitle "$(ui_backtitle)" --title "OpenShift Version" \
		--extra-button --extra-label "<BACK>" \
		--menu "Choose the OpenShift version to install:" $DLG_H $DLG_W 7 \
		l "Latest   ($latest)" \
		p "Previous ($previous)" \
		m "Manual entry (x.y or x.y.z)" \
		2>"$TMP"

	rc=$?
	case "$rc" in
		0) : ;;
		3|1) DIALOG_RC="back"; return ;;  # Cancel behaves like Back
		*) DIALOG_RC="back"; return ;;
	esac

	choice=$(<"$TMP")
	case "$choice" in
		l|"") OCP_VERSION="$latest" ;;
		p) OCP_VERSION="$previous" ;;
		m)
			dialog --backtitle "$(ui_backtitle)" --inputbox "Enter OpenShift version (x.y or x.y.z):" 12 70 "$latest" 2>"$TMP" || { DIALOG_RC="back"; return; }
			OCP_VERSION=$(<"$TMP")
			OCP_VERSION=${OCP_VERSION//$'
'/}
			OCP_VERSION=${OCP_VERSION##[[:space:]]}
			OCP_VERSION=${OCP_VERSION%%[[:space:]]}

			if [[ "$OCP_VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
				# Resolve x.y -> latest x.y.z (background + wait just like aba.sh)
				run_once -i "ocp:${OCP_CHANNEL}:${OCP_VERSION}:latest_z" -- \
					bash -lc 'source ./scripts/include_all.sh; fetch_latest_z_version "'$OCP_CHANNEL'" "'$OCP_VERSION'"'
				dialog --backtitle "$(ui_backtitle)" --infobox "Please wait… resolving $OCP_VERSION to latest z-stream" 5 80
				run_once -w -i "ocp:${OCP_CHANNEL}:${OCP_VERSION}:latest_z"
				OCP_VERSION=$(fetch_latest_z_version "$OCP_CHANNEL" "$OCP_VERSION")
			fi
			;;
		*) OCP_VERSION="$latest" ;;
	esac

	# Confirmation (prevents the "blank version" confusion)
	dialog --backtitle "$(ui_backtitle)" --msgbox "Selected:

  Channel: $OCP_CHANNEL
  Version:  $OCP_VERSION

Next: Choose operators." 12 60

	DIALOG_RC="next"
}

# -----------------------------------------------------------------------------
# Step 3: Select Operators
# -----------------------------------------------------------------------------
# Basket helpers (simple model)
# - OP_BASKET: the only mutable basket
# - OP_SET_ADDED: sets that have been added (cannot be removed)
# - OP_REMOVED: operators explicitly removed, to prevent re-add by later set additions

add_set_to_basket() {
	local set_key=$1
	local file="$ABA_ROOT/templates/operator-set-$set_key"
	[[ -f "$file" ]] || return 1

	while IFS= read -r op; do
		[[ "$op" =~ ^# ]] && continue
		op=${op%%#*}
		op=${op//$'
'/}
		op=${op##[[:space:]]}
		op=${op%%[[:space:]]}
		[[ -z "$op" ]] && continue

		# Respect explicit removals
		[[ -n "${OP_REMOVED[$op]:-}" ]] && continue
		OP_BASKET["$op"]=1
	done <"$file"
	return 0
}

select_operators() {
	DIALOG_RC=""

	# Start long-running background tasks as soon as OCP_VERSION is known
	run_once -i download_catalog_indexes -- make -s -C "$ABA_ROOT" catalog
	run_once -i mirror:reg:download      -- make -s -C "$ABA_ROOT/mirror" download-registries
	"$ABA_ROOT/scripts/cli-download-all.sh" >/dev/null 2>&1 || true

	# Simple state (don’t clobber resume)
	declare -gA OP_BASKET
	declare -gA OP_SET_ADDED
	declare -gA OP_REMOVED
	: "${OP_BASKET:=}"
	: "${OP_SET_ADDED:=}"
	: "${OP_REMOVED:=}"

	while :; do
		dialog --clear --backtitle "$(ui_backtitle)" --title "Operators" \
			--extra-button --extra-label "<BACK>" \
			--menu "Select operator actions:" $DLG_H $DLG_W 8 \
			1 "Select Operator Set" \
			2 "Search Operator Names" \
			3 "View Basket" \
			4 "Clear Basket" \
			5 "Accept" \
			2>"$TMP"

		rc=$?
	# Treat Cancel like Back (don’t exit the whole script)
	[[ "$rc" == 3 || "$rc" == 1 ]] && { DIALOG_RC="back"; return; }
	[[ "$rc" != 0 ]] && { DIALOG_RC="back"; return; }

		action=$(<"$TMP")
		case "$action" in
			1)
				# Add operator sets to basket (sets are add-only)
				items=()
				for f in "$ABA_ROOT"/templates/operator-set-*; do
					[[ -f "$f" ]] || continue
					key=${f##*/operator-set-}
					display=$(head -n1 "$f" 2>/dev/null | sed 's/^# *//')
					[[ -z "$display" ]] && display="$key"

					state="off"
					[[ -n "${OP_SET_ADDED[$key]:-}" ]] && state="on"
					items+=("$key" "$display" "$state")
				done

				[[ "${#items[@]}" -eq 0 ]] && {
					dialog --backtitle "$(ui_backtitle)" --msgbox "No operator-set templates found under: $ABA_ROOT/templates" 8 70
					continue
				}

				dialog --clear --backtitle "$(ui_backtitle)" --title "Operator Sets" \
					--checklist "Select operator sets to ADD (already-added sets stay added):" $DLG_H $DLG_W 15 \
					"${items[@]}" 2>"$TMP" || continue

				newsel=$(<"$TMP")
				read -r -a sel_arr <<<"$newsel"
				for k in "${sel_arr[@]}"; do
					k=${k//\"/}
					[[ -z "$k" ]] && continue
					if [[ -z "${OP_SET_ADDED[$k]:-}" ]]; then
						OP_SET_ADDED["$k"]=1
						add_set_to_basket "$k" || true
					fi
				done
				;;

			2)
				# Search operators (needs index files)
				run_once -w -i download_catalog_indexes

				dialog --backtitle "$(ui_backtitle)" --inputbox "Search operator names (case-insensitive substring):" 12 80 2>"$TMP" || continue
				query=$(<"$TMP")
				query=${query//$'
'/}
				query=${query##[[:space:]]}
				query=${query%%[[:space:]]}
				[[ -z "$query" ]] && continue

				matches=$(grep -hRi --no-filename -i -- "$query" "$ABA_ROOT"/mirror/.index/* 2>/dev/null | sort -u)
				if [[ -z "$matches" ]]; then
					dialog --backtitle "$(ui_backtitle)" --msgbox "No matches for: $query" 8 50
					continue
				fi

				items=()
				while IFS= read -r op; do
					op=${op//$'
'/}
					op=${op##[[:space:]]}
					op=${op%%[[:space:]]}
					[[ -z "$op" ]] && continue
					state="off"
					[[ -n "${OP_BASKET[$op]:-}" ]] && state="on"
					items+=("$op" "" "$state")
				done <<<"$matches"

				dialog --clear --backtitle "$(ui_backtitle)" --title "Select Operators" \
					--checklist "Toggle operators (already-selected are ON):" $DLG_H $DLG_W 18 \
					"${items[@]}" 2>"$TMP" || continue

				newsel=$(<"$TMP")
				declare -A SEL
				SEL=()
				read -r -a sel_arr <<<"$newsel"
				for op in "${sel_arr[@]}"; do
					op=${op//\"/}
					[[ -n "$op" ]] && SEL["$op"]=1
				done

				# Apply selection to the ONE basket
				while IFS= read -r op; do
					op=${op//$'
'/}
					op=${op##[[:space:]]}
					op=${op%%[[:space:]]}
					[[ -z "$op" ]] && continue

					if [[ -n "${SEL[$op]:-}" ]]; then
						# Add
						unset 'OP_REMOVED[$op]'
						OP_BASKET["$op"]=1
					else
						# Remove
						OP_REMOVED["$op"]=1
						unset 'OP_BASKET[$op]'
					fi
				done <<<"$matches"
				;;

			3)
				# View basket (allow multi-select adjustments)
				items=()
				for op in $(printf "%s
" "${!OP_BASKET[@]}" | sort); do
					items+=("$op" "" "on")
				done
				if [[ "${#items[@]}" -eq 0 ]]; then
					dialog --backtitle "$(ui_backtitle)" --msgbox "Basket is empty." 7 40
					continue
				fi

				dialog --clear --backtitle "$(ui_backtitle)" --title "Basket" \
					--checklist "Uncheck operators to remove them from the basket." \
					$DLG_H $DLG_W 18 \
					"${items[@]}" 2>"$TMP" || continue

				newsel=$(<"$TMP")
				declare -A KEEP
				KEEP=()
				read -r -a sel_arr <<<"$newsel"
				for op in "${sel_arr[@]}"; do
					op=${op//\"/}
					[[ -n "$op" ]] && KEEP["$op"]=1
				done

				for op in "${!OP_BASKET[@]}"; do
					if [[ -n "${KEEP[$op]:-}" ]]; then
						:
					else
						OP_REMOVED["$op"]=1
						unset 'OP_BASKET[$op]'
					fi
				done
				;;

			4)
				dialog --backtitle "$(ui_backtitle)" --yesno "Clear operator basket?" 10 55 && { OP_BASKET=(); OP_SET_ADDED=(); OP_REMOVED=(); }
				;;

			5)
				DIALOG_RC="next"
				return
				;;
		esac
	done
}

# -----------------------------------------------------------------------------
# Step 4: Summary / Apply
# -----------------------------------------------------------------------------
summary_apply() {
	# Build comma-separated values for aba.conf
	ops_csv=$(printf "%s\n" "${!OP_BASKET[@]}" | sort | paste -sd, -)
	op_sets_csv=$(printf "%s
" "${!OP_SET_ADDED[@]}" 2>/dev/null | sort | paste -sd, -)

	# Human-friendly preview list
	op_list=$(printf "%s\n" "${!OP_BASKET[@]}" | sort)
	[[ -z "$op_list" ]] && op_list="(none)"

	dialog --clear --backtitle "$(ui_backtitle)" --title "Summary" \
		--yes-label "<APPLY>" --no-label "<BACK>" \
		--yesno "OpenShift channel: $OCP_CHANNEL
OpenShift version: $OCP_VERSION

Operator sets (added): ${op_sets_csv:-\(none\)}

Operators:
$op_list

Apply these values to aba.conf?" 20 80

	rc=$?
	case "$rc" in
		0)
			replace-value-conf -q -n ocp_channel   -v "$OCP_CHANNEL" -f aba.conf
			replace-value-conf -q -n ocp_version   -v "$OCP_VERSION" -f aba.conf
			replace-value-conf -q -n ops           -v "$ops_csv"     -f aba.conf
			replace-value-conf -q -n op_sets       -v "$op_sets_csv" -f aba.conf
			return 0
			;;
		1) return 1 ;; # BACK
		*) clear; exit 1 ;;
	esac
}

# -----------------------------------------------------------------------------
# Main wizard loop
# -----------------------------------------------------------------------------
ui_header
resume_from_conf

STEP="channel"
while :; do
	case "$STEP" in
		channel)
			select_ocp_channel
			[[ "$DIALOG_RC" == "next" ]] && STEP="version"
			[[ "$DIALOG_RC" == "back" ]] && break
			;;
		version)
			select_ocp_version
			[[ "$DIALOG_RC" == "next" ]] && STEP="operators"
			[[ "$DIALOG_RC" == "back" ]] && STEP="channel"
			;;
		operators)
			select_operators
			[[ "$DIALOG_RC" == "next" ]] && STEP="summary"
			[[ "$DIALOG_RC" == "back" ]] && STEP="version"
			;;
		summary)
			if summary_apply; then
				break
			else
				STEP="operators"
			fi
			;;
	esac
done

clear
echo "TUI complete."
