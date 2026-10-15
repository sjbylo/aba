# Developer Guide

Procedures that are run manually during ABA development and release
preparation.  For the full architecture, read `01-SPEC.md`.  For design
decisions, see `adr/`.

---

## 1. Refresh Catalog Indexes (before every release)

Catalog indexes ship in `catalogs/` so the TUI can browse operators
instantly on a fresh clone.  They must be refreshed before each release
to pick up new operators and channel changes.

**Where:** any connected host with `podman` and container auth for
`registry.redhat.io` (typically bastion).

```bash
tools/refresh-catalog-indexes.sh -y          # download + verify
```

The script:
1. Detects the latest 6 GA minor versions plus any pre-release catalog.
2. Compares the content-layer digest of each remote catalog image against
   the stored digest — only downloads catalogs whose operators actually
   changed (base-image-only rebuilds are skipped).
3. Extracts operator package names, display names, and default channels
   into `catalogs/{catalog}-index-v{version}` files.
4. Validates every downloaded index (minimum operator count, format,
   display names, expected count match).
5. Drift-checks against the previously shipped version (>5% change in
   both lines and bytes aborts unless `--force`).

After it finishes, review the diff and commit:

```bash
git diff --stat catalogs/
git add catalogs/ && git commit -m "Update shipped catalog indexes"
```

Or let the script do it:

```bash
tools/refresh-catalog-indexes.sh -y --commit
```

### Catalog index image (optional)

A read-only OCI image containing all indexes is published for
air-gapped bootstrapping:

```bash
tools/catalog-index-image.sh build           # build from catalogs/
tools/catalog-index-image.sh push            # push to quay.io
tools/catalog-index-image.sh list            # inspect the image
```

---

## 2. Generate Operator Sizing Data (periodic, not every release)

The sizing data in `catalogs/sizes/` lets `estimate-isc-size.sh`
predict how much disk space a mirror will need.  Generating it requires
mirroring every operator individually with `oc-mirror`, which takes
many hours and ~500 GB of temporary disk space.

### Prerequisites

**Where:** a connected host with plenty of disk — at least 500 GB free
(the "bundle host").  Needs:
- `oc-mirror` on `PATH`
- `skopeo` on `PATH`
- A pull secret at `~/.docker/config.json`
- A catalog index in `catalogs/` for the target version (refresh first
  — see section 1)

### 2a. Generate sizing data for a new OCP version

When a new OCP minor version is released (e.g. 4.23, 5.0), generate
sizing data for all three catalogs.  The `--version` flag selects the
catalog tag; the script reads operator names from the corresponding
catalog index in `catalogs/`.

```bash
VER=4.23   # ← set to the new version

# 1. Red Hat operators (largest — has all operator-set-* entries)
tools/measure-operator-mirror-sizes.sh --version $VER

# 2. Certified operators (only the sets that reference this catalog)
tools/measure-operator-mirror-sizes.sh --version $VER --catalog certified-operator

# 3. Community operators (only the sets that reference this catalog)
tools/measure-operator-mirror-sizes.sh --version $VER --catalog community-operator
```

Each command mirrors every operator from the shipped
`templates/operator-set-*` files that exists in the target catalog.
The archives land in `~/aba-operator-mirror-sizes/{catalog}-v{VER}/`.

Key options:
- `--parallel N` — concurrent mirrors (default 4; needs disk + network)
- `--limit N` — stop after N operators (useful for incremental runs)
- `--dry-run` — print the operator list and exit
- `--out DIR` — output directory (default `~/aba-operator-mirror-sizes`)

The script **resumes automatically**: operators whose latest
`sizes.txt` status is `ok` and whose archive is still on disk are
skipped.  If a run is interrupted, just re-run the same command.

### 2b. Refresh / re-generate existing sizing data

To refresh data for a version that already has sizing data (e.g. 4.22
operators changed significantly):

```bash
VER=4.22

# Delete old archives to force re-measurement (or just the changed ones)
ssh bundle "rm -rf ~/aba-operator-mirror-sizes/redhat-operator-v${VER}"

# Re-run (same commands as 2a)
tools/measure-operator-mirror-sizes.sh --version $VER
tools/measure-operator-mirror-sizes.sh --version $VER --catalog certified-operator
tools/measure-operator-mirror-sizes.sh --version $VER --catalog community-operator
```

To re-measure only specific operators without deleting everything:

```bash
# Delete just the operators you want to re-measure
ssh bundle "rm -rf ~/aba-operator-mirror-sizes/redhat-operator-v${VER}/odf-operator"

# Re-run — only missing/failed operators are measured
tools/measure-operator-mirror-sizes.sh --version $VER
```

To rebuild just the blob index from existing archives (no new mirrors):

```bash
tools/measure-operator-mirror-sizes.sh --version $VER --index-blobs
```

### 2c. Output structure

```
~/aba-operator-mirror-sizes/
  redhat-operator-v4.23/
    blobs.tsv              ← blob-level index (primary, built at end)
    sizes.txt              ← per-operator status + total archive bytes
    3scale-operator/
      mirror_000001.tar    ← oc-mirror archive (kept for blob indexing)
      imageset-config.yaml
      oc-mirror.log
    ...
  certified-operator-v4.23/
    blobs.tsv
    ...
  community-operator-v4.23/
    blobs.tsv
    ...
```

After all operators finish, the script automatically runs
`tools/index-operator-blobs.sh` to build `blobs.tsv` from the
archives.

### 2d. Copy sizing data into the repo

The naming convention is `{catalog}-v{version}-{arch}.blobs`.

```bash
VER=4.23   # ← must match the version you measured

# Blob-level indexes (primary — lets the estimator deduplicate shared layers)
scp bundle:~/aba-operator-mirror-sizes/redhat-operator-v${VER}/blobs.tsv \
    catalogs/sizes/redhat-operator-v${VER}-amd64.blobs

scp bundle:~/aba-operator-mirror-sizes/certified-operator-v${VER}/blobs.tsv \
    catalogs/sizes/certified-operator-v${VER}-amd64.blobs

scp bundle:~/aba-operator-mirror-sizes/community-operator-v${VER}/blobs.tsv \
    catalogs/sizes/community-operator-v${VER}-amd64.blobs
```

There is also a fallback per-operator summary file (e.g.
`redhat-operator-v4.23-amd64`, no `.blobs` suffix) used when the
`.blobs` file is absent.  That file is derived from `sizes.txt`.
Generate it if needed:

```bash
# Extract ok-status operator sizes from sizes.txt
ssh bundle "awk -F'\t' '\$3==\"ok\" {print \$1, \$2}' \
    ~/aba-operator-mirror-sizes/redhat-operator-v${VER}/sizes.txt" \
    > catalogs/sizes/redhat-operator-v${VER}-amd64
```

### 2e. Measure additional image sizes

Additional images (virtctl disk images, etc.) that are not part of the
operator catalogs or the platform release.  These are version-agnostic.

```bash
# Re-measure all images listed in the file
tools/measure-additional-image-sizes.sh --update

# Measure specific new images
tools/measure-additional-image-sizes.sh quay.io/containerdisks/fedora:latest
```

This updates `catalogs/sizes/additional-images` in-place.

### 2f. Commit

```bash
git add catalogs/sizes/
git commit -m "Add operator sizing data for v${VER}"
```

### 2g. Clean up the bundle host (optional)

Once the data is committed to the repo and verified:

```bash
ssh bundle "rm -rf ~/aba-operator-mirror-sizes/{redhat,certified,community}-operator-v${VER}"
```

Keep the archives around until you've confirmed the repo data matches
(compare `md5sum` of `blobs.tsv` on bundle vs the `.blobs` file in the
repo).

### When to regenerate

- **New OCP minor version** — operators may add/remove layers.
- **Major operator changes** — e.g. new large operators added to
  `templates/operator-set-*` files.
- **Not needed every release** — the estimates are approximate; small
  upstream changes don't materially affect the predictions.

---

## 3. Release Checklist

See the [prep-for-release skill](../.cursor/skills/prep-for-release/SKILL.md)
for the full step-by-step procedure, and `build/release.sh --help` for
the release script itself.

Quick summary:
1. Refresh catalog indexes (section 1 above)
2. Run functional tests: `test/func/run-all-tests.sh`
3. Smoke test on conno (if significant changes)
4. Write CHANGELOG entries and release bullets
5. `build/release.sh <version> "<description>"`
