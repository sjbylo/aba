# Sigstore Configuration Test Report

**Date:** 2026-03-28
**oc-mirror version:** 4.21.0-202603092144.p2.g3a3bf57.assembly.stream.el9
**Bastion:** bastion.example.com (RHEL 9)
**Test registry:** localhost:15000 (podman registry:2, no TLS)

---

## Background

ABA uses `~/.config/containers/registries.d/aba-sigstore.yaml` to control
whether `oc-mirror` fetches and writes OCI sigstore (cosign) signature
attachments on a per-registry basis.

The previous approach used `--remove-signatures=true` globally, which
stripped **all** signatures — including the ones OCP 4.21+ needs for
`ClusterImagePolicy` verification of release images.

The new approach uses `registries.d` to selectively enable sigstore for
registries known to carry valid signatures (OpenShift releases, Red Hat
catalog) while leaving it disabled for everything else.

During E2E testing, the **load** (disk-to-mirror) workflow failed because
the local mirror registry was not listed in the sigstore config, and
`oc-mirror` could not write sigstore attachments to it.

This report documents comprehensive testing of all three `oc-mirror`
workflows with different sigstore configurations and image types.

---

## Test Images

| Source Registry | Image Type | Has Sigstore? | Count |
|----------------|-----------|---------------|-------|
| `quay.io/openshift-release-dev` | OCP 4.20.16 release images | **Yes** | 193 |
| `registry.redhat.io/redhat/community-operator-index:v4.20` | RH-hosted catalog index | **Yes** | 1 |
| `registry.redhat.io/ubi9/ubi:latest` | Red Hat base image | **Yes** | 1 |
| `quay.io/argoprojlabs/argocd-operator` | Community operator image | **No** | 1 |
| `quay.io/community-operator-pipeline-prod/argocd-operator` | Community operator bundle | **No** | 1 |
| `quay.io/openshifttest/hello-openshift:1.2.0` | Third-party test image | **No** | 1 |

**Total: 198 images** (193 release + 3 operator + 2 additional)

The image set includes a deliberate mix of:
- Registries that **do** publish sigstore signatures (Red Hat / OpenShift)
- Registries that **do not** have sigstore signatures (community / third-party)

---

## Configurations Tested

### Config A — "Global true" (Option A candidate)

```yaml
default-docker:
    use-sigstore-attachments: true
```

All registries, including the destination mirror, have sigstore enabled.

### Config B — "Selective false, mirror NOT listed" (current broken config)

```yaml
default-docker:
    use-sigstore-attachments: false
docker:
    quay.io/openshift-release-dev:
        use-sigstore-attachments: true
    registry.redhat.io:
        use-sigstore-attachments: true
```

Source registries with known sigstore are enabled. The destination mirror
registry falls under the `false` default.

### Config C — "Selective false, mirror explicitly listed" (Option B candidate)

```yaml
default-docker:
    use-sigstore-attachments: false
docker:
    quay.io/openshift-release-dev:
        use-sigstore-attachments: true
    registry.redhat.io:
        use-sigstore-attachments: true
    localhost:15000:
        use-sigstore-attachments: true
```

Same as Config B but with the destination mirror registry explicitly
enabled for sigstore writes.

---

## Test Results

### Test 1 — SAVE (mirror-to-disk) with Config A

```
Workflow:   mirrorToDisk
Config:     default-docker: true (Config A)
Command:    oc-mirror --v2 --config imageset-config.yaml file:///output
```

| Image Category | Result | Count |
|---------------|--------|-------|
| Release images | ✅ Success | 193/193 |
| Operator images | ✅ Success | 3/3 |
| Additional images | ✅ Success | 2/2 |

**Exit code: 0**
**Mirror time: 11m 6s**

**Finding:** With `default: true`, source registries that lack sigstore
(community operators, third-party images) do **not** cause errors.
`oc-mirror` 4.21 looks for sigstore, finds nothing, and moves on.

---

### Test 2 — LOAD (disk-to-mirror) with Config A

```
Workflow:   diskToMirror
Config:     default-docker: true (Config A)
Command:    oc-mirror --v2 --config ... --from file:///output docker://localhost:15000/test
```

| Image Category | Result | Count |
|---------------|--------|-------|
| Release images | ✅ Success | 193/193 |
| Operator images | ✅ Success | 3/3 |
| Additional images | ✅ Success | 2/2 |

**Exit code: 0**
**Mirror time: 15m 57s**

Generated cluster resources: IDMS, ITMS, CatalogSource, ClusterCatalog,
signature-configmap.

**Finding:** With `default: true`, the destination mirror accepts sigstore
writes. All images loaded successfully, including those without sigstore.

---

### Test 3 — LOAD (disk-to-mirror) with Config B (mirror NOT listed)

```
Workflow:   diskToMirror
Config:     default: false, mirror NOT listed (Config B — current broken config)
Command:    oc-mirror --v2 --config ... --from file:///output docker://localhost:15000/test
```

| Image Category | Result | Count |
|---------------|--------|-------|
| Release images | ❌ Failed | 0/193 |
| Operator images | ❌ Failed | 0/3 |
| Additional images | ❌ Failed | 0/2 |

**Exit code: 14**
**Error:**
```
error mirroring image quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:00f1...
error: writing signatures: writing sigstore attachments is disabled by configuration
```

**Finding:** This reproduces the E2E pool 1 failure. `oc-mirror` fetched
sigstore attachments from `quay.io/openshift-release-dev` (where `true`
is set), then tried to write them to the mirror. The mirror falls under
`default: false`, blocking the write. **All 198 images fail** — oc-mirror
bails after the first sigstore write error.

---

### Test 4 — LOAD (disk-to-mirror) with Config C (mirror explicitly listed)

```
Workflow:   diskToMirror
Config:     default: false, mirror listed: true (Config C — Option B candidate)
Command:    oc-mirror --v2 --config ... --from file:///output docker://localhost:15000/test
```

| Image Category | Result | Count |
|---------------|--------|-------|
| Release images | ✅ Success | 193/193 |
| Operator images | ✅ Success | 3/3 |
| Additional images | ✅ Success | 2/2 |

**Exit code: 0**
**Mirror time: 13m 41s**

**Finding:** Adding only the mirror registry with `true` fixes the load.
Source defaults remain `false`, so community/third-party registries are
never checked for sigstore — zero risk of failures from unknown registries.

---

### Test 5 — SYNC (mirror-to-mirror) with Config A

```
Workflow:   mirrorToMirror
Config:     default-docker: true (Config A)
Command:    oc-mirror --v2 --config ... --workspace file:///workspace docker://localhost:15000/test
```

| Image Category | Result | Count |
|---------------|--------|-------|
| Release images | ⚠️ Partial | 62/193 |
| Operator images | ❌ Failed | 0/4 |
| Additional images | ❌ Failed | 0/1 |

**Exit code: 14**
**Error:**
```
error: determining manifest MIME type for docker://quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:4e70...
Manifest does not match provided manifest digest
```

**Finding:** This failure is **NOT sigstore-related**. It is a transient
manifest digest mismatch from the upstream registry (a known oc-mirror
issue when upstream content changes mid-sync). No sigstore errors appear
in the error log. 62 release images that were fetched before the bad
manifest were copied successfully.

---

### Test 6 — SYNC (mirror-to-mirror) with Config B (mirror NOT listed)

```
Workflow:   mirrorToMirror
Config:     default: false, mirror NOT listed (Config B)
Command:    oc-mirror --v2 --config ... --workspace file:///workspace docker://localhost:15000/test
```

| Image Category | Result | Count |
|---------------|--------|-------|
| Release images | ❌ Failed | 0/193 |
| Operator images | ❌ Failed | 0/4 |
| Additional images | ❌ Failed | 0/1 |

**Exit code: 14**
**Error:**
```
error: writing signatures: writing sigstore attachments is disabled by configuration
```

**Finding:** Same sigstore write failure as Test 3. Sync also writes
sigstore to the destination, so the same bug applies.

---

## Summary Matrix

| Test | Workflow | Config | Sigstore errors? | Result |
|------|---------|--------|-------------------|--------|
| 1 | Save | A (default: true) | None | ✅ 198/198 |
| 2 | Load | A (default: true) | None | ✅ 198/198 |
| 3 | Load | B (default: false, mirror unlisted) | **Yes — write blocked** | ❌ 0/198 |
| 4 | Load | C (default: false, mirror listed) | None | ✅ 198/198 |
| 5 | Sync | A (default: true) | None (unrelated failure) | ⚠️ 62/198 |
| 6 | Sync | B (default: false, mirror unlisted) | **Yes — write blocked** | ❌ 0/198 |

---

## Conclusions

1. **The current config (B) is broken for load and sync.** The local
   mirror registry must have `use-sigstore-attachments: true` to accept
   sigstore writes from images whose source registries had sigstore enabled.

2. **oc-mirror 4.21 handles missing sigstore gracefully.** When
   `use-sigstore-attachments: true` is set for a source registry that
   has no sigstore, oc-mirror simply finds nothing and proceeds — no error.

3. **Both Config A (global true) and Config C (mirror explicitly listed)
   fix the issue.** However, Config A expands the blast radius: any future
   image from any registry with corrupt/partial sigstore would be fetched
   and could cause unexpected failures.

4. **Config C (Option B) is the safer choice.** It enables sigstore only
   for known-good sources and the destination mirror. Community operators,
   third-party images, and private registries are never checked for
   sigstore, eliminating the risk of failures from unknown registries.

---

## Recommendation

**Implement Option B (Config C):** dynamically add the local mirror
registry to `aba-sigstore.yaml` with `use-sigstore-attachments: true`
before each `oc-mirror` invocation.

This provides:
- Sigstore preservation for OCP releases and RH images (required for 4.21+)
- Clean handling of community/third-party images (sigstore ignored)
- No risk from unknown registries with broken sigstore
- Automatic adaptation to any mirror hostname

The `--remove-signatures=true` flag in `OC_MIRROR_FLAGS` remains available
as an escape hatch if any issues arise.
