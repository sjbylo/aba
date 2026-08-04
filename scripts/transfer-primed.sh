#!/bin/bash -e
# INTENT:      Create aba-transfer-configs.tar with primed cluster dirs for day-N transfers
# CALLED BY:   aba transfer-primed (or aba transfer)
# CWD:         ABA repo root OR a cluster directory (via -d)
# ARGS:        None
# REQUIRES:    At least one cluster directory with cluster.conf
# PRODUCES:    mirror/data/aba-transfer-configs.tar
# SIDE EFFECTS:
#   - Temporarily resolves symlinks in cluster dirs (restored on exit)
#   - Temporarily creates .primed markers (restored on exit)
# IDEMPOTENT:  Yes (recreates tar each time)

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

source <(normalize-aba-conf)

# Determine if running from repo root or a single cluster dir
_single_cluster=""
if [ -f cluster.conf ] && ! grep -q "Top level Makefile" Makefile 2>/dev/null; then
	_single_cluster="$PWD"
	cd ..
fi

# Locate ABA root
_aba_root="$PWD"
if ! grep -q "Top level Makefile" Makefile 2>/dev/null; then
	aba_abort "Cannot determine ABA root directory. Run from repo root or use 'aba -d <cluster> transfer-primed'."
fi

_output_dir="mirror/data"
_output_file="$_output_dir/aba-transfer-configs.tar"
mkdir -p "$_output_dir"

# Collect cluster dirs to include
_cluster_dirs=()
if [ "$_single_cluster" ]; then
	_cluster_dirs=("$_single_cluster")
else
	for _cf in */cluster.conf; do
		[ -f "$_cf" ] || continue
		_cdir=$(dirname "$_cf")
		[ "$_cdir" = "mirror" ] && continue
		_cluster_dirs+=("$_cdir")
	done
fi

if [ ${#_cluster_dirs[@]} -eq 0 ]; then
	aba_abort "No cluster directories found. Create a cluster first: aba cluster -n <name> -t <type>"
fi

# Parallel arrays for symlink restoration on exit
_resolved_copies=""
declare -a _original_targets=()
_primed_dirs=""

_restore_transfer_cleanup() {
	local _i=0
	for _resolved in $_resolved_copies; do
		rm -f "$_resolved"
		ln -sf "${_original_targets[$_i]}" "$_resolved"
		_i=$(( _i + 1 ))
	done
	for _d in $_primed_dirs; do
		rm -f "$_d/.primed"
	done
}
trap '_restore_transfer_cleanup' EXIT

# Prepare each cluster dir: resolve symlinks, set .primed markers
for _cdir in "${_cluster_dirs[@]}"; do
	[ ! -f "$_cdir/.init" ] && [ -f "$_cdir/cluster.conf" ] && touch -r "$_cdir/cluster.conf" "$_cdir/.init"

	for _f in vmware.conf kvm.conf mirror.conf; do
		if [ -L "$_cdir/$_f" ]; then
			_orig_target=$(readlink "$_cdir/$_f")
			if [ -e "$_cdir/$_f" ]; then
				cp --remove-destination "$(readlink -f "$_cdir/$_f")" "$_cdir/$_f"
				_resolved_copies+=" $_cdir/$_f"
				_original_targets+=("$_orig_target")
			fi
		fi
	done

	if [ -f "$_cdir/install-config.yaml" ] && [ -f "$_cdir/agent-config.yaml" ]; then
		touch "$_cdir/.primed"
		touch "$_cdir/.bm-message"
		_primed_dirs+=" $_cdir"
	fi
done

# Build the tar — exclude only iso-agent-based/ (large ISOs)
_tar_args=()
for _cdir in "${_cluster_dirs[@]}"; do
	_tar_args+=("$_cdir")
done

aba_info "Creating transfer configs tar: $_output_file"
aba_info "Including ${#_cluster_dirs[@]} cluster dir(s): ${_cluster_dirs[*]}"

tar cf "$_output_file" \
	--exclude='*/iso-agent-based' \
	--exclude='.install-complete' \
	--exclude='.autopoweroff' \
	--exclude='.autoupload' \
	--exclude='.autorefresh' \
	--exclude='.auto-agent-up' \
	--exclude='.bm-nextstep' \
	--exclude='.preflight-done' \
	"${_tar_args[@]}"

_size=$(du -h "$_output_file" | awk '{print $1}')
aba_success "Transfer configs tar created: $_output_file ($_size)"
aba_info "Copy to disconnected side: cp $_output_file /path/to/portable/media/"
aba_info "On disco: cp /path/to/media/$(basename "$_output_file") mirror/data/ && aba -d mirror load"
