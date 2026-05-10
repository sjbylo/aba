#!/usr/bin/env bash
# =============================================================================
# TUI v2 — Cluster Operations (configure, install, monitor, day2)
# =============================================================================
# NEW code — not in v1. Implements the 4-page cluster configuration wizard.
#
# Design decisions:
#   - All 4 pages use MENU-STYLE (not --form). In dialog --form, the Tab key
#     moves to buttons instead of the next field, causing users to accidentally
#     advance pages. Menu-style: user selects a row, edits in a focused inputbox,
#     then returns to the menu. Consistent with Basics and Interfaces pages.
#   - Button layout: --ok-label "$TUI2_BTN_SELECT" --extra-button --extra-label "$TUI2_BTN_NEXT"
#     --cancel-label "$TUI2_BTN_BACK" --help-button. Tab order from menu area:
#     Tab→Extra(Next), Tab Tab→Cancel(Back). Empirically verified on dialog 1.3
#     (RHEL 9). See plan appendix A.25.
#   - Fixed menu dimensions (width + menu-height) on pages where items appear/
#     disappear (e.g. Basics: "Worker count" shows only for standard). Prevents
#     dialog resize flicker when toggling cluster type.
#   - Base domain pre-filled from aba.conf but editable per-cluster. Passed as
#     --base-domain flag to "aba cluster" command.
#   - VM Resources page (page 4) only shown for vmw/kvm platforms, skipped for bm.
#   - Values pre-filled from aba.conf vars, then get_*() auto-detect functions,
#     then smart guesses (e.g. VIPs from DNS, starting IP from machine network).
#
# Usage: source tui/v2/tui-cluster.sh

# --- BASH_SOURCE guard ---
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	echo "This file should be sourced, not executed directly."
	exit 1
fi

# =============================================================================
# Persistent cluster wizard state (survives Back → re-entry)
# =============================================================================
_CL_STATE_INIT=false
_cl_name=""
_cl_domain=""
_cl_type=""
_cl_workers=""
_cl_network=""
_cl_starting_ip=""
_cl_api_vip=""
_cl_ingress_vip=""
_cl_dns=""
_cl_gateway=""
_cl_ntp=""
_cl_ports=""
_cl_vlan=""
_cl_connection=""
_cl_macs=""
_cl_master_cpu=""
_cl_master_mem=""
_cl_worker_cpu=""
_cl_worker_mem=""
_cl_disk=""
_cl_mac_template=""
_cl_platform=""

# =============================================================================
# Cluster config persistence helpers
# =============================================================================

# Load wizard variables from an existing cluster.conf
_cluster_load_conf() {
	local conf="$1"
	[[ ! -f "$conf" ]] && return 1

	local key val _nm="" _nw=""

	# Parse key=value pairs (strip comments and whitespace)
	while IFS= read -r line; do
		# Skip comments and empty lines
		[[ "$line" =~ ^[[:space:]]*# ]] && continue
		[[ -z "${line// /}" ]] && continue
		# Extract key=value (strip inline comments)
		key="${line%%=*}"
		val="${line#*=}"
		val="${val%%#*}"
		# Trim whitespace
		key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
		val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
		[[ -z "$key" ]] && continue

		case "$key" in
			cluster_name)     cl_name="$val" ;;
			base_domain)      cl_domain="$val" ;;
			machine_network)  cl_network="$val" ;;
			starting_ip)      cl_starting_ip="$val" ;;
			api_vip)          cl_api_vip="$val" ;;
			ingress_vip)      cl_ingress_vip="$val" ;;
			dns_servers)      cl_dns="$val" ;;
			next_hop_address) cl_gateway="$val" ;;
			ntp_servers)      cl_ntp="$val" ;;
			ports)            cl_ports="$val" ;;
			vlan)             cl_vlan="$val" ;;
			int_connection)   cl_connection="$val" ;;
			mac_prefix)       cl_mac_template="$val" ;;
			num_masters)      _nm="$val" ;;
			num_workers)      _nw="$val" ;;
			master_cpu_count) cl_master_cpu="$val" ;;
			master_mem)       cl_master_mem="$val" ;;
			worker_cpu_count) cl_worker_cpu="$val" ;;
			worker_mem)       cl_worker_mem="$val" ;;
			data_disk)        cl_disk="$val" ;;
		esac
	done < "$conf"

	# Derive cluster type from num_masters/num_workers
	_nm="${_nm:-1}"; _nw="${_nw:-0}"
	if [[ "$_nm" -eq 1 && "$_nw" -eq 0 ]]; then
		cl_type="sno"
	elif [[ "$_nm" -ge 3 && "$_nw" -eq 0 ]]; then
		cl_type="compact"
	elif [[ "$_nm" -ge 3 && "$_nw" -gt 0 ]]; then
		cl_type="standard"
		cl_workers="$_nw"
	fi

	return 0
}

# Persist current wizard values to cluster.conf (draft save)
_persist_cluster_draft() {
	[[ -z "$cl_name" ]] && return 0

	local cluster_dir="$ABA_ROOT/$cl_name"
	mkdir -p "$cluster_dir" 2>/dev/null || true

	local conf="$cluster_dir/cluster.conf"

	# If cluster.conf doesn't exist yet, seed from template
	if [[ ! -s "$conf" ]]; then
		cp "$ABA_ROOT/templates/cluster.conf.j2" "$conf"
		# Strip j2 placeholders to bare key=value (replace {{ xxx }} with empty)
		sed -i 's/{{ *[a-z_]* *}}//g' "$conf"
	fi

	# Derive num_masters/num_workers from type
	local _nm=1 _nw=0
	case "$cl_type" in
		sno)      _nm=1; _nw=0 ;;
		compact)  _nm=3; _nw=0 ;;
		standard) _nm=3; _nw="${cl_workers:-2}" ;;
	esac

	# Use replace-value-conf for each field (preserves comments and format)
	replace-value-conf -q -n cluster_name    -v "$cl_name"             -f "$conf"
	replace-value-conf -q -n base_domain     -v "${cl_domain:-}"       -f "$conf"
	replace-value-conf -q -n api_vip         -v "${cl_api_vip:-}"      -f "$conf"
	replace-value-conf -q -n ingress_vip     -v "${cl_ingress_vip:-}"  -f "$conf"
	replace-value-conf -q -n machine_network -v "${cl_network:-}"      -f "$conf"
	replace-value-conf -q -n starting_ip     -v "${cl_starting_ip:-}"  -f "$conf"
	replace-value-conf -q -n num_masters     -v "$_nm"                 -f "$conf"
	replace-value-conf -q -n num_workers     -v "$_nw"                 -f "$conf"
	replace-value-conf -q -n dns_servers     -v "${cl_dns:-}"          -f "$conf"
	replace-value-conf -q -n next_hop_address -v "${cl_gateway:-}"     -f "$conf"
	replace-value-conf -q -n ntp_servers     -v "${cl_ntp:-}"          -f "$conf"
	replace-value-conf -q -n ports           -v "${cl_ports:-}"        -f "$conf"
	replace-value-conf -q -n vlan            -v "${cl_vlan:-}"         -f "$conf"
	local _conn_val="${cl_connection:-}"
	[[ "$_conn_val" == "mirror" ]] && _conn_val=""
	replace-value-conf -q -n int_connection  -v "$_conn_val"           -f "$conf"
	replace-value-conf -q -n mac_prefix      -v "${cl_mac_template:-}" -f "$conf"
	replace-value-conf -q -n master_cpu_count -v "${cl_master_cpu:-8}" -f "$conf"
	replace-value-conf -q -n master_mem      -v "${cl_master_mem:-32}" -f "$conf"
	replace-value-conf -q -n worker_cpu_count -v "${cl_worker_cpu:-4}" -f "$conf"
	replace-value-conf -q -n worker_mem      -v "${cl_worker_mem:-16}" -f "$conf"
	replace-value-conf -q -n data_disk       -v "${cl_disk:-}"         -f "$conf"

	tui_log "Saved cluster draft: $conf"
}

# Gate: check platform config when leaving Basics page (vmw/kvm only)
_gate_platform_config() {
	[[ "$cl_platform" == "bm" ]] && return 0

	local conf_name conf_path cached_path plat_label
	case "$cl_platform" in
		vmw)
			conf_name="vmware.conf"
			plat_label="VMware/ESXi"
			;;
		kvm)
			conf_name="kvm.conf"
			plat_label="KVM/libvirt"
			;;
		*) return 0 ;;
	esac

	conf_path="$ABA_ROOT/$conf_name"
	cached_path="$HOME/.$conf_name"

	# Already configured? (check ABA root, then cached in home)
	if [[ -s "$conf_path" ]]; then
		return 0
	fi

	# Try to reuse cached config from ~/.vmware.conf or ~/.kvm.conf
	if [[ -s "$cached_path" ]]; then
		local cached_info=""
		if [[ "$cl_platform" == "vmw" ]]; then
			cached_info=$(grep -m1 "^GOVC_URL=" "$cached_path" 2>/dev/null | cut -d= -f2 | tr -d "'" | tr -d '"')
		else
			cached_info=$(grep -m1 "^LIBVIRT_URI=" "$cached_path" 2>/dev/null | cut -d= -f2 | tr -d "'" | tr -d '"')
		fi

		dlg --backtitle "$(ui_backtitle)" --title " $plat_label Configuration " \
			--yes-label "Use Saved" \
			--no-label "Configure New" \
			--extra-button --extra-label "Skip" \
			--yesno "\n$plat_label config not found in project.\n\nA saved config exists: ${cached_info:-$cached_path}\n\nUse it, configure a new one, or skip for now?" 0 0
		local rc=$?
		case "$rc" in
			0)
				cp "$cached_path" "$conf_path"
				tui_log "Reused cached $conf_name from $cached_path"
				return 0
				;;
			1)
				_configure_platform_file "$conf_name" "$plat_label"
				return 0
				;;
			3)
				tui_log "Skipped $conf_name configuration (will be required at install time)"
				return 0
				;;
		esac
	fi

	# No cached config — prompt to configure or skip
	dlg --backtitle "$(ui_backtitle)" --title " $plat_label Configuration " \
		--yes-label "Configure Now" \
		--no-label "Skip" \
		--yesno "\nPlatform is set to $cl_platform but $conf_name is not configured.\n\nConfigure now or skip? (Required before install.)" 0 0
	local rc=$?
	case "$rc" in
		0)
			_configure_platform_file "$conf_name" "$plat_label"
			return 0
			;;
		*)
			tui_log "Skipped $conf_name configuration"
			return 0
			;;
	esac
}

# Open platform config for editing (template → editor → validate)
_configure_platform_file() {
	local conf_name="$1" plat_label="$2"
	local conf_path="$ABA_ROOT/$conf_name"
	local template_path="$ABA_ROOT/templates/$conf_name"

	# Copy template if config doesn't exist
	if [[ ! -s "$conf_path" && -f "$template_path" ]]; then
		cp "$template_path" "$conf_path"
	fi

	while :; do
		dlg --backtitle "$(ui_backtitle)" --title " Edit $plat_label Config " \
			--ok-label "Save" --cancel-label "Cancel" \
			--editbox "$conf_path" 0 0 2>"$_TUI_TMP"
		local rc=$?
		if [[ $rc -ne 0 ]]; then
			tui_log "$conf_name editing cancelled"
			return 0
		fi

		# Save edited content
		cp "$_TUI_TMP" "$conf_path"
		tui_log "Saved $conf_name"

		# Validate connection
		local valid=true
		if [[ "$conf_name" == "vmware.conf" ]]; then
			dlg --backtitle "$(ui_backtitle)" --infobox "\nTesting vSphere connection..." 0 0
			source <(normalize-vmware-conf) 2>/dev/null || true
			if command -v govc >/dev/null 2>&1 && ! govc about >/dev/null 2>&1; then
				valid=false
			fi
		elif [[ "$conf_name" == "kvm.conf" ]]; then
			dlg --backtitle "$(ui_backtitle)" --infobox "\nTesting libvirt connection..." 0 0
			source <(normalize-kvm-conf) 2>/dev/null || true
			if command -v virsh >/dev/null 2>&1 && ! virsh -c "${LIBVIRT_URI:-}" version >/dev/null 2>&1; then
				valid=false
			fi
		fi

		if [[ "$valid" == "false" ]]; then
			dlg --backtitle "$(ui_backtitle)" --title " Connection Failed " \
				--yes-label "Edit Again" \
				--no-label "Save Anyway" \
				--yesno "\nConnection test failed. Edit again or save as-is?" 0 0
			[[ $? -eq 0 ]] && continue
		fi

		# Cache validated config to home dir
		cp "$conf_path" "$HOME/.$conf_name" 2>/dev/null || true
		tui_log "Cached $conf_name to ~/.$conf_name"
		break
	done
}

# =============================================================================
# Cluster Configure — 4-page form
# =============================================================================

cluster_install_flow() {
	tui_log "Action: Install Cluster (unified configure + install)"

	# Initialize state once per session; subsequent calls reuse previous values
	if [[ "$_CL_STATE_INIT" != "true" ]]; then
		_cl_name="ocp"
		_cl_domain="${domain:-}"
		_cl_type="sno"
		_cl_workers="2"
		_cl_network=""
		_cl_starting_ip=""
		_cl_api_vip=""
		_cl_ingress_vip=""
		_cl_dns=""
		_cl_gateway=""
		_cl_ntp=""
		_cl_ports=""
		_cl_vlan=""
		_cl_connection="mirror"
		_cl_macs=""
		_cl_master_cpu="8"
		_cl_master_mem="32"
		_cl_worker_cpu="4"
		_cl_worker_mem="16"
		_cl_disk=""
		_cl_mac_template=""
		_cl_platform="${platform:-bm}"
		_CL_STATE_INIT=true
	fi

	# Local aliases for readability (reference the globals)
	local cl_name="$_cl_name"
	local cl_domain="$_cl_domain"
	local cl_type="$_cl_type"
	local cl_workers="$_cl_workers"
	local cl_network="$_cl_network" cl_starting_ip="$_cl_starting_ip"
	local cl_api_vip="$_cl_api_vip" cl_ingress_vip="$_cl_ingress_vip"
	local cl_dns="$_cl_dns" cl_gateway="$_cl_gateway" cl_ntp="$_cl_ntp"
	local cl_ports="$_cl_ports" cl_vlan="$_cl_vlan"
	local cl_connection="$_cl_connection" cl_macs="$_cl_macs"
	local cl_master_cpu="$_cl_master_cpu" cl_master_mem="$_cl_master_mem"
	local cl_worker_cpu="$_cl_worker_cpu" cl_worker_mem="$_cl_worker_mem"
	local cl_disk="$_cl_disk" cl_mac_template="$_cl_mac_template"
	local cl_platform="$_cl_platform"

	# --- Load from existing cluster.conf if present (config = single source of truth) ---
	local _draft_loaded=false
	local _is_reentry=false
	[[ -n "$cl_name" && "$cl_name" != "ocp" ]] && _is_reentry=true
	[[ -n "$cl_network" || -n "$cl_starting_ip" ]] && _is_reentry=true

	if [[ -n "$cl_name" && -f "$ABA_ROOT/$cl_name/cluster.conf" ]]; then
		_cluster_load_conf "$ABA_ROOT/$cl_name/cluster.conf"
		_draft_loaded=true
		tui_log "Loaded existing cluster.conf for '$cl_name'"
	fi

	# Only apply auto-detect defaults on first entry (not re-entry or draft load)
	if [[ "$_draft_loaded" == "false" && "$_is_reentry" == "false" ]]; then
		# Pre-fill from sourced aba.conf variables, fallback to auto-detect
		cl_network="${machine_network:-}"
		[[ -z "$cl_network" ]] && cl_network=$(get_machine_network 2>/dev/null) || true
		cl_dns="${dns_servers:-}"
		[[ -z "$cl_dns" ]] && cl_dns=$(get_dns_servers 2>/dev/null) || true
		cl_dns=$(filter_disco_values "$cl_dns")
		cl_gateway="${next_hop_address:-}"
		[[ -z "$cl_gateway" ]] && cl_gateway=$(get_next_hop 2>/dev/null) || true
		cl_ntp="${ntp_servers:-}"
		[[ -z "$cl_ntp" ]] && cl_ntp=$(get_ntp_servers 2>/dev/null) || true
		cl_ntp=$(filter_disco_values "$cl_ntp")

		# Smart guess for starting IP from machine network
		if [[ -z "$cl_starting_ip" && -n "$cl_network" ]]; then
			local net_prefix="${cl_network%%/*}"
			local octets
			IFS='.' read -ra octets <<< "$net_prefix"
			if [[ ${#octets[@]} -eq 4 ]]; then
				cl_starting_ip="${octets[0]}.${octets[1]}.${octets[2]}.100"
			fi
		fi

		# Smart guess VIPs from DNS (if base domain available)
		if [[ -n "$cl_domain" ]]; then
			local api_dns ingress_dns
			api_dns=$(dig +short "api.${cl_name}.${cl_domain}" A 2>/dev/null | head -1)
			[[ -n "$api_dns" ]] && cl_api_vip="$api_dns"
			ingress_dns=$(dig +short "*.apps.${cl_name}.${cl_domain}" A 2>/dev/null | head -1)
			[[ -z "$ingress_dns" ]] && ingress_dns=$(dig +short "apps.${cl_name}.${cl_domain}" A 2>/dev/null | head -1)
			[[ -n "$ingress_dns" ]] && cl_ingress_vip="$ingress_dns"
		fi

		# Platform-aware default port name
		case "$cl_platform" in
			vmw) cl_ports="ens160" ;;
			kvm) cl_ports="enp1s0" ;;
		esac
	fi

	# In DIRECT mode, default to "direct" but also allow "proxy" (no "mirror")
	if [[ "$_TUI_MODE" == "DIRECT" ]]; then
		[[ "$cl_connection" != "proxy" ]] && cl_connection="direct"
	fi

	# Save locals back to globals (called before every return)
	_cl_save_state() {
		_cl_name="$cl_name"; _cl_domain="$cl_domain"
		_cl_type="$cl_type"; _cl_workers="$cl_workers"
		_cl_network="$cl_network"; _cl_starting_ip="$cl_starting_ip"
		_cl_api_vip="$cl_api_vip"; _cl_ingress_vip="$cl_ingress_vip"
		_cl_dns="$cl_dns"; _cl_gateway="$cl_gateway"; _cl_ntp="$cl_ntp"
		_cl_ports="$cl_ports"; _cl_vlan="$cl_vlan"
		_cl_connection="$cl_connection"; _cl_macs="$cl_macs"
		_cl_master_cpu="$cl_master_cpu"; _cl_master_mem="$cl_master_mem"
		_cl_worker_cpu="$cl_worker_cpu"; _cl_worker_mem="$cl_worker_mem"
		_cl_disk="$cl_disk"; _cl_mac_template="$cl_mac_template"
		_cl_platform="$cl_platform"
	}

	# Page navigation: each page function returns 0 (advance) or 1 (go back).
	# Page 1 Back breaks the loop (returns to action menu).
	# Per-page save: persist cluster.conf after each page's NEXT.
	local page=1
	while :; do
		case $page in
			1)
				_cluster_page_basics || { page=0; break; }
				# Gate: check VMware/KVM config on leaving Basics
				_gate_platform_config || continue
				_persist_cluster_draft
				;;
			2)
				_cluster_page_network || { page=$((page - 1)); continue; }
				_persist_cluster_draft
				;;
			3)
				_cluster_page_iface || { page=$((page - 1)); continue; }
				_persist_cluster_draft
				;;
			4)
				if [[ "$cl_platform" != "bm" ]]; then
					_cluster_page_vm || { page=$((page - 1)); continue; }
					_persist_cluster_draft
				else
					# Skip VM page for bare metal, go to review
					page=5
					continue
				fi
				;;
			5)
				# Review/confirm page — returns 1 if user presses "Back"
				_cluster_execute && { _cl_save_state; return 0; }
				# Back from review → return to last real page
				if [[ "$cl_platform" != "bm" ]]; then
					page=4
				else
					page=3
				fi
				continue
				;;
			0)
				# Cancelled from page 1 — still save draft if user entered anything
				_persist_cluster_draft
				_cl_save_state
				return 1
				;;
		esac
		page=$((page + 1))
	done

	# If cancelled from page 1, return to action menu
	_cl_save_state
	[[ $page -eq 0 ]] && return 1
}

# --- Page 1: Basics (menu-style with toggle) ---
_cluster_page_basics() {
	local default_item="name"
	while :; do
		# Build menu items (hide worker row for sno)
		local items=()
		local _plat_desc="" _plat_status=""
		case "$cl_platform" in
			bm)  _plat_desc="bm (bare-metal)" ;;
			vmw)
				_plat_desc="vmw (VMware/ESXi)"
				if [[ -s "$ABA_ROOT/vmware.conf" || -s "$HOME/.vmware.conf" ]]; then
					_plat_status=" \Z2\Zb✓\Zn"
				else
					_plat_status=" \Z1⚠\Zn"
				fi
				;;
			kvm)
				_plat_desc="kvm (libvirt/KVM)"
				if [[ -s "$ABA_ROOT/kvm.conf" || -s "$HOME/.kvm.conf" ]]; then
					_plat_status=" \Z2\Zb✓\Zn"
				else
					_plat_status=" \Z1⚠\Zn"
				fi
				;;
			*)   _plat_desc="$cl_platform" ;;
		esac
		items+=("P" "Platform:       ${_plat_desc}${_plat_status}")
		items+=("N" "Cluster name:   $cl_name")
		items+=("D" "Base domain:    ${cl_domain:-(not set)}")
		items+=("T" "Type:           $cl_type")
		if [[ "$cl_type" == "standard" ]]; then
			items+=("W" "Worker count:   $cl_workers")
		fi

		dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CLUSTER_BASICS" \
			--cancel-label "$TUI2_BTN_BACK" \
			--ok-label "$TUI2_BTN_SELECT" \
			--extra-button --extra-label "$TUI2_BTN_NEXT" \
			--help-button \
			--default-item "$default_item" \
			--menu "$TUI2_MSG_CLUSTER_BASICS" 14 60 5 \
			"${items[@]}" \
			2>"$_TUI_TMP"
		local rc=$?

		case "$rc" in
			2)
				show_help "$TUI2_HELP_TITLE_BASICS" \
"• Cluster name: short name (lowercase, numbers, hyphens)
• Type: sno (single node), compact (3 masters), standard (3 masters + workers)
• Worker count: number of worker nodes (only for standard type)
• Platform: bm (bare metal), vmw (VMware), kvm (KVM/libvirt)

Toggle 'Type' or 'Platform' to cycle through options.
Press 'Next' to proceed to networking.

Current OpenShift version: ${ocp_version:-?} (channel: ${ocp_channel:-?})
To change version/channel, exit and re-run the setup wizard."
				continue
				;;
			3)
				tui_log "Page 1: Next (Extra button)"
				return 0
				;;
			1)
				tui_log "Page 1: Back (Cancel button)"
				return 1
				;;
			255)
				if confirm_quit; then clear; _show_v2_exit_summary; exit 0; fi
				continue
				;;
			0) ;;
		esac

		local choice
		choice=$(<"$_TUI_TMP")
		[[ -n "$choice" ]] && default_item="$choice"

		case "$choice" in
	N)
		while :; do
			dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CLUSTER_NAME" \
				--inputbox "$TUI2_MSG_CLUSTER_NAME_PROMPT" 0 0 "$cl_name" \
				2>"$_TUI_TMP"
			[[ $? -ne 0 ]] && break
			local input
			input=$(<"$_TUI_TMP")
			if [[ -n "$input" && ! "$input" =~ ^[a-z][a-z0-9-]*$ ]]; then
				dlg --backtitle "$(ui_backtitle)" --msgbox \
					"$TUI2_MSG_INVALID_CLUSTER_NAME" 0 0 || true
				continue
			fi
			[[ -n "$input" ]] && cl_name="$input"
			# Silently load existing cluster.conf if present
			if [[ -f "$ABA_ROOT/$cl_name/cluster.conf" ]]; then
				_cluster_load_conf "$ABA_ROOT/$cl_name/cluster.conf"
				tui_log "Loaded existing cluster.conf for '$cl_name'"
			fi
			break
		done
			;;
		D)
			while :; do
				dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CLUSTER_BASE_DOMAIN" \
					--inputbox "$TUI2_MSG_BASE_DOMAIN_PROMPT" 0 0 "$cl_domain" \
					2>"$_TUI_TMP"
				[[ $? -ne 0 ]] && break
				local dom_input
				dom_input=$(<"$_TUI_TMP")
				if [[ -n "$dom_input" && ! "$dom_input" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
					dlg --backtitle "$(ui_backtitle)" --msgbox \
						"Invalid base domain.\n\nMust be a valid DNS name (e.g. example.com, lab.internal)." 0 0 || true
					continue
				fi
				[[ -n "$dom_input" ]] && cl_domain="$dom_input"
				break
			done
			;;
	T)
		# Toggle: sno → compact → standard → sno
		case "$cl_type" in
			sno) cl_type="compact" ;;
			compact) cl_type="standard"; [[ "$cl_workers" == "0" || -z "$cl_workers" ]] && cl_workers="2" ;;
			standard) cl_type="sno" ;;
		esac
		tui_log "Toggled type to: $cl_type"
		;;
	P)
		# Toggle: bm → vmw → kvm → bm
		# Only update port default if user hasn't manually edited it
		local _prev_default=""
		case "$cl_platform" in
			bm)  _prev_default="" ;;
			vmw) _prev_default="ens160" ;;
			kvm) _prev_default="enp1s0" ;;
		esac
		case "$cl_platform" in
			bm)  cl_platform="vmw" ;;
			vmw) cl_platform="kvm" ;;
			kvm) cl_platform="bm" ;;
		esac
		# Update ports only if still at the previous platform's default
		if [[ "$cl_ports" == "$_prev_default" ]]; then
			case "$cl_platform" in
				vmw) cl_ports="ens160" ;;
				kvm) cl_ports="enp1s0" ;;
				bm)  cl_ports="" ;;
			esac
		fi
		tui_log "Toggled platform to: $cl_platform (ports: ${cl_ports:-(empty)})"
		;;
		W)
				while :; do
					dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CLUSTER_WORKER_COUNT" \
						--inputbox "$TUI2_MSG_CLUSTER_WORKER_PROMPT" 0 0 "$cl_workers" \
						2>"$_TUI_TMP"
					[[ $? -ne 0 ]] && break
					local wrk_input
					wrk_input=$(<"$_TUI_TMP")
					if [[ -n "$wrk_input" && ! "$wrk_input" =~ ^[0-9]+$ ]]; then
						dlg --backtitle "$(ui_backtitle)" --msgbox \
							"Invalid worker count.\n\nMust be a positive number (e.g. 2, 3, 5)." 0 0 || true
						continue
					fi
					[[ -n "$wrk_input" ]] && cl_workers="$wrk_input"
					break
				done
				;;
		esac
	done
}

# --- Page 2: Networking (menu-style) ---
_cluster_page_network() {
	local default_item="M"
	while :; do
		local items=()
		items+=("M"  "Machine network: ${cl_network:-(auto)}")
		items+=("S"  "Starting IP:     ${cl_starting_ip:-(auto)}")
		if [[ "$cl_type" != "sno" ]]; then
			items+=("A"  "API VIP:         ${cl_api_vip:-(auto: fetch from DNS)}")
			items+=("I"  "Ingress VIP:     ${cl_ingress_vip:-(auto: fetch from DNS)}")
		fi
		items+=("D"  "DNS servers:     ${cl_dns:-(auto)}")
		items+=("G"  "Gateway:         ${cl_gateway:-(auto)}")
		items+=("N"  "NTP servers:     ${cl_ntp:-(none)}")

		dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CLUSTER_NETWORK" \
			--cancel-label "$TUI2_BTN_BACK" \
			--ok-label "$TUI2_BTN_SELECT" \
			--extra-button --extra-label "$TUI2_BTN_NEXT" \
			--help-button \
			--default-item "$default_item" \
			--menu "$TUI2_MSG_CLUSTER_NETWORK" 16 60 7 \
			"${items[@]}" \
			2>"$_TUI_TMP"
		local rc=$?

		case "$rc" in
			2)
				show_help "$TUI2_HELP_TITLE_NETWORK" \
"• Machine network: CIDR of the cluster network (e.g., 10.0.0.0/24)
• Starting IP: first IP assigned to cluster nodes
• API VIP: virtual IP for the Kubernetes API (compact/standard only)
• Ingress VIP: virtual IP for ingress traffic (compact/standard only)
• DNS: comma-separated DNS server IPs
• Gateway: default gateway IP
• NTP: comma-separated NTP servers (optional)"
				continue
				;;
			3) return 0 ;;  # Next
			1) return 1 ;;  # Back
			255)
				if confirm_quit; then clear; _show_v2_exit_summary; exit 0; fi
				continue
				;;
			0) ;;
		esac

		local choice
		choice=$(<"$_TUI_TMP")
		[[ -n "$choice" ]] && default_item="$choice"

		case "$choice" in
			M)
				while :; do
					dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CLUSTER_MACHINE_NET" \
						--inputbox "$TUI2_MSG_NET_CIDR_PROMPT" 0 0 "$cl_network" \
						2>"$_TUI_TMP"
					[[ $? -ne 0 ]] && break
					local net_val
					net_val=$(<"$_TUI_TMP")
					if [[ -n "$net_val" ]] && ! _valid_cidr "$net_val"; then
						dlg --backtitle "$(ui_backtitle)" --msgbox \
							"Invalid CIDR format.\n\nExpected: IP/prefix (e.g. 10.0.0.0/24)" 0 0 || true
						continue
					fi
					[[ -n "$net_val" ]] && cl_network="$net_val"
					break
				done
				;;
			S)
				while :; do
					dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CLUSTER_STARTING_IP" \
						--inputbox "$TUI2_MSG_NET_STARTING_IP_PROMPT" 0 0 "$cl_starting_ip" \
						2>"$_TUI_TMP"
					[[ $? -ne 0 ]] && break
					local sip_val
					sip_val=$(<"$_TUI_TMP")
					if [[ -n "$sip_val" ]] && ! _valid_ip "$sip_val"; then
						dlg --backtitle "$(ui_backtitle)" --msgbox \
							"Invalid IP address.\n\nExpected format: N.N.N.N (e.g. 10.0.0.100)" 0 0 || true
						continue
					fi
					[[ -n "$sip_val" ]] && cl_starting_ip="$sip_val"
					break
				done
				;;
			A)
				while :; do
					dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CLUSTER_API_VIP" \
						--inputbox "$TUI2_MSG_NET_API_VIP_PROMPT" 0 0 "$cl_api_vip" \
						2>"$_TUI_TMP"
					[[ $? -ne 0 ]] && break
					local api_val
					api_val=$(<"$_TUI_TMP")
					if [[ -n "$api_val" ]] && ! _valid_ip "$api_val"; then
						dlg --backtitle "$(ui_backtitle)" --msgbox \
							"Invalid IP address.\n\nExpected format: N.N.N.N (e.g. 10.0.0.200)" 0 0 || true
						continue
					fi
					[[ -n "$api_val" ]] && cl_api_vip="$api_val"
					break
				done
				;;
			I)
				while :; do
					dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CLUSTER_INGRESS_VIP" \
						--inputbox "$TUI2_MSG_NET_INGRESS_VIP_PROMPT" 0 0 "$cl_ingress_vip" \
						2>"$_TUI_TMP"
					[[ $? -ne 0 ]] && break
					local ing_val
					ing_val=$(<"$_TUI_TMP")
					if [[ -n "$ing_val" ]] && ! _valid_ip "$ing_val"; then
						dlg --backtitle "$(ui_backtitle)" --msgbox \
							"Invalid IP address.\n\nExpected format: N.N.N.N (e.g. 10.0.0.201)" 0 0 || true
						continue
					fi
					[[ -n "$ing_val" ]] && cl_ingress_vip="$ing_val"
					break
				done
				;;
			D)
				while :; do
					dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CLUSTER_DNS" \
						--inputbox "$TUI2_MSG_NET_DNS_PROMPT" 0 0 "$cl_dns" \
						2>"$_TUI_TMP"
					[[ $? -ne 0 ]] && break
					local dns_val
					dns_val=$(<"$_TUI_TMP")
					if [[ -n "$dns_val" ]] && ! _valid_ip_or_host_list "$dns_val"; then
						dlg --backtitle "$(ui_backtitle)" --msgbox \
							"Invalid DNS entry.\n\nExpected: comma-separated IPs (e.g. 10.0.1.8,10.0.1.9)" 0 0 || true
						continue
					fi
					[[ -n "$dns_val" ]] && cl_dns="$dns_val"
					break
				done
				;;
			G)
				while :; do
					dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CLUSTER_GATEWAY" \
						--inputbox "$TUI2_MSG_NET_GATEWAY_PROMPT" 0 0 "$cl_gateway" \
						2>"$_TUI_TMP"
					[[ $? -ne 0 ]] && break
					local gw_val
					gw_val=$(<"$_TUI_TMP")
					if [[ -n "$gw_val" ]] && ! _valid_ip "$gw_val"; then
						dlg --backtitle "$(ui_backtitle)" --msgbox \
							"Invalid IP address.\n\nExpected format: N.N.N.N (e.g. 10.0.1.1)" 0 0 || true
						continue
					fi
					[[ -n "$gw_val" ]] && cl_gateway="$gw_val"
					break
				done
				;;
			N)
				while :; do
					dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CLUSTER_NTP" \
						--inputbox "$TUI2_MSG_NET_NTP_PROMPT" 0 0 "$cl_ntp" \
						2>"$_TUI_TMP"
					[[ $? -ne 0 ]] && break
					local ntp_val
					ntp_val=$(<"$_TUI_TMP")
					if [[ -n "$ntp_val" ]] && ! _valid_ip_or_host_list "$ntp_val"; then
						dlg --backtitle "$(ui_backtitle)" --msgbox \
							"Invalid NTP entry.\n\nExpected: comma-separated IPs or hostnames\n(e.g. 10.0.1.8,ntp.lab.local)" 0 0 || true
						continue
					fi
					[[ -n "$ntp_val" ]] && cl_ntp="$ntp_val"
					break
				done
				;;
		esac
	done
}

# --- Page 3: Interfaces (menu-style with toggle) ---
_cluster_page_iface() {
	local default_item="P"
	# Normalize empty connection to "mirror" (ABA default)
	[[ -z "$cl_connection" ]] && cl_connection="mirror"
	while :; do
		local conn_display="$cl_connection"

		# Build items — add MAC row for bare-metal
		local iface_items=(
			"P" "Ports:       $cl_ports"
			"V" "VLAN:        ${cl_vlan:-(none)}"
			"C" "Connection:  $conn_display"
		)
		if [[ "$cl_platform" == "bm" ]]; then
			local mac_count=0
			[[ -n "$cl_macs" ]] && mac_count=$(echo "$cl_macs" | wc -l)
			if [[ $mac_count -gt 0 ]]; then
				iface_items+=("M" "MACs:        $mac_count entered")
			else
				iface_items+=("M" "MACs:        (none — paste to add)")
			fi
		fi

		dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CLUSTER_IFACE" \
			--cancel-label "$TUI2_BTN_BACK" \
			--ok-label "$TUI2_BTN_SELECT" \
			--extra-button --extra-label "$TUI2_BTN_NEXT" \
			--help-button \
			--default-item "$default_item" \
			--menu "$TUI2_MSG_CLUSTER_IFACE" 13 55 4 \
			"${iface_items[@]}" \
			2>"$_TUI_TMP"
		local rc=$?

		case "$rc" in
			2)
				show_help "$TUI2_HELP_TITLE_IFACE" \
"• Ports: network interface name(s) on the host (e.g., ens1f0)
• VLAN: optional VLAN tag
• Connection: how the cluster reaches container images
  - mirror: uses the local mirror registry
  - proxy: uses an HTTP proxy
  - direct: direct internet access (NAT)"
				continue
				;;
			3) return 0 ;;  # Next (Extra button)
			1) return 1 ;;  # Back (Cancel button)
			255)
				if confirm_quit; then clear; _show_v2_exit_summary; exit 0; fi
				continue
				;;
			0) ;;
		esac

		local choice
		choice=$(<"$_TUI_TMP")
		[[ -n "$choice" ]] && default_item="$choice"

		case "$choice" in
		P)
			while :; do
				dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CLUSTER_PORT_NAMES" \
					--inputbox "$TUI2_MSG_IFACE_PORT_PROMPT" 0 0 "$cl_ports" \
					2>"$_TUI_TMP"
				[[ $? -ne 0 ]] && break
				local ports_val
				ports_val=$(<"$_TUI_TMP")
				if [[ -n "$ports_val" && "$ports_val" =~ [[:space:]] ]]; then
					dlg --backtitle "$(ui_backtitle)" --msgbox \
						"Invalid port name(s).\n\nUse commas to separate multiple ports (e.g. ens1f0,ens1f1).\nSpaces are not allowed." 0 0 || true
					continue
				fi
				cl_ports="$ports_val"
				break
			done
			;;
		V)
			while :; do
				dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CLUSTER_VLAN" \
					--inputbox "$TUI2_MSG_IFACE_VLAN_PROMPT" 0 0 "$cl_vlan" \
					2>"$_TUI_TMP"
				[[ $? -ne 0 ]] && break
				local vlan_val
				vlan_val=$(<"$_TUI_TMP")
				if [[ -n "$vlan_val" && ! "$vlan_val" =~ ^[0-9]+$ ]]; then
					dlg --backtitle "$(ui_backtitle)" --msgbox \
						"Invalid VLAN tag.\n\nMust be a number (e.g. 100, 4094)." 0 0 || true
					continue
				fi
				cl_vlan="$vlan_val"
				break
			done
			;;
		C)
			if [[ "$_TUI_MODE" == "DIRECT" ]]; then
				# Toggle: direct ↔ proxy (no "mirror" in DIRECT mode)
				case "$cl_connection" in
					direct) cl_connection="proxy" ;;
					*) cl_connection="direct" ;;
				esac
			else
				# Toggle: mirror → proxy → direct → mirror
				case "$cl_connection" in
					mirror|"") cl_connection="proxy" ;;
					proxy) cl_connection="direct" ;;
					direct) cl_connection="mirror" ;;
				esac
			fi
			tui_log "Toggled connection to: $cl_connection"
			;;
		M)
			# Paste MAC addresses (one per line, for bare-metal nodes)
			dlg --backtitle "$(ui_backtitle)" --title "MAC Addresses" \
				--inputbox "Enter MAC addresses (one per line, or comma-separated).\nFormat: aa:bb:cc:dd:ee:ff\n\nNeeded: 1 per node per port (masters + workers × ports)." \
				0 0 "$(echo "$cl_macs" | tr '\n' ',' | sed 's/,$//')" \
				2>"$_TUI_TMP"
			if [[ $? -eq 0 ]]; then
				local raw=$(<"$_TUI_TMP")
				# Normalize: convert commas/spaces to newlines, trim whitespace
				cl_macs=$(echo "$raw" | tr ',; ' '\n' | sed '/^$/d' | tr -d ' \t')
				tui_log "MAC addresses entered: $(echo "$cl_macs" | wc -l)"
			fi
			;;
	esac
	done
}

# --- Page 4: VM Resources (menu-style, only for vmw/kvm) ---
_cluster_page_vm() {
	local default_item="C"
	local mac_info=""
	if [[ -f "$ABA_ROOT/macs.conf" ]] && grep -qE '^[^#]' "$ABA_ROOT/macs.conf" 2>/dev/null; then
		mac_info=" (from macs.conf)"
	fi

	while :; do
		local items=()
		items+=("C" "Master CPUs:    ${cl_master_cpu:-8}")
		items+=("R" "Master Memory:  ${cl_master_mem:-32} GB")
		if [[ "$cl_type" == "standard" ]]; then
			items+=("W" "Worker CPUs:    ${cl_worker_cpu:-4}")
			items+=("E" "Worker Memory:  ${cl_worker_mem:-16} GB")
		fi
		items+=("D" "Data disk:      ${cl_disk:-(none)} GB")
		items+=("A" "MAC template:   ${cl_mac_template:-(auto)}${mac_info}")

		dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CLUSTER_VM" \
			--cancel-label "$TUI2_BTN_BACK" \
			--ok-label "$TUI2_BTN_SELECT" \
			--extra-button --extra-label "$TUI2_BTN_NEXT" \
			--help-button \
			--default-item "$default_item" \
			--menu "$(printf "$TUI2_MSG_CLUSTER_VM" "$cl_platform")" 15 55 6 \
			"${items[@]}" \
			2>"$_TUI_TMP"
		local rc=$?

		case "$rc" in
			2)
				show_help "$TUI2_HELP_TITLE_VM" \
"• CPUs/Memory: resources allocated to each VM
• Data disk: additional disk size in GB (optional)
• MAC template: prefix for generated MAC addresses
  (e.g., 52:54:00 — used when macs.conf is not provided)"
				continue
				;;
			3) return 0 ;;  # Next
			1) return 1 ;;  # Back
			255)
				if confirm_quit; then clear; _show_v2_exit_summary; exit 0; fi
				continue
				;;
			0) ;;
		esac

		local choice
		choice=$(<"$_TUI_TMP")
		[[ -n "$choice" ]] && default_item="$choice"

		case "$choice" in
			C)
				dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CLUSTER_MASTER_CPU" \
					--inputbox "$TUI2_MSG_VM_MASTER_CPU_PROMPT" 0 0 "$cl_master_cpu" \
					2>"$_TUI_TMP"
				[[ $? -eq 0 ]] && cl_master_cpu=$(<"$_TUI_TMP")
				;;
			R)
				dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CLUSTER_MASTER_MEM" \
					--inputbox "$TUI2_MSG_VM_MASTER_MEM_PROMPT" 0 0 "$cl_master_mem" \
					2>"$_TUI_TMP"
				[[ $? -eq 0 ]] && cl_master_mem=$(<"$_TUI_TMP")
				;;
			W)
				dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CLUSTER_WORKER_CPU" \
					--inputbox "$TUI2_MSG_VM_WORKER_CPU_PROMPT" 0 0 "$cl_worker_cpu" \
					2>"$_TUI_TMP"
				[[ $? -eq 0 ]] && cl_worker_cpu=$(<"$_TUI_TMP")
				;;
			E)
				dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CLUSTER_WORKER_MEM" \
					--inputbox "$TUI2_MSG_VM_WORKER_MEM_PROMPT" 0 0 "$cl_worker_mem" \
					2>"$_TUI_TMP"
				[[ $? -eq 0 ]] && cl_worker_mem=$(<"$_TUI_TMP")
				;;
			D)
				dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CLUSTER_DATA_DISK" \
					--inputbox "$TUI2_MSG_VM_DISK_PROMPT" 9 55 "$cl_disk" \
					2>"$_TUI_TMP"
				[[ $? -eq 0 ]] && cl_disk=$(<"$_TUI_TMP")
				;;
			A)
				dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CLUSTER_MAC_TEMPLATE" \
					--inputbox "$TUI2_MSG_VM_MAC_PROMPT" 0 0 "$cl_mac_template" \
					2>"$_TUI_TMP"
				[[ $? -eq 0 ]] && cl_mac_template=$(<"$_TUI_TMP")
				;;
		esac
	done
}

# --- Assemble command, show review page, execute install ---
_cluster_execute() {
	local cmd="aba cluster --name $cl_name --type $cl_type"
	[[ -n "$cl_domain" ]] && cmd="$cmd --base-domain $cl_domain"
	[[ -n "$cl_platform" && "$cl_platform" != "bm" ]] && cmd="$cmd --platform $cl_platform"

	[[ -n "$cl_starting_ip" ]] && cmd="$cmd --starting-ip $cl_starting_ip"
	[[ -n "$cl_network" ]] && cmd="$cmd --machine-network $cl_network"
	[[ -n "$cl_dns" ]] && cmd="$cmd --dns ${cl_dns//,/ }"
	[[ -n "$cl_gateway" ]] && cmd="$cmd --gateway-ip $cl_gateway"
	[[ -n "$cl_ntp" ]] && cmd="$cmd --ntp ${cl_ntp//,/ }"
	[[ -n "$cl_ports" ]] && cmd="$cmd --ports ${cl_ports//,/ }"
	[[ -n "$cl_vlan" ]] && cmd="$cmd --vlan $cl_vlan"
	[[ "$cl_connection" == "proxy" || "$cl_connection" == "direct" ]] && cmd="$cmd --int-connection $cl_connection"

	if [[ "$cl_type" != "sno" ]]; then
		[[ -n "$cl_api_vip" ]] && cmd="$cmd --api-vip $cl_api_vip"
		[[ -n "$cl_ingress_vip" ]] && cmd="$cmd --ingress-vip $cl_ingress_vip"
	fi

	if [[ "$cl_type" == "standard" && -n "$cl_workers" ]]; then
		cmd="$cmd --num-workers $cl_workers"
	fi

	# VM resource flags (only for vmw/kvm platforms)
	if [[ "$cl_platform" != "bm" ]]; then
		[[ -n "$cl_master_cpu" && "$cl_master_cpu" != "8" ]] && cmd="$cmd --mcpu $cl_master_cpu"
		[[ -n "$cl_master_mem" && "$cl_master_mem" != "32" ]] && cmd="$cmd --mmem $cl_master_mem"
		if [[ "$cl_type" == "standard" ]]; then
			[[ -n "$cl_worker_cpu" && "$cl_worker_cpu" != "4" ]] && cmd="$cmd --wcpu $cl_worker_cpu"
			[[ -n "$cl_worker_mem" && "$cl_worker_mem" != "16" ]] && cmd="$cmd --wmem $cl_worker_mem"
		fi
		[[ -n "$cl_disk" ]] && cmd="$cmd --data-disk-gb $cl_disk"
	fi

	# Step will be determined after review (bm gets ISO vs Install choice)
	local install_step="install"

	# Review page showing ALL values
	local fqdn="${cl_name}.${cl_domain:-${domain:-example.com}}"

	# Derive node counts
	local _nm=1 _nw=0
	case "$cl_type" in
		sno)      _nm=1; _nw=0 ;;
		compact)  _nm=3; _nw=0 ;;
		standard) _nm=3; _nw="${cl_workers:-2}" ;;
	esac
	local total_nodes=$(( _nm + _nw ))

	# Platform display
	local _plat_disp="$cl_platform"
	case "$cl_platform" in
		bm)  _plat_disp="bm (bare-metal)" ;;
		vmw) _plat_disp="vmw (VMware/ESXi)" ;;
		kvm) _plat_disp="kvm (libvirt/KVM)" ;;
	esac

	# Mirror registry name — source mirror.conf for reg_host/reg_port
	local _mirror_disp="(none — direct install)"
	if [[ "$cl_connection" != "direct" && "$_TUI_MODE" != "DIRECT" ]]; then
		local reg_host="${reg_host:-}" reg_port="${reg_port:-}"
		if [[ -f "$ABA_ROOT/mirror/mirror.conf" ]]; then
			source <(cd "$ABA_ROOT/mirror" && normalize-mirror-conf) 2>/dev/null || true
		fi
		_mirror_disp="${reg_host:-}${reg_host:+:}${reg_port:-}"
		[[ -z "$_mirror_disp" || "$_mirror_disp" == ":" ]] && _mirror_disp="(local mirror)"
	fi

	# Operator count
	local _op_count="${#OP_BASKET[@]}"

	# Connection display
	local _conn_disp="${cl_connection:-mirror}"

	local summary="Review — Confirm before installing:\n\n"
	summary+="  Cluster:      $fqdn\n"
	summary+="  Type:         $cl_type ($_nm master, $_nw workers = $total_nodes node$( [[ $total_nodes -ne 1 ]] && echo s))\n"
	summary+="  Platform:     $_plat_disp\n"
	summary+="  OpenShift:    ${ocp_version:-?} (${ocp_channel:-?})\n"
	summary+="  Mode:         $_TUI_MODE\n"
	summary+="  Mirror:       $_mirror_disp\n"
	summary+="\n"
	summary+="  Network:      ${cl_network:-(auto)}\n"
	summary+="  Starting IP:  ${cl_starting_ip:-(auto)}\n"
	if [[ "$cl_type" != "sno" ]]; then
		summary+="  API VIP:      ${cl_api_vip:-(auto: DNS)}\n"
		summary+="  Ingress VIP:  ${cl_ingress_vip:-(auto: DNS)}\n"
	fi
	summary+="  DNS:          ${cl_dns:-(auto)}\n"
	summary+="  Gateway:      ${cl_gateway:-(auto)}\n"
	summary+="  NTP:          ${cl_ntp:-(none)}\n"
	summary+="\n"
	summary+="  Ports:        ${cl_ports:-(default)}\n"
	[[ -n "$cl_vlan" ]] && summary+="  VLAN:         $cl_vlan\n"
	summary+="  Connection:   $_conn_disp\n"
	summary+="  SSH key:      ~/.ssh/id_rsa\n"
	summary+="\n"
	if [[ "$cl_platform" != "bm" ]]; then
		summary+="  Master CPU:   $cl_master_cpu\n"
		summary+="  Master Mem:   ${cl_master_mem} GB\n"
		if [[ "$cl_type" == "standard" ]]; then
			summary+="  Worker CPU:   $cl_worker_cpu\n"
			summary+="  Worker Mem:   ${cl_worker_mem} GB\n"
		fi
		[[ -n "$cl_disk" ]] && summary+="  Data disk:    ${cl_disk} GB\n"
		summary+="  MAC prefix:   ${cl_mac_template:-(auto)}\n"
	fi
	if [[ -n "$cl_macs" && "$cl_platform" == "bm" ]]; then
		local mac_cnt
		mac_cnt=$(echo "$cl_macs" | wc -l)
		summary+="  MACs:         $mac_cnt addresses\n"
	fi
	summary+="\n"
	summary+="  Operators:    $_op_count selected\n"

	while :; do
		dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CLUSTER_INSTALL" \
			--yes-label "$TUI2_BTN_INSTALL" \
			--no-label "$TUI2_BTN_BACK" \
			--yesno "$summary" 0 0
		local rc=$?
		case "$rc" in
			0) break ;;  # Install
			1) return 1 ;;  # Back to edit
			255)
				if confirm_quit; then clear; _show_v2_exit_summary; exit 0; fi
				continue
				;;
		esac
	done

	# For bare-metal: offer choice between ISO creation only or full install
	if [[ "$cl_platform" == "bm" ]]; then
		dlg --backtitle "$(ui_backtitle)" --title "Install Action" \
			--menu "Choose the install action:" 0 0 0 \
			"F" "Full Install (create ISO + monitor until complete)" \
			"I" "Create ISO only (download ISO, then boot servers manually)" \
			2>"$_TUI_TMP"
		case $? in
			0)
				local _action=$(<"$_TUI_TMP")
				case "$_action" in
					F) install_step="install" ;;
					I) install_step="iso" ;;
				esac
				;;
			1|255) return 1 ;;
		esac
	fi
	cmd="$cmd -s $install_step"

	tui_log "Installing cluster ($install_step): $cmd"

	# Write macs.conf if MACs were entered (bare-metal)
	if [[ -n "$cl_macs" && "$cl_platform" == "bm" ]]; then
		local cluster_dir="$ABA_ROOT/$cl_name"
		mkdir -p "$cluster_dir"
		echo "$cl_macs" > "$cluster_dir/macs.conf"
		tui_log "Wrote ${cluster_dir}/macs.conf with $(echo "$cl_macs" | wc -l) entries"
	fi

	# Platform config check before executing
	_check_platform_config "$cl_name" || return 1

	# Long operation — use confirm_and_execute (terminal/TUI mode choice)
	confirm_and_execute "$cmd" "Install Cluster: $fqdn"
}

# =============================================================================
# Cluster Install (with platform config check + auto-monitor)
# =============================================================================




# --- Platform config check ---
_check_platform_config() {
	local dir="$1"
	# $platform already available from sourced aba.conf
	# vmware.conf/kvm.conf live in cluster dir, with fallback to parent and $HOME

	case "$platform" in
		vmw)
			if [[ ! -s "$dir/vmware.conf" && ! -s vmware.conf && ! -s "$HOME/vmware.conf" ]]; then
				_platform_config_missing "VMware" "vmware.conf" \
					"vcenter_fqdn, vcenter_user, vcenter_pass, datacenter, datastore, network, folder, cluster"
				return $?
			fi
			;;
		kvm)
			if [[ ! -s "$dir/kvm.conf" && ! -s kvm.conf && ! -s "$HOME/kvm.conf" ]]; then
				_platform_config_missing "KVM" "kvm.conf" \
					"libvirt_uri, storage_pool, network"
				return $?
			fi
			;;
	esac
	return 0
}

_platform_config_missing() {
	local name="$1" path="$2" fields="$3"

	while :; do
		dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_PLATFORM_CHECK" \
			--cancel-label "$TUI2_BTN_CANCEL" \
			--menu "$(printf "$TUI2_MSG_PLATFORM_CONFIG_MISSING" "$name" "$path" "$fields")" 0 0 0 \
			"1" "Edit in terminal (\$EDITOR)" \
			"2" "Edit in TUI dialog" \
			"3" "Skip (proceed without config)" \
			2>"$_TUI_TMP"
		local rc=$?
		case "$rc" in
			1) return 1 ;;  # Cancel
			255)
				if confirm_quit; then clear; _show_v2_exit_summary; exit 0; fi
				continue
				;;
			0) ;;
		esac

		local choice
		choice=$(<"$_TUI_TMP")

		case "$choice" in
			1)
				clear
				${EDITOR:-vi} "$path"
				;;
			2)
				# Create minimal template if file doesn't exist
				if [[ ! -f "$path" ]]; then
					echo "# $name configuration" > "$path"
				fi
				dlg --backtitle "$(ui_backtitle)" --title "Edit $name Config" \
					--ok-label "$TUI2_BTN_SAVE" --cancel-label "$TUI2_BTN_CANCEL" \
					--editbox "$path" 0 0 2>"$_TUI_TMP"
				[[ $? -eq 0 ]] && cp "$_TUI_TMP" "$path"
				;;
			3)
				return 0
				;;
		esac

		# Re-check
		[[ -f "$path" ]] && return 0
	done
}

# =============================================================================
# Cluster Monitor
# =============================================================================

cluster_monitor() {
	tui_log "Action: Monitor Cluster"

	if ! select_installed_cluster "$TUI2_TITLE_CLUSTER_MONITOR" "Select cluster to monitor:"; then
		return 1
	fi

	confirm_and_execute "aba -d $SELECTED_CLUSTER mon" "$TUI2_TITLE_CLUSTER_MONITOR"
}

# =============================================================================
# Delete Cluster
# =============================================================================

cluster_delete() {
	tui_log "Action: Delete Cluster"

	if ! select_cluster "$TUI2_TITLE_CLUSTER_DELETE" "Select cluster to delete:"; then
		return 1
	fi

	local cl_display
	cl_display=$(cluster_display_name "$SELECTED_CLUSTER")

	dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CLUSTER_DELETE" \
		--yes-label "Delete" --no-label "Cancel" \
		--yesno "Delete cluster '$cl_display'?\n\nThis will destroy all VMs and remove cluster resources.\nThis action cannot be undone." 0 0
	local rc=$?
	[[ $rc -ne 0 ]] && return 1

	confirm_and_execute "aba -d $SELECTED_CLUSTER delete" "$TUI2_TITLE_CLUSTER_DELETE: $cl_display"
}

# =============================================================================
# Day-2 Operations
# =============================================================================

cluster_day2_menu() {
	tui_log "Action: Day-2 menu"
	local default_item="full"

	while :; do
		dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_DAY2_MENU" \
			--cancel-label "$TUI2_BTN_BACK" \
			--help-button \
			--default-item "$default_item" \
			--menu "$TUI2_MSG_DAY2_MENU" 0 0 0 \
			"F" "Day-2: Full configuration" \
			"N" "Day-2: NTP only" \
			"O" "Day-2: OSUS (Cincinnati upgrade service)" \
			2>"$_TUI_TMP"
		local rc=$?

		case "$rc" in
			2)
				show_help "$TUI2_HELP_TITLE_DAY2" \
"• Full: applies all Day-2 configuration (IDMS, CatalogSources, NTP, etc.)
• NTP: configures NTP on all cluster nodes
• OSUS: installs the Cincinnati/OSUS operator for connected upgrades
  (requires the cincinnati-operator in your ImageSet config)"
				continue
				;;
			0) ;;
			1) return 0 ;;  # Back
			255)
				if confirm_quit; then clear; _show_v2_exit_summary; exit 0; fi
				continue
				;;
		esac

		local choice
		choice=$(<"$_TUI_TMP")
		[[ -n "$choice" ]] && default_item="$choice"

		case "$choice" in
			F) _day2_run "day2" ;;
			N) _day2_run "day2-ntp" ;;
			O) _day2_run_osus ;;
		esac
	done
}

_day2_run() {
	local target="$1"

	if ! select_installed_cluster "$TUI2_TITLE_DAY2_MENU" "Select cluster for Day-2:"; then
		return 1
	fi

	confirm_and_execute "aba -d $SELECTED_CLUSTER $target" "Day-2: $target"
}

_day2_run_osus() {
	# Pre-check: warn if Cincinnati operator not in ISC
	local isconf_file="$ABA_ROOT/mirror/data/imageset-config.yaml"
	if [[ -f "$isconf_file" ]]; then
		if ! grep -q "cincinnati-operator" "$isconf_file" 2>/dev/null; then
			dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CLUSTER_OSUS_WARN" \
				--yes-label "$TUI2_BTN_CONTINUE" \
				--no-label "$TUI2_BTN_CANCEL" \
				--yesno "$TUI2_MSG_OSUS_WARNING" 0 0
			[[ $? -ne 0 ]] && return 0
		fi
	fi

	_day2_run "day2-osus"
}
