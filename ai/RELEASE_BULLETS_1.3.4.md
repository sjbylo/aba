# ABA 1.3.4 Release Highlights

Operator sets overhaul, TUI operator UX improvements, ownership UX, and preflight/bundle fixes.

- **27 curated operator sets** — 14 new sets covering storage vendors (Dell, NetApp, HPE, IBM, Portworx), networking, edge/telco, migration, databases, backup, observability, confidential containers, security secrets, and supply chain security. Security set expanded with 6 operators (Suggested by [@rach228](https://github.com/rach228) in [#41](https://github.com/sjbylo/aba/issues/41)).
- **Operator sets include all dependencies** — Each set is self-contained. Selecting a single set mirrors everything needed to install those operators.
- **TUI: Catalog column in operator selection** — Operator selection and search dialogs show which catalog each operator belongs to (redhat, certified, or community).
- **Smarter file ownership for edited configs** — When you edit the ImageSet Config, ABA marks the file as user-managed with clear instructions on how to reset. No more misleading "edit this file and you own it" invitation in generated files.
- **`aba image add/remove/list`** — Manage additional container images (UBI, support-tools, container disks, etc.) from the CLI. Images are stored in `images.conf` and mirrored alongside OpenShift platform and operator images.
- **TUI: Image reference validation** — The `images.conf` editor now validates entries before saving, rejecting invalid image references.
- **Agent-config apiVersion bumped to `v1beta1`** — Generated `agent-config.yaml` files now use the stable `v1beta1` API (supported since OCP 4.12).
- **vSphere preflight: missing folder is now a warning** — The folder is created at install time, so a missing folder during preflight no longer aborts.
- **FAQ: Extracting client binaries for other OSes** — README explains how to get oc/openshift-install for Linux, Mac, and Windows from the mirrored release payload.
- **Fixed: Cluster delete left VMs behind when vCenter was unreachable** — Delete now aborts instead of silently skipping cleanup.
- **Fixed: TUI mirror confirm showed a reverse-upgrade arrow** — Confirmations no longer display 5.0 → 4.22.
