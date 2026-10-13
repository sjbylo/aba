#!/bin/bash
# Digest refs are name@sha256:hex. The measurer must request the child
# manifest as name@sha256:<child>, and count a shared layer once.

set -u
cd "$(dirname "$0")/../.."

fail=0
check() {
	local name=$1
	local got=$2
	local want=$3
	if [ "$got" = "$want" ]; then
		echo "  PASS: $name"
	else
		echo "  FAIL: $name (got $got want $want)"
		fail=$((fail + 1))
	fi
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/skopeo" << 'EOF'
#!/bin/bash
ref=${3#docker://}
printf '%s\n' "$ref" >> "$SKOPEO_LOG"
case "$ref" in
	*@sha256@sha256:*)
		echo "doubled digest: $ref" >&2
		exit 1
		;;
	quay.io/ex/ray@sha256:parent|quay.io/ex/disk:latest)
		cat << 'JSON'
{"manifests":[
  {"digest":"sha256:amd","platform":{"os":"linux","architecture":"amd64"}},
  {"digest":"sha256:arm","platform":{"os":"linux","architecture":"arm64"}},
  {"digest":"sha256:win","platform":{"os":"windows","architecture":"amd64"}},
  {"digest":"sha256:unk","platform":{"os":"linux","architecture":"unknown"}}
]}
JSON
		;;
	quay.io/ex/ray@sha256:amd|quay.io/ex/disk@sha256:amd)
		cat << 'JSON'
{"layers":[{"digest":"sha256:shared","size":100},{"digest":"sha256:amdonly","size":50}]}
JSON
		;;
	quay.io/ex/ray@sha256:arm|quay.io/ex/disk@sha256:arm)
		cat << 'JSON'
{"layers":[{"digest":"sha256:shared","size":100},{"digest":"sha256:armonly","size":70}]}
JSON
		;;
	*)
		echo "unexpected ref: $ref" >&2
		exit 1
		;;
esac
EOF
chmod +x "$tmp/skopeo"

export SKOPEO_LOG="$tmp/log"
export PATH="$tmp:$PATH"

echo "=== digest ref and tag ref ==="
out=$(tools/measure-additional-image-sizes.sh --file "$tmp/sizes" --update \
	quay.io/ex/ray@sha256:parent \
	quay.io/ex/disk:latest)
check "digest image counts the shared layer once" \
	"$(printf '%s\n' "$out" | awk '/ray@sha256:parent/ { print $2 }')" "220"
check "tag image still resolves the repo name" \
	"$(printf '%s\n' "$out" | awk '/disk:latest/ { print $2 }')" "220"
check "child of a digest ref is name@sha256:child" \
	"$(grep -c '^quay.io/ex/ray@sha256:amd$' "$SKOPEO_LOG")" "1"
check "child of a tag ref is name@sha256:child" \
	"$(grep -c '^quay.io/ex/disk@sha256:amd$' "$SKOPEO_LOG")" "1"
check "no doubled digest was requested" \
	"$(grep -c '@sha256@sha256:' "$SKOPEO_LOG" || true)" "0"
check "size file keeps the digest ref" \
	"$(awk '/ray@sha256:parent/ { print $2 }' "$tmp/sizes")" "220"

if [ "$fail" -eq 0 ]; then
	echo "ALL PASSED"
	exit 0
fi
echo "$fail FAILED"
exit 1
