#!/usr/bin/env bash
# =============================================================================
# E2E Test Framework v2 -- CLI Argument Parser
# =============================================================================
# Parses command-line arguments for run.sh.
# Exports CLI_* variables consumed by all other modules.
#
# Dependencies: constants.sh
# =============================================================================

# --- CLI Variables (defaults) ------------------------------------------------

CLI_COMMAND=""
CLI_SUITE=""
CLI_ALL=""
CLI_WITH_DUMMY=""
CLI_POOLS=""               # Raw pool spec from -p/--pools (parsed later)
CLI_RECREATE_GOLDEN=""
CLI_RECREATE_VMS=""
CLI_YES=""
CLI_QUIET=""
CLI_CLEAN=""
CLI_DRY_RUN=""
CLI_FORCE=""
CLI_RESUME=""
CLI_DEV=""
CLI_REVERT=""
CLI_OS=""
CLI_VMWARE_CONF=""
CLI_CON_USER=""
CLI_DIS_USER=""
CLI_ATTACH=""
CLI_LIVE=""
CLI_DASHBOARD=""
CLI_DASH_LOG="summary.log"

# Resolved pool list (space-separated integers, populated by _resolve_pools)
CLI_POOL_LIST=""

# --- Usage -------------------------------------------------------------------

_usage() {
	cat <<-'USAGE'
	E2E Test Framework v2 -- Coordinator

	Commands:
	  run.sh run [-s X] [-p 1,2,3]             Run suites (blocks until completion)
	  run.sh run -p all                        Run all suites across all pools
	  run.sh run -s X -p 2 -f                 Force dispatch onto pool 2
	  run.sh run -p all -d                     Push local source to ~/aba, then run
	  run.sh run -a -D -p all                  Include dummy framework test suites
	  run.sh daemon [-a] [-p 1-4]              Auto-restarting dispatcher (crash-resilient)
	  run.sh reschedule [-s X]                 Re-queue suites to running dispatcher
	  run.sh deploy [-p 2,3]                   Push source code + harness to conN
	  run.sh restart [-p 2] [-r]               Stop + deploy + re-run last suite
	  run.sh stop [-p 2,3] [-c]               Kill runners (-c: delete clusters/mirrors)
	  run.sh start [-p 1-4]                    Power on pool VMs (conN + disN)
	  run.sh status [-p 3]                     Show what's running
	  run.sh verify [-p all]                   Verify pool VMs (run ALL checks, report ALL results)
	  run.sh list                              List available suites (dummy suites shown separately)
	  run.sh destroy [-p all] [-c]             Destroy pool VMs (-c: delete clusters first)
	  run.sh attach conN                       Attach to runner tmux session on conN
	  run.sh live [-p 1-3]                     Interactive multi-pane dashboard
	  run.sh dash [-p all] [log]               Read-only summary dashboard

	Options:
	  -s, --suite X,Y        Select specific suite(s) (comma-separated)
	  -a, --all              Select all suites (default for run/reschedule)
	  -D, --with-dummy       Include dummy-* suites (excluded from --all by default)
	  -p, --pool SPEC        Pool selection: N, N-M, N,M,O, or "all"
	                         (aliases: --pools, --pool-list)
	  -f, --force            Override safety checks (dispatch to busy pool, hot-deploy)
	  -d, --dev              Push local source to ~/aba on conN (instead of git clone)
	  -r, --resume           Skip previously-passed tests (checkpointed)
	  -n, --dry-run          Show dispatch plan, don't execute
	  -c, --clean            Delete clusters/mirrors before stopping/destroying
	  -V, --revert           Revert pool VMs to pool-ready snapshot before running
	  -G, --recreate-golden  Force rebuild golden VM from template
	  -R, --recreate-vms     Force reclone conN/disN from golden (scoped to -p)
	  -y, --yes              Auto-accept prompts
	  -q, --quiet            CI mode (implies -y)
	  -o, --os RHEL          RHEL version for pool VMs (rhel8|rhel9|rhel10)
	  -v, --vmware-conf F    Path to vmware.conf (e.g. ~/.vmware-esxi.conf)
	  -u, --user USER        SSH user for both conN and disN
	  --con-user USER        SSH user for conN only
	  --dis-user USER        SSH user for disN only

	USAGE
}

# --- Pool Selection Parser ---------------------------------------------------
# Input: SPEC string from -p / --pools
# Output: space-separated list of pool numbers (e.g. "1 2 3") on stdout
#
# Supports: single (3), list (1,4), range (1-4), keyword (all).
# Validates: pool numbers 1-6, ascending ranges, pools exist in pools.conf.

_parse_pools() {
	local spec="$1"
	local pools_file="$2"

	if [ "$spec" = "all" ]; then
		_all_pool_numbers "$pools_file"
		return
	fi

	local result=()
	local parts
	local _old_ifs="$IFS"
	IFS=',' read -ra parts <<< "$spec"
	IFS="$_old_ifs"

	local part
	for part in "${parts[@]}"; do
		if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
			local start="${BASH_REMATCH[1]}"
			local end="${BASH_REMATCH[2]}"
			if [ "$start" -gt "$end" ]; then
				echo "ERROR: Invalid pool range '$part' -- must be ascending (e.g. 1-4, not 4-1)" >&2
				return 1
			fi
			local i
			for (( i=start; i<=end; i++ )); do
				result+=("$i")
			done
		elif [[ "$part" =~ ^[0-9]+$ ]]; then
			result+=("$part")
		else
			echo "ERROR: Invalid pool spec '$part' -- use a number, range (1-4), or 'all'" >&2
			return 1
		fi
	done

	# Deduplicate while preserving order
	local seen=() unique=() n
	for n in "${result[@]}"; do
		local dup=""
		local s
		for s in "${seen[@]+"${seen[@]}"}"; do
			[ "$s" = "$n" ] && dup=1 && break
		done
		if [ -z "$dup" ]; then
			seen+=("$n")
			unique+=("$n")
		fi
	done

	# Validate range 1-6
	for n in "${unique[@]}"; do
		if [ "$n" -lt 1 ] || [ "$n" -gt 6 ]; then
			echo "ERROR: Pool number $n is out of range (must be 1-6)" >&2
			return 1
		fi
	done

	echo "${unique[*]}"
}

# Read all pool numbers from pools.conf.
_all_pool_numbers() {
	local pools_file="$1"
	if [ ! -f "$pools_file" ]; then
		echo "ERROR: pools.conf not found: $pools_file" >&2
		return 1
	fi
	grep -v '^#' "$pools_file" | grep -v '^[[:space:]]*$' | while read -r _name _con _dis _template _rest; do
		for _kv in $_rest; do
			case "$_kv" in
				POOL_NUM=*) echo "${_kv#POOL_NUM=}" ;;
			esac
		done
	done | sort -n | tr '\n' ' '
}

# Count pools in pools.conf.
_pool_count_from_conf() {
	local pools_file="$1"
	if [ -f "$pools_file" ]; then
		grep -c '^[^#]' "$pools_file" 2>/dev/null || echo 0
	else
		echo 0
	fi
}

# --- Argument Parsing --------------------------------------------------------

_parse_args() {
	local run_dir="$1"; shift
	local pools_file="${run_dir}/pools.conf"

	# Step 1: Detect subcommand (first non-flag argument)
	if [ $# -gt 0 ]; then
		case "$1" in
			run|daemon|reschedule|deploy|restart|stop|start|status|verify|list|destroy|attach|live|dash)
				CLI_COMMAND="$1"; shift ;;
		esac
	fi

	# Step 2: Consume positional args for commands that take them
	case "${CLI_COMMAND:-}" in
		attach)
			if [ $# -gt 0 ] && [[ "$1" != -* ]]; then CLI_ATTACH="$1"; shift; fi ;;
		live)
			CLI_LIVE=""
			if [ $# -gt 0 ] && [[ "$1" =~ ^[0-9]+$ ]]; then CLI_LIVE="$1"; shift; fi ;;
		dash)
			CLI_DASHBOARD=""; CLI_DASH_LOG="summary.log"
			if [ $# -gt 0 ] && [[ "$1" =~ ^[0-9]+$ ]]; then CLI_DASHBOARD="$1"; shift; fi
			if [ $# -gt 0 ] && [ "$1" = "log" ]; then CLI_DASH_LOG="latest.log"; shift; fi ;;
	esac

	# Step 3: Parse flags
	while [ $# -gt 0 ]; do
		case "$1" in
			-s|--suite|--suites)    CLI_SUITE="$2"; shift 2 ;;
			-a|--all)               CLI_ALL=1; shift ;;
			-D|--with-dummy)        CLI_WITH_DUMMY=1; shift ;;
			-p|--pool|--pools|--pool-list)  CLI_POOLS="$2"; shift 2 ;;
			-G|--recreate-golden)   CLI_RECREATE_GOLDEN=1; shift ;;
			-R|--recreate-vms)      CLI_RECREATE_VMS=1; shift ;;
			-V|--revert)            CLI_REVERT=1; shift ;;
			-y|--yes)               CLI_YES=1; shift ;;
			-q|--quiet)             CLI_QUIET=1; CLI_YES=1; shift ;;
			-c|--clean)             CLI_CLEAN=1; shift ;;
			-n|--dry-run)           CLI_DRY_RUN=1; shift ;;
			-f|--force)             CLI_FORCE=1; shift ;;
			-d|--dev)               CLI_DEV=1; shift ;;
			-r|--resume)            CLI_RESUME=1; shift ;;
			-o|--os)                CLI_OS="$2"; shift 2 ;;
			-v|--vmware-conf)       CLI_VMWARE_CONF="$2"; shift 2 ;;
			-u|--user)              CLI_CON_USER="$2"; CLI_DIS_USER="$2"; shift 2 ;;
			--con-user)             CLI_CON_USER="$2"; shift 2 ;;
			--dis-user)             CLI_DIS_USER="$2"; shift 2 ;;
			-h|--help)              _usage; exit 0 ;;
			*) echo "Unknown option: $1" >&2; _usage; exit 1 ;;
		esac
	done

	# Step 4: Infer "run" when --all/--suite/--resume/--with-dummy used without a subcommand
	if [ -z "$CLI_COMMAND" ]; then
		if [ -n "$CLI_ALL" ] || [ -n "$CLI_SUITE" ] || [ -n "$CLI_RESUME" ] || [ -n "$CLI_WITH_DUMMY" ]; then
			CLI_COMMAND="run"
		fi
	fi

	# Step 5: Validate command
	case "${CLI_COMMAND:-}" in
		run|reschedule|deploy|restart|stop|start|status|verify|list|destroy|live|dash) ;;
		attach)
			if [ -z "${CLI_ATTACH:-}" ]; then
				echo "ERROR: attach requires a host (e.g. run.sh attach con1)" >&2
				exit 1
			fi ;;
		"")
			echo "ERROR: No command specified. Use: run, stop, status, list, etc." >&2
			_usage; exit 1 ;;
	esac

	# Step 6: For "run" and "reschedule", default to --all when no suite selector
	if [ "$CLI_COMMAND" = "run" ] || [ "$CLI_COMMAND" = "reschedule" ]; then
		if [ -z "$CLI_ALL" ] && [ -z "$CLI_SUITE" ] && [ -z "$CLI_RESUME" ]; then
			CLI_ALL=1
		fi
	fi

	# Step 7: Resolve pool list from -p/--pools spec
	_resolve_pools "$pools_file"
}

# --- Pool Resolution ---------------------------------------------------------
# Converts CLI_POOLS spec into CLI_POOL_LIST (space-separated integers).
# If -p was not given, uses last-run state or pools.conf defaults.

_resolve_pools() {
	local pools_file="$1"
	local last_run_file
	last_run_file="$(dirname "$pools_file")/.e2e-last-run"

	if [ -n "$CLI_POOLS" ]; then
		# Explicit -p/--pools given
		CLI_POOL_LIST=$(_parse_pools "$CLI_POOLS" "$pools_file") || exit 1
	else
		# No -p given: read-only commands default to ALL pools (show everything).
		# User/OS/vmware.conf context is still inherited from last-run.
		if _is_readonly_cmd && [ -f "$last_run_file" ]; then
			local _SAVED_POOLS=""
			local _SAVED_OS="" _SAVED_CON_USER="" _SAVED_DIS_USER="" _SAVED_VMWARE_CONF=""
			source "$last_run_file"
			# Inherit user/OS/vmware context (but NOT pools -- see below)
			[ -z "$CLI_OS" ] && [ -n "$_SAVED_OS" ] && CLI_OS="$_SAVED_OS"
			[ -z "$CLI_CON_USER" ] && [ -n "$_SAVED_CON_USER" ] && CLI_CON_USER="$_SAVED_CON_USER"
			[ -z "$CLI_DIS_USER" ] && [ -n "$_SAVED_DIS_USER" ] && CLI_DIS_USER="$_SAVED_DIS_USER"
			[ -z "$CLI_VMWARE_CONF" ] && [ -n "$_SAVED_VMWARE_CONF" ] && CLI_VMWARE_CONF="$_SAVED_VMWARE_CONF"
		fi
		# Default to all pools from pools.conf (not last-run pools).
		# Multiple dispatchers may target different pools; showing only the
		# last-run set hides active suites on other pools.
		CLI_POOL_LIST=$(_all_pool_numbers "$pools_file") || exit 1
	fi

	# Trim trailing whitespace
	CLI_POOL_LIST="${CLI_POOL_LIST%"${CLI_POOL_LIST##*[![:space:]]}"}"

	if [ -z "$CLI_POOL_LIST" ]; then
		echo "ERROR: No pools resolved. Check pools.conf or use -p to specify pools." >&2
		exit 1
	fi
}

# Readonly commands inherit state from last run.
_is_readonly_cmd() {
	case "${CLI_COMMAND:-}" in
		status|live|dash|stop|attach|verify|start|deploy|reschedule) return 0 ;;
		*) return 1 ;;
	esac
}

# --- Config Loading ----------------------------------------------------------
# Source config.env and apply CLI overrides.

_load_config() {
	local run_dir="$1"

	if [ -f "${run_dir}/config.env" ]; then
		set -a
		source "${run_dir}/config.env"
		set +a
	fi

	# CLI flags override config.env defaults
	[ -n "$CLI_OS" ] && export INT_BASTION_RHEL_VER="$CLI_OS"
	[ -n "$CLI_VMWARE_CONF" ] && export VMWARE_CONF="$CLI_VMWARE_CONF"
	[ -n "$CLI_CON_USER" ] && export CON_SSH_USER="$CLI_CON_USER"
	[ -n "$CLI_DIS_USER" ] && export DIS_SSH_USER="$CLI_DIS_USER"
}

# --- Git Metadata ------------------------------------------------------------

_detect_git_metadata() {
	local aba_root="$1"
	export E2E_GIT_BRANCH="${E2E_GIT_BRANCH:-$(git -C "$aba_root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo dev)}"
	export E2E_GIT_REPO="${E2E_GIT_REPO:-$(git -C "$aba_root" remote get-url origin 2>/dev/null || echo https://github.com/sjbylo/aba.git)}"
	export E2E_GIT_REPO_SLUG="${E2E_GIT_REPO_SLUG:-$(echo "$E2E_GIT_REPO" | sed 's|.*github.com[:/]||; s|\.git$||')}"
}

# --- Deployable config.env Generation ----------------------------------------
# Creates .config.env.deploy with CLI overrides baked in for conN.

_generate_deploy_config() {
	local run_dir="$1"
	local deploy_file="${run_dir}/.config.env.deploy"

	case "${CLI_COMMAND:-}" in
		run|deploy|restart|reschedule) ;;
		*) return 0 ;;
	esac

	{
		cat "${run_dir}/config.env"
		printf '\n# --- Auto-injected by run.sh (do not edit manually) ---\n'
		printf 'E2E_GIT_BRANCH=%s\n' "$E2E_GIT_BRANCH"
		printf 'E2E_GIT_REPO=%s\n' "$E2E_GIT_REPO"
		printf 'E2E_GIT_REPO_SLUG=%s\n' "$E2E_GIT_REPO_SLUG"

		local _cli_flags=""
		if [ -n "$CLI_OS" ]; then
			printf 'INT_BASTION_RHEL_VER=%s\n' "$CLI_OS"
			_cli_flags="${_cli_flags} OS"
		fi
		if [ -n "$CLI_VMWARE_CONF" ]; then
			printf 'VMWARE_CONF=%s\n' "$CLI_VMWARE_CONF"
			_cli_flags="${_cli_flags} VMWARE"
		fi
		if [ -n "$CLI_CON_USER" ]; then
			printf 'CON_SSH_USER=%s\n' "$CLI_CON_USER"
			_cli_flags="${_cli_flags} CON_USER"
		fi
		if [ -n "$CLI_DIS_USER" ]; then
			printf 'DIS_SSH_USER=%s\n' "$CLI_DIS_USER"
			_cli_flags="${_cli_flags} DIS_USER"
		fi
		[ -n "$_cli_flags" ] && printf '_E2E_CLI_OVERRIDES="%s"\n' "${_cli_flags# }"
	} > "$deploy_file"
}

# --- Save Last Run -----------------------------------------------------------
# Persist CLI state for readonly commands to inherit.

_save_last_run() {
	local run_dir="$1"
	local last_run_file="${run_dir}/.e2e-last-run"

	case "${CLI_COMMAND:-}" in
		run|restart) ;;
		*) return 0 ;;
	esac

	{
		printf '_SAVED_POOLS="%s"\n' "$CLI_POOL_LIST"
		[ -n "$CLI_OS" ] && printf '_SAVED_OS="%s"\n' "$CLI_OS"
		[ -n "$CLI_CON_USER" ] && printf '_SAVED_CON_USER="%s"\n' "$CLI_CON_USER"
		[ -n "$CLI_DIS_USER" ] && printf '_SAVED_DIS_USER="%s"\n' "$CLI_DIS_USER"
		[ -n "$CLI_VMWARE_CONF" ] && printf '_SAVED_VMWARE_CONF="%s"\n' "$CLI_VMWARE_CONF"
	} > "$last_run_file"
}
