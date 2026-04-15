# oc-mirror v2 Internals -- Source Code Analysis

**Date**: 2026-04-15
**Source commit**: `be3d7693` (openshift/oc-mirror)

This documents key oc-mirror v2 behaviors verified by reading the source code.
Relevant to ABA's `reg-save.sh`, `reg-sync.sh`, and `reg-load.sh`.

---

## 1. The three workflows

| Workflow | ABA command | oc-mirror mode | Direction |
|----------|-------------|----------------|-----------|
| mirror-to-disk (m2d) | `aba mirror save` | `MirrorToDisk` | Internet → local tarball |
| disk-to-mirror (d2m) | `aba mirror load` | `DiskToMirror` | Tarball → disconnected registry |
| mirror-to-mirror (m2m) | `aba mirror sync` | `MirrorToMirror` | Internet → connected registry |

All three require `--config imageset-config.yaml` on the command line. In ABA,
`save` and `load` both use the same file: `data/imageset-config.yaml`.

---

## 2. How `--since` controls archive contents (save only)

### The short version

- **Without `--since`**: subsequent saves create smaller differential archives
  (only new blobs). Works fine IF every previous archive was loaded into the
  disconnected registry. Breaks if the registry was rebuilt or a transfer was skipped.

- **With `--since <far-back-date>`**: every save creates a complete, self-contained
  tarball. Larger, but always works on a fresh registry.

- **ABA fix**: replace the hardcoded `--since 2025-01-01` in `reg-save.sh` with
  `${OC_MIRROR_SINCE:+--since $OC_MIRROR_SINCE}`, configurable in `~/.aba/config`,
  OFF by default.

### How it works under the hood

oc-mirror tracks previously archived blobs in `working-dir/.history/`. Each save
writes a timestamped history file listing every blob hash that went into the archive.

Each archive contains:
1. ALL manifests (image references) -- always included
2. ALL of working-dir (metadata, history)
3. The imageset-config used for this run
4. **Only new blobs** -- blobs not in the history file are skipped

The `--since <date>` flag tells oc-mirror: "pretend my last save was before this
date". It picks the latest history file older than that date. If none exists
(typical for a far-back date), history is empty and ALL blobs go into the archive.

Without `--since`, oc-mirror uses the most recent history file, so only blobs
added since the last save go into the archive.

| Scenario | Archive size | Works on fresh registry? |
|----------|-------------|------------------------|
| First save (no history exists) | Full | Yes |
| Subsequent save without `--since` | Small (diff only) | No -- needs all previous loads |
| Subsequent save with `--since <far-back-date>` | Full | Yes |

---

## 3. The imageset-config must always list everything you want

### The short version

The imageset-config is the **complete truth for each round** -- it's not additive
across rounds. Each `load` rebuilds the operator catalog index from scratch using
only the operators listed in the config. If you drop an operator from the config,
it disappears from OperatorHub. If you add one, it gets picked up.

**To keep OperatorHub complete**: the imageset-config must always list ALL operators
you want -- not just the ones added since the last round.

### How it works under the hood

**During `save`**: oc-mirror reads the imageset-config and collects all matching
images (releases, operators, additional images, helm) into the local cache,
then packs them into the archive.

**During `load`**: oc-mirror extracts the archive, then reads the **CLI-provided**
imageset-config (not the one bundled in the archive). For each operator catalog:
1. Reads the catalog from the extracted cache
2. Filters to only the packages listed in the config
3. Rebuilds a new catalog index containing only those packages
4. Pushes the rebuilt index to the disconnected registry, **overwriting** the old one

So the catalog in the registry always reflects exactly what's in the current
imageset-config -- nothing more, nothing less.

### What this means for multiple save/transfer/load rounds

- **Remove an operator from the config**: it disappears from OperatorHub.
  Its images are still in the registry but orphaned (not referenced by the catalog).

- **Add a new operator**: its images get collected during `save` regardless of
  `--since` settings. The history tracks blobs by hash, not by config entries.
  New operator blobs aren't in history, so they always go into the archive.

- **Change nothing**: the same images get pushed again. No harm, just wasted time
  on images that are already in the registry.

---

## 4. Exit codes tell you WHAT failed, not WHY

### The short version

oc-mirror v2 returns a bitmask exit code that tells you which **category** of
image failed. It does NOT tell you whether the failure was transient (network blip)
or permanent (bad auth, missing image). A release image that fails due to a
2-second network timeout returns the same exit code as a permanent auth failure.
Therefore: **all exit codes should be retried**.

### Exit code table

| Code | Constant | Meaning |
|------|----------|---------|
| 1 | `GenericErr` | Something failed before image copying started (config, auth, collection) |
| 2 | `ReleaseErr` | One or more release images failed to copy |
| 4 | `OperatorErr` | One or more operator images failed to copy |
| 8 | `AdditionalImgErr` | One or more additional images failed to copy |
| 16 | `HelmErr` | One or more helm images failed to copy |

Codes 2/4/8/16 are combined with bitwise OR. For example, exit 12 means both
operator (4) and additional (8) images failed. Exit 6 means release (2) and
operator (4) images failed.

Exit 1 (generic) is different -- it's returned when the error happens **outside**
the image copy phase entirely (e.g. bad config file, auth handshake failed,
catalog collection timed out).

### How the bitmask is computed

The batch worker counts how many images were expected vs. how many succeeded:
```
releaseCountDiff = expected release images - successfully copied release images
```
If the diff is non-zero, the release bit (2) is set. It doesn't look at the
error message or cause -- just the count. Same for all other categories.

### Release images trigger fail-fast

When a release image fails to copy, oc-mirror cancels ALL other in-flight copies
and stops immediately. For operator/additional/helm failures, it skips the failing
image and continues with the rest.

---

## 5. Source file reference

Related Pull Request: https://github.com/openshift/oc-mirror/pull/1062 

All paths relative to `github.com/openshift/oc-mirror` at commit `be3d7693`:

| File | What it does |
|------|-------------|
| `v2/cmd/oc-mirror/main.go` | Entry point, converts error → exit code |
| `v2/internal/pkg/cli/executor.go` | Main logic: `CollectAll`, `RunMirrorToDisk`, `RunDiskToMirror` |
| `v2/internal/pkg/batch/common.go` | `BatchError` struct, `ExitCode()` bitmask computation |
| `v2/internal/pkg/batch/concurrent_chan_worker.go` | Image copy worker, fail-fast on release errors |
| `v2/internal/pkg/errcode/code.go` | Error code constants (1, 2, 4, 8, 16) |
| `v2/internal/pkg/archive/archive.go` | Archive builder, differential blob logic |
| `v2/internal/pkg/history/history.go` | Blob history tracking, `--since` baseline selection |
| `v2/internal/pkg/release/local_stored_collector.go` | Release image collector (save + load) |
| `v2/internal/pkg/operator/local_stored_collector.go` | Operator collector, catalog rebuild during load |
