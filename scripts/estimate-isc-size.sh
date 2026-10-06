#!/bin/bash
# Estimate the oc-mirror archive size of an ImageSetConfiguration.
#
# When catalogs/sizes/<catalog>-v<minor>-<arch>.blobs exists, add the
# platform once and each registry blob once. A blob shared by several
# operators is not added again. An operator with no blob row uses the
# median size of the measured operators' own blobs (catalog blobs, the
# ones present in every measured operator, are not included in that guess).
#
# Without a blob index, fall back to:
#   platform + one catalog per catalog index + sum(archive - catalog), then +5%.
# A missing operator then uses the median extra, or 1 GiB when the size
# file has no rows. Certified and community catalogs are not measured in
# full, so they use this fallback.
#
# catalogs/sizes/additional-images holds images that are not already inside
# the platform mirror (the release archive). Those are added when the ISC
# names them. The usual ubi and hello-openshift images are left out of that
# file because the platform figure already includes them.
#
# --shell prints sourceable keys. Otherwise one human line on stdout.

set -u

shell=
isc=
sizes_dir=
arch=amd64

usage() {
	echo "Usage: estimate-isc-size.sh --isc FILE [--sizes-dir DIR] [--arch amd64] [--shell]" >&2
}

while [ $# -gt 0 ]; do
	case "$1" in
		--isc) isc=$2; shift 2 ;;
		--sizes-dir) sizes_dir=$2; shift 2 ;;
		--arch) arch=$2; shift 2 ;;
		--shell) shell=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
	esac
done

if [ -z "$isc" ] || [ ! -f "$isc" ]; then
	echo "ImageSetConfiguration not found: ${isc:-}" >&2
	usage
	exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
if [ -z "$sizes_dir" ]; then
	sizes_dir="$ROOT/catalogs/sizes"
fi

export EST_ISC="$isc"
export EST_SIZES_DIR="$sizes_dir"
export EST_ARCH="$arch"
export EST_SHELL="$shell"

python3 - << 'PY'
import os

isc_path = os.environ["EST_ISC"]
sizes_dir = os.environ["EST_SIZES_DIR"]
arch = os.environ["EST_ARCH"]
shell = os.environ.get("EST_SHELL") == "1"

# 4.4 GiB catalog packed into every single-operator archive. Used only
# when there is no blob index. The blob index already contains the catalog
# layers once per operator, and the union counts them once.
# 22 GiB release-only mirror (platform images, including the usual extras).
CATALOG = 44 * 1024 ** 3 // 10
PLATFORM = 22 * 1024 ** 3
DEFAULT_EXCESS = 1024 ** 3
text = open(isc_path, encoding="utf-8").read().splitlines()

def strip_comment(line):
	if "#" in line:
		line = line.split("#", 1)[0]
	return line

has_platform = False
in_operators = False
in_additional = False
catalog = None
version = None
ops = []
seen = set()
additional = []

for raw in text:
	line = strip_comment(raw)
	stripped = line.strip()
	if stripped.startswith("platform:"):
		has_platform = True
		in_operators = False
		in_additional = False
		continue
	if stripped.startswith("additionalImages:"):
		in_operators = False
		in_additional = True
		continue
	if stripped.startswith("operators:"):
		in_operators = True
		in_additional = False
		continue
	if in_additional and stripped.startswith("- name:"):
		ref = stripped.split(":", 1)[1].strip().strip('"').strip("'")
		if ref and ref not in additional:
			additional.append(ref)
		continue
	if not in_operators:
		continue
	if "operator-index:v" in stripped and "catalog:" in stripped:
		# registry.redhat.io/redhat/redhat-operator-index:v4.22
		try:
			image = stripped.split("catalog:", 1)[1].strip()
			leaf = image.split("/")[-1]
			name, ver = leaf.split("-index:v", 1)
			catalog = name
			version = ver.split()[0]
		except ValueError:
			catalog = None
			version = None
		continue
	if stripped.startswith("channels:"):
		continue
	if stripped.startswith("- name:") and catalog and version:
		# Channel names are indented further than package names.
		indent = len(line) - len(line.lstrip(" "))
		if indent > 4:
			continue
		op = stripped.split()[-1].strip('"').strip("'")
		key = (catalog, version, op)
		if key not in seen:
			seen.add(key)
			ops.append(key)

def median(vals):
	if not vals:
		return DEFAULT_EXCESS
	vals = sorted(vals)
	mid = len(vals) // 2
	if len(vals) % 2:
		return vals[mid]
	return (vals[mid - 1] + vals[mid]) // 2

def load_additional():
	# Sizes of images that are not already inside the platform mirror.
	# Bytes are the unique blobs across every Linux architecture, because
	# oc-mirror stores each manifest-list member.
	path = os.path.join(sizes_dir, "additional-images")
	sizes = {}
	if not os.path.isfile(path):
		return sizes
	for raw in open(path, encoding="utf-8"):
		line = raw.split("#", 1)[0].strip()
		if not line:
			continue
		# The ref itself contains no spaces. The size is the last field.
		parts = line.split()
		if len(parts) < 2:
			continue
		try:
			sizes[parts[0]] = int(parts[-1])
		except ValueError:
			continue
	return sizes

def load_sizes(cat, ver):
	path = os.path.join(sizes_dir, f"{cat}-v{ver}-{arch}")
	sizes = {}
	if not os.path.isfile(path):
		return sizes
	for raw in open(path, encoding="utf-8"):
		line = raw.split("#", 1)[0].strip()
		if not line:
			continue
		parts = line.split()
		if len(parts) < 2:
			continue
		try:
			sizes[parts[0]] = int(parts[1])
		except ValueError:
			continue
	return sizes

def load_blobs(cat, ver):
	path = os.path.join(sizes_dir, f"{cat}-v{ver}-{arch}.blobs")
	if not os.path.isfile(path):
		return None
	per = {}
	for raw in open(path, encoding="utf-8"):
		line = raw.strip()
		if not line or line.startswith("#"):
			continue
		parts = line.split("\t") if "\t" in line else line.split()
		if len(parts) < 3:
			continue
		try:
			size = int(parts[2])
		except ValueError:
			continue
		per.setdefault(parts[0], {})[parts[1]] = size
	return per or None

def common_blobs(per):
	# Layers present in every measured operator are the catalog, not the operator.
	sets = [set(blobs) for blobs in per.values()]
	if not sets:
		return {}
	shared = set.intersection(*sets)
	sample = next(iter(per.values()))
	return {digest: sample[digest] for digest in shared}

def median_excess(sizes):
	vals = []
	for blob_size in sizes.values():
		extra = blob_size - CATALOG
		if extra < 0:
			extra = 0
		vals.append(extra)
	return median(vals)

def private_bytes(blobs, common):
	return sum(size for digest, size in blobs.items() if digest not in common)

cache = {}
union = {}
missing_bytes = 0
fallback_catalogs = 0
fallback_excess = 0
common_all = {}
used_blobs = False
known = 0
estimated = 0
estimated_names = []

by_cat = {}
for cat, ver, op in ops:
	by_cat.setdefault((cat, ver), []).append(op)

for (cat, ver), names in by_cat.items():
	key = (cat, ver)
	if key not in cache:
		cache[key] = load_blobs(cat, ver)
	per = cache[key]
	if per:
		used_blobs = True
		common = common_blobs(per)
		common_all.update(common)
		typical = median([private_bytes(blobs, common) for blobs in per.values()])
		if typical <= 0:
			typical = DEFAULT_EXCESS
		known_here = 0
		for op in names:
			if op in per:
				union.update(per[op])
				known += 1
				known_here += 1
			else:
				missing_bytes += typical
				estimated += 1
				estimated_names.append(op)
		# No measured operator in this ISC yet, so the union has no catalog layers.
		if known_here == 0:
			union.update(common)
		continue
	sizes = load_sizes(cat, ver)
	typical = median_excess(sizes)
	fallback_catalogs += 1
	for op in names:
		if op in sizes:
			extra = sizes[op] - CATALOG
			if extra < 0:
				extra = 0
			known += 1
		else:
			extra = typical
			estimated += 1
			estimated_names.append(op)
		fallback_excess += extra

platform = PLATFORM if has_platform else 0
additional_sizes = load_additional()
additional_bytes = 0
for ref in additional:
	if ref in additional_sizes:
		additional_bytes += additional_sizes[ref]
catalog_in_union = sum(size for digest, size in union.items() if digest in common_all)
catalog_bytes = catalog_in_union + CATALOG * fallback_catalogs
operator_bytes = sum(union.values()) - catalog_in_union + missing_bytes + fallback_excess
raw = platform + sum(union.values()) + missing_bytes + CATALOG * fallback_catalogs + fallback_excess + additional_bytes
fallback_part = CATALOG * fallback_catalogs + fallback_excess
if not used_blobs:
	padded = raw * 105 // 100
	pad = 5
elif fallback_part:
	padded = raw + fallback_part * 5 // 100
	pad = 5
else:
	padded = raw
	pad = 0

def gib(n):
	return f"{n / 1024 ** 3:.1f}"

if shell:
	print(f"estimate_bytes={padded}")
	print(f"estimate_bytes_raw={raw}")
	print(f"platform_bytes={platform}")
	print(f"catalog_bytes={catalog_bytes}")
	print(f"excess_bytes={operator_bytes}")
	print(f"additional_bytes={additional_bytes}")
	print(f"known={known}")
	print(f"estimated={estimated}")
	print("estimated_operators=" + ",".join(estimated_names))
	print(f"pad_percent={pad}")
	# Same download, placed on the disks each command writes.
	# save: archive + cache. sync: registry only. load: registry + cache.
	print(f"save_archive_bytes={padded}")
	print(f"save_cache_bytes={padded}")
	print(f"sync_archive_bytes=0")
	print(f"sync_cache_bytes=0")
	print(f"sync_registry_bytes={padded}")
	print(f"load_archive_bytes=0")
	print(f"load_cache_bytes={padded}")
	print(f"load_registry_bytes={padded}")
else:
	msg = f"Estimate: ~{gib(padded)} GiB"
	bits = []
	if platform:
		bits.append(f"{gib(platform)} GiB platform")
	if catalog_bytes:
		bits.append(f"{gib(catalog_bytes)} GiB catalog")
	if ops:
		bits.append(f"{gib(operator_bytes)} GiB operators")
	if additional_bytes:
		bits.append(f"{gib(additional_bytes)} GiB images")
	detail = ", ".join(bits)
	tail = []
	if pad:
		tail.append(f"+{pad}%")
	if estimated:
		tail.append(f"{estimated} operators estimated")
	suffix = "; " + ", ".join(tail) if tail else ""
	print(f"{msg} ({detail}{suffix})")
PY
