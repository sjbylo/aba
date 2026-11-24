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
	&& grep -q '^    registry\.access\.redhat\.com:$' templates/registries.d/registry.access.redhat.com.yaml; then
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

if grep -q '^    registry\.access\.redhat\.com:$' "$tmp/registry.access.redhat.com.yaml"; then
	_ok "missing registry.access.redhat.com.yaml is created"
else
	_fail "registry.access.redhat.com.yaml was not created"
fi

before=$(cksum "$tmp/aba-sigstore.yaml")
SIGSTORE_DEST="$tmp" "$ROOT/scripts/ensure-sigstore-registries.sh"
after=$(cksum "$tmp/aba-sigstore.yaml")
if [ "$before" = "$after" ]; then
	_ok "a second run does not rewrite aba-sigstore.yaml"
else
	_fail "a second run changed aba-sigstore.yaml"
fi

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
