#!/bin/bash
# create-install-config.sh -- Generate install-config.yaml from cluster/mirror config
#
# INTENT:    Assemble all inputs (configs, credentials, SSH keys, CA certs),
#            validate them, resolve the pull secret and connectivity mode,
#            then render templates/install-config.yaml.j2 into install-config.yaml.
# CALLED BY: Makefile.cluster 'install-config.yaml' target (never directly)
# CWD:       cluster directory (set by Makefile -C)
# REQUIRES:  aba.conf, cluster.conf, mirror.conf (sourced via include_all.sh);
#            vmware.conf when platform=vmw; kvm.conf when platform=kvm;
#            pull secret (mirror, full, or public); scripts/j2 renderer
# PRODUCES:  install-config.yaml in CWD (backs up existing to .backup)
# IDEMPOTENT: Yes (re-running overwrites install-config.yaml)
#
# STEPS:
#   1. Source and normalize all config files (aba.conf, cluster.conf,
#      mirror.conf, vmware.conf/kvm.conf as needed)
#   2. Validate configs (verify-aba-conf, verify-cluster-conf, verify-mirror-conf)
#   3. Display cluster.conf summary table to stdout
#   4. Set rendezvous_ip = starting_ip (first master IP)
#   5. Adjust hostPrefix 23->22 for bare-metal platforms
#   6. Resolve connectivity mode (image_source: direct / proxy / mirror):
#      - direct: use public pull secret, no mirror
#      - proxy:  use public pull secret + cluster-wide proxy settings
#      - mirror (default): use mirror pull secret + rootCA + imageContentSources
#   7. Fall back to public pull secret if no mirror credentials found
#   8. Generate or load SSH key pair
#   9. Validate registry host + verify release image in private registry
#  10. Render install-config.yaml via j2 template
#
# PLATFORM SELECTION (in template):
#   1. SNO (1 master, 0 workers) -> platform: none
#   2. s390x / ppc64le -> platform: none (baremetal unsupported on these arches)
#   3. VMware + vCenter (VC=1) + (OCP < 4.22 or vCenter > 8.0.0) -> platform: vsphere
#   4. VMware + vCenter + OCP >= 4.22 + vCenter < 8.0 U1 -> platform: baremetal (CSI unsupported)
#   5. Everything else (BM, KVM, ESXi-direct) -> platform: baremetal
#   See devel/01-SPEC.md "install-config.yaml Platform Selection"

source scripts/include_all.sh

# Release-image extract and credential checks happen in this script, before
# any later step. Repeat START so a skipped resolve-vips/DNS still opens the row.
aba_progress "START|ci_config"

aba_debug "Starting: $0 $* at $(date) in dir: $PWD"

source <(normalize-aba-conf)
source <(normalize-cluster-conf)
export regcreds_dir=$HOME/.aba/mirror/${image_source:-mirror}
export regcreds_display="${image_source:-mirror}/regcreds"
source <(normalize-mirror-conf)
[ "$platform" = "vmw" ] && source <(normalize-vmware-conf)  # vSphere values needed for install-config.yaml
[ "$platform" = "kvm" ] && source <(normalize-kvm-conf)

# ADR-005: ocp_major is not a normalize output. The content-sources template
# applies | int to it. A failed j2 used to be swallowed by the assignment, so
# install-config.yaml was written with no ImageDigestSources and still reported success.
_render_image_content_sources() {
	if [ "$(dist_of)" = "okd" ]; then
		_render_okd_image_content_sources
		return
	fi
	export ocp_major="$(ocp_major_of "${ocp_version:-}")"
	if [ -z "$ocp_major" ]; then
		aba_abort "ocp_version '${ocp_version:-}' has no major number"
	fi
	local _src
	if ! _src=$(scripts/j2 templates/image-content-sources.yaml.j2); then
		aba_abort "Could not render image content sources"
	fi
	export image_content_sources="$_src"
}

# OKD: the sources come from the IDMS oc-mirror wrote for this mirror (the file 'aba day2' applies), not
# from the static OCP template.  oc-mirror does not map the repository the installer pulls the release
# from (the distribution payload repo), so that source is added with the destination of the IDMS rule for
# the release images.  Nothing is guessed: no IDMS, no release-images rule, or a destination outside this
# registry stops the render.
_render_okd_image_content_sources() {
	local _idms=mirror/data/working-dir/cluster-resources/idms-oc-mirror.yaml
	local _dest="$reg_host:$reg_port$reg_path/" _re='\A[A-Za-z0-9][A-Za-z0-9._:/@-]*\z'
	local _json _src _payload
	if [ ! -s "$_idms" ]; then
		aba_abort "No oc-mirror IDMS found: $_idms" \
			"Run 'aba -d mirror sync' (or 'aba -d mirror load') first; the install-config is built from it."
	fi
	if ! _json=$(yaml2json < "$_idms" 2>/dev/null); then
		aba_abort "Could not read $_idms (not valid YAML)"
	fi
	if ! jq -e '(.spec.imageDigestMirrors // []) | length > 0 and all(.[]; (.source | type == "string") and ((.mirrors // []) | length > 0))' <<<"$_json" >/dev/null 2>&1; then
		aba_abort "$_idms has no usable imageDigestMirrors"
	fi
	# Values end up unquoted in install-config.yaml: only plain registry references pass
	if ! jq -e --arg re "$_re" 'all(.spec.imageDigestMirrors[]; (.source | test($re)) and all(.mirrors[]; test($re)))' <<<"$_json" >/dev/null 2>&1; then
		aba_abort "$_idms has a source or mirror that is not a valid registry reference"
	fi
	if ! jq -e --arg dest "$_dest" 'all(.spec.imageDigestMirrors[].mirrors[]; startswith($dest))' <<<"$_json" >/dev/null 2>&1; then
		aba_abort "$_idms points outside the registry in mirror.conf (expected mirrors under $_dest)" \
			"The IDMS may come from another registry; run 'aba -d mirror sync' (or 'load') again."
	fi
	_payload=$(dist_release_payload_repo)
	if ! _src=$(jq -r --arg payload "$_payload" '
		.spec.imageDigestMirrors as $m
		| (if any($m[]; .source == $payload) then $m
		   else ($m | map(select(.mirrors[0] | endswith("/openshift/release-images"))) | .[0]) as $rel
		   | if $rel == null then error("no release-images rule") else $m + [{mirrors: $rel.mirrors, source: $payload}] end
		   end)
		| .[] | "- mirrors:", (.mirrors[] | "  - " + .), "  source: " + .source' <<<"$_json" 2>/dev/null); then
		aba_abort "$_idms has no rule for the release images (.../openshift/release-images)" \
			"Run 'aba -d mirror sync' (or 'load') again."
	fi
	export image_content_sources="$_src"
}

# OKD installed from a mirror must not call out to the internet on its own: the Samples Operator would
# create image streams from registries the cluster cannot reach, and the default OperatorHub catalogs
# point at registry.redhat.io / registry.access.redhat.com.  Both are switched off at install time with
# manifests that generate-image.sh copies from openshift/ into the agent assets.  With direct/proxy
# (no mirror content sources) the OKD defaults stay and any manifest written earlier for a mirror
# install is removed.  Does nothing for OCP.
_okd_install_manifests() {
	local _dir=openshift
	local _samples=$_dir/99-aba-samples-removed.yaml _hub=$_dir/99-aba-operatorhub-default-sources-off.yaml
	[ "$(dist_of)" = "okd" ] || return 0
	if [ -n "${image_content_sources:-}" ]; then
		mkdir -p "$_dir"
		cat > "$_samples" <<-END
		# File generated by ABA (github.com/sjbylo/aba)
		apiVersion: samples.operator.openshift.io/v1
		kind: Config
		metadata:
		  name: cluster
		spec:
		  managementState: Removed
		END
		cat > "$_hub" <<-END
		# File generated by ABA (github.com/sjbylo/aba)
		apiVersion: config.openshift.io/v1
		kind: OperatorHub
		metadata:
		  name: cluster
		spec:
		  disableAllDefaultSources: true
		END
		aba_info "OKD from a mirror: added install-time manifests to $PWD/$_dir (Samples Operator removed, OperatorHub default sources off)"
	else
		rm -f "$_samples" "$_hub"
		rmdir "$_dir" 2>/dev/null || true
	fi
}

verify-aba-conf || aba_abort "$_ABA_CONF_ERR"
verify-cluster-conf || exit 1
verify-mirror-conf || aba_abort "Invalid or incomplete mirror.conf. Check the errors above and fix mirror/mirror.conf."

#to_output=$(normalize-cluster-conf | sed -e "s/^export //g" | paste -d '  ' - - - | column -t --output-separator " | ")
if [ "$platform" = "bm" ]; then
	to_output=$(normalize-cluster-conf | sed -E -e "s/^export //g" -e 's/^(mac_prefix|master_cpu_count|master_mem|worker_cpu_count|worker_mem|data_disk)=.*//g')
elif [ "$platform" = "vmw" ] || [ "$platform" = "kvm" ]; then
	to_output=$(normalize-cluster-conf | sed -e "s/^export //g")
fi
echo
aba_info "Showing existing values in cluster.conf:"
output_table 3 "$to_output"
echo

# Set the rendezvous_ip to the the first master's ip
export rendezvous_ip=$starting_ip

export pull_secret=
export ssh_key_pub=
export additional_trust_bundle=
export image_content_sources=

aba_debug rendezvous_ip: $starting_ip

# Change the default of bare-metal host prefix
if [ "$platform" = "bm" ] && [ $hostPrefix -eq 23 ]; then
	aba_info "Adjusting hostPrefix from 23 to 22 for bare-metal (allows more pods per node on large servers)"
	export hostPrefix=22
fi

# Generate the needed iso-agent-based config files ...

# Read in the needed files ...

# OKD: no Red Hat pull secret needed unless operators are selected; the OKD placeholder stands in for a missing one (direct and proxy)
if [ "$(dist_of)" = "okd" ] && [ "$image_source" = "direct" -o "$image_source" = "proxy" ] && [ ! -s "$pull_secret_file" ]; then
	_ps_err=$(dist_pull_secret_ensure "$pull_secret_file") || aba_abort "$_ps_err" "$(dist_pull_secret_hint "$pull_secret_file")"
fi

# Determine install mode from image_source: direct, proxy, or mirror (default).

use_mirror=1

if [ "$image_source" = "direct" ]; then
	aba_info "Using direct internet access: image_source=direct"

	use_mirror=
elif [ "$image_source" = "proxy" ]; then
	if [ "$http_proxy" ] || [ "$https_proxy" ]; then
		if [ -s $pull_secret_file ]; then
			export pull_secret=$(jq . "$pull_secret_file")
			aba_info "Found pull secret file at $pull_secret_file.  Assuming online installation using public Red Hat registry."
		else
			aba_abort \
				"No pull secret found at $pull_secret_file.  Aborting!  See the README.md file for help!" \
				"Get your pull secret from: https://console.redhat.com/openshift/downloads#tool-pull-secret (select 'Tokens' in the pull-down)"
		fi

		aba_success "Configuring the cluster wide proxy using the following settings:"
		aba_info "  http_proxy=$http_proxy"
		aba_info "  https_proxy=$https_proxy"
		aba_info "  no_proxy=$no_proxy"

		image_content_sources=
		additional_trust_bundle=

		export use_proxy=1
		use_mirror=
	else
		aba_warn \
			"Ignoring image_source=proxy! Proxy vars (http_proxy/https_proxy) are not set." \
			"If you want to configure the cluster wide proxy, set the '*_proxy' values" \
			"in cluster.conf or in the environment."

		sleep 2
	fi
elif ! image_source_is_mirror; then
	aba_warn "image_source value not recognized in cluster.conf [$image_source]" >&2
fi

# If the proxy is not in use (usually the case in disco env), find the pull secret to use/prioritize the mirror ...
if [ "$use_mirror" ]; then
	# From this point on we are expecting to find a mirror ...
	aba_info "Validating credentials of mirror registry ..."

	if [ -s "$regcreds_dir/pull-secret-mirror.json" ]; then
		# Early check: does the pull secret have credentials for the configured reg_host?
		_ps_auth=$(jq -r ".auths[\"$reg_host:$reg_port\"].auth" "$regcreds_dir/pull-secret-mirror.json" 2>/dev/null)
		if [ -z "$_ps_auth" ] || [ "$_ps_auth" = "null" ]; then
			_ps_hosts=$(jq -r '.auths | keys[]' "$regcreds_dir/pull-secret-mirror.json" 2>/dev/null | paste -sd ', ')
			aba_warn \
				"Pull secret has no credentials for $reg_host:$reg_port" \
				"Pull secret contains: ${_ps_hosts:-(empty)}" \
				"Check that reg_host/reg_port in ${image_source:-mirror}/mirror.conf match your registry" \
				"Pull secret: $regcreds_display/pull-secret-mirror.json"
		fi

		export pull_secret=$(cat "$regcreds_dir/pull-secret-mirror.json") 

		aba_info "Using mirror registry pull secret file at $regcreds_display/pull-secret-mirror.json to access registry at: $reg_host"

		# If we pull from the local reg. then we define the image content sources
		_render_image_content_sources
	elif [ -s "$regcreds_dir/pull-secret-full.json" ]; then
		export pull_secret=$(cat "$regcreds_dir/pull-secret-full.json") 

		aba_info "Using mirror registry pull secret file at $regcreds_display/pull-secret-full.json to access registry at: $reg_host"

		# If we pull from the local reg. then we define the image content sources
		_render_image_content_sources
	else
		aba_warn -p Attention \
			"Expected to find mirror credentials but found none!" \
			"No pull secret files found in directory: $regcreds_display/" \
			"A mirror registry has NOT been installed or configured!  See: aba mirror --help"

		show_mirror_missing_err=1
	fi

	# ... we also, need a root CA... if using our own registry.
	if [ -s "$regcreds_dir/rootCA.pem" ]; then
		export additional_trust_bundle=$(cat "$regcreds_dir/rootCA.pem") 
		aba_info "Using root CA file at $regcreds_display/rootCA.pem"
	else
		# Only show this warning IF there is no internet connection?
		# Or, only show if proxy is NOT being used?
		#if [ "$use_proxy" ]; then
		#	echo_red "No private mirror registry configured! Using proxy settings to access Red Hat's public registry" >&2
		#else
		# Should check accessibility to registry.redhat.io?
			aba_warn -p Attention \
				"Root CA file missing: $regcreds_display/rootCA.pem" \
				"No mirror registry available!" \
				"No value: additionalTrustBundle will be added to install-config.yaml"

			show_mirror_missing_err=1
		#fi
	fi

	if [ "$show_mirror_missing_err" ]; then
		aba_warn -p Attention \
			"No mirror registry found and no Internet connection (proxy or direct) defined in cluster.conf" \
			"If this is *unexpected*, you should do one of the following:" \
			"  1) Install a mirror registry: see aba mirror --help" \
			"  2) Integrate an existing mirror registry or" \
			"  3) Set image_source=proxy or image_source=direct in $PWD/cluster.conf for an online installation" \
			"Refer to the README.md for more" 

		sleep 2
	fi
fi

# If not already set, set the default value
if [ ! "$pull_secret" ]; then
	if [ -s "$pull_secret_file" ]; then
		export pull_secret=$(cat "$pull_secret_file" | jq .) 

		aba_info Using pull secret file at $pull_secret_file to access Red Hat registry

		# Note, no image_content_sources needed
		export image_content_sources=
	else
		aba_abort "Pull secret file missing: $pull_secret_file"
	fi
fi

# Check for ssh key files
if [ -s "$ssh_key_file" ] && [ -s "$ssh_key_file.pub" ]; then
	aba_info "Using existing ssh key files: $ssh_key_file"
elif [ -s "$ssh_key_file" ] && [ ! -s "$ssh_key_file.pub" ]; then
	# Private key exists but public key missing — regenerate .pub from private key
	aba_info "Regenerating public key from existing $ssh_key_file ..."
	ssh-keygen -y -f "$ssh_key_file" > "$ssh_key_file.pub"
else
	aba_info "Creating ssh key files: $ssh_key_file ..."
	ssh-keygen -t rsa -f "$ssh_key_file" -N ''
fi
export ssh_key_pub=$(cat "$ssh_key_file.pub")


# Check the private registry is defined, if it's in use
if [ "$additional_trust_bundle" ] && [ "$pull_secret" ]; then
	[ ! "$reg_host" ] && aba_abort "registry host value: reg_host is not defined in mirror.conf!"
fi

# Check that the release image is available in the private registry
if [ "$additional_trust_bundle" ] && [ "$image_content_sources" ]; then
	scripts/create-containers-auth.sh --load || exit 1
	scripts/verify-release-image.sh || exit 1
fi

# OCP 4.22+ CSI requires vSphere 8.0 U1+. Older vCenter still hosts the VMs;
# install-config must not use platform: vsphere or storage stays False forever.
USE_VSPHERE_PLATFORM=0
VSPHERE_PLATFORM_FALLBACK=0
if [ "$platform" = "vmw" ] && [ "${VC:-}" = "1" ]; then
	_vc_ver=$(govc about 2>/dev/null | awk '/^Version:/{print $2; exit}') || true
	_ocp_mm=$(_ver_minor "${ocp_version:-}")
	if is_version_greater "${_ocp_mm}.0" "4.21.0" && { [ -z "${_vc_ver:-}" ] || ! is_version_greater "$_vc_ver" "8.0.0"; }; then
		VSPHERE_PLATFORM_FALLBACK=1
		aba_warn "OCP ${ocp_version} requires vSphere 8.0 U1+ for platform: vsphere (CSI)." \
			"vCenter reports ${_vc_ver:-unknown}; generating platform: baremetal (apiVIPs)." \
			"VMs still run on this hypervisor; OpenShift will not integrate with vCenter."
	else
		USE_VSPHERE_PLATFORM=1
	fi
fi
export USE_VSPHERE_PLATFORM VSPHERE_PLATFORM_FALLBACK

aba_info
aba_info Generating Agent-based configuration file: $PWD/install-config.yaml 
aba_info

# Input is additional_trust_bundle, ssh_key_pub, image_content_sources, pull_secret, use_proxy, arch ...
aba_debug Creating install-config.yaml ...
[ -s install-config.yaml ] && cp install-config.yaml install-config.yaml.backup
scripts/j2 templates/install-config.yaml.j2 > install-config.yaml

_okd_install_manifests

aba_success "$PWD/install-config.yaml generated successfully!"
echo

