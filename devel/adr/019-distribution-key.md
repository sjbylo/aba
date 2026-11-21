# ADR-019: One distribution file per product (ocp | okd)

## Status
Accepted

## Context
ABA installs OpenShift. OKD is the community build of the same installer, and
a disconnected install follows the same steps. What changes is where the
release, the clients, the update graph, and the catalogs come from, and which
commands are valid.

OKD publishes the release as `quay.io/okd/scos-release`. Versions look like
`X.Y.Z-okd-scos.N`, and on the candidate channel also `X.Y.Z-okd-scos.ec.N`.
`oc` and `openshift-install` are GitHub release assets of `okd-project/okd`.
`oc-mirror` is not. The update graph is `updates.okd.io`, and the only
channels are `stable` and `candidate`. A release-only install does not need a
Red Hat pull secret. The community catalog is served without an entitlement.
The release in the mirror is a digest. oc-mirror does not leave a
`<version>-<arch>` tag.

ABA had no way to say which product it was installing. Adding OKD must not
change an OpenShift run.

A draft of this decision lived on the OKD pull request as the same number.
That draft put `dist_*` helpers in `include_all.sh` and branched with
`if dist_of = okd` at each call site. It also kept the TUI as the way to pick
OKD, and it refused VMware. That draft was not merged. The code that landed
is the decision below.

## Decision
`aba.conf` has one key:

```
distribution=ocp		# 'ocp' (default) or 'okd'
```

A missing or empty value, and any value other than `okd`, loads OpenShift.
`verify-aba-conf` rejects a value that is neither `ocp` nor `okd`.
`aba --distribution` writes the key before anything is loaded. An exported
`distribution=` does not override the file.

### One file, no call-site branch
`scripts/dist.sh` is the only place that reads the key. `okd` sources
`scripts/dist-okd.sh`. Everything else sources `scripts/dist-ocp.sh`. Each
file defines the same `dist_*` names. Callers call the function. They do not
test `dist_of`.

`dist_of` prints `ocp` or `okd`. `dist_display` prints `OCP` or `OKD` for
text a person reads. The config keys stay `ocp_version`, `ocp_channel`, and
`ocp_upgrade_to`. Renaming them would touch every script and every existing
`aba.conf`.

### What OKD can do
A fresh install is supported, including mirror, save, load, and bundle.
`aba day2` publishes the catalog. VMware, KVM, and bare metal are allowed on
amd64. An OKD VMware VM is created with secure boot off. Other CPU
architectures stop.

The CLI is the OKD interface. `dist_tui_allowed` fails for OKD, and the TUI
exits before it draws a menu. A missing `distribution` key still opens the
OpenShift TUI.

Channels are `stable` and `candidate`. `fast` and `eus` are rejected as
"not a channel for distribution OKD". A token that is not a channel at all
still gets the generic wrong-value error.

`upgrade`, `upgrade-mon`, `--upgrade-to`, `day2-osus`, and `day2-virt` call
`dist_stop_unsupported` and stop. `day2-virt` stops because the virt answers
(operator, HyperConverged object, guest disks) are not filled in for OKD yet.
The command name stays `aba day2-virt` for both products when that work is done.

### Where the release digest comes from
Before the mirror, the digest is the `Digest` field of the GitHub release
asset `release.txt` for that version
(`https://github.com/okd-project/okd/releases/download/<version>/release.txt`).
The image set pins that one digest (`mirror.platform.release`, `graph: false`).
An OpenShift channel block is not used, because an OKD build is not in the
OpenShift update graph.

After the mirror, the digest is the one oc-mirror recorded in its signature
files. The disconnected host cannot download `release.txt`.

### Accounts, catalogs, and tools ABA still borrows
With no `ops` and no `op_sets`, OKD does not require a pull secret. Selecting
operators does. The catalog list is `community-operator`. Operator sets stay
the Red Hat lists. OKD selects an operator with `--ops` instead.

`oc-mirror` still comes from `mirror.openshift.com`. Release signatures are
verified from the OpenShift CI signature bucket, with
`templates/okd-release-signing-key.asc`. `save` and `load` pass
`--remove-signatures` because `quay.io/okd/scos-content` has no cosign tags.
`sync` keeps signatures.

A connected check probes `github.com`, `quay.io`, `updates.okd.io`, and
`mirror.openshift.com`. It does not probe `registry.redhat.io`. An OpenShift
check does not probe OKD sites.

### State
`dist_record_mirror_state` writes `distribution=okd` and, when the digest is
known, `mirror_release_digest` into the mirror `state.sh`. The OpenShift
function writes nothing, so an OpenShift state file keeps the keys it had.

## Consequences
- A new difference between the products is a function in both distribution
  files. It is not a new `if` at a call site.
- OpenShift behavior stays on `dist-ocp.sh`. A missing key cannot select OKD.
- The OKD path depends on GitHub (the release list and `release.txt`),
  `updates.okd.io`, the OpenShift CI signature bucket, and `oc-mirror` from
  `mirror.openshift.com`. ABA does not control those.
- The TUI cannot install OKD. That is intentional.
- `day2-virt` and installing the community virt operator are not part of this
  decision. They stop today.

## Alternatives considered
1. **Branch at each call site (`if dist_of = okd`).** This is what the
   unmerged pull-request draft did, with the helpers living in
   `include_all.sh`. The same test would be copied through every script, and
   a missed branch would run the OpenShift path on an OKD install. Rejected.
2. **A separate tool or fork.** Duplicates the mirror, bundle, and install
   workflow. Rejected.
3. **Detect OKD from the version string.** The version is chosen after the
   channel, the graph, and the client download are already decided, and an
   empty `aba.conf` has no version. Rejected.
4. **Rename `ocp_*` keys.** Touches every script and breaks existing
   `aba.conf` files. Rejected.
5. **Let unsupported OKD commands fall through to the OpenShift path.** An
   OKD cluster would be sent through OpenShift upgrade or OSUS logic.
   Rejected. Those commands stop.
6. **Require a Red Hat pull secret for every OKD install.** The release pulls
   from `quay.io/okd` without one. Rejected. Operators still require a real
   secret.
7. **Refuse VMware.** The pull-request draft did. Lab installs boot on
   VMware when secure boot is off. Rejected.

## References
- ADR-001: config is the source of truth
- ADR-005: `normalize*()` outputs config only
- `scripts/dist.sh`, `scripts/dist-ocp.sh`, `scripts/dist-okd.sh`
- `templates/aba.conf.j2`: `distribution`
- `templates/okd-release-signing-key.asc`
- `templates/imageset-config.yaml.j2`: digest pin versus channel block
