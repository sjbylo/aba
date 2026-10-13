#!/bin/bash
# Measure additionalImages the way oc-mirror stores them.
#
# A manifest list is expanded to every Linux architecture. A layer that
# those architectures share is counted once. Print one line per image:
# "<ref> <bytes>".
#
# The platform mirror already includes ubi, ubi-micro, support-tools, and
# hello-openshift. Do not add those here. catalogs/sizes/additional-images
# is only the images on top of that platform figure.
#
# Examples:
#   tools/measure-additional-image-sizes.sh
#   tools/measure-additional-image-sizes.sh quay.io/containerdisks/fedora:latest
#   tools/measure-additional-image-sizes.sh --update

set -u

update=
size_file=
images=()

usage() {
	cat <<'EOF'
Usage: measure-additional-image-sizes.sh [--update] [--file PATH] [IMAGE ...]

  Measure each image with skopeo. With no images, measure every ref in
  the size file.

  --file PATH   Size file to read (default: catalogs/sizes/additional-images)
  --update      Write the measured sizes back into that file
  -h, --help    Show this help
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--update) update=1; shift ;;
		--file) size_file=$2; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		--) shift; break ;;
		-*) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
		*) images+=("$1"); shift ;;
	esac
done
while [ $# -gt 0 ]; do
	images+=("$1")
	shift
done

if ! command -v skopeo >/dev/null 2>&1; then
	echo "skopeo is not on PATH" >&2
	exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
if [ -z "$size_file" ]; then
	size_file="$ROOT/catalogs/sizes/additional-images"
fi

if [ ${#images[@]} -eq 0 ]; then
	if [ ! -f "$size_file" ]; then
		echo "No images given and no size file: $size_file" >&2
		exit 1
	fi
	while read -r ref _; do
		[ -n "$ref" ] || continue
		case "$ref" in
			\#*) continue ;;
		esac
		images+=("$ref")
	done < "$size_file"
fi

if [ ${#images[@]} -eq 0 ]; then
	echo "No images to measure" >&2
	exit 1
fi

# The image list is an environment variable. A heredoc would swallow a pipe.
IMG_LIST=$(printf '%s\n' "${images[@]}")
export IMG_LIST
export SIZE_FILE="$size_file"
export SIZE_UPDATE="${update:-}"

python3 - << 'PY'
import json
import os
import subprocess
import sys

images = [line for line in os.environ["IMG_LIST"].splitlines() if line]
size_file = os.environ["SIZE_FILE"]
do_update = os.environ.get("SIZE_UPDATE") == "1"

def manifest(ref):
    raw = subprocess.check_output(
        ["skopeo", "inspect", "--raw", "docker://" + ref],
        stderr=subprocess.DEVNULL,
    )
    return json.loads(raw)

def unique_bytes(ref):
    man = manifest(ref)
    blobs = {}
    entries = man.get("manifests")
    if not entries:
        for layer in man.get("layers") or []:
            blobs[layer["digest"]] = layer.get("size", 0)
        return sum(blobs.values())
    # Tag form is name:tag. Digest form is name@sha256:hex.
    # Cutting on the first colon would keep "name@sha256" and then
    # request name@sha256@sha256:<child>.
    name = ref.split("@", 1)[0].split(":", 1)[0]
    for item in entries:
        plat = item.get("platform") or {}
        if plat.get("os") not in (None, "linux"):
            continue
        if plat.get("architecture") in ("unknown", "wasm"):
            continue
        child = manifest(name + "@" + item["digest"])
        for layer in child.get("layers") or []:
            blobs[layer["digest"]] = layer.get("size", 0)
    return sum(blobs.values())

measured = []
failed = 0
for ref in images:
    try:
        size = unique_bytes(ref)
    except (subprocess.CalledProcessError, json.JSONDecodeError, KeyError, ValueError) as exc:
        print(f"fail {ref}: {exc}", file=sys.stderr)
        failed += 1
        continue
    measured.append((ref, size))
    print(f"{ref} {size}")

if do_update and measured:
    old = []
    if os.path.isfile(size_file):
        old = open(size_file, encoding="utf-8").read().splitlines()
    seen = set()
    out = []
    by_ref = {ref: size for ref, size in measured}
    for line in old:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            out.append(line)
            continue
        ref = stripped.split()[0]
        if ref in by_ref:
            out.append(f"{ref} {by_ref[ref]}")
            seen.add(ref)
        else:
            out.append(line)
    for ref, size in measured:
        if ref not in seen:
            out.append(f"{ref} {size}")
    text = "\n".join(out)
    if text and not text.endswith("\n"):
        text += "\n"
    open(size_file, "w", encoding="utf-8").write(text)
    print(f"updated {size_file}", file=sys.stderr)

sys.exit(1 if failed and not measured else 0)
PY
