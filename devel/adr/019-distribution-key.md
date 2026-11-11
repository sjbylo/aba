# ADR-019: Distribution key (ocp | okd)

## Status
Proposed

## Context
ABA installs OpenShift. Users also ask for OKD, the community distribution
built from the same sources. OKD differs from OpenShift in where things are
downloaded from and in what is available, not in how a disconnected install is
done:

- The release payload is `quay.io/okd/scos-release`, not
  `quay.io/openshift-release-dev/ocp-release`. Versions look like
  `X.Y.Z-okd-scos.N`.
- `oc` and `openshift-install` are GitHub release assets of `okd-project/okd`.
  `oc-mirror` is not published by OKD.
- The update graph is `updates.okd.io`. Only the channels `stable` and
  `candidate` exist.
- No Red Hat pull secret is needed to pull the release. The operator catalogs
  `redhat-operator-index` and `certified-operator-index` need a Red Hat account;
  the community catalog is served anonymously by `registry.access.redhat.com`.
- Release signatures are not on `mirror.openshift.com`; `oc-mirror` has to be
  told where they are and which key signed them.
- The mirror holds the release under a digest. There is no `<version>-<arch>`
  tag, and the digest the upstream installer reports belongs to an index the
  mirror does not hold.

ABA has no way to say which of the two it is working with. Adding OKD must not
change what an OpenShift user gets.

## Decision
Add one key to `aba.conf`:

```
distribution=ocp		# 'ocp' (default) or 'okd'
```

A missing or empty value means `ocp`, so existing `aba.conf` files keep working.
`aba --distribution okd`, the first page of the TUI wizard, or editing the file
sets it. `verify-aba-conf` rejects any other value.

### One reader, one place per constant
`dist_of()` returns `ocp` or `okd`. A set of `dist_*` helpers in
`include_all.sh` returns the distribution-specific constants: payload
repository, CLI base URL, update-graph API, version pattern, valid channels,
catalogs and catalog references, whether a pull secret is required. Code that
differs between the distributions branches once, with the existing code as the
`else` side:

```bash
if [ "$(dist_of)" = "okd" ]; then
	<okd code>
else
	<existing code, unchanged>
fi
```

OpenShift output stays byte-identical. No release version, digest, or tag of a
specific OKD release is written into scripts, templates, or the TUI.

### Names are not changed
`ocp_version`, `ocp_channel`, `ocp_upgrade_to`, and the `OCP_SIGNATURE_*`
variables keep their names. Renaming them would touch every script and every
existing `aba.conf`. For OKD they hold an OKD version and channel.

### Three states stay separate (see ADR-007)
| State | Where | OKD keys |
|-------|-------|----------|
| Next install | `aba.conf` | `distribution`, `ocp_version` |
| Mirror content | mirror `state.sh` | `distribution`, `mirror_release_digest` |
| Installed cluster | cluster `state.sh` | `distribution`, `release_digest` |

Only `okd` is written; a state without the key reads as `ocp`, so OpenShift
state files keep exactly the keys they had. Once written, the label is not
changed by editing `aba.conf`, so a later edit does not relabel an existing
mirror or cluster. A
mismatch stops with an error (a registry never holds both distributions; a
bundle of the other distribution or another release is refused by `load`).

### No Red Hat account on the okd side
On `okd`, ABA does not require a Red Hat pull secret, a `registry.redhat.io`
credential, a `console.redhat.com` step, or subscription content.

- If no operators are selected and `pull_secret_file` is missing, ABA writes the
  placeholder secret published by the OKD project (it holds no credential).
  With `ops` or `op_sets` the placeholder is rejected and a real secret is needed.
- The Internet check probes `github.com`, `quay.io`, `updates.okd.io`, and
  `mirror.openshift.com`.
- Anonymous downloads from Red Hat hosts are allowed and are listed in the
  README: `oc-mirror`, `butane`, and the `mirror-registry` installer from
  `mirror.openshift.com`; the community catalog and `ubi9` images from
  `registry.access.redhat.com`.

### Release signatures
For `sync`, `save`, and `load`, ABA exports `OCP_SIGNATURE_URL` (the OpenShift CI
signature bucket, ending in `/`) and `OCP_SIGNATURE_VERIFICATION_PK` (the
release CI public key shipped in `templates/okd-release-signing-key.asc`). A
value the user already set wins, for each variable on its own. The shipped key
expires on 2027-03-31 and must be refreshed before then.

### What is not supported stops, it does not fall back
Upgrades (`upgrade`, `upgrade-mon`, `--upgrade-to`, `ocp_upgrade_to`), `day2-osus`,
`day2-virt`, `aba import`, Red Hat operator catalogs and operator sets, and the
channels `fast` and `eus` stop with "unsupported for OKD" (or a channel error)
before anything is changed or a cluster is contacted. Architectures other than
x86_64 and VMware vSphere are outside the scope: `distribution=okd` with `platform=vmw`, or on a host that is not
x86_64, stops with "not supported for OKD" (`verify-aba-conf`, and `aba --distribution` / `--platform` in any
order).

## Consequences
- OpenShift users see no change; the `ocp` side of every branch is the old code.
  This is checked by comparing the output of the affected scripts before and
  after.
- Every new difference between the distributions needs one more branch or one
  more `dist_*` helper. The cost is spread across many scripts, but each branch
  is small and reviewable on its own.
- The OKD path depends on three external services ABA does not control:
  `updates.okd.io`, the GitHub releases API, and the OpenShift CI signature
  bucket. The last one is not an official OKD release channel; if its location
  or key changes, one constant and one file change.
- `oc-mirror` and `mirror-registry` still come from Red Hat hosts. The downloads
  are anonymous, but a user who blocks `mirror.openshift.com` cannot use the
  default registry (`reg_vendor=docker` avoids the installer, not `oc-mirror`).
- The TUI asks for the distribution after its start-up Internet check, which
  uses the OpenShift sites on a first run. Until that order changes, a host that
  reaches only the OKD sites has to run `aba --distribution okd` before `abatui`.
- Operators on OKD are limited to the community catalog. Operator sets are
  Red Hat products and are not offered.
- The signing key is a dated artifact. A release process for refreshing it is
  needed before 2027-03-31.

## Alternatives considered
1. **A separate tool or fork for OKD.** Duplicates the mirror, bundle, and
   install workflow and drifts from upstream. Rejected.
2. **Detect OKD from the version string.** A version is chosen after the
   channel, the update graph, and the CLI download have already been decided, and
   an empty `aba.conf` has no version. Rejected.
3. **Rename `ocp_*` keys to neutral names.** Touches every script and breaks
   existing `aba.conf` files. Rejected for now; the cost is that `ocp_version`
   holds an OKD version.
4. **Branch at each call site without helpers.** The constants would be
   repeated across scripts. Rejected in favour of `dist_*` helpers.
5. **Fall back to the OpenShift path for unsupported OKD operations.** Would send
   an OKD cluster through OpenShift upgrade or OSUS logic. Rejected; those
   operations stop instead.
6. **Require a Red Hat pull secret for OKD as for OpenShift.** OKD pulls from
   `quay.io/okd` anonymously; the requirement would be a barrier for no gain.
   Rejected.

## References
- ADR-005: `normalize*()` outputs config only
- ADR-007: Unified state management
- `scripts/include_all.sh`: `dist_of()`, `dist_*` helpers,
  `ensure_release_signature_env()`, `cluster_okd_guard()`, `okd_conf_guard()`
- `templates/aba.conf.j2`: `distribution`
- `templates/okd-release-signing-key.asc`, `templates/aba-sigstore-config-okd.yaml`
- README: "Using OKD"
