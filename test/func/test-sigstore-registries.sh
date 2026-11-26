#!/bin/bash
# Red Hat sigstore namespaces stay in their own files, including when an
# older aba-sigstore.yaml still defines them.

set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)

pass=0
fail=0
_ok() { pass=$((pass + 1)); printf '  PASS  %s\n' "$*"; }
_fail() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$*"; }

if ! grep -q '^    registry\.redhat\.io:$' templates/registries.d/aba-sigstore.yaml \
	&& ! grep -q '^    registry\.access\.redhat\.com:$' templates/registries.d/aba-sigstore.yaml \
	&& grep -q '^    quay.io/openshift-release-dev:$' templates/registries.d/aba-sigstore.yaml; then
	_ok "aba-sigstore template keeps only the quay.io release rule"
else
	_fail "aba-sigstore template still defines a Red Hat namespace"
fi

if grep -q '^    registry\.redhat\.io:$' templates/registries.d/registry.redhat.io.yaml \
	&& grep -q '^    registry\.access\.redhat\.com:$' templates/registries.d/registry.access.redhat.com.yaml \
	&& grep -q '^        use-sigstore-attachments: true$' templates/registries.d/registry.access.redhat.com.yaml \
	&& grep -q 'lookaside: https://access.redhat.com/webassets/docker/content/sigstore' templates/registries.d/registry.access.redhat.com.yaml; then
	_ok "Red Hat namespaces have their own registries.d files"
else
	_fail "Red Hat registries.d templates are missing a namespace"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Older combined file, plus a key the user added, plus a sibling they edited.
cat > "$tmp/aba-sigstore.yaml" <<'EOF'
default-docker:
    use-sigstore-attachments: false
docker:
    quay.io/openshift-release-dev:
        use-sigstore-attachments: true
    example.com:
        use-sigstore-attachments: true
    registry.redhat.io:
        use-sigstore-attachments: true
        lookaside: https://registry.redhat.io/containers/sigstore
    registry.access.redhat.com:
        lookaside: https://access.redhat.com/webassets/docker/content/sigstore
EOF
echo 'user-edited' > "$tmp/registry.redhat.io.yaml"

SIGSTORE_DEST="$tmp" "$ROOT/scripts/ensure-sigstore-registries.sh"

if grep -q '^    quay.io/openshift-release-dev:$' "$tmp/aba-sigstore.yaml" \
	&& grep -q '^    example.com:$' "$tmp/aba-sigstore.yaml" \
	&& ! grep -q '^    registry\.redhat\.io:$' "$tmp/aba-sigstore.yaml" \
	&& ! grep -q '^    registry\.access\.redhat\.com:$' "$tmp/aba-sigstore.yaml"; then
	_ok "existing aba-sigstore.yaml loses only the Red Hat namespaces"
else
	_fail "existing aba-sigstore.yaml was not split cleanly"
fi

if [ "$(cat "$tmp/registry.redhat.io.yaml")" = "user-edited" ]; then
	_ok "an existing registry.redhat.io.yaml is left alone"
else
	_fail "registry.redhat.io.yaml was replaced"
fi

if grep -q '^    registry\.access\.redhat\.com:$' "$tmp/registry.access.redhat.com.yaml" \
	&& grep -q '^        use-sigstore-attachments: true$' "$tmp/registry.access.redhat.com.yaml"; then
	_ok "missing registry.access.redhat.com.yaml is created with sigstore attachments"
else
	_fail "registry.access.redhat.com.yaml was not created with sigstore attachments"
fi

before=$(cksum "$tmp/aba-sigstore.yaml")
SIGSTORE_DEST="$tmp" "$ROOT/scripts/ensure-sigstore-registries.sh"
after=$(cksum "$tmp/aba-sigstore.yaml")
if [ "$before" = "$after" ]; then
	_ok "a second run does not rewrite aba-sigstore.yaml"
else
	_fail "a second run changed aba-sigstore.yaml"
fi

# A host that already has the lookaside-only file must gain the flag.
old=$(mktemp -d)
cat > "$old/registry.access.redhat.com.yaml" <<'EOF'
# Same filename as /etc/containers/registries.d and as the file
# oc-mirror 2.0 ships. One name, one definition.
docker:
    registry.access.redhat.com:
        lookaside: https://access.redhat.com/webassets/docker/content/sigstore
EOF
SIGSTORE_DEST="$old" "$ROOT/scripts/ensure-sigstore-registries.sh"
if grep -q '^        use-sigstore-attachments: true$' "$old/registry.access.redhat.com.yaml" \
	&& grep -q 'lookaside: https://access.redhat.com/webassets/docker/content/sigstore' "$old/registry.access.redhat.com.yaml"; then
	_ok "lookaside-only registry.access.redhat.com.yaml gains sigstore attachments"
else
	_fail "lookaside-only registry.access.redhat.com.yaml was not updated"
fi
rm -rf "$old"

# Another registry key means the file was edited. Leave it.
edited=$(mktemp -d)
cat > "$edited/registry.access.redhat.com.yaml" <<'EOF'
docker:
    registry.access.redhat.com:
        lookaside: https://access.redhat.com/webassets/docker/content/sigstore
    example.com:
        lookaside: https://example.com/sigstore
EOF
before=$(cksum "$edited/registry.access.redhat.com.yaml")
SIGSTORE_DEST="$edited" "$ROOT/scripts/ensure-sigstore-registries.sh"
after=$(cksum "$edited/registry.access.redhat.com.yaml")
if [ "$before" = "$after" ] && grep -q '^    example.com:$' "$edited/registry.access.redhat.com.yaml"; then
	_ok "an edited registry.access.redhat.com.yaml is left alone"
else
	_fail "an edited registry.access.redhat.com.yaml was replaced"
fi
rm -rf "$edited"

# An explicit false is a choice. Do not flip it to true.
chosen=$(mktemp -d)
cat > "$chosen/registry.access.redhat.com.yaml" <<'EOF'
docker:
    registry.access.redhat.com:
        use-sigstore-attachments: false
        lookaside: https://access.redhat.com/webassets/docker/content/sigstore
EOF
before=$(cksum "$chosen/registry.access.redhat.com.yaml")
SIGSTORE_DEST="$chosen" "$ROOT/scripts/ensure-sigstore-registries.sh"
after=$(cksum "$chosen/registry.access.redhat.com.yaml")
if [ "$before" = "$after" ]; then
	_ok "use-sigstore-attachments false is left alone"
else
	_fail "use-sigstore-attachments false was rewritten"
fi
rm -rf "$chosen"

if grep -q 'ensure_sigstore_mirror_config "$reg_host:$reg_port"' "$ROOT/scripts/reg-common.sh"; then
	_ok "registry install enables sigstore writes for the mirror host"
else
	_fail "reg_post_install does not enable sigstore writes"
fi

source "$ROOT/scripts/include_all.sh"
trap - ERR
mirror_home=$(mktemp -d)
mkdir -p "$mirror_home/.config/containers/registries.d"
printf 'default-docker:\n    use-sigstore-attachments: false\n' \
	> "$mirror_home/.config/containers/registries.d/aba-sigstore.yaml"
(
	HOME="$mirror_home"
	ensure_sigstore_mirror_config "dis3.example.com:8443"
)
mirror_file="$mirror_home/.config/containers/registries.d/aba-sigstore-mirror-dis3.example.com-8443.yaml"
if [ "$(cat "$mirror_file" 2>/dev/null || true)" = "$(printf 'docker:\n    dis3.example.com:8443:\n        use-sigstore-attachments: true\n')" ]; then
	_ok "mirror host:port gets use-sigstore-attachments true"
else
	_fail "mirror sigstore file was $(cat "$mirror_file" 2>/dev/null || echo missing)"
fi
rm -rf "$mirror_home"

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
