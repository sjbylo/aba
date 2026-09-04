# ADR-013: additionalImages via images.conf (ABA-managed ISC)

## Status
Proposed

## Context

Users often need extra container images in the oc-mirror ImageSet
Configuration (`mirror/data/imageset-config.yaml`, the ISC) — UBI, `ose-cli`,
support-tools, virt container disks, and similar. Today those are commented
examples in `templates/imageset-config.yaml.j2`. The only way to include them
is to edit the generated ISC.

That edit makes the ISC newer than `mirror/data/.created`, so ABA treats the
file as user-managed and **stops regenerating** platform channels and
operators. Adding one extra image should not force that takeover.

`aba.conf` / `mirror.conf` are `key=value`. Image refs are long, numerous, and
need comments. A comma-separated config key is a poor editor experience.

## Decision

### Source of truth: `images.conf`, not the ISC

Ship and honor two optional list files (one image per line, `#` comments and
blank lines ignored):

| File | Scope |
|------|--------|
| `images.conf` (next to `aba.conf`) | Repo / bundle-wide extras |
| `mirror/images.conf` (next to `mirror.conf`) | Per-mirror extras |

Either file may be absent. Both may exist. **Union, then dedupe:** an image
listed in both files appears **once** in the ISC.

Order: repo `images.conf` first, then images that exist only in
`mirror/images.conf`. If the same ref is in both, keep the first occurrence.

ABA still owns `platform` and `operators` in the ISC. Editing `images.conf`
must **not** trip the user-managed ISC guard. The generator reads the conf
files, writes `additionalImages`, then `touch data/.created` as today.

Hand-editing the ISC remains the full-takeover escape hatch (existing
`.created` rule). If the ISC is already user-managed, changing `images.conf`
does not silently overwrite the YAML; warn and require
`aba --force -d mirror imagesetconf`.

### Format (not `key=value`)

```
# images.conf — extra images for oc-mirror additionalImages
# Edit this file. Do not add additionalImages by hand in imageset-config.yaml.

registry.redhat.io/ubi9/ubi-micro:latest
registry.redhat.io/openshift4/ose-cli:latest
```

Do not funnel this list through `normalize-aba-conf` (ADR-005: normalize
emits config keys only). A small core helper reads/merges the two files for
the ISC generator (and for `aba image list`).

### Notes in the generated ISC

The ISC must show **how each extra image got there**, so users do not edit
the YAML to “add” images:

```yaml
  # additionalImages: generated from images.conf. Edit images.conf, not this file.
  additionalImages:
  - name: registry.redhat.io/ubi9/ubi-micro:latest  # aba/images.conf
  - name: registry.redhat.io/openshift4/ose-cli:latest  # aba/images.conf, mirror/images.conf
  - name: quay.io/containerdisks/fedora:latest  # mirror/images.conf
```

Section header plus per-entry `#` source comment. Deduped entries that
appeared in both files list **both** sources in the comment.

### Regeneration

`data/imageset-config.yaml` Make dependencies include `../images.conf` and
`$(wildcard images.conf)` (mirror dir) so save/sync/imagesetconf rebuild when
either list changes.

### Bundles and CLI

- `backup.sh` includes repo `images.conf` (and `mirror/images.conf` when that
  mirror dir is bundled).
- Ship `templates/images.conf` with commented examples. After bundle scripts
  stop using `uncomment_line` on the ISC template, remove the commented
  `additionalImages` block from `imageset-config.yaml.j2`.
- CLI (`aba image add/remove/list`) is a thin editor of those files.
  Target file follows ABA’s existing `-d` rule, not TUI internals:
  - `aba image add <img> [<img> ...]` → repo `images.conf` (next to `aba.conf`)
  - `aba -d mirror image add <img> [<img> ...]` → `mirror/images.conf`
  Multiple refs on one command are allowed. The files remain the source of
  truth; users may also edit them in a text editor.

### TUI

TUI screens and dialogs live in `tui/v2/SPEC.md` (additional images).
Invariant here: the TUI is a dumb consumer of `aba image add` / `list` /
`remove`. It must not write `images.conf`, merge lists, or edit the ISC.

## Consequences

- Extra images survive ISC regeneration (operator changes, upgrade prep).
- Two files merge with no duplicate `additionalImages` names.
- ISC comments document origin; users learn to edit `images.conf`.
- New Makefile deps, bundle include, generator/template, and (optional) CLI.
- Operator-set auto-companion images (virt disks, etc.) stay a later optional
  (confirm, then append to `images.conf`) — not required for this ADR.
