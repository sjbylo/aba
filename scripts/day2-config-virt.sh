#!/bin/bash -e
# Configure OpenShift Virtualization boot sources to use the mirror registry.
#
# PROBLEM:
#   In disconnected environments, the default OCP Virt boot source
#   DataImportCron jobs cannot import VM images.  The CentOS/Fedora entries
#   use upstream registry URLs (quay.io) and the RHEL entries use
#   ImageStreams that point to registry.redhat.io — both unreachable.
#
#   The OpenShift ImageStream import controller does NOT respect IDMS, ITMS,
#   or ICSP mirror rules.  It contacts the upstream registry directly.
#   This is documented by Red Hat:
#     "the image stream import process does not use the mirror or search
#      mechanism at this time"
#     — https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/postinstallation_configuration/post-install-image-config
#
# SOLUTION:
#   Following the same pattern Red Hat recommends for the Cluster Samples
#   Operator in disconnected environments, this script:
#
#   1. Creates custom ImageStreams that point directly to the mirror registry
#      (the import controller contacts the mirror, which IS reachable).
#   2. Patches the HyperConverged CR's dataImportCronTemplates to reference
#      those custom ImageStreams for RHEL boot sources.
#   3. CentOS/Fedora boot sources already use pullMethod=node with direct
#      URLs, so ITMS handles mirror redirection for those automatically.
#      We override them with explicit mirror URLs for consistency.
#
#   This keeps the native OCP Virt ImageStream-based design for RHEL images
#   while pointing them at the reachable mirror registry.
#
# REFERENCES:
#   IBM Z blog — Importing VM templates in disconnected OCP Virt:
#     https://community.ibm.com/community/user/blogs/konstantin-konson/2026/01/07/importing-the-vm-templates-to-ocpv-disconnected
#   Red Hat docs — Cluster Samples Operator in disconnected environments:
#     https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/postinstallation_configuration/post-install-image-config
#
# PREREQUISITES:
#   - Mirror images synced/loaded (including templates/image-set-virt images)
#   - 'aba day2' applied (creates ITMS for CentOS/Fedora tag-based images)
#
# Run from a cluster directory: aba -d <cluster> day2-virt

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

umask 077

source <(normalize-aba-conf)
source <(normalize-cluster-conf)
export regcreds_dir=$HOME/.aba/mirror/$(image_source_mirror_name)
export regcreds_display="$(image_source_mirror_name)/regcreds"
source <(normalize-mirror-conf)

verify-aba-conf || aba_abort "$_ABA_CONF_ERR"
verify-cluster-conf || exit 1
verify-mirror-conf || aba_abort "Invalid or incomplete mirror.conf. Check the errors above and fix mirror/mirror.conf."

if ! image_source_is_mirror; then
	aba_info "This cluster connects directly to the internet (image_source=$image_source)."
	aba_info "Boot sources are auto-imported from public registries — no configuration needed."
	exit 0
fi

scripts/cli-install-all.sh --wait oc

aba_info "Accessing the cluster ..."

if [ ! "$KUBECONFIG" ]; then
	_kc=$(cluster_kubeconfig 2>/dev/null)
	[ -n "$_kc" ] && export KUBECONFIG="$_kc"
fi

cluster_api_reachable "$KUBECONFIG" || aba_abort "Cluster API is not reachable. Is the cluster running?"

if ! oc whoami --request-timeout='20s' >/dev/null 2>/dev/null; then
	if ! oc whoami >/dev/null; then
		aba_warn "Unable to access the cluster using KUBECONFIG=$KUBECONFIG"
		. <(aba login)
		if ! oc whoami --request-timeout='20s' >/dev/null; then
			aba_abort "Unable to log into the cluster"
		fi
	fi
fi

warn_if_cluster_unstable

# Verify OpenShift Virtualization (HyperConverged) is installed
if ! oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv >/dev/null 2>&1; then
	aba_info "OpenShift Virtualization is not installed (no HyperConverged CR found in openshift-cnv)."
	aba_info "Install the kubevirt-hyperconverged operator first, then run this command again."
	exit 0
fi

aba_info "Configuring OpenShift Virtualization boot sources to use mirror registry ($reg_host:$reg_port) ..."

_mirror_base="${reg_host}:${reg_port}${reg_path}"
_os_images_ns="openshift-virtualization-os-images"

# ---------------------------------------------------------------------------
# Boot source definitions
# ---------------------------------------------------------------------------
# Format: <cron-name> <source-type> <upstream-image>
#
# source-type determines how the DataImportCron imports the image:
#   imagestream  — Create a custom ImageStream pointing to the mirror, then
#                  reference it in the DataImportCron.  This is needed for
#                  RHEL images because the default ImageStreams point to
#                  registry.redhat.io (unreachable) and the import controller
#                  does NOT use IDMS/ITMS mirror rules.
#   url          — Use a direct registry URL with pullMethod=node.  CRI-O on
#                  the node pulls the image and ITMS handles the mirror
#                  redirection.  Used for CentOS/Fedora (no ImageStream).

_boot_sources="
centos-stream10-image-cron	url		quay.io/containerdisks/centos-stream:10
centos-stream9-image-cron	url		quay.io/containerdisks/centos-stream:9
fedora-image-cron		url		quay.io/containerdisks/fedora:latest
rhel9-image-cron		imagestream	registry.redhat.io/rhel9/rhel-guest-image:latest
rhel10-image-cron		imagestream	registry.redhat.io/rhel10/rhel-guest-image:latest
rhel11-image-cron		imagestream	registry.redhat.io/rhel11/rhel-guest-image:latest
"

# ---------------------------------------------------------------------------
# Step 1: Create custom ImageStreams for RHEL images pointing to the mirror
# ---------------------------------------------------------------------------
# The ImageStream import controller contacts whatever registry is in the
# ImageStream spec.  By pointing directly at the mirror (reachable), the
# import succeeds without needing IDMS/ITMS.

aba_info "Creating mirror-backed ImageStreams for RHEL boot sources ..."

while read -r _cron_name _source_type _upstream_image; do
	[ -z "$_cron_name" ] && continue
	[ "$_source_type" != "imagestream" ] && continue

	# Build the mirror image reference
	# e.g. registry.redhat.io/rhel9/rhel-guest-image:latest -> mirror:8443/path/rhel9/rhel-guest-image:latest
	_image_path="${_upstream_image#*/}"
	_mirrored_image="${_mirror_base}/${_image_path}"

	# Derive ImageStream name from cron name: rhel9-image-cron -> rhel9-guest-mirror
	_is_name="${_cron_name%-image-cron}-guest-mirror"

	aba_info "  $_is_name -> $_mirrored_image"

	oc apply -f - <<-EOF
	apiVersion: image.openshift.io/v1
	kind: ImageStream
	metadata:
	  name: $_is_name
	  namespace: $_os_images_ns
	  labels:
	    app.kubernetes.io/managed-by: aba-day2-virt
	spec:
	  tags:
	  - name: latest
	    from:
	      kind: DockerImage
	      name: $_mirrored_image
	    importPolicy:
	      importMode: PreserveOriginal
	      scheduled: true
	    referencePolicy:
	      type: Source
	EOF
done <<< "$_boot_sources"

# Verify the ImageStreams imported successfully.
# Track which ones succeeded — failed ones are skipped in the patch and cleaned up.
# This allows future RHEL versions (e.g. rhel11) to be listed in _boot_sources
# before their images are available; they are simply skipped until mirrored.
sleep 5
_imported_crons=" "
while read -r _cron_name _source_type _upstream_image; do
	[ -z "$_cron_name" ] && continue
	[ "$_source_type" != "imagestream" ] && continue
	_is_name="${_cron_name%-image-cron}-guest-mirror"
	_is_digest=$(oc get imagestream "$_is_name" -n "$_os_images_ns" \
		-o jsonpath='{.status.tags[0].items[0].image}' 2>/dev/null)
	if [ -n "$_is_digest" ]; then
		aba_info "  $_is_name: imported ($_is_digest)"
		_imported_crons="$_imported_crons$_cron_name "
	else
		aba_warn "  $_is_name: image not available in mirror — skipping"
		oc delete imagestream "$_is_name" -n "$_os_images_ns" --ignore-not-found >/dev/null 2>&1
	fi
done <<< "$_boot_sources"

# ---------------------------------------------------------------------------
# Step 2: Build the HyperConverged CR patch
# ---------------------------------------------------------------------------
# Override the default DataImportCronTemplates so that:
#   - RHEL entries reference our custom mirror-backed ImageStreams
#   - CentOS/Fedora entries use direct mirror URLs with pullMethod=node

aba_info "Building HyperConverged CR patch ..."

_templates="[]"
while read -r _cron_name _source_type _upstream_image; do
	[ -z "$_cron_name" ] && continue

	# Skip imagestream entries whose images were not available in the mirror
	if [ "$_source_type" = "imagestream" ]; then
		case "$_imported_crons" in
			*" $_cron_name "*) ;;
			*) continue ;;
		esac
	fi

	_ds_name="${_cron_name%-image-cron}"

	if [ "$_source_type" = "imagestream" ]; then
		# RHEL: reference the custom mirror-backed ImageStream
		_is_name="${_cron_name%-image-cron}-guest-mirror"
		_source_json='"registry": {"imageStream": "'"$_is_name"'", "pullMethod": "node"}'
		aba_info "  $_cron_name -> imageStream:$_is_name"
	else
		# CentOS/Fedora: direct mirror URL with pullMethod=node
		_image_path="${_upstream_image#*/}"
		_mirrored_url="docker://${_mirror_base}/${_image_path}"
		_source_json='"registry": {"url": "'"$_mirrored_url"'", "pullMethod": "node"}'
		aba_info "  $_cron_name -> $_mirrored_url"
	fi

	_template=$(cat <<-EOJSON
	{
		"metadata": {
			"annotations": {
				"cdi.kubevirt.io/storage.bind.immediate.requested": "true"
			},
			"name": "$_cron_name"
		},
		"spec": {
			"managedDataSource": "$_ds_name",
			"schedule": "0 */12 * * *",
			"template": {
				"spec": {
					"source": { $_source_json },
					"storage": {
						"resources": {
							"requests": {
								"storage": "15Gi"
							}
						}
					}
				}
			},
			"garbageCollect": "Outdated"
		}
	}
	EOJSON
	)

	_templates=$(echo "$_templates" | jq --argjson t "$_template" '. += [$t]')
done <<< "$_boot_sources"

# ---------------------------------------------------------------------------
# Step 3: Patch the HyperConverged CR
# ---------------------------------------------------------------------------
# In OCP 4.22+, dataImportCronTemplates moved to spec.workloadSources.
# Detect the correct path by probing the CRD schema.

if oc explain hyperconverged.spec.workloadSources.dataImportCronTemplates >/dev/null 2>&1; then
	_patch_path='{"spec":{"workloadSources":{"dataImportCronTemplates":'"$_templates"'}}}'
else
	_patch_path='{"spec":{"dataImportCronTemplates":'"$_templates"'}}'
fi

aba_info "Patching HyperConverged CR ..."
oc patch hyperconverged kubevirt-hyperconverged -n openshift-cnv \
	--type merge \
	-p "$_patch_path"

aba_success "HyperConverged CR patched."

# ---------------------------------------------------------------------------
# Step 4: Verify
# ---------------------------------------------------------------------------

_dic_ready() {
	local _count
	_count=$(oc get dataimportcron -n "$_os_images_ns" --no-headers 2>/dev/null | wc -l)
	[ "$_count" -ge 1 ]
}

aba_wait_show "Waiting for DataImportCron resources to appear" 5 120 _dic_ready || \
	aba_warn "DataImportCron resources did not appear within 2 minutes — check 'oc get dataimportcron -A'"

echo
aba_info "DataImportCron status:"
oc get dataimportcron -n "$_os_images_ns" \
	-o custom-columns='NAME:.metadata.name,SOURCE-TYPE:.spec.template.spec.source.registry.pullMethod,UP-TO-DATE:.status.conditions[?(@.type=="UpToDate")].status,LAST-IMPORT:.status.lastImportedPVC.name' 2>/dev/null || true

echo
_dv_count=$(oc get dv -n "$_os_images_ns" --no-headers 2>/dev/null | wc -l)
if [ "$_dv_count" -gt 0 ]; then
	aba_info "Boot source DataVolumes (import status):"
	oc get dv -n "$_os_images_ns" 2>/dev/null
else
	aba_info "No DataVolumes yet — boot sources will import on the next cron schedule (every 12 hours)."
	aba_info "To trigger an immediate import, run:"
	aba_info "  oc delete dataimportcron --all -n $_os_images_ns"
	aba_info "  (they will be recreated and immediately start importing)"
fi

echo
aba_success "OpenShift Virtualization boot source configuration completed successfully."
