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
#   - Button layout: Select | Next | Back | Help (page 1).
#     Page 1 Help shows comprehensive wizard help. ESC exits wizard to main menu.
#     Tab order from menu area: Tab→Extra(Next), Tab Tab→Cancel(Back).
#     Empirically verified on dialog 1.3 (RHEL 9). See plan appendix A.25.
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
_cl_ssh_key="~/.ssh/id_rsa"
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
			prefix_length)    [[ -n "$val" && "$cl_network" != */* ]] && cl_network="${cl_network}/${val}" ;;
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
			ssh_key_file)     cl_ssh_key="$val" ;;
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

	# Load macs.conf if it exists alongside cluster.conf
	local _macs_file="${conf%/*}/macs.conf"
	if [[ -f "$_macs_file" ]]; then
		cl_macs="$(< "$_macs_file")"
	fi

	return 0
}

# Write current wizard values back to cluster.conf (the single source of truth).
# Called after every page transition so changes persist across re-entries and crashes.
_persist_cluster_draft() {
	local _conf="$ABA_ROOT/$cl_name/cluster.conf"
	[[ ! -f "$_conf" ]] && return 0

	replace-value-conf -q -n cluster_name     -v "$cl_name"        -f "$_conf"
	replace-value-conf -q -n base_domain      -v "$cl_domain"      -f "$_conf"
	replace-value-conf -q -n machine_network  -v "$cl_network"     -f "$_conf"
	replace-value-conf -q -n starting_ip      -v "$cl_starting_ip" -f "$_conf"
	replace-value-conf -q -n api_vip          -v "$cl_api_vip"     -f "$_conf"
	replace-value-conf -q -n ingress_vip      -v "$cl_ingress_vip" -f "$_conf"
	replace-value-conf -q -n dns_servers      -v "$cl_dns"         -f "$_conf"
	replace-value-conf -q -n next_hop_address -v "$cl_gateway"     -f "$_conf"
	replace-value-conf -q -n ntp_servers      -v "$cl_ntp"         -f "$_conf"
	replace-value-conf -q -n ports            -v "$cl_ports"       -f "$_conf"
	replace-value-conf -q -n vlan             -v "$cl_vlan"        -f "$_conf"
	replace-value-conf -q -n ssh_key_file     -v "$cl_ssh_key"     -f "$_conf"
	replace-value-conf -q -n mac_prefix       -v "$cl_mac_template" -f "$_conf"
	replace-value-conf -q -n master_cpu_count -v "$cl_master_cpu"  -f "$_conf"
	replace-value-conf -q -n master_mem       -v "$cl_master_mem"  -f "$_conf"
	replace-value-conf -q -n worker_cpu_count -v "$cl_worker_cpu"  -f "$_conf"
	replace-value-conf -q -n worker_mem       -v "$cl_worker_mem"  -f "$_conf"
	replace-value-conf -q -n data_disk        -v "$cl_disk"        -f "$_conf"

	# int_connection: empty means "use mirror" (the default)
	local _conn="$cl_connection"
	[[ "$_conn" == "mirror" ]] && _conn=""
	replace-value-conf -q -n int_connection   -v "$_conn"          -f "$_conf"

	# Derive num_masters/num_workers from type
	case "$cl_type" in
		sno)      replace-value-conf -q -n num_masters -v 1 -f "$_conf"
		          replace-value-conf -q -n num_workers -v 0 -f "$_conf" ;;
		compact)  replace-value-conf -q -n num_masters -v 3 -f "$_conf"
		          replace-value-conf -q -n num_workers -v 0 -f "$_conf" ;;
		standard) replace-value-conf -q -n num_masters -v 3 -f "$_conf"
		          replace-value-conf -q -n num_workers -v "$cl_workers" -f "$_conf" ;;
	esac

	tui_log "Persisted wizard values to $_conf"

	# Persist macs.conf for bare-metal (not stored in cluster.conf)
	if [[ "${cl_platform:-}" == "bm" && -n "${cl_macs:-}" ]]; then
		echo "$cl_macs" > "$ABA_ROOT/$cl_name/macs.conf"
		tui_log "Persisted macs.conf for '$cl_name'"
	fi
}

# Generate a preliminary cluster.conf via aba core to get real defaults.
# Called after page 1 (Basics) completes. If the config already exists,
# just loads it. The file is the single source of truth — _persist_cluster_draft
# writes user changes back after every page.
_cluster_generate_defaults() {
	local _conf="$ABA_ROOT/$cl_name/cluster.conf"

	# Always call core -- handles both new and existing cluster.conf.
	# For new: renders from template with auto-detected values.
	# For existing: fills empty network fields from aba.conf.
	local _cmd="aba cluster --name $cl_name --type $cl_type --platform $cl_platform --step cluster.conf --yes"
	tui_log "Generating/refreshing defaults: $_cmd"

	# Run it (fast ~2s) — fully detached from TUI's terminal/dialog
	local _gen_rc=0
	(cd "$ABA_ROOT" && eval "$_cmd") </dev/null >>"$_TUI_LOG_FILE" 2>&1 || _gen_rc=$?
	if [[ $_gen_rc -ne 0 ]]; then
		tui_log "ERROR: Failed to generate cluster.conf (rc=$_gen_rc)"
		dlg --backtitle "$(ui_backtitle)" --msgbox \
			"Failed to generate cluster configuration (exit code $_gen_rc).\n\nCheck the TUI log for details:\n  $_TUI_LOG_FILE\n\nYou may need to fix aba.conf or platform configuration." 0 0 || true
		return 1
	fi

	# Load the (now-populated) config into form fields
	if [[ -f "$_conf" ]]; then
		_cluster_load_conf "$_conf"
		tui_log "Loaded cluster.conf for '$cl_name'"
	fi
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
			cached_info=$(source "$cached_path" 2>/dev/null && echo "$GOVC_URL")
		else
			cached_info=$(source "$cached_path" 2>/dev/null && echo "$LIBVIRT_URI")
		fi

		dlg --backtitle "$(ui_backtitle)" --title "$plat_label Configuration" \
			--yes-label "Use Existing" \
			--no-label "Configure New" \
			--extra-button --extra-label "$TUI2_BTN_SKIP" \
			--yesno "\nA previous $plat_label configuration was found:\n\n  ${cached_info:-$cached_path}\n\nUse this configuration or create a new one?" 0 0
		local rc=$?
		case "$rc" in
			0)
				cp "$cached_path" "$conf_path"
				tui_log "Reused cached $conf_name from $cached_path"
				return 0
				;;
			1)
				_configure_platform_file "$conf_name" "$plat_label" || return 1
				return 0
				;;
			3)
				tui_log "Skipped $conf_name configuration (will be required at install time)"
				return 0
				;;
			255)
				return 1
				;;
		esac
	fi

	# No cached config — prompt to configure or skip
	dlg --backtitle "$(ui_backtitle)" --title "$plat_label Configuration" \
		--yes-label "Configure Now" \
		--no-label "$TUI2_BTN_SKIP" \
		--yesno "\nPlatform is set to $cl_platform but $conf_name is not configured.\n\nConfigure now or skip? (Required before install.)" 0 0
	local rc=$?
	case "$rc" in
		0)
			# If user cancels inside config form, return 1 to stay on page 1
			_configure_platform_file "$conf_name" "$plat_label" || return 1
			return 0
			;;
		*)
			tui_log "Skipped $conf_name configuration"
			return 0
			;;
	esac
}

# Route to the appropriate platform config form
_configure_platform_file() {
	local conf_name="$1" plat_label="$2"

	case "$conf_name" in
		vmware.conf) _configure_vmw_form ;;
		kvm.conf)    _configure_kvm_form ;;
	esac
}

# VMware config form — menu with one row per GOVC_* field
_configure_vmw_form() {
	local conf_path="$ABA_ROOT/vmware.conf"

	# Create from template if missing
	if [[ ! -s "$conf_path" ]]; then
		cp "$ABA_ROOT/templates/vmware.conf" "$conf_path"
	fi

	# Load current values
	local v_url="" v_user="" v_pass="" v_datastore="" v_network=""
	local v_datacenter="" v_cluster="" v_folder="" v_insecure=""
	source <(normalize-vmware-conf) 2>/dev/null || true
	v_url="${GOVC_URL:-}"
	v_user="${GOVC_USERNAME:-}"
	v_pass="${GOVC_PASSWORD:-}"
	v_datastore="${GOVC_DATASTORE:-}"
	v_network="${GOVC_NETWORK:-}"
	v_datacenter="${GOVC_DATACENTER:-}"
	v_cluster="${GOVC_CLUSTER:-}"
	v_folder="${VC_FOLDER:-}"
	v_insecure="${GOVC_INSECURE:-true}"

	local default_item="U"
	while :; do
		dlg --backtitle "$(ui_backtitle)" --title "VMware/ESXi Configuration" \
			--default-item "$default_item" \
			--ok-label "$TUI2_BTN_SELECT" \
			--extra-button --extra-label "Continue" \
			--cancel-label "$TUI2_BTN_BACK" \
			--menu "Configure vSphere/ESXi connection — select a row to edit:" 0 0 0 \
			"U"  "vCenter/ESXi URL:  $v_url" \
			"N"  "Username:          $v_user" \
			"P"  "Password:          ${v_pass:+(set)}" \
			"D"  "Datastore:         $v_datastore" \
			"W"  "Network:           $v_network" \
			"C"  "Datacenter:        $v_datacenter" \
			"L"  "Cluster:           $v_cluster" \
			"F"  "VM Folder:         $v_folder" \
			"I"  "Skip TLS verify:   $v_insecure" \
			"T"  "── Test Connection ──" \
			2>"$_TUI_TMP"
		local rc=$?

		case "$rc" in
			3) break ;;        # Continue → done
			1|255) return 1 ;; # Back/Cancel
			0) ;;              # Select → edit field
		esac

		local field
		field=$(<"$_TUI_TMP")
		[[ -n "$field" ]] && default_item="$field"

		case "$field" in
			U)
				dlg --backtitle "$(ui_backtitle)" --inputbox "vCenter or ESXi hostname/IP:" 0 60 "$v_url" 2>"$_TUI_TMP"
				if [[ $? -eq 0 ]]; then
					v_url=$(<"$_TUI_TMP")
					_tui_reject_squote "$v_url" || continue
					# Strip protocol prefix for validation; govc accepts host, host:port, or https://host forms
					local _url_host="${v_url#https://}"
					_url_host="${_url_host%%/*}"
					_url_host="${_url_host%%:*}"
					if [[ -n "$_url_host" ]] && ! _valid_fqdn "$_url_host" && ! _valid_ip "$_url_host"; then
						dlg --backtitle "$(ui_backtitle)" --msgbox \
							"Invalid hostname/IP.\n\nExpected: FQDN or IP (e.g. vcenter.lab.com, 10.0.1.5)." 0 0
						continue
					fi
					replace-value-conf -q -n GOVC_URL -v "$v_url" -f "$conf_path"
				fi
				;;
			N)
				dlg --backtitle "$(ui_backtitle)" --inputbox "Username:" 0 60 "$v_user" 2>"$_TUI_TMP"
				if [[ $? -eq 0 ]]; then
					v_user=$(<"$_TUI_TMP")
					_tui_reject_squote "$v_user" || continue
					replace-value-conf -q -n GOVC_USERNAME -v "$v_user" -f "$conf_path"
				fi
				;;
			P)
				_tui_prompt_password "Enter vSphere/ESXi password:" || continue
				v_pass=$(<"$_TUI_TMP")
				replace-value-conf -q -n GOVC_PASSWORD -v "'$v_pass'" -f "$conf_path"
				;;
			D)
				dlg --backtitle "$(ui_backtitle)" --inputbox "Datastore name:" 0 60 "$v_datastore" 2>"$_TUI_TMP"
				if [[ $? -eq 0 ]]; then
					v_datastore=$(<"$_TUI_TMP")
					_tui_reject_squote "$v_datastore" || continue
					replace-value-conf -q -n GOVC_DATASTORE -v "$v_datastore" -f "$conf_path"
				fi
				;;
			W)
				dlg --backtitle "$(ui_backtitle)" --inputbox "Network (port group name):" 0 60 "$v_network" 2>"$_TUI_TMP"
				if [[ $? -eq 0 ]]; then
					v_network=$(<"$_TUI_TMP")
					_tui_reject_squote "$v_network" || continue
					replace-value-conf -q -n GOVC_NETWORK -v "'$v_network'" -f "$conf_path"
				fi
				;;
			C)
				dlg --backtitle "$(ui_backtitle)" --inputbox "Datacenter name:" 0 60 "$v_datacenter" 2>"$_TUI_TMP"
				if [[ $? -eq 0 ]]; then
					v_datacenter=$(<"$_TUI_TMP")
					_tui_reject_squote "$v_datacenter" || continue
					replace-value-conf -q -n GOVC_DATACENTER -v "$v_datacenter" -f "$conf_path"
				fi
				;;
			L)
				dlg --backtitle "$(ui_backtitle)" --inputbox "Cluster name:" 0 60 "$v_cluster" 2>"$_TUI_TMP"
				if [[ $? -eq 0 ]]; then
					v_cluster=$(<"$_TUI_TMP")
					_tui_reject_squote "$v_cluster" || continue
					replace-value-conf -q -n GOVC_CLUSTER -v "$v_cluster" -f "$conf_path"
				fi
				;;
			F)
				dlg --backtitle "$(ui_backtitle)" --inputbox "VM folder path (e.g. /Datacenter/vm):" 0 60 "$v_folder" 2>"$_TUI_TMP"
				if [[ $? -eq 0 ]]; then
					v_folder=$(<"$_TUI_TMP")
					_tui_reject_squote "$v_folder" || continue
					replace-value-conf -q -n VC_FOLDER -v "$v_folder" -f "$conf_path"
				fi
				;;
			I)
				# Toggle true/false
				if [[ "$v_insecure" == "true" ]]; then
					v_insecure="false"
				else
					v_insecure="true"
				fi
				replace-value-conf -q -n GOVC_INSECURE -v "$v_insecure" -f "$conf_path"
				;;
			T)
				_test_vmw_connection
				;;
		esac
	done

	# Save to home cache
	[[ -s "$conf_path" ]] && cp "$conf_path" "$HOME/.vmware.conf" 2>/dev/null || true
	tui_log "VMware config saved"
	return 0
}

# Test vSphere/ESXi connection using current vmware.conf
_test_vmw_connection() {
	dlg --backtitle "$(ui_backtitle)" --infobox "\nTesting vSphere/ESXi connection..." 0 0
	source <(normalize-vmware-conf) 2>/dev/null || true
	ensure_govc >>"$_TUI_LOG_FILE" 2>&1 || true

	if ! command -v govc >/dev/null 2>&1; then
		dlg --backtitle "$(ui_backtitle)" --msgbox "\n'govc' could not be installed.\n\nCannot verify vSphere connection." 0 0
		return 1
	fi

	local _out
	if _out=$(govc about 2>&1); then
		dlg --backtitle "$(ui_backtitle)" --title "Connection Successful" \
			--no-collapse --cr-wrap \
			--msgbox "\nvSphere connection verified!\n\n$_out" 0 0
		return 0
	else
		dlg --backtitle "$(ui_backtitle)" --title "Connection Failed" \
			--msgbox "\nCannot connect to vSphere at ${GOVC_URL:-?}\n\n$_out\n\nCheck URL, username, and password." 0 0
		return 1
	fi
}

# KVM/libvirt config form — menu with one row per field
_configure_kvm_form() {
	local conf_path="$ABA_ROOT/kvm.conf"

	# Create from template if missing
	if [[ ! -s "$conf_path" ]]; then
		cp "$ABA_ROOT/templates/kvm.conf" "$conf_path"
	fi

	# Load current values
	local k_uri="" k_pool="" k_network="" k_boot="" k_graphics=""
	source <(normalize-kvm-conf) 2>/dev/null || true
	k_uri="${LIBVIRT_URI:-}"
	k_pool="${KVM_STORAGE_POOL:-}"
	k_network="${KVM_NETWORK:-}"
	k_boot="${KVM_BOOT_ARGS:-}"
	k_graphics="${KVM_GRAPHICS_ARGS:-}"

	local default_item="U"
	while :; do
		dlg --backtitle "$(ui_backtitle)" --title "KVM/Libvirt Configuration" \
			--default-item "$default_item" \
			--ok-label "$TUI2_BTN_SELECT" \
			--extra-button --extra-label "Continue" \
			--cancel-label "$TUI2_BTN_BACK" \
			--menu "Configure KVM/libvirt connection — select a row to edit:" 0 0 0 \
			"U"  "Libvirt URI:    $k_uri" \
			"S"  "Storage pool:   $k_pool" \
			"N"  "Network bridge: $k_network" \
			"B"  "Boot args:      $k_boot" \
			"G"  "Graphics args:  $k_graphics" \
			"T"  "── Test Connection ──" \
			2>"$_TUI_TMP"
		local rc=$?

		case "$rc" in
			3) break ;;        # Continue → done
			1|255) return 1 ;; # Back/Cancel
			0) ;;              # Select → edit field
		esac

		local field
		field=$(<"$_TUI_TMP")
		[[ -n "$field" ]] && default_item="$field"

		case "$field" in
			U)
				dlg --backtitle "$(ui_backtitle)" --inputbox "Libvirt connection URI\n(e.g. qemu+ssh://user@host/system):" 0 70 "$k_uri" 2>"$_TUI_TMP"
				if [[ $? -eq 0 ]]; then
					k_uri=$(<"$_TUI_TMP")
					_tui_reject_squote "$k_uri" || continue
					replace-value-conf -q -n LIBVIRT_URI -v "$k_uri" -f "$conf_path"
				fi
				;;
			S)
				dlg --backtitle "$(ui_backtitle)" --inputbox "Storage pool path on KVM host:" 0 60 "$k_pool" 2>"$_TUI_TMP"
				if [[ $? -eq 0 ]]; then
					k_pool=$(<"$_TUI_TMP")
					_tui_reject_squote "$k_pool" || continue
					replace-value-conf -q -n KVM_STORAGE_POOL -v "$k_pool" -f "$conf_path"
				fi
				;;
			N)
				dlg --backtitle "$(ui_backtitle)" --inputbox "Bridge name on KVM host:" 0 60 "$k_network" 2>"$_TUI_TMP"
				if [[ $? -eq 0 ]]; then
					k_network=$(<"$_TUI_TMP")
					_tui_reject_squote "$k_network" || continue
					replace-value-conf -q -n KVM_NETWORK -v "$k_network" -f "$conf_path"
				fi
				;;
			B)
				dlg --backtitle "$(ui_backtitle)" --inputbox "Boot firmware/order (e.g. uefi,hd,cdrom):" 0 60 "$k_boot" 2>"$_TUI_TMP"
				if [[ $? -eq 0 ]]; then
					k_boot=$(<"$_TUI_TMP")
					_tui_reject_squote "$k_boot" || continue
					replace-value-conf -q -n KVM_BOOT_ARGS -v "$k_boot" -f "$conf_path"
				fi
				;;
			G)
				dlg --backtitle "$(ui_backtitle)" --inputbox "Graphics args (e.g. vnc,listen=0.0.0.0 --video virtio):" 0 70 "$k_graphics" 2>"$_TUI_TMP"
				if [[ $? -eq 0 ]]; then
					k_graphics=$(<"$_TUI_TMP")
					_tui_reject_squote "$k_graphics" || continue
					replace-value-conf -q -n KVM_GRAPHICS_ARGS -v "'$k_graphics'" -f "$conf_path"
				fi
				;;
			T)
				_test_kvm_connection
				;;
		esac
	done

	# Save to home cache
	[[ -s "$conf_path" ]] && cp "$conf_path" "$HOME/.kvm.conf" 2>/dev/null || true
	tui_log "KVM config saved"
	return 0
}

# Test libvirt connection using current kvm.conf
_test_kvm_connection() {
	dlg --backtitle "$(ui_backtitle)" --infobox "\nTesting libvirt connection..." 0 0
	source <(normalize-kvm-conf) 2>/dev/null || true
	ensure_virsh >>"$_TUI_LOG_FILE" 2>&1 || true

	if ! command -v virsh >/dev/null 2>&1; then
		dlg --backtitle "$(ui_backtitle)" --msgbox "\n'virsh' could not be installed.\n\nCannot verify libvirt connection." 0 0
		return 1
	fi

	local _out
	if _out=$(virsh -c "${LIBVIRT_URI:-}" version 2>&1); then
		dlg --backtitle "$(ui_backtitle)" --title "Connection Successful" \
			--msgbox "\nLibvirt connection verified!\n\n$_out" 0 0
		return 0
	else
		dlg --backtitle "$(ui_backtitle)" --title "Connection Failed" \
			--msgbox "\nCannot connect to libvirt at:\n${LIBVIRT_URI:-?}\n\n$_out\n\nCheck URI and SSH access." 0 0
		return 1
	fi
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
		_cl_master_cpu=""
		_cl_master_mem=""
		_cl_worker_cpu=""
		_cl_worker_mem=""
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
	local cl_connection="$_cl_connection" cl_ssh_key="$_cl_ssh_key"
	local cl_macs="$_cl_macs"
	local cl_master_cpu="$_cl_master_cpu" cl_master_mem="$_cl_master_mem"
	local cl_worker_cpu="$_cl_worker_cpu" cl_worker_mem="$_cl_worker_mem"
	local cl_disk="$_cl_disk" cl_mac_template="$_cl_mac_template"
	local cl_platform="$_cl_platform"

	# --- Always load from cluster.conf (the single source of truth) ---
	# _persist_cluster_draft writes changes after every page, so the file
	# always has the user's latest values, even across re-entries.
	local _draft_loaded=false
	if [[ -n "$cl_name" && -f "$ABA_ROOT/$cl_name/cluster.conf" ]]; then
		_cluster_load_conf "$ABA_ROOT/$cl_name/cluster.conf"
		_draft_loaded=true
		tui_log "Loaded cluster.conf for '$cl_name'"
		# Load macs.conf for bare-metal (separate file, not in cluster.conf)
		if [[ -f "$ABA_ROOT/$cl_name/macs.conf" ]]; then
			cl_macs=$(<"$ABA_ROOT/$cl_name/macs.conf")
		fi
	fi

	# Pre-fill from aba.conf when no cluster.conf exists yet (core will auto-detect
	# network values when _cluster_generate_defaults calls aba cluster --step cluster.conf)
	if [[ "$_draft_loaded" == "false" ]]; then
		cl_network="${machine_network:-}"
		# Recombine prefix_length (normalize-aba-conf splits "10.0.0.0/24" into two vars)
		[[ -n "${prefix_length:-}" && -n "$cl_network" && "$cl_network" != */* ]] && cl_network="${cl_network}/${prefix_length}"
		cl_dns="${dns_servers:-}"
		cl_gateway="${next_hop_address:-}"
		cl_ntp="${ntp_servers:-}"

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

	# Sanitize cl_connection for the current TUI mode.
	# DIRECT: only "direct" and "proxy" are valid.
	# DISCO: only "mirror" is valid (no internet).
	# CONNO: all three (mirror/proxy/direct) are valid — don't override.
	_apply_mode_connection() {
		if [[ "$_TUI_MODE" == "DIRECT" ]]; then
			[[ "$cl_connection" != "proxy" ]] && cl_connection="direct"
		elif [[ "$_TUI_MODE" == "DISCO" ]]; then
			[[ "$cl_connection" != "mirror" ]] && cl_connection="mirror"
		fi
	}
	_apply_mode_connection

	# Save locals back to globals (called before every return)
	_cl_save_state() {
		_cl_name="$cl_name"; _cl_domain="$cl_domain"
		_cl_type="$cl_type"; _cl_workers="$cl_workers"
		_cl_network="$cl_network"; _cl_starting_ip="$cl_starting_ip"
		_cl_api_vip="$cl_api_vip"; _cl_ingress_vip="$cl_ingress_vip"
		_cl_dns="$cl_dns"; _cl_gateway="$cl_gateway"; _cl_ntp="$cl_ntp"
		_cl_ports="$cl_ports"; _cl_vlan="$cl_vlan"
		_cl_connection="$cl_connection"; _cl_ssh_key="$cl_ssh_key"
		_cl_macs="$cl_macs"
		_cl_master_cpu="$cl_master_cpu"; _cl_master_mem="$cl_master_mem"
		_cl_worker_cpu="$cl_worker_cpu"; _cl_worker_mem="$cl_worker_mem"
		_cl_disk="$cl_disk"; _cl_mac_template="$cl_mac_template"
		_cl_platform="$cl_platform"
	}

	# Page navigation: 0=advance, 1=back one page, 255=ESC (exit wizard).
	# Page 1 Back breaks the loop (returns to action menu).
	local page=1
	while :; do
		case $page in
			1)
				_cluster_page_basics
				local _rc=$?
				if [[ $_rc -eq 255 ]]; then _cl_save_state; return 1; fi
				if [[ $_rc -ne 0 ]]; then page=0; break; fi
				_gate_platform_config || continue
				# Generate preliminary cluster.conf to get real defaults from aba core
				_cluster_generate_defaults || continue
				_apply_mode_connection
				_persist_cluster_draft
				;;
			2)
				_cluster_page_network
				local _rc=$?
				if [[ $_rc -eq 255 ]]; then _cl_save_state; return 1; fi
				if [[ $_rc -eq 1 ]]; then page=$((page - 1)); continue; fi
				_persist_cluster_draft
				;;
			3)
				_cluster_page_iface
				local _rc=$?
				if [[ $_rc -eq 255 ]]; then _cl_save_state; return 1; fi
				if [[ $_rc -eq 1 ]]; then page=$((page - 1)); continue; fi
				_persist_cluster_draft
				;;
			4)
				if [[ "$cl_platform" != "bm" ]]; then
					_cluster_page_vm
					local _rc=$?
					if [[ $_rc -eq 255 ]]; then _cl_save_state; return 1; fi
					if [[ $_rc -eq 1 ]]; then page=$((page - 1)); continue; fi
					_persist_cluster_draft
				else
					page=5
					continue
				fi
				;;
			5)
				_cluster_execute
				local _rc=$?
				case "$_rc" in
					0)
						# Command ran (success or failure) — exit wizard to main menu
						_cl_save_state; return 0
						;;
					1)
						# "Back" pressed on the review page — return to last edit page
						if [[ "$cl_platform" != "bm" ]]; then
							page=4
						else
							page=3
						fi
						continue
						;;
					*)
						# ESC or anything else — exit wizard
						_cl_save_state; return 1
						;;
				esac
				;;
			0)
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
	local default_item="N"
	while :; do
		# Build menu items (hide worker row for sno)
		local items=()
		local _plat_desc="" _plat_status=""
		case "$cl_platform" in
			bm)  _plat_desc="bm (bare-metal)" ;;
			vmw) _plat_desc="vmw (VMware/ESXi)" ;;
			kvm) _plat_desc="kvm (libvirt/KVM)" ;;
			*)   _plat_desc="$cl_platform" ;;
		esac
		if [[ "$cl_platform" == "vmw" || "$cl_platform" == "kvm" ]]; then
			local _conf_ok=false
			[[ "$cl_platform" == "vmw" ]] && [[ -s "$ABA_ROOT/vmware.conf" || -s "$HOME/.vmware.conf" ]] && _conf_ok=true
			[[ "$cl_platform" == "kvm" ]] && [[ -s "$ABA_ROOT/kvm.conf" || -s "$HOME/.kvm.conf" ]] && _conf_ok=true
			if $_conf_ok; then
				_plat_status=" \Z2\Zb✓\Zn"
			else
				_plat_status=" \Z1⚠\Zn"
			fi
		fi
		# Pad to fixed raw byte width so dialog column sizing stays stable.
		# Color-coded status (" \Z2\Zb✓\Zn") adds ~10 raw bytes; compensate
		# with trailing spaces when there's no status indicator.
		local _plat_full
		if [[ -n "$_plat_status" ]]; then
			printf -v _plat_full "%-18s" "$_plat_desc"
		else
			printf -v _plat_full "%-28s" "$_plat_desc"
		fi
		# Show OCP version and image source so the user knows what will be installed
		local _src_desc
		case "$_TUI_MODE" in
			DIRECT) _src_desc="internet" ;;
			*)      _src_desc="mirror registry" ;;
		esac

		items+=("P" "Platform:       ${_plat_full}${_plat_status}")
		items+=("N" "Cluster name:   $cl_name")
		items+=("D" "Base domain:    ${cl_domain:-(not set)}")
		items+=("T" "Type:           $cl_type")
		if [[ "$cl_type" == "standard" ]]; then
			items+=("W" "Worker count:   $cl_workers")
		fi

		local _basics_msg
		_basics_msg="OpenShift ${ocp_version:-?} (${ocp_channel:-?}) — source: ${_src_desc}\n\n$TUI2_MSG_CLUSTER_BASICS"

		dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CLUSTER_BASICS" \
			--cancel-label "$TUI2_BTN_BACK" \
			--ok-label "$TUI2_BTN_SELECT" \
			--extra-button --extra-label "$TUI2_BTN_NEXT" \
			--default-button ok \
			--help-button \
			--default-item "$default_item" \
			--menu "$_basics_msg" 0 0 0 \
			"${items[@]}" \
			2>"$_TUI_TMP"
		local rc=$?

		case "$rc" in
			2)
				show_help "Cluster Wizard Help" \
"--- Page 1: Basics ---
• Cluster name: short name (lowercase, numbers, hyphens)
• Type: sno (single node), compact (3 masters), standard (3+N)
• Worker count: number of workers (standard only)
• Platform: bm (bare metal), vmw (VMware), kvm (KVM/libvirt)
Toggle 'Type' or 'Platform' to cycle options.

--- Page 2: Network ---
• Machine network: cluster subnet CIDR (e.g. 10.0.0.0/24)
• Starting IP: first IP for cluster nodes
• API VIP / Ingress VIP: virtual IPs (compact/standard)
• DNS / Gateway / NTP: network services

--- Page 3: Interfaces ---
• Ports: host NIC name(s) (e.g. ens1f0)
• VLAN: optional VLAN tag
• Image source: mirror | proxy | direct

--- Page 4: VM Resources (vmw/kvm only) ---
• CPUs / Memory: per-VM allocation
• Data disk: additional disk in GB
• MAC template: prefix for generated MACs

--- Navigation ---
Select: edit a field   Next: advance page   Back: previous page
Press ESC on any page to return to the main menu.

OpenShift version: ${ocp_version:-?} (channel: ${ocp_channel:-?})"
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
			255) return 255 ;;
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
			if [[ -n "$input" ]]; then
				if ! aba cluster --name "$input" --validate >/dev/null 2>&1; then
					dlg --backtitle "$(ui_backtitle)" --msgbox \
						"$TUI2_MSG_INVALID_CLUSTER_NAME" 0 0 || true
					continue
				fi
			fi
			[[ -n "$input" ]] && cl_name="$input"
			# Warn if cluster is already installed
			if [[ -f "$ABA_ROOT/$cl_name/.install-complete" ]]; then
				dlg --backtitle "$(ui_backtitle)" --title "Cluster Already Installed" \
					--yes-label "Continue" --no-label "Back" \
					--yesno "Cluster '$cl_name' is already installed.\n\nUse Day-2 menu for operations on installed clusters.\nContinuing will overwrite the cluster configuration.\n\nContinue anyway?" 0 0
				[[ $? -ne 0 ]] && continue
			fi
			# Silently load existing cluster.conf if present
			if [[ -f "$ABA_ROOT/$cl_name/cluster.conf" ]]; then
				_cluster_load_conf "$ABA_ROOT/$cl_name/cluster.conf"
				_apply_mode_connection
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
				if [[ -n "$dom_input" && ! "$dom_input" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]]; then
					dlg --backtitle "$(ui_backtitle)" --msgbox \
						"Invalid base domain.\n\nMust be a valid DNS name (e.g. example.com, lab.internal)." 0 0 || true
					continue
				fi
				[[ -n "$dom_input" ]] && cl_domain="${dom_input,,}"
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
		replace-value-conf -q -n platform -v "$cl_platform" -f "$ABA_ROOT/aba.conf"
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
				if [[ -n "$wrk_input" ]] && { [[ ! "$wrk_input" =~ ^[0-9]+$ ]] || [[ "$wrk_input" -eq 0 && "$cl_type" == "standard" ]]; }; then
					dlg --backtitle "$(ui_backtitle)" --msgbox \
						"Invalid worker count.\n\nMust be a positive number (e.g. 2, 3, 5).\nStandard clusters require at least 1 worker." 0 0 || true
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
			--default-button ok \
			--help-button \
			--default-item "$default_item" \
			--menu "$TUI2_MSG_CLUSTER_NETWORK" 0 0 0 \
			"${items[@]}" \
			2>"$_TUI_TMP"
		local rc=$?

		case "$rc" in
			3) return 0 ;;  # Next
			2) show_help "$TUI2_TITLE_CLUSTER_NETWORK" \
"• Machine network: cluster subnet in CIDR (e.g. 10.0.0.0/24)
• Starting IP: first IP for cluster nodes (auto-calculated if blank)
• API VIP: virtual IP for Kubernetes API (compact/standard only)
• Ingress VIP: virtual IP for ingress routes (compact/standard only)
  VIPs are auto-fetched from DNS if not set.
• DNS servers: comma-separated DNS server IPs
• Gateway: default gateway IP
• NTP servers: comma-separated NTP server addresses (optional)"
			   continue ;;
			1) return 1 ;;  # Back
			255) return 255 ;;
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
				cl_network="$net_val"
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
				cl_starting_ip="$sip_val"
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
				cl_api_vip="$api_val"
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
				cl_ingress_vip="$ing_val"
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
					if [[ -n "$dns_val" ]] && ! _valid_ip_list "$dns_val"; then
						dlg --backtitle "$(ui_backtitle)" --msgbox \
							"Invalid DNS entry.\n\nExpected: comma-separated IP addresses (e.g. 10.0.1.8,10.0.1.9)." 0 0 || true
						continue
					fi
				cl_dns="$dns_val"
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
				cl_gateway="$gw_val"
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
				cl_ntp="$ntp_val"
				break
			done
			;;
	esac
	done
}

# --- Page 3: Interfaces (menu-style with toggle) ---
_cluster_page_iface() {
	local default_item="P"
	# Normalize empty connection: "direct" in DIRECT mode, "mirror" otherwise
	if [[ -z "$cl_connection" ]]; then
		[[ "$_TUI_MODE" == "DIRECT" ]] && cl_connection="direct" || cl_connection="mirror"
	fi
	while :; do
		local conn_display=""
		case "$cl_connection" in
			mirror|"")
				local _rh="" _rp=""
				if [[ -f "$ABA_ROOT/mirror/mirror.conf" ]]; then
					source <(cd "$ABA_ROOT/mirror" && normalize-mirror-conf) 2>/dev/null || true
					_rh="${reg_host:-}" _rp="${reg_port:-}"
				fi
				if [[ -n "$_rh" ]]; then
					conn_display="mirror (${_rh}${_rp:+:$_rp})"
				else
					conn_display="mirror"
				fi
				;;
			proxy)  conn_display="proxy (public registries)" ;;
			direct) conn_display="direct (public registries)" ;;
			*)      conn_display="$cl_connection" ;;
		esac

		# Build items — add MAC row for bare-metal
		local iface_items=(
			"P" "Ports:        $cl_ports"
			"V" "VLAN:         ${cl_vlan:-(none)}"
			"C" "Image source: $conn_display"
			"K" "SSH key:      ${cl_ssh_key:-~/.ssh/id_rsa}"
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
		# Width 62: prevents narrow dialog when "Image source" has short values (proxy/direct)
		# while still expanding for long FQDNs (mirror with registry host:port)
		dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CLUSTER_IFACE" \
			--cancel-label "$TUI2_BTN_BACK" \
			--ok-label "$TUI2_BTN_SELECT" \
			--extra-button --extra-label "$TUI2_BTN_NEXT" \
			--default-button ok \
			--help-button \
			--default-item "$default_item" \
			--menu "$TUI2_MSG_CLUSTER_IFACE" 0 62 0 \
			"${iface_items[@]}" \
			2>"$_TUI_TMP"
		local rc=$?

		case "$rc" in
			3) return 0 ;;  # Next (Extra button)
			2) show_help "$TUI2_TITLE_CLUSTER_IFACE" \

"• Ports: network port names (e.g. ens160, ens1f0)
  Multiple ports create a bond (e.g. ens1f0,ens1f1)

• VLAN: optional 802.1Q VLAN tag

• Image source: where the cluster pulls container images from
  - mirror: from the local mirror registry (default)
  - proxy: from public registries via HTTP proxy
  - direct: from public registries with direct internet

• MACs (bare-metal only): paste one or more MAC addresses per node
  Ensures each node gets the correct IP via mac address mapping."
			   continue ;;
			1) return 1 ;;  # Back (Cancel button)
			255) return 255 ;;
			0) ;;  # Select (OK button)
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
				if [[ -n "$ports_val" ]] && ! _valid_port_names "$ports_val"; then
					dlg --backtitle "$(ui_backtitle)" --msgbox \
						"Invalid port name(s).\n\nOnly letters, digits, dots, dashes, underscores allowed.\nComma-separated for multiple (e.g. ens1f0,ens1f1)." 0 0 || true
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
				if [[ -n "$vlan_val" ]] && { [[ ! "$vlan_val" =~ ^[0-9]+$ ]] || [[ "$vlan_val" -lt 1 || "$vlan_val" -gt 4094 ]]; }; then
					dlg --backtitle "$(ui_backtitle)" --msgbox \
						"Invalid VLAN tag.\n\nMust be a number between 1 and 4094." 0 0 || true
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
		elif [[ "$_TUI_MODE" == "DISCO" ]]; then
			# DISCO: only "mirror" is valid (no internet)
			if [[ "$cl_connection" != "mirror" ]]; then
				cl_connection="mirror"
			fi
			dlg --backtitle "$(ui_backtitle)" --msgbox \
				"In disconnected mode only \"mirror\" is available as an image source." 0 0 || true
		else
			# CONNO: Toggle mirror → proxy → direct → mirror
			case "$cl_connection" in
				mirror|"") cl_connection="proxy" ;;
				proxy) cl_connection="direct" ;;
				direct) cl_connection="mirror" ;;
			esac
		fi
			tui_log "Toggled connection to: $cl_connection"
			;;
		M)
			# Use --editbox (multi-line) instead of --inputbox (single-line) so users
			# can paste or type multiple MACs — one per line, as required for bare-metal
			local _mac_edit="${_TUI_TMP}.macs"
			echo "$cl_macs" > "$_mac_edit"
			dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CLUSTER_MAC_ADDRS" \
				--ok-label "$TUI2_BTN_SAVE" --cancel-label "$TUI2_BTN_CANCEL" \
				--editbox "$_mac_edit" 18 70 \
				2>"$_TUI_TMP"
			if [[ $? -eq 0 ]]; then
				local raw=$(<"$_TUI_TMP")
				# Normalize: convert commas/spaces to newlines, trim empty lines and whitespace
				cl_macs=$(echo "$raw" | tr ',; ' '\n' | sed '/^$/d' | tr -d ' \t')
				tui_log "MAC addresses entered: $(echo "$cl_macs" | wc -l)"
			fi
			rm -f "$_mac_edit"
			;;
		K)
			dlg --backtitle "$(ui_backtitle)" --title "SSH Key" \
				--inputbox "Path to SSH private key:" 0 60 "$cl_ssh_key" \
				2>"$_TUI_TMP"
			if [[ $? -eq 0 ]]; then
				local key_val=$(<"$_TUI_TMP")
				_tui_reject_squote "$key_val" || continue
				if [[ -n "$key_val" ]] && ! _valid_abs_path "$key_val"; then
					dlg --backtitle "$(ui_backtitle)" --msgbox \
						"Invalid path.\n\nMust start with / or ~ (e.g. ~/.ssh/id_rsa)." 0 0
					continue
				fi
				cl_ssh_key="$key_val"
			fi
			;;
	esac
	done
}

# --- Page 4: VM Resources (menu-style, only for vmw/kvm) ---
_cluster_page_vm() {
	local default_item="C"
	local mac_info=""
	if [[ -f "$ABA_ROOT/$cl_name/macs.conf" ]] && grep -qE '^[^#]' "$ABA_ROOT/$cl_name/macs.conf" 2>/dev/null; then
		mac_info=" (from macs.conf)"
	fi

	while :; do
		local items=()
		items+=("C" "Master CPUs:    ${cl_master_cpu:-(not set)}")
		items+=("R" "Master Memory:  ${cl_master_mem:+"${cl_master_mem} GB"}${cl_master_mem:-(not set)}")
		if [[ "$cl_type" == "standard" ]]; then
			items+=("W" "Worker CPUs:    ${cl_worker_cpu:-(not set)}")
			items+=("E" "Worker Memory:  ${cl_worker_mem:+"${cl_worker_mem} GB"}${cl_worker_mem:-(not set)}")
		fi
		items+=("D" "Data disk:      ${cl_disk:+"${cl_disk} GB"}${cl_disk:-(not set)}")
		items+=("A" "MAC template:   ${cl_mac_template:-(auto)}${mac_info}")

		dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CLUSTER_VM" \
			--cancel-label "$TUI2_BTN_BACK" \
			--ok-label "$TUI2_BTN_SELECT" \
			--extra-button --extra-label "$TUI2_BTN_NEXT" \
			--default-button ok \
			--help-button \
			--default-item "$default_item" \
			--menu "$(printf "$TUI2_MSG_CLUSTER_VM" "$cl_platform")" 0 0 0 \
			"${items[@]}" \
			2>"$_TUI_TMP"
		local rc=$?

		case "$rc" in
			3) return 0 ;;  # Next
			2) show_help "$TUI2_TITLE_CLUSTER_VM" \
"• Master CPUs: vCPU count per control-plane VM (min 4)
• Master Memory: RAM in GB per control-plane VM (min 16)
• Worker CPUs: vCPU count per worker VM (standard only, min 2)
• Worker Memory: RAM in GB per worker VM (standard only, min 8)
• Data disk: additional disk in GB (0 = no extra disk)
• MAC template: prefix for auto-generated MAC addresses
  (e.g. 00:50:56:xx — last 3 octets auto-filled)"
			   continue ;;
			1) return 1 ;;  # Back
			255) return 255 ;;
			0) ;;
		esac

		local choice
		choice=$(<"$_TUI_TMP")
		[[ -n "$choice" ]] && default_item="$choice"

		case "$choice" in
			C)
				while :; do
					dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CLUSTER_MASTER_CPU" \
						--inputbox "$TUI2_MSG_VM_MASTER_CPU_PROMPT" 0 0 "$cl_master_cpu" \
						2>"$_TUI_TMP"
					[[ $? -ne 0 ]] && break
					local val=$(<"$_TUI_TMP")
					if [[ -n "$val" ]] && { [[ ! "$val" =~ ^[0-9]+$ ]] || [[ "$val" -lt 1 ]]; }; then
						dlg --backtitle "$(ui_backtitle)" --msgbox "Must be a positive number." 0 0 || true
						continue
					fi
				cl_master_cpu="$val"
				break
			done
			;;
		R)
				while :; do
					dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CLUSTER_MASTER_MEM" \
						--inputbox "$TUI2_MSG_VM_MASTER_MEM_PROMPT" 0 0 "$cl_master_mem" \
						2>"$_TUI_TMP"
					[[ $? -ne 0 ]] && break
					local val=$(<"$_TUI_TMP")
					if [[ -n "$val" ]] && { [[ ! "$val" =~ ^[0-9]+$ ]] || [[ "$val" -lt 1 ]]; }; then
						dlg --backtitle "$(ui_backtitle)" --msgbox "Must be a positive number." 0 0 || true
						continue
					fi
				cl_master_mem="$val"
				break
			done
			;;
		W)
				while :; do
					dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CLUSTER_WORKER_CPU" \
						--inputbox "$TUI2_MSG_VM_WORKER_CPU_PROMPT" 0 0 "$cl_worker_cpu" \
						2>"$_TUI_TMP"
					[[ $? -ne 0 ]] && break
					local val=$(<"$_TUI_TMP")
					if [[ -n "$val" ]] && { [[ ! "$val" =~ ^[0-9]+$ ]] || [[ "$val" -lt 1 ]]; }; then
						dlg --backtitle "$(ui_backtitle)" --msgbox "Must be a positive number." 0 0 || true
						continue
					fi
				cl_worker_cpu="$val"
				break
			done
			;;
		E)
				while :; do
					dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CLUSTER_WORKER_MEM" \
						--inputbox "$TUI2_MSG_VM_WORKER_MEM_PROMPT" 0 0 "$cl_worker_mem" \
						2>"$_TUI_TMP"
					[[ $? -ne 0 ]] && break
					local val=$(<"$_TUI_TMP")
					if [[ -n "$val" ]] && { [[ ! "$val" =~ ^[0-9]+$ ]] || [[ "$val" -lt 1 ]]; }; then
						dlg --backtitle "$(ui_backtitle)" --msgbox "Must be a positive number." 0 0 || true
						continue
					fi
				cl_worker_mem="$val"
				break
			done
			;;
		D)
			while :; do
				dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CLUSTER_DATA_DISK" \
						--inputbox "$TUI2_MSG_VM_DISK_PROMPT" 0 0 "$cl_disk" \
						2>"$_TUI_TMP"
					[[ $? -ne 0 ]] && break
					local val=$(<"$_TUI_TMP")
					if [[ -n "$val" ]] && { [[ ! "$val" =~ ^[0-9]+$ ]] || [[ "$val" -lt 0 ]]; }; then
						dlg --backtitle "$(ui_backtitle)" --msgbox "Must be a non-negative number (0 = no extra disk)." 0 0 || true
						continue
					fi
				cl_disk="$val"
				break
			done
			;;
		A)
			dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CLUSTER_MAC_TEMPLATE" \
					--inputbox "$TUI2_MSG_VM_MAC_PROMPT" 0 0 "$cl_mac_template" \
					2>"$_TUI_TMP"
				if [[ $? -eq 0 ]]; then
					local _mac_val=$(<"$_TUI_TMP")
					if [[ -n "$_mac_val" ]] && ! _valid_mac_prefix "$_mac_val"; then
						dlg --backtitle "$(ui_backtitle)" --msgbox \
							"Invalid MAC prefix.\n\nExpected: 5 hex octets with trailing colon\ne.g. 00:50:56:1a:2b: or 00:50:56:xx:xx:\n\nUse 'x' for random hex (auto-generated per VM)." 0 0 || true
						continue
					fi
					cl_mac_template="$_mac_val"
				fi
				;;
		esac
	done
}

# --- Assemble command, show review page, execute install ---
_cluster_execute() {
	# cluster.conf is already up to date (_persist_cluster_draft writes after every page).
	# Just tell aba to use the existing config — no flags needed.
	local cmd="aba cluster --name $cl_name"

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

	# Image source display (enrich with details)
	local _conn_disp="$cl_connection"
	if [[ -z "$_conn_disp" ]]; then
		[[ "$_TUI_MODE" == "DIRECT" ]] && _conn_disp="direct" || _conn_disp="mirror"
	fi
	case "$_conn_disp" in
		mirror)
			local _srh="${reg_host:-}" _srp="${reg_port:-}"
			[[ -n "$_srh" ]] && _conn_disp="mirror (${_srh}${_srp:+:$_srp})"
			;;
		proxy)  _conn_disp="proxy (public registries)" ;;
		direct) _conn_disp="direct (public registries)" ;;
	esac

	local summary="Review — Confirm before installing:\n\n"
	summary+="  Cluster:      $fqdn\n"
	summary+="  Type:         $cl_type ($_nm master, $_nw workers = $total_nodes node$( [[ $total_nodes -ne 1 ]] && echo s))\n"
	summary+="  Platform:     $_plat_disp\n"
	summary+="  OpenShift:    ${ocp_version:-?} (${ocp_channel:-?})\n"
	local _mode_display
	case "$_TUI_MODE" in
		DISCO)  _mode_display="Fully Disconnected" ;;
		CONNO)  _mode_display="Partially Disconnected" ;;
		DIRECT) _mode_display="Fully Connected" ;;
		*)      _mode_display="$_TUI_MODE" ;;
	esac
	summary+="  Mode:         $_mode_display\n"
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
	summary+="  Image source: $_conn_disp\n"
	summary+="  SSH key:      ${cl_ssh_key:-~/.ssh/id_rsa}\n"
	summary+="\n"
	if [[ "$cl_platform" != "bm" ]]; then
		summary+="  Master CPU:   ${cl_master_cpu:-(not set)}\n"
		summary+="  Master Mem:   ${cl_master_mem:-(not set)} GB\n"
		if [[ "$cl_type" == "standard" ]]; then
			summary+="  Worker CPU:   ${cl_worker_cpu:-(not set)}\n"
			summary+="  Worker Mem:   ${cl_worker_mem:-(not set)} GB\n"
		fi
		summary+="  Data disk:    ${cl_disk:-(not set)} GB\n"
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
			255) return 255 ;;
		esac
	done

	# For bare-metal: offer choice between ISO creation only or full install
	if [[ "$cl_platform" == "bm" ]]; then
		dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CLUSTER_INSTALL_ACTION" \
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
	cmd="$cmd --step $install_step"

	tui_log "Installing cluster ($install_step): $cmd"

	# Clean stale artifacts if connection mode changed (prevents mirror refs in DIRECT etc.)
	local cluster_dir="$ABA_ROOT/$cl_name"
	if [[ -f "$cluster_dir/cluster.conf" ]]; then
		local _old_conn
		_old_conn=$(source <(cd "$cluster_dir" && normalize-cluster-conf) 2>/dev/null && echo "$int_connection")
		[[ -z "$_old_conn" ]] && _old_conn="mirror"
		local _new_conn="$cl_connection"
		if [[ -z "$_new_conn" ]]; then
			[[ "$_TUI_MODE" == "DIRECT" ]] && _new_conn="direct" || _new_conn="mirror"
		fi
		if [[ "$_old_conn" != "$_new_conn" ]]; then
			tui_log "Connection mode changed ($cluster_dir): $_old_conn -> $_new_conn, cleaning stale artifacts"
			rm -f "$cluster_dir/install-config.yaml" "$cluster_dir/.init" "$cluster_dir/.configured" 2>/dev/null
		fi
	fi

	# Write macs.conf if MACs were entered (bare-metal)
	if [[ -n "$cl_macs" && "$cl_platform" == "bm" ]]; then
		mkdir -p "$cluster_dir"
		echo "$cl_macs" > "$cluster_dir/macs.conf"
		tui_log "Wrote ${cluster_dir}/macs.conf with $(echo "$cl_macs" | wc -l) entries"
	fi

	# Platform config check before executing
	_check_platform_config "$cl_name" "$cl_platform" || return 1

	# Long operation — use confirm_and_execute (terminal/TUI mode choice)
	# Always return 0 after command execution so the wizard exits back to the
	# main menu.  Return 1 is reserved for "Back" on the review page (above).
	confirm_and_execute "$cmd" "Install Cluster: $fqdn"
	local rc=$?

	# After successful install in mirror mode, offer to configure OperatorHub
	if [[ $rc -eq 0 && "$_TUI_MODE" != "DIRECT" && -f "$ABA_ROOT/$cl_name/.install-complete" ]]; then
		dlg --backtitle "$(ui_backtitle)" --title "Configure OperatorHub" \
			--yes-label "Yes, apply now" \
			--no-label "No, later" \
			--yesno "Cluster $fqdn installed successfully!\n\n\
Run 'Configure OperatorHub' (aba day2) to set up:\n\
  • OperatorHub catalog sources\n\
  • Image content source policies\n\
  • Release signature verification\n\n\
This is needed for operators and upgrades to work\n\
from your mirror registry." 0 0
		if [[ $? -eq 0 ]]; then
			confirm_and_execute "aba --dir $cl_name day2" "Configure OperatorHub: $fqdn"
		fi
	fi

	return 0
}

# =============================================================================
# Cluster Install (with platform config check + auto-monitor)
# =============================================================================




# --- Platform config check ---
_check_platform_config() {
	local dir="$1"
	local plat="${2:-$platform}"

	case "$plat" in
		vmw)
			if [[ ! -s "$dir/vmware.conf" && ! -s vmware.conf && ! -s "$HOME/.vmware.conf" ]]; then
				_platform_config_missing "VMware" "vmware.conf" \
					"vcenter_fqdn, vcenter_user, vcenter_pass, datacenter, datastore, network, folder, cluster"
				return $?
			fi
			;;
		kvm)
			if [[ ! -s "$dir/kvm.conf" && ! -s kvm.conf && ! -s "$HOME/.kvm.conf" ]]; then
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

	dlg --backtitle "$(ui_backtitle)" --title "$name Configuration Required" \
		--yes-label "Configure Now" \
		--no-label "$TUI2_BTN_CANCEL" \
		--yesno "\n$name configuration ($path) is required but not found.\n\nFields needed: $fields\n\nConfigure now?" 0 0
	local rc=$?
	[[ $rc -ne 0 ]] && return 1

	case "$path" in
		vmware.conf) _configure_vmw_form ;;
		kvm.conf)    _configure_kvm_form ;;
	esac
}

# =============================================================================
# Monitor Cluster Installation (re-attach to wait-for install-complete)
# =============================================================================

cluster_monitor() {
	tui_log "Action: Monitor Cluster Installation"

	if ! select_cluster "$TUI2_TITLE_CLUSTER_MONITOR" "Select installing cluster to monitor:" "installing"; then
		return 1
	fi

	local _cl="$SELECTED_CLUSTER"
	confirm_and_execute "aba --dir $_cl mon" "$TUI2_TITLE_CLUSTER_MONITOR"
	local rc=$?

	# After successful monitor completion in mirror mode, offer to configure OperatorHub
	if [[ $rc -eq 0 && "$_TUI_MODE" != "DIRECT" && -f "$ABA_ROOT/$_cl/.install-complete" ]]; then
		local _fqdn
		_fqdn=$(cluster_display_name "$_cl")
		dlg --backtitle "$(ui_backtitle)" --title "Configure OperatorHub" \
			--yes-label "Yes, apply now" \
			--no-label "No, later" \
			--yesno "Cluster $_fqdn is ready!\n\n\
Run 'Configure OperatorHub' (aba day2) to set up:\n\
  • OperatorHub catalog sources\n\
  • Image content source policies\n\
  • Release signature verification\n\n\
This is needed for operators and upgrades to work\n\
from your mirror registry." 0 0
		if [[ $? -eq 0 ]]; then
			confirm_and_execute "aba --dir $_cl day2" "Configure OperatorHub: $_fqdn"
		fi
	fi
}

# =============================================================================
# Delete Cluster
# =============================================================================

cluster_delete() {
	tui_log "Action: Delete Cluster"

	if ! select_cluster "$TUI2_TITLE_CLUSTER_DELETE" "Select cluster to delete:"; then
		return 1
	fi

	local cl_display="$SELECTED_CLUSTER_DISPLAY"

	while true; do
		dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_CLUSTER_DELETE" \
			--yes-label "Delete" --no-label "$TUI2_BTN_CANCEL" \
			--help-button --help-label "Help" \
			--yesno "Delete cluster '$cl_display'?\n\nThis removes all cluster state and resources.\nThis action cannot be undone." 0 0
		local rc=$?
		case $rc in
			0) break ;;
			2)
				dlg --backtitle "$(ui_backtitle)" --title "Delete Cluster – Help" \
					--msgbox "\
Delete removes the cluster directory and all generated resources\n\
(kubeconfig, manifests, ISOs, state markers).\n\n\
On virtualized platforms (VMware, KVM), the VMs are also destroyed.\n\
On bare-metal, nodes are left powered — decommission them manually." 0 0
				continue
				;;
			*) return 1 ;;
		esac
	done

	confirm_and_execute "aba --dir $SELECTED_CLUSTER delete" "$TUI2_TITLE_CLUSTER_DELETE: $cl_display"
}

# =============================================================================
# Advanced Menu
# =============================================================================

tui_advanced_menu() {
	tui_log "Action: Advanced Menu"
	local default_item="P"

	while :; do
		local adv_items=()
		# Platform config (view/edit vmware.conf or kvm.conf)
		local _plat_label="Platform Settings"
		source <(normalize-aba-conf) 2>/dev/null || true
		_plat_label="Platform Settings (${platform:-bm})"
		adv_items+=("P" "$_plat_label")
		if mirror_available; then
			adv_items+=("U" "Uninstall Mirror Registry (destructive)")
		fi
		if [[ "${_CLUSTER_MON_AVAIL}" == "true" ]]; then
			adv_items+=("F" "Monitor Cluster Installation (re-attach)")
		fi
		if [[ -n "$_TUI_EXEC_MODE" ]]; then
			adv_items+=("E" "Reset Execution Mode (currently: $_TUI_EXEC_MODE)")
		fi
		# Mode switches (normally auto-detected; here for manual override)
		adv_items+=("" "──── Switch Mode ───────────────────")
		case "$_TUI_MODE" in
			CONNO)
				adv_items+=("X" "Switch to Fully Connected (direct)")
				adv_items+=("Z" "Switch to Fully Disconnected")
				;;
			DIRECT)
				adv_items+=("X" "Switch to Partially Disconnected (mirror)")
				;;
			DISCO)
				adv_items+=("X" "Switch to Connected Mode")
				;;
		esac
	adv_items+=("" "──── Danger Zone ───────────────────")
	if [[ "${_CLUSTER_DAY2_AVAIL}" == "true" ]]; then
		adv_items+=("W" "Refresh Cluster (recreate VMs, new install)")
	fi
	adv_items+=("R" "Reset ABA (full clean — returns to initial state)")

		dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_ADVANCED" \
			--default-item "$default_item" \
			--cancel-label "$TUI2_BTN_BACK" \
			--help-button \
			--menu "Advanced operations (use with care):" 0 0 0 \
			"${adv_items[@]}" \
			2>"$_TUI_TMP"
		local rc=$?

		[[ $rc -eq 1 || $rc -eq 255 ]] && return 0

		if [[ $rc -eq 2 ]]; then
			dlg --backtitle "$(ui_backtitle)" --title "Advanced Menu Help" \
				--msgbox "\
P - Platform Settings: View or edit your hypervisor configuration\n\
    (vmware.conf for vSphere, kvm.conf for KVM/libvirt).\n\n\
U - Uninstall Mirror Registry: Removes the mirror registry container\n\
    and ALL mirrored data. You will need to re-sync images after reinstall.\n\n\
F - Monitor Cluster Installation: Re-attach to a running install\n\
    and wait for completion. Rarely needed since ABA auto-detects.\n\n\
E - Reset Execution Mode: Clears your 'Always TUI' or 'Always Terminal'\n\
    preference for this session.\n\n\
X/Z - Switch Mode: Manually switch between Connected, Partially\n\
    Disconnected, and Fully Disconnected workflows.\n\n\
W - Refresh Cluster: Destroys existing VMs and triggers a fresh\n\
    installation from scratch. All current cluster data is lost.\n\n\
R - Reset ABA: Removes ALL configuration, clusters, mirror data, and\n\
    returns ABA to its initial unpacked state. CANNOT BE UNDONE." 0 0
			continue
		fi

		local choice
		choice=$(<"$_TUI_TMP")
		[[ -n "$choice" ]] && default_item="$choice"

		case "$choice" in
		"W")
			_day2_refresh
			;;
		"R")
			dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_ADVANCED" \
				--yes-label "Reset" --no-label "$TUI2_BTN_CANCEL" \
				--yesno "Reset ABA to initial state?\n\nThis will remove ALL configuration, clusters, and mirror data.\nEquivalent to: aba reset --force\n\nThis action cannot be undone!" 0 0
			[[ $? -ne 0 ]] && continue
			confirm_and_execute "aba reset --force" "Reset ABA"
			return 0
			;;
			"P")
				source <(normalize-aba-conf) 2>/dev/null || true
				local _default_ptag="M"
				case "${platform:-bm}" in
					vmw) _default_ptag="V" ;;
					kvm) _default_ptag="K" ;;
				esac
				dlg --backtitle "$(ui_backtitle)" --title "Platform Settings" \
					--default-item "$_default_ptag" \
					--cancel-label "$TUI2_BTN_BACK" \
					--menu "Select platform to configure:" 0 0 0 \
					"M"  "Bare Metal" \
					"V"  "VMware vSphere" \
					"K"  "KVM/libvirt" \
					2>"$_TUI_TMP"
				[[ $? -ne 0 ]] && continue
				local _ptag
				_ptag=$(<"$_TUI_TMP")
				case "$_ptag" in
					V)
						replace-value-conf -q -n platform -v vmw -f "$ABA_ROOT/aba.conf"
						platform=vmw
						_configure_platform_file "vmware.conf" "VMware/ESXi"
						;;
					K)
						replace-value-conf -q -n platform -v kvm -f "$ABA_ROOT/aba.conf"
						platform=kvm
						_configure_platform_file "kvm.conf" "KVM/libvirt"
						;;
					M)
						replace-value-conf -q -n platform -v bm -f "$ABA_ROOT/aba.conf"
						platform=bm
						tui_log "Platform set to bare metal"
						;;
				esac
				;;
			"U")
				local _unreg_host
				_unreg_host=$(source <(cd "$ABA_ROOT/mirror" && normalize-mirror-conf) 2>/dev/null && echo "$reg_host")
				[[ -z "$_unreg_host" ]] && _unreg_host="localhost"
				dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_UNINSTALL_MIRROR" \
					--yes-label "Uninstall" --no-label "$TUI2_BTN_CANCEL" \
					--yesno "Uninstall the mirror registry on: ${_unreg_host}\n\nThis will remove the registry and its data.\nImages will need to be re-synced after reinstall." 0 0
				[[ $? -ne 0 ]] && continue
				confirm_and_execute "aba --dir mirror uninstall" "Uninstall Mirror Registry" _invalidate_mirror_cache
				;;
			"F")
				cluster_monitor
				;;
			"E")
				_TUI_EXEC_MODE=""
				tui_log "Execution mode preference reset"
				dlg --backtitle "$(ui_backtitle)" --msgbox "Execution mode reset.\n\nYou will be asked to choose TUI or Terminal for each command." 0 0
				;;
			"X")
				case "$_TUI_MODE" in
					CONNO)
						_TUI_MODE="DIRECT"
						tui_log "Advanced: switching to DIRECT mode"
						direct_main || true
						_TUI_MODE="CONNO"
						;;
					DIRECT)
						_TUI_MODE="CONNO"
						tui_log "Advanced: switching to CONNO mode"
						return 0
						;;
					DISCO)
						disco_reset
						return $?
						;;
				esac
				;;
			"Z")
				if [[ "$_TUI_MODE" == "CONNO" ]]; then
					dlg --backtitle "$(ui_backtitle)" \
						--title "Warning: Switching to Fully Disconnected Mode" \
						--defaultno \
						--yesno "\
Switching from Connected to Disconnected mode on the same host is not\n\
the standard workflow.\n\n\
Disconnected mode is designed for fully disconnected (air-gapped)\n\
environments. The recommended workflow is:\n\n\
  1. Create an Install Bundle in Connected mode\n\
     (aba bundle, or aba save + aba tar)\n\
  2. Transfer the bundle to the disconnected environment\n\
  3. Unpack the bundle, install aba and run aba/TUI there\n\n\
Continue only if you know what you are doing." 0 0 || continue
					_ensure_offline_prereqs || continue
					_TUI_MODE="DISCO"
					_TUI_DISCO_FROM_CONNO=true
					tui_log "Advanced: switching to DISCO mode (user confirmed warning)"
					disco_main || true
					_TUI_MODE="CONNO"
					_TUI_DISCO_FROM_CONNO=false
				fi
				;;
		esac
	done
}

# =============================================================================
# Day-2 Operations
# =============================================================================

cluster_day2_menu() {
	tui_log "Action: Day-2 / Cluster Management menu"
	local default_item="R"

	while :; do
		dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_DAY2_MENU" \
			--cancel-label "$TUI2_BTN_BACK" \
			--help-button \
			--default-item "$default_item" \
			--menu "$TUI2_MSG_DAY2_MENU" 0 0 0 \
			"" "──── Configuration ────────────────" \
			"R" "Configure OperatorHub (after mirror load/sync)" \
			"N" "Network Time Protocol" \
			"O" "OpenShift Update Service (OSUS)" \
			"" "──── Status ───────────────────────" \
			"S" "Cluster status" \
			"H" "SSH into Rendezvous Server" \
			"" "──── Lifecycle ────────────────────" \
			"U" "Upgrade cluster (beta)" \
			"G" "Graceful cluster shutdown" \
			"T" "Graceful cluster startup" \
		"" "──── Cleanup ──────────────────────" \
			"C" "Clean (remove artifacts, retry install)" \
			"K" "Delete cluster" \
			2>"$_TUI_TMP"
		local rc=$?

		case "$rc" in
			2)
				show_help "$TUI2_HELP_TITLE_DAY2" \
"Configuration:
• Resources: applies all Day-2 config (IDMS, CatalogSources, OperatorHub, etc.)
• NTP: configures Network Time Protocol on all cluster nodes
• OSUS: installs the OpenShift Update Service operator for upgrades

Status:
• Cluster status: shows cluster operators and node status
• SSH: opens an interactive SSH session on the Rendezvous Server

Lifecycle:
• Upgrade: upgrade cluster to a newer OpenShift version
• Shutdown: graceful cluster shutdown (waits for completion)
• Startup: graceful cluster startup (powers on VMs)

Cleanup:
• Clean: remove generated artifacts so you can retry install
• Delete: remove cluster state and resources (VMs destroyed on virt platforms)

Navigation:
• Arrow keys / Tab — move between items and buttons
• Enter — select highlighted item
• ESC — go back to the main menu"
				continue
				;;
			0) ;;
			1|255) return 0 ;;
		esac

		local choice
		choice=$(<"$_TUI_TMP")
		[[ -n "$choice" ]] && default_item="$choice"

		case "$choice" in
			R) _day2_run "day2" ;;
			N) _day2_run "day2-ntp" ;;
			O) _day2_run_osus ;;
			S) _day2_status ;;
			H) _day2_ssh ;;
			U) _day2_upgrade ;;
		G) _day2_shutdown ;;
		T) _day2_startup ;;
		C) _day2_clean ;;
			K) _day2_delete ;;
		esac
	done
}

_day2_run() {
	local target="$1"

	if ! select_installed_cluster "$TUI2_TITLE_DAY2_MENU" "Select cluster for Day-2:"; then
		return 1
	fi

	confirm_and_execute "aba --dir $SELECTED_CLUSTER $target" "Day-2: $target"
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

# --- Status: oc get co + oc get nodes ---
_day2_status() {
	if ! select_installed_cluster "$TUI2_TITLE_DAY2_STATUS" "Select cluster for status:"; then
		return 1
	fi

	local cl_display="$SELECTED_CLUSTER_DISPLAY"
	local cl_dir="$SELECTED_CLUSTER"
	tui_log "Running status check on $cl_display"

	dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_DAY2_STATUS" \
		--infobox "Fetching status for $cl_display ...\n\nThis may take a moment if the cluster is slow to respond." 0 0

	local output_file
	output_file=$(mktemp)

	local kc="$ABA_ROOT/$cl_dir/iso-agent-based/auth/kubeconfig"
	trap : INT
	{
		echo "═══ Cluster Operators ($cl_display) ═══"
		echo ""
		cd "$ABA_ROOT"
		KUBECONFIG="$kc" oc get co --request-timeout=5s 2>&1 || echo "(Cluster API unreachable — is the cluster shut down?)"
		echo ""
		echo "═══ Nodes ($cl_display) ═══"
		echo ""
		KUBECONFIG="$kc" oc get nodes --request-timeout=5s 2>&1 || echo "(Cluster API unreachable)"
		echo ""
		echo "═══ Pending Pods ($cl_display) ═══"
		echo ""
		KUBECONFIG="$kc" oc get po -A --sort-by=.status.conditions[-1].lastTransitionTime --request-timeout=5s 2>&1 \
			| awk '{split($3, arr, "/"); if (arr[1] != arr[2] && $4 != "Completed") print}' \
			|| echo "(Cluster API unreachable)"
		echo ""
	echo "═══ Upgrade Status ($cl_display) ═══"
	echo ""
	KUBECONFIG="$kc" oc adm upgrade --request-timeout=5s 2>&1 || echo "(Cluster API unreachable)"
	echo ""
	echo "═══ Cluster Info ($cl_display) ═══"
	echo ""
	aba --dir "$cl_dir" info 2>&1 || echo "(Unable to retrieve cluster info)"
} > "$output_file" 2>&1
	# Restore global TUI INT handler (trap - INT would reset to SIG_DFL)
	trap 'exit 0' HUP TERM INT

	sed -i -r 's/\x1B\[[0-9;]*[mK]//g; s/\x1B\(B//g' "$output_file"

	dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_DAY2_STATUS: $cl_display" \
		--exit-label "$TUI2_BTN_BACK" \
		--textbox "$output_file" 0 0
	rm -f "$output_file"
}

# --- SSH into Rendezvous Server ---
_day2_ssh() {
	if ! select_installed_cluster "$TUI2_TITLE_DAY2_SSH" "Select cluster for SSH:"; then
		return 1
	fi

	local cl_display="$SELECTED_CLUSTER_DISPLAY"
	tui_log "SSH into Rendezvous Server of $cl_display"

	clear
	echo "═══════════════════════════════════════════════════════════════"
	echo "  SSH into Rendezvous Server of: $cl_display"
	echo "  Type 'exit' to return to TUI"
	echo "═══════════════════════════════════════════════════════════════"
	echo

	cd "$ABA_ROOT"
	# Close flock fd so SSH session doesn't inherit and hold the TUI lock
	bash -c "aba --dir $SELECTED_CLUSTER ssh" {ABA_TUI_FLOCK_FD}>&- || true

	echo
	read -rp "Press ENTER to return to TUI..."
}

# --- Upgrade cluster ---
_day2_upgrade() {
	if ! select_installed_cluster "$TUI2_TITLE_DAY2_UPGRADE" "Select cluster to upgrade:"; then
		return 1
	fi

	# Fetch available versions
	dlg --backtitle "$(ui_backtitle)" --infobox "\nFetching available upgrade versions for $SELECTED_CLUSTER_DISPLAY..." 0 0
	local _versions_raw
	_versions_raw=$(aba --dir "$SELECTED_CLUSTER" upgrade --dry-run 2>&1) || true

	# Parse version lines — only from the "Versions in mirror" list section
	local _versions=() _in_list=0
	while IFS= read -r line; do
		[[ "$line" =~ Versions\ in\ mirror ]] && _in_list=1 && continue
		[[ $_in_list -eq 0 ]] && continue
		local ver
		ver=$(echo "$line" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[a-z]+\.[0-9]+)?' | head -1)
		[[ -n "$ver" ]] && _versions+=("$ver")
	done <<< "$_versions_raw"

	# De-duplicate and sort descending
	local _sorted=()
	if [[ ${#_versions[@]} -gt 0 ]]; then
		while IFS= read -r v; do
			_sorted+=("$v")
		done < <(printf '%s\n' "${_versions[@]}" | sort -V -r | uniq)
	fi

	if [[ ${#_sorted[@]} -eq 0 ]]; then
		local _upgrade_hint=""
		case "$_TUI_MODE" in
			CONNO)
				_upgrade_hint="To add newer versions to the mirror:\n  1. Update the channel/version in ImageSet Config (main menu → V)\n  2. Sync images (main menu → Y)\n  3. Run Day-2 to apply changes (main menu → D)\n  4. Then retry Upgrade here"
				;;
	DISCO)
		_upgrade_hint="To upgrade in a disconnected environment:\n\n  On the connected host:\n    1. Prepare Upgrade for Transfer (U)\n    2. Copy mirror/data/ files to this host\n\n  On this host:\n    3. Load images (L)\n    4. Day-2 → Configure OperatorHub (D → R)\n    5. Then retry Upgrade here\n\nIf you already copied new archives, have you loaded them (L)?"
		;;
			*)
				_upgrade_hint="Ensure newer OpenShift versions are available in the mirror,\nthen retry Upgrade here."
				;;
		esac
		dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_DAY2_UPGRADE" \
			--msgbox "No available upgrade versions found for $SELECTED_CLUSTER_DISPLAY.\n\n$_upgrade_hint" 0 0
		return 1
	fi

	local default_item="${_sorted[0]}"

	while :; do
		if [[ ${#_sorted[@]} -gt 0 ]]; then
			# Build menu from available versions
			local items=()
			local idx=0
			for v in "${_sorted[@]}"; do
				if [[ $idx -eq 0 ]]; then
					items+=("$v" "(newest)")
				else
					items+=("$v" "")
				fi
				idx=$(( idx + 1 ))
			done
			items+=("M" "Manual entry...")

			dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_DAY2_UPGRADE" \
				--ok-label "Upgrade" \
				--cancel-label "$TUI2_BTN_BACK" \
				--help-button \
				--default-item "$default_item" \
				--menu "Select target version for $SELECTED_CLUSTER_DISPLAY:" 0 0 0 \
				"${items[@]}" \
				2>"$_TUI_TMP"
			local rc=$?

			case $rc in
				2)
					# Help — show raw output from dry-run
					dlg --backtitle "$(ui_backtitle)" --title "Available Versions (raw)" \
						--msgbox "$_versions_raw" 0 0
					continue
					;;
				1|255) return 1 ;;
				0) ;;
			esac

			local choice
			choice=$(<"$_TUI_TMP")
			[[ -n "$choice" ]] && default_item="$choice"

			if [[ "$choice" == "M" ]]; then
				# Fall through to manual entry below
				:
			elif [[ "$choice" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-z]+\.[0-9]+)?$ ]]; then
				confirm_and_execute "aba --dir $SELECTED_CLUSTER upgrade --to $choice" \
					"$TUI2_TITLE_DAY2_UPGRADE: $SELECTED_CLUSTER_DISPLAY → $choice"
				return
			fi
		fi

		# Manual entry (fallback or explicit choice)
		dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_DAY2_UPGRADE" \
			--ok-label "Upgrade" \
			--cancel-label "$TUI2_BTN_BACK" \
			--inputbox "Enter target version for $SELECTED_CLUSTER_DISPLAY:\n\n(Format: X.Y.Z or X.Y.Z-rc.N, e.g. 4.21.15 or 4.22.0-rc.1)" 0 0 "" \
			2>"$_TUI_TMP"
		[[ $? -ne 0 ]] && return 1

		local target_ver
		target_ver=$(<"$_TUI_TMP")
		if [[ -z "$target_ver" ]]; then
			dlg --backtitle "$(ui_backtitle)" --msgbox "No version entered." 0 0
			continue
		fi
		if ! [[ "$target_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-z]+\.[0-9]+)?$ ]]; then
			dlg --backtitle "$(ui_backtitle)" --msgbox "Invalid version format: '$target_ver'\n\nExpected format: X.Y.Z or X.Y.Z-rc.N (e.g. 4.21.15 or 4.22.0-rc.1)" 0 0
			continue
		fi
		confirm_and_execute "aba --dir $SELECTED_CLUSTER upgrade --to $target_ver" \
			"$TUI2_TITLE_DAY2_UPGRADE: $SELECTED_CLUSTER_DISPLAY → $target_ver"
		return
	done
}

# --- Graceful Cluster Shutdown ---
_day2_shutdown() {
	if ! select_installed_cluster "$TUI2_TITLE_DAY2_SHUTDOWN" "Select cluster to shut down:"; then
		return 1
	fi

	local cl_display="$SELECTED_CLUSTER_DISPLAY"

	dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_DAY2_SHUTDOWN" \
		--yes-label "Shutdown" --no-label "$TUI2_BTN_CANCEL" \
		--yesno "Gracefully shut down cluster '$cl_display'?\n\nThis will cordon, drain and shutdown all nodes.\nThe operation will wait until shutdown is complete." 0 0
	[[ $? -ne 0 ]] && return 0

	confirm_and_execute "aba --dir $SELECTED_CLUSTER shutdown --wait" "$TUI2_TITLE_DAY2_SHUTDOWN: $cl_display"
}

# --- Graceful Cluster Startup ---
_day2_startup() {
	if ! select_installed_cluster "$TUI2_TITLE_DAY2_STARTUP" "Select cluster to start:"; then
		return 1
	fi

	local cl_display="$SELECTED_CLUSTER_DISPLAY"

	dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_DAY2_STARTUP" \
		--yes-label "Start" --no-label "$TUI2_BTN_CANCEL" \
		--yesno "Start cluster '$cl_display'?\n\nThis will power on the cluster VMs." 0 0
	[[ $? -ne 0 ]] && return 0

	confirm_and_execute "aba --dir $SELECTED_CLUSTER startup" "$TUI2_TITLE_DAY2_STARTUP: $cl_display"
}

# --- Refresh (recreate VMs, trigger new install) ---
_day2_refresh() {
	if ! select_cluster "$TUI2_TITLE_DAY2_REFRESH" "Select cluster to refresh:"; then
		return 1
	fi

	local cl_display="$SELECTED_CLUSTER_DISPLAY"

	dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_DAY2_REFRESH" \
		--yes-label "Refresh" --no-label "$TUI2_BTN_CANCEL" \
		--yesno "Refresh cluster '$cl_display'?\n\nThis will destroy existing VMs and trigger a fresh installation.\nAll current cluster data will be lost.\n\nThis action cannot be undone!" 0 0
	[[ $? -ne 0 ]] && return 0

	confirm_and_execute "aba --dir $SELECTED_CLUSTER refresh" "$TUI2_TITLE_DAY2_REFRESH: $cl_display"
}

# --- Clean cluster dir (retry install) ---
_day2_clean() {
	if ! select_cluster "$TUI2_TITLE_DAY2_CLEAN" "Select cluster to clean:"; then
		return 1
	fi

	local cl_display="$SELECTED_CLUSTER_DISPLAY"

	dlg --backtitle "$(ui_backtitle)" --title "$TUI2_TITLE_DAY2_CLEAN" \
		--yes-label "Clean" --no-label "$TUI2_BTN_CANCEL" \
		--yesno "Clean cluster '$cl_display'?\n\nThis removes generated artifacts (ISO, install-config, etc.)\nso you can retry the installation.\n\nCluster configuration (cluster.conf) is preserved." 0 0
	[[ $? -ne 0 ]] && return 0

	confirm_and_execute "aba --dir $SELECTED_CLUSTER clean" "$TUI2_TITLE_DAY2_CLEAN: $cl_display"
}

# --- Delete cluster (reuses existing cluster_delete, now accessed from Day-2 menu) ---
_day2_delete() {
	cluster_delete
}
