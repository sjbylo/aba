#!/bin/bash
# Record the registry blobs inside each operator's oc-mirror archive.
#
# One row per operator and blob digest. A digest stored twice in the same
# archive is recorded once. Operators whose latest sizes.txt status is not
# "ok" are skipped, so a failed mirror cannot contribute a partial tar.
#
# The measure script writes the result next to the archives. Copy that file
# to catalogs/sizes/<catalog>-v<version>-<arch>.blobs for the estimator.
#
# Usage:
#   tools/index-operator-blobs.sh --archives DIR --sizes FILE --out FILE

set -u

usage() {
	echo "Usage: index-operator-blobs.sh --archives DIR --sizes FILE --out FILE" >&2
}

archives=
sizes=
out=
while [ $# -gt 0 ]; do
	case "$1" in
		--archives) archives=$2; shift 2 ;;
		--sizes) sizes=$2; shift 2 ;;
		--out) out=$2; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
	esac
done

if [ -z "$archives" ] || [ -z "$sizes" ] || [ -z "$out" ]; then
	usage
	exit 1
fi
if [ ! -d "$archives" ]; then
	echo "Archive directory not found: $archives" >&2
	exit 1
fi
if [ ! -f "$sizes" ]; then
	echo "sizes.txt not found: $sizes" >&2
	exit 1
fi

export IDX_ARCHIVES="$archives"
export IDX_SIZES="$sizes"
export IDX_OUT="$out"

python3 - << 'PY'
import os
import re
import sys

archives = os.environ["IDX_ARCHIVES"]
sizes_path = os.environ["IDX_SIZES"]
out_path = os.environ["IDX_OUT"]

reg_re = re.compile(r"docker/registry/v2/blobs/sha256/[0-9a-f]{2}/([0-9a-f]{64})/data$")
cat_re = re.compile(r"/blobs/sha256/([0-9a-f]{64})$")

def parse_size(field):
	if field[:1] in (b"\x80", b"\xff"):
		val = int.from_bytes(field[1:], "big")
		if field[:1] == b"\xff":
			val -= 1 << 88
		return val
	text = field.split(b"\0", 1)[0].strip() or b"0"
	return int(text, 8)

def pax_path(data):
	i = 0
	found = None
	while i < len(data):
		sp = data.find(b" ", i)
		if sp < 0:
			break
		try:
			length = int(data[i:sp])
		except ValueError:
			break
		if length <= 0:
			break
		rec = data[sp + 1:i + length]
		if rec.startswith(b"path="):
			found = rec[5:].rstrip(b"\n").decode("utf-8", "replace")
		i += length
	return found

def ustar_name(hdr):
	name = hdr[0:100].split(b"\0", 1)[0].decode("utf-8", "replace")
	pre = hdr[345:500].split(b"\0", 1)[0].decode("utf-8", "replace")
	if pre:
		return pre + "/" + name
	return name

def add_blob(blobs, digest, size, from_registry):
	old = blobs.get(digest)
	if old is None:
		blobs[digest] = (size, from_registry)
		return
	old_size, old_reg = old
	if from_registry and not old_reg:
		blobs[digest] = (size, True)
	elif from_registry == old_reg and size > old_size:
		blobs[digest] = (size, from_registry)

def index_tar(path):
	blobs = {}
	fh = open(path, "rb")
	pending = None
	while True:
		hdr = fh.read(512)
		if len(hdr) < 512 or set(hdr) == {0}:
			break
		size = parse_size(hdr[124:136])
		typ = chr(hdr[156])
		pad = (size + 511) // 512 * 512
		if typ in ("L", "K", "x", "g"):
			body = fh.read(pad)[:size]
			if typ == "L":
				pending = body.split(b"\0", 1)[0].decode("utf-8", "replace")
			elif typ == "x":
				parsed = pax_path(body)
				if parsed:
					pending = parsed
			continue
		if pending is not None:
			name = pending
			pending = None
		else:
			name = ustar_name(hdr)
		match = reg_re.search(name)
		if match:
			add_blob(blobs, match.group(1), size, True)
		elif typ == "0":
			match = cat_re.search(name)
			if match:
				add_blob(blobs, match.group(1), size, False)
		if pad:
			fh.seek(pad, 1)
	fh.close()
	return blobs

latest = {}
for raw in open(sizes_path, encoding="utf-8"):
	parts = raw.rstrip("\n").split("\t")
	if len(parts) >= 3 and parts[0]:
		latest[parts[0]] = parts[2]

ops = []
for name in sorted(os.listdir(archives)):
	dest = os.path.join(archives, name)
	if not os.path.isdir(dest):
		continue
	if latest.get(name) != "ok":
		print(f"skip {name}: latest status is {latest.get(name, 'absent')}", file=sys.stderr)
		continue
	tars = sorted(
		os.path.join(dest, fn)
		for fn in os.listdir(dest)
		if fn.startswith("mirror_") and fn.endswith(".tar")
	)
	if not tars:
		print(f"skip {name}: no archive", file=sys.stderr)
		continue
	ops.append((name, tars))

tmp = out_path + ".tmp"
nblobs = 0
nbytes = 0
with open(tmp, "w", encoding="utf-8") as out:
	out.write("# operator\tdigest\tbytes\n")
	for name, tars in ops:
		merged = {}
		for tar in tars:
			for digest, (size, from_registry) in index_tar(tar).items():
				add_blob(merged, digest, size, from_registry)
		op_bytes = 0
		for digest in sorted(merged):
			size = merged[digest][0]
			out.write(f"{name}\t{digest}\t{size}\n")
			nblobs += 1
			op_bytes += size
		nbytes += op_bytes
		print(
			f"indexed {name} blobs={len(merged)} bytes={op_bytes}",
			file=sys.stderr,
		)

os.replace(tmp, out_path)
print(f"wrote {out_path} operators={len(ops)} rows={nblobs} bytes={nbytes}", file=sys.stderr)
PY
