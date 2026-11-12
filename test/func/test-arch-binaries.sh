#!/bin/bash
# Test: download, checksum-verify, install, and check the cli/ and mirror/
# binaries ABA's Makefiles actually fetch, for every architecture.
#
# A file is in scope only when a Make recipe names its URL and that URL is
# published (HTTP 200/206). Unpublished names the recipe would still form
# (govc and virtctl on ppc64le, mirror-registry on aarch64) are skipped.
#
# Checksums are the Makefile recipes (atomic-download / verify-sha256).
# Install extracts the same members those recipes install.
# Every binary must be an ELF for that architecture. The host architecture
# must also execute. Cross-arch binaries are not executed.
#
# Runs in a temp tree. The repo and ~/bin are left alone.
# Integration tier: this downloads several gigabytes.

cd "$(dirname "$0")/../.." || exit 1

pass=0
fail=0
skip=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }
_skip() { skip=$(( skip + 1 )); printf "  \033[33mSKIP\033[0m  %s\n" "$*"; }

WORK=$(mktemp -d /tmp/aba-arch-bins.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/tree/cli" "$WORK/tree/mirror" "$WORK/home" "$WORK/stage"
ln -s "$PWD/aba.conf" "$WORK/tree/aba.conf"
ln -s "$PWD/cli/Makefile" "$WORK/tree/cli/Makefile"
ln -s "$PWD/mirror/Makefile" "$WORK/tree/mirror/Makefile"
export HOME="$WORK/home"
export PLAIN_OUTPUT=1

HOST=$(uname -m)
CLI="$WORK/tree/cli"
MIRROR="$WORK/tree/mirror"

# uname -m -> substring that `file` prints for that ELF.
_elf_tag() {
	case "$1" in
		x86_64) echo 'x86-64' ;;
		aarch64) echo 'aarch64' ;;
		s390x) echo 'S/390' ;;
		ppc64le) echo 'PowerPC' ;;
		*) echo 'UNKNOWN' ;;
	esac
}

_reset_dir() {
	[ -d "$1" ] || return 0
	find "$1" -mindepth 1 -maxdepth 1 ! -name Makefile -exec rm -rf {} +
}

# uname -m -> the arch token ABA puts in download filenames.
_file_arch() {
	case "$1" in
		x86_64) echo amd64 ;;
		aarch64) echo arm64 ;;
		*) echo "$1" ;;
	esac
}

# True when the URL is a real published file, not a 404.
_http_ok() {
	local code
	code=$(curl -fsL --connect-timeout 10 --max-time 30 -o /dev/null -r 0-0 -w '%{http_code}' "$1" 2>/dev/null) || return 1
	case "$code" in
		200|206) return 0 ;;
		*) return 1 ;;
	esac
}

# Artifact URLs the Make recipe names. Checksum indexes are not artifacts.
# virtctl and argocd build the URL in the recipe, so resolve it the same way.
_artifact_urls() {
	local dir="$1" uname_arch="$2" target="$3" urls ver base fa
	# Only the "[ABA] Downloading <url>" lines. The recipe body repeats the
	# URL beside checksum indexes and shell punctuation, which is not a file.
	urls=$(make -C "$dir" -Bn --no-print-directory PLAIN_OUTPUT=1 arch="$uname_arch" "$target" 2>/dev/null \
		| sed -n 's/.*\[ABA\] Downloading \(https:\/\/[^[:space:]"]*\).*/\1/p' \
		| sort -u)
	if [ -n "$urls" ]; then
		printf '%s\n' "$urls"
		return 0
	fi
	fa=$(_file_arch "$uname_arch")
	case "$target" in
		download-virtctl)
			ver=$(curl -fsSL --connect-timeout 10 --max-time 20 \
				https://storage.googleapis.com/kubevirt-prow/release/kubevirt/kubevirt/stable.txt) || return 0
			ver=${ver//$'\n'/}
			echo "https://github.com/kubevirt/kubevirt/releases/download/${ver}/virtctl-${ver}-linux-${fa}"
			;;
		download-argocd)
			base=https://mirror.openshift.com/pub/cgw/openshift-gitops/
			ver=$(curl -fsSL --connect-timeout 10 --max-time 20 "$base" \
				| grep -oE '[0-9]+\.[0-9]+\.[0-9]+/' | tr -d '/' | sort -V | tail -1)
			[ -n "$ver" ] || return 0
			echo "${base}${ver}/argocd-linux-${fa}.tar.gz"
			;;
	esac
}

# Download one Make target. Checksum verification is inside the recipe.
_make_download() {
	local dir="$1" uname_arch="$2" target="$3"
	echo "--- $uname_arch $target ---"
	if make -C "$dir" --no-print-directory PLAIN_OUTPUT=1 arch="$uname_arch" "$target"; then
		return 0
	fi
	_fail "$uname_arch $target download+verify"
	_reset_dir "$dir"
	return 1
}

_runs() {
	local bin="$1"
	timeout 60 "$bin" --help >/dev/null 2>&1 && return 0
	timeout 60 "$bin" version --client >/dev/null 2>&1 && return 0
	timeout 60 "$bin" version >/dev/null 2>&1 && return 0
	return 1
}

_check_elf() {
	local bin="$1" uname_arch="$2" label="$3"
	local desc tag
	if [ ! -s "$bin" ]; then
		_fail "$label is empty"
		return
	fi
	chmod a+rx "$bin" || true
	desc=$(file -b "$bin")
	tag=$(_elf_tag "$uname_arch")
	if ! printf '%s\n' "$desc" | grep -q "$tag"; then
		_fail "$label is not $uname_arch ELF ($desc)"
		return
	fi
	if [ "$uname_arch" = "$HOST" ]; then
		if _runs "$bin"; then
			_pass "$label ($uname_arch, runs)"
		else
			_fail "$label ($uname_arch ELF ok, did not run)"
		fi
	else
		_pass "$label ($uname_arch ELF)"
	fi
}

# Extract named archive members (basename match) and check each.
_check_members() {
	local tar="$1" uname_arch="$2"
	shift 2
	local base member td bin
	td=$(mktemp -d "$WORK/stage/ext.XXXXXX")
	for base in "$@"; do
		member=$(tar -tzf "$tar" | grep -E "(^|/)${base}$" | head -1)
		if [ -z "$member" ]; then
			_fail "$(basename "$tar") has no $base member"
			continue
		fi
		tar -C "$td" --no-same-owner -xzf "$tar" "$member" || {
			_fail "$(basename "$tar") extract $base"
			continue
		}
		bin=$(find "$td" -type f -name "$base" | head -1)
		_check_elf "$bin" "$uname_arch" "$base from $(basename "$tar")"
	done
	rm -rf "$td"
}

# Extract the whole archive and check the first file whose name matches.
_check_found() {
	local tar="$1" uname_arch="$2" namepat="$3"
	local td bin
	td=$(mktemp -d "$WORK/stage/ext.XXXXXX")
	if ! tar -C "$td" --no-same-owner -xzf "$tar"; then
		_fail "$(basename "$tar") extract"
		rm -rf "$td"
		return
	fi
	bin=$(find "$td" -type f -name "$namepat" ! -name '*.tar.gz' | head -1)
	if [ -z "$bin" ]; then
		_fail "$(basename "$tar") has no $namepat binary"
		rm -rf "$td"
		return
	fi
	_check_elf "$bin" "$uname_arch" "$(basename "$bin") from $(basename "$tar")"
	rm -rf "$td"
}

_check_raw() {
	local file="$1" uname_arch="$2"
	local td
	td=$(mktemp -d "$WORK/stage/ext.XXXXXX")
	cp "$file" "$td/$(basename "$file")"
	_check_elf "$td/$(basename "$file")" "$uname_arch" "$(basename "$file")"
	rm -rf "$td"
}

# Install and check every regular file the last Make target wrote.
_check_downloaded() {
	local dir="$1" uname_arch="$2"
	local f name found=0
	while IFS= read -r f; do
		found=1
		name=$(basename "$f")
		if [ ! -s "$f" ]; then
			_skip "$uname_arch $name is not published"
			continue
		fi
		case "$name" in
			*.sha256|*.sha256sum.txt) ;;
			openshift-client-*) _check_members "$f" "$uname_arch" oc kubectl ;;
			openshift-install-*) _check_members "$f" "$uname_arch" openshift-install ;;
			oc-mirror-*) _check_members "$f" "$uname_arch" oc-mirror ;;
			govc_*) _check_members "$f" "$uname_arch" govc ;;
			kn-*) _check_found "$f" "$uname_arch" 'kn*' ;;
			tkn-*) _check_members "$f" "$uname_arch" tkn ;;
			helm-*) _check_found "$f" "$uname_arch" 'helm*' ;;
			opm-*) _check_found "$f" "$uname_arch" 'opm*' ;;
			argocd-*) _check_found "$f" "$uname_arch" 'argocd*' ;;
			butane-*|virtctl-*|roxctl-*) _check_raw "$f" "$uname_arch" ;;
			mirror-registry-*) _check_members "$f" "$uname_arch" mirror-registry ;;
			*) _fail "$uname_arch unexpected artifact $name" ;;
		esac
	done < <(find "$dir" -maxdepth 1 -type f 2>/dev/null | sort)
	if [ "$found" -eq 0 ]; then
		_fail "$uname_arch download produced no files"
	fi
	_reset_dir "$dir"
}

# Download only the named files that are actually published.
_cli_one() {
	local uname_arch="$1" target="$2" url base n_all=0 n_ok=0
	local -a files=()
	if [ ! -d "$CLI" ]; then
		_fail "cli work tree disappeared"
		echo ""
		echo "Results: $pass passed, $fail failed, $skip skipped"
		exit 1
	fi
	echo "--- $uname_arch $target ---"
	while IFS= read -r url; do
		[ -n "$url" ] || continue
		n_all=$(( n_all + 1 ))
		base=$(basename "${url%%\?*}")
		if _http_ok "$url"; then
			n_ok=$(( n_ok + 1 ))
			files+=("$base")
		else
			_skip "$uname_arch $base is not published"
		fi
	done < <(_artifact_urls "$CLI" "$uname_arch" "$target")
	if [ "$n_all" -eq 0 ]; then
		_skip "$uname_arch $target is not an ABA download"
		return 0
	fi
	if [ "$n_ok" -eq 0 ]; then
		return 0
	fi
	# Every named URL is published: use the phony target so the output filename
	# stays the one the recipe writes (virtctl-$(ARCH), not the versioned URL).
	# A partial set (one oc flavor missing) is fetched by filename.
	if [ "$n_ok" -eq "$n_all" ]; then
		files=("$target")
	fi
	if make -C "$CLI" --no-print-directory PLAIN_OUTPUT=1 arch="$uname_arch" "${files[@]}"; then
		_check_downloaded "$CLI" "$uname_arch"
		return 0
	fi
	_fail "$uname_arch $target download+verify"
	_reset_dir "$CLI"
	return 1
}

echo "=== CLI and mirror binaries, all architectures ==="
echo "Host arch: $HOST"
echo "Work dir: $WORK"

# Confirm Make is writing into the temp tree, not the repo.
_cwd=$(make -C "$CLI" --no-print-directory --eval='show-cwd: ; @pwd' show-cwd arch=s390x)
if [ "$_cwd" = "$CLI" ]; then
	_pass "cli Make runs in the temp tree"
else
	_fail "cli Make cwd is $_cwd"
	echo "Results: $pass passed, $fail failed, $skip skipped"
	exit 1
fi

for _arch in x86_64 aarch64 s390x ppc64le; do
	echo ""
	echo "======== cli $_arch ========"
	for _target in \
		download-butane \
		download-govc \
		download-kn \
		download-helm \
		download-roxctl \
		download-virtctl \
		download-argocd \
		download-tkn \
		download-opm \
		download-oc \
		download-oc-mirror \
		download-openshift-install
	do
		_cli_one "$_arch" "$_target"
	done

	echo ""
	echo "======== mirror $_arch ========"
	if [ ! -d "$MIRROR" ]; then
		_fail "mirror work tree disappeared"
		echo ""
		echo "Results: $pass passed, $fail failed, $skip skipped"
		exit 1
	fi
	_mr=$(make -C "$MIRROR" --no-print-directory --eval='show-mr: ; @echo $(MR_TARBALL)' show-mr arch="$_arch")
	# aarch64 leaves MR_TARBALL out of the quay download. There is no arm64 file.
	if ! make -C "$MIRROR" -Bn --no-print-directory PLAIN_OUTPUT=1 arch="$_arch" download-quay-tarball 2>/dev/null \
		| grep -q "$_mr"; then
		_skip "$_arch mirror-registry is not an ABA download"
		continue
	fi
	_mr_url=$(make -C "$MIRROR" -Bn --no-print-directory PLAIN_OUTPUT=1 arch="$_arch" "$_mr" 2>/dev/null \
		| grep -oE 'https://[^[:space:]\\]+' | grep -F "/${_mr}" | head -1)
	if [ -z "$_mr_url" ] || ! _http_ok "$_mr_url"; then
		_skip "$_arch $_mr is not published"
		continue
	fi
	if _make_download "$MIRROR" "$_arch" "$_mr"; then
		_check_downloaded "$MIRROR" "$_arch"
	fi
done

echo ""
echo "Results: $pass passed, $fail failed, $skip skipped"
if [ "$fail" -gt 0 ]; then
	exit 1
fi
echo "All architecture binaries passed"
