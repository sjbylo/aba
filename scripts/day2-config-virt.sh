#!/bin/bash -e
# Configure OpenShift Virtualization boot sources to use the mirror registry.
#
# In disconnected environments, the DataImportCron jobs that populate the
# VM boot source catalog default to upstream registry URLs (registry.redhat.io,
# quay.io) which are unreachable.  This script patches the HyperConverged CR
# to rewrite those URLs to the local mirror registry so boot sources import
# correctly.
#
# Requires: OpenShift Virtualization operator installed, mirror registry running.
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
	aba_abort "OpenShift Virtualization is not installed (no HyperConverged CR found in openshift-cnv)." \
		"Install the kubevirt-hyperconverged operator first, then run this command again."
fi

aba_info "Configuring OpenShift Virtualization boot sources to use mirror registry ($reg_host:$reg_port) ..."

_mirror_base="${reg_host}:${reg_port}${reg_path}"

# Boot source images and their DataImportCron names.
# Format: <cron-name> <upstream-image>
# These match the default boot sources that OCP Virt creates.
_boot_sources="
centos-stream10-image-cron	quay.io/containerdisks/centos-stream:10
centos-stream9-image-cron	quay.io/containerdisks/centos-stream:9
fedora-image-cron		quay.io/containerdisks/fedora:latest
rhel9-image-cron		registry.redhat.io/rhel9/rhel-guest-image:latest
rhel10-image-cron		registry.redhat.io/rhel10/rhel-guest-image:latest
"

# Build the JSON patch for dataImportCronTemplates
_templates="[]"
while read -r _cron_name _upstream_image; do
	[ -z "$_cron_name" ] && continue

	# Rewrite upstream registry path to mirror path
	# e.g. quay.io/containerdisks/centos-stream:10 -> mirror:8443/containerdisks/centos-stream:10
	# e.g. registry.redhat.io/rhel9/rhel-guest-image:latest -> mirror:8443/rhel9/rhel-guest-image:latest
	_image_path="${_upstream_image#*/}"
	_mirrored_url="docker://${_mirror_base}/${_image_path}"

	# Derive the managedDataSource name from the cron name (strip -image-cron suffix)
	_ds_name="${_cron_name%-image-cron}"

	_template=$(cat <<-EOJSON
	{
		"metadata": {
			"name": "$_cron_name"
		},
		"spec": {
			"managedDataSource": "$_ds_name",
			"schedule": "0 */12 * * *",
			"template": {
				"spec": {
					"source": {
						"registry": {
							"url": "$_mirrored_url",
							"pullMethod": "node"
						}
					},
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

	aba_info "  $_cron_name -> $_mirrored_url"
done <<< "$_boot_sources"

# Patch the HyperConverged CR
aba_info "Patching HyperConverged CR with mirror boot sources ..."
oc patch hyperconverged kubevirt-hyperconverged -n openshift-cnv \
	--type merge \
	-p '{"spec":{"dataImportCronTemplates":'"$_templates"'}}'

aba_success "HyperConverged CR patched with mirrored boot source URLs."

# Wait for DataImportCrons to be created
_dic_ready() {
	local _count
	_count=$(oc get dataimportcron -n openshift-virtualization-os-images --no-headers 2>/dev/null | wc -l)
	[ "$_count" -ge 1 ]
}

aba_wait_show "Waiting for DataImportCron resources to appear" 5 120 _dic_ready || \
	aba_warn "DataImportCron resources did not appear within 2 minutes — check 'oc get dataimportcron -A'"

echo
aba_info "DataImportCron status:"
oc get dataimportcron -n openshift-virtualization-os-images 2>/dev/null || true

echo
aba_success "OpenShift Virtualization boot source configuration complete."
aba_info "Boot sources will be imported on the next cron schedule (every 12 hours)."
aba_info "To trigger an immediate import, delete the DataImportCron resources and they will be recreated."
