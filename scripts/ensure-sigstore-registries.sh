#!/bin/bash
# Put each sigstore namespace in one registries.d file.
#
# oc-mirror copies every file in registries.d into one directory and
# rejects the same docker namespace defined twice. The OS and oc-mirror
# 2.0 already use registry.redhat.io.yaml and
# registry.access.redhat.com.yaml. ABA writes those same names, and
# keeps only the quay.io release rule in aba-sigstore.yaml.
#
# An older aba-sigstore.yaml that still contains the Red Hat namespaces
# is rewritten in place. Other keys in that file are left as they are.
# A sibling file that already exists is not replaced, except a
# registry.access.redhat.com.yaml that is still the lookaside-only
# copy. That copy hides the OS sigstore-attachment flag RHEL 10 needs,
# so it is rewritten from the template. A file that already sets the
# flag, or that names another registry, stays.

set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
dest="${SIGSTORE_DEST:-$HOME/.config/containers/registries.d}"
mkdir -p "$dest"

# Each file in templates/registries.d is installed under the same name.
for src in "$root/templates/registries.d/"*.yaml; do
	name=$(basename "$src")
	[ -f "$dest/$name" ] && continue
	cp "$src" "$dest/$name"
done

# The lookaside-only access.redhat.com file is the template from before RHEL 10.
# Rewrite that one so the attachment flag is present. Leave any other edit.
access="$dest/registry.access.redhat.com.yaml"
access_src="$root/templates/registries.d/registry.access.redhat.com.yaml"
if [ -f "$access" ] && [ -f "$access_src" ] \
	&& ! grep -q 'use-sigstore-attachments:' "$access" \
	&& grep -q 'lookaside: https://access.redhat.com/webassets/docker/content/sigstore' "$access"
then
	other=$(grep -E '^    [^[:space:]]+:$' "$access" | grep -v '^    registry\.access\.redhat\.com:$' || true)
	if [ -z "$other" ]; then
		cp "$access_src" "$access"
	fi
fi

aba="$dest/aba-sigstore.yaml"
[ -f "$aba" ] || exit 0

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
awk '
	/^    registry\.redhat\.io:$/ || /^    registry\.access\.redhat\.com:$/ { skip=1; next }
	skip && (/^    [^[:space:]]/ || /^[^[:space:]]/) { skip=0 }
	skip { next }
	{ print }
' "$aba" > "$tmp"
if cmp -s "$aba" "$tmp"; then
	exit 0
fi
mv "$tmp" "$aba"
trap - EXIT
