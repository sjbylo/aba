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
	_cp_verbatim() {
		local s="$1" t="$2"
		mkdir -p "$(dirname "$t")"
		[ -s "$t" ] && cp -f -- "$t" "$t.backup"
		cp -f -- "$s" "$t"
		aba_info "imported ${t#"$dest"/}"
	}

	local copied=0 f d name

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
		copied=$((copied + 1))
	fi
	if [ -f "$src/mirror/imageset-config.yaml" ]; then
		_cp_verbatim "$src/mirror/imageset-config.yaml" "$dest/mirror/data/imageset-config.yaml"
		copied=$((copied + 1))
	fi

	# Per-cluster configs: every subdir of the site except mirror/ and helm/
	for d in "$src"/*/; do
		[ -d "$d" ] || continue
		name="$(basename "$d")"
		case "$name" in mirror|helm) continue ;; esac
		[ -f "$d/cluster.conf" ]        && { _cp_verbatim "$d/cluster.conf"        "$dest/$name/cluster.conf";        copied=$((copied + 1)); }
		[ -f "$d/install-config.yaml" ] && { _cp_verbatim "$d/install-config.yaml" "$dest/$name/install-config.yaml"; copied=$((copied + 1)); }
		[ -f "$d/agent-config.yaml" ]   && { _cp_verbatim "$d/agent-config.yaml"   "$dest/$name/agent-config.yaml";   copied=$((copied + 1)); }
		[ -f "$d/macs.conf" ]           && { _cp_verbatim "$d/macs.conf"           "$dest/$name/macs.conf";           copied=$((copied + 1)); }
		if [ -d "$d/day2-custom-manifests" ]; then
			mkdir -p "$dest/$name"
			rm -rf -- "$dest/$name/day2-custom-manifests"
			cp -a -- "$d/day2-custom-manifests" "$dest/$name/day2-custom-manifests"
			copied=$((copied + 1))
		fi
	done

	# Optional helm charts payload (opaque passthrough, no regeneration guard)
	if [ -d "$src/helm" ]; then
		rm -rf -- "$dest/helm"
		cp -a -- "$src/helm" "$dest/helm"
	fi

	[ "$copied" -gt 0 ] || aba_abort "config import: no recognized config files found under $src"

	# --- pin regeneration guards ---------------------------------------------
	# Every copy above has an mtime of 'now'. On filesystems with second-level
	# mtime granularity, "protected file newer than trigger" is not guaranteed by
	# copy order alone, so we age the TRIGGER files by a minute and re-stamp the
	# PROTECTED files to 'now', making the strict "-nt" guards deterministic.

	# ISC: reg-create-imageset-config.sh regenerates unless imageset-config.yaml
	# is strictly newer than data/.created - so keep the imported ISC pinned.
	if [ -f "$dest/mirror/data/imageset-config.yaml" ]; then
		touch -d '1 minute ago' "$dest/mirror/data/.created" 2>/dev/null || : > "$dest/mirror/data/.created"
		touch "$dest/mirror/data/imageset-config.yaml"
	fi

	# install-config.yaml / agent-config.yaml: make regenerates them if they are
	# older than their prerequisites cluster.conf or mirror.conf - so keep them newest.
	for d in "$dest"/*/; do
		[ -d "$d" ] || continue
		name="$(basename "$d")"
		case "$name" in mirror|helm) continue ;; esac
		if [ -f "$d/install-config.yaml" ] || [ -f "$d/agent-config.yaml" ]; then
			touch -d '1 minute ago' "$d/cluster.conf" "$dest/mirror/mirror.conf" 2>/dev/null || true
			[ -f "$d/install-config.yaml" ] && touch "$d/install-config.yaml"
			[ -f "$d/agent-config.yaml" ]   && touch "$d/agent-config.yaml"
		fi
	done

	return 0
}

# ---- run (the unit test extracts config_import_apply and never reaches here) --
aba_debug "Starting: $0 $*"

_verb=""
[ "$1" = "import" ] && { _verb="import"; shift; }

_src="$1"
[ -n "$_src" ] || aba_abort "Usage: aba config import <dir>" "Imports configs from <dir> into this aba installation (source-agnostic; files are used verbatim)."
[ -d "$_src" ] || aba_abort "config import: source directory not found: $_src"
_src="$(cd "$_src" && pwd -P)"

aba_info "Importing configuration from: $_src"
config_import_apply "$_src" "$PWD"

# Validate the imported top-level config; fail with a clear error if invalid.
if [ -f aba.conf ]; then
	source <(normalize-aba-conf)
	verify-aba-conf || aba_abort "$_ABA_CONF_ERR"
fi

aba_info_ok "Configuration imported. aba will use these files verbatim (no re-templating)."
