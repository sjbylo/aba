#!/bin/bash
# config-import.sh -- Import a "site" config payload into this aba tree, VERBATIM.
#
# INTENT:   Take a directory of pre-built aba configs (produced by anything: a
#           generator, a human, CI - aba does not care) and place each file at its
#           correct path in this aba installation, byte-for-byte, then pin the
#           regeneration guards so aba never re-templates over the imported files.
#           This is the "bring your own configs" path used by 'aba deploy'.
#
# LAYOUT (source-agnostic convention; every path is optional):
#   <dir>/aba.conf                              -> aba.conf
#   <dir>/vmware.conf | kvm.conf                -> vmware.conf | kvm.conf
#   <dir>/mirror/mirror.conf                    -> mirror/mirror.conf
#   <dir>/mirror/imageset-config.yaml           -> mirror/data/imageset-config.yaml
#   <dir>/<cluster>/cluster.conf                -> <cluster>/cluster.conf
#   <dir>/<cluster>/install-config.yaml         -> <cluster>/install-config.yaml
#   <dir>/<cluster>/agent-config.yaml           -> <cluster>/agent-config.yaml
#   <dir>/<cluster>/macs.conf                   -> <cluster>/macs.conf
#   <dir>/<cluster>/day2-custom-manifests/...   -> <cluster>/day2-custom-manifests/...
#   <dir>/helm/...                              -> helm/... (opaque passthrough)
#   (any subdir other than mirror/ or helm/ is treated as a cluster directory)
#
# USAGE:    aba config import <dir>

_CALLER_PWD="$PWD"   # user's cwd, captured before we cd to the aba root (to resolve a relative <dir>)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
cd "$SCRIPT_DIR/.." || exit 1
source scripts/include_all.sh

# config_import_apply <src_site_dir> <dest_aba_root>
# Copy recognized configs from the site layout into the aba tree byte-for-byte,
# backing up any existing target to *.backup, then pin regeneration guards.
config_import_apply() {
	local src="$1" dest="$2"

	{ [ -n "$src" ] && [ -d "$src" ]; } || aba_abort "config import: source directory not found: ${src:-<none>}"
	[ -n "$dest" ] || aba_abort "config import: no destination aba root given"

	# Copy a file byte-for-byte, creating parent dirs and backing up any existing target.
	# Every mutation is checked so a failed copy aborts loudly instead of reporting success.
	_cp_verbatim() {
		local s="$1" t="$2"
		mkdir -p "$(dirname "$t")" || aba_abort "config import: cannot create directory for ${t#"$dest"/}"
		# Back up an existing target only ONCE, so re-imports never overwrite the
		# user's genuine pre-aba original with a previously-imported copy.
		[ -s "$t" ] && [ ! -e "$t.backup" ] && { cp -f -- "$t" "$t.backup" || aba_abort "config import: cannot back up ${t#"$dest"/}"; }
		cp -f -- "$s" "$t" || aba_abort "config import: failed to copy '$s' -> ${t#"$dest"/}"
		aba_info "imported ${t#"$dest"/}"
	}

	local copied=0 f d name imported="" _did_mirror_conf="" _did_isc=""

	# Replace a directory payload byte-for-byte, backing up any existing target to
	# *.backup first (mirrors _cp_verbatim's backup behavior for files).
	_cp_dir_verbatim() {
		local s="$1" t="$2"
		mkdir -p "$(dirname "$t")" || aba_abort "config import: cannot create directory for ${t#"$dest"/}"
		if [ -e "$t" ]; then
			# Back up the original ONCE; later re-imports must not clobber it.
			if [ -e "$t.backup" ]; then rm -rf -- "$t"; else mv -- "$t" "$t.backup" || aba_abort "config import: cannot back up ${t#"$dest"/}"; fi
		fi
		cp -a -- "$s" "$t" || aba_abort "config import: failed to copy '$s' -> ${t#"$dest"/}"
	}

	# Validate ALL cluster-dir names up front, before copying anything, so a bad or
	# reserved name aborts while the tree is still untouched (no half-import).
	for d in "$src"/*/; do
		[ -d "$d" ] || continue
		name="$(basename "$d")"
		case "$name" in mirror|helm) continue ;; esac
		_valid_cluster_name "$name" >/dev/null 2>&1 || aba_abort "config import: invalid or reserved cluster directory name '$name' in the site payload"
	done

	# Top-level aba configs
	for f in aba.conf vmware.conf kvm.conf; do
		if [ -f "$src/$f" ]; then
			_cp_verbatim "$src/$f" "$dest/$f"
			copied=$((copied + 1))
		fi
	done

	# Mirror configs
	if [ -f "$src/mirror/mirror.conf" ]; then
		_cp_verbatim "$src/mirror/mirror.conf" "$dest/mirror/mirror.conf"
		copied=$((copied + 1)); _did_mirror_conf=1
	fi
	if [ -f "$src/mirror/imageset-config.yaml" ]; then
		_cp_verbatim "$src/mirror/imageset-config.yaml" "$dest/mirror/data/imageset-config.yaml"
		copied=$((copied + 1)); _did_isc=1
	fi

	# Per-cluster configs: every subdir of the site except mirror/ and helm/ (names
	# were validated in the pre-pass above).
	for d in "$src"/*/; do
		[ -d "$d" ] || continue
		name="$(basename "$d")"
		case "$name" in mirror|helm) continue ;; esac
		local _n=0
		[ -f "$d/cluster.conf" ]        && { _cp_verbatim "$d/cluster.conf"        "$dest/$name/cluster.conf";        copied=$((copied + 1)); _n=$((_n + 1)); }
		[ -f "$d/install-config.yaml" ] && { _cp_verbatim "$d/install-config.yaml" "$dest/$name/install-config.yaml"; copied=$((copied + 1)); _n=$((_n + 1)); }
		[ -f "$d/agent-config.yaml" ]   && { _cp_verbatim "$d/agent-config.yaml"   "$dest/$name/agent-config.yaml";   copied=$((copied + 1)); _n=$((_n + 1)); }
		[ -f "$d/macs.conf" ]           && { _cp_verbatim "$d/macs.conf"           "$dest/$name/macs.conf";           copied=$((copied + 1)); _n=$((_n + 1)); }
		[ -d "$d/day2-custom-manifests" ] && { _cp_dir_verbatim "$d/day2-custom-manifests" "$dest/$name/day2-custom-manifests"; copied=$((copied + 1)); _n=$((_n + 1)); }
		# The site layout carries a single mirror/ payload, so a cluster wired to a
		# non-default mirror_name would look elsewhere and ignore it - warn clearly.
		if [ -f "$d/cluster.conf" ]; then
			local _mn; _mn="$(grep '^mirror_name=' "$d/cluster.conf" 2>/dev/null | head -1 | cut -d= -f2 | awk '{print $1}')"
			[ -n "$_mn" ] && [ "$_mn" != "mirror" ] && aba_warning "config import: cluster '$name' sets mirror_name='$_mn'; the site layout carries a single 'mirror/' payload, so this cluster may not use the imported mirror config."
		fi
		# Only record this cluster as imported when at least one file was actually copied,
		# so the pins/scaffold below never mutate a same-named pre-existing cluster.
		[ "$_n" -gt 0 ] && imported="$imported $name"
	done

	# Optional helm charts payload (opaque passthrough, no regeneration guard)
	[ -d "$src/helm" ] && { _cp_dir_verbatim "$src/helm" "$dest/helm"; copied=$((copied + 1)); }

	[ "$copied" -gt 0 ] || aba_abort "config import: no recognized config files found under $src"

	# --- pin regeneration guards ---------------------------------------------
	# Every copy above has an mtime of 'now'. On second-granularity filesystems,
	# "protected file newer than trigger" is not guaranteed by copy order alone, so
	# we age the TRIGGER files ~1 minute and re-stamp the PROTECTED files to 'now'.
	# Only files imported this run are touched, and no absent file is created.

	# Best-effort: age an EXISTING file ~1 minute into the past (portable, no-create).
	_age_past() {
		touch -c -d '1 minute ago' "$1" 2>/dev/null && return 0
		local ts
		ts="$(date -d '1 minute ago' +%Y%m%d%H%M.%S 2>/dev/null || date -v-1M +%Y%m%d%H%M.%S 2>/dev/null || true)"
		[ -n "$ts" ] && touch -c -t "$ts" "$1" 2>/dev/null
		return 0
	}

	# ISC: reg-create-imageset-config.sh regenerates unless imageset-config.yaml is
	# strictly newer than data/.created - so keep the imported ISC pinned, but ONLY when
	# it was actually imported this run (never re-pin a pre-existing generated ISC).
	# .created must exist for the guard, so create it (empty marker) before aging it.
	if [ -n "$_did_isc" ] && [ -f "$dest/mirror/data/imageset-config.yaml" ]; then
		[ -f "$dest/mirror/data/.created" ] || : > "$dest/mirror/data/.created"
		_age_past "$dest/mirror/data/.created"
		touch "$dest/mirror/data/imageset-config.yaml"
	fi

	# install-config.yaml / agent-config.yaml: make regenerates them if they are older
	# than their prerequisites cluster.conf or mirror.conf - so keep the IMPORTED ones
	# newest. Gate every touch on what was copied THIS run (checked against $src), so a
	# partial payload never rewinds or re-pins a user's own pre-existing files.
	for name in $imported; do
		d="$dest/$name"; s="$src/$name"
		if [ -f "$s/install-config.yaml" ] || [ -f "$s/agent-config.yaml" ]; then
			# Age a trigger only if IT was imported too; a non-imported cluster.conf or
			# mirror.conf is already older than the just-copied protected file.
			[ -f "$s/cluster.conf" ] && _age_past "$d/cluster.conf"
			[ -n "$_did_mirror_conf" ] && _age_past "$dest/mirror/mirror.conf"
			[ -f "$s/install-config.yaml" ] && touch "$d/install-config.yaml"
			[ -f "$s/agent-config.yaml" ]   && touch "$d/agent-config.yaml"
		fi
	done

	_IMPORTED_CLUSTERS="$imported"   # expose to the caller so scaffolding touches only these
	return 0
}

# ---- run (the unit test extracts config_import_apply and never reaches here) --
aba_debug "Starting: $0 $*"

_verb=""
[ "$1" = "import" ] && { _verb="import"; shift; }

_src="$1"
[ -n "$_src" ] || aba_abort "Usage: aba config import <dir>" "Imports configs from <dir> into this aba installation (source-agnostic; files are used verbatim)."
# Resolve a relative <dir> against the user's original cwd, not the aba root we cd'd to.
case "$_src" in /*) ;; *) _src="$_CALLER_PWD/$_src" ;; esac
[ -d "$_src" ] || aba_abort "config import: source directory not found: $_src"
_src="$(cd "$_src" && pwd -P)"

aba_info "Importing configuration from: $_src"
config_import_apply "$_src" "$PWD"

# Scaffold each imported cluster dir so 'make'/'aba' can operate on it: config
# import only copies config files, but a working cluster dir also needs the
# 'Makefile' symlink and the 'scripts'/'templates'/'mirror'/'aba.conf' symlinks
# that 'make init' creates. Without this, 'make -C <cluster> iso' and day2 fail.
# Re-assert the mtime pins afterwards: 'make init' creates a fresh '.init' marker
# (mtime now), and '.init' is a NORMAL prerequisite of cluster.conf in
# templates/Makefile.cluster ('cluster.conf: .init | mirror.conf'). Since
# config_import_apply aged cluster.conf into the past, an un-pinned cluster.conf
# would be older than '.init', so the next 'make ... iso' would re-run
# create-cluster-conf.sh and then re-template the imported install/agent-config.
# Pin ONLY the files imported verbatim THIS run (checked against $_src), in
# cluster.conf -> install/agent order so each stays newest-in-turn (make rebuilds
# only on a STRICTLY newer prerequisite). Files NOT imported are left alone so make
# can still (re)generate them - e.g. install-config after a cluster.conf-only import.
for _cname in $_IMPORTED_CLUSTERS; do
	[ -f "$_cname/cluster.conf" ] || continue
	[ -e "$_cname/Makefile" ] || ln -fs ../templates/Makefile.cluster "$_cname/Makefile"
	make -s -C "$_cname" init >/dev/null 2>&1 || aba_warning "config import: 'make init' for cluster '$_cname' reported an issue (continuing)"
	[ -f "$_src/$_cname/cluster.conf" ]        && touch "$_cname/cluster.conf"
	[ -f "$_src/$_cname/install-config.yaml" ] && touch "$_cname/install-config.yaml"
	[ -f "$_src/$_cname/agent-config.yaml" ]   && touch "$_cname/agent-config.yaml"
done

# Validate the imported top-level config; fail with a clear error if invalid.
if [ -f aba.conf ]; then
	source <(normalize-aba-conf)
	verify-aba-conf || aba_abort "$_ABA_CONF_ERR"
fi

aba_info_ok "Configuration imported. aba will use these files verbatim (no re-templating)."
