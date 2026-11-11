#!/bin/bash
# Test helper: a throw-away ABA root (aba.conf, mirror/, a cluster dir) and shims for curl, oc and
# openshift-install, so scripts that talk to a registry run offline.  Sourced by the okd tests.
#
#   okd_fx_init <root> <ocp_version> <distribution|-> <image_source>
#   okd_fx_creds <root> <mirror|full|none> [with-ca|no-ca]
#   okd_fx_mirror_output <root> [reg_host:reg_port/reg_path]   (oc-mirror output files for a mirror)
#   okd_fx_run <root> <cmd...>        run <cmd> in <root>/demo with the shims, HOME=<root>/home
#
# Nothing here reads or writes the real $HOME.

OKD_FX_REPO="${OKD_FX_REPO:-$PWD}"

okd_fx_init() {
	local root="$1" ver="$2" dist="${3:--}" isrc="${4:-mirror}" f
	mkdir -p "$root/bin" "$root/home/bin" "$root/home/.aba" "$root/home/.ssh" "$root/mirror" "$root/tmp"
	ln -sfn "$OKD_FX_REPO/templates" "$root/templates"
	ln -sfn "$OKD_FX_REPO/cli" "$root/cli"
	# scripts/ as per-file links so two helpers that would reach the network can be replaced
	rm -rf "$root/scripts"; mkdir "$root/scripts"
	for f in "$OKD_FX_REPO"/scripts/*; do ln -s "$f" "$root/scripts/${f##*/}"; done
	for f in cli-install-all.sh create-containers-auth.sh; do
		rm -f "$root/scripts/$f"; printf '#!/bin/bash\nexit 0\n' > "$root/scripts/$f"; chmod +x "$root/scripts/$f"
	done

	cat > "$root/bin/curl" <<-'EOF'
	#!/usr/bin/bash
	out=""; w=""; url=""; hdr=""
	while [ $# -gt 0 ]; do
		case "$1" in
			-o) out="$2"; shift 2;;
			-w) w="$2"; shift 2;;
			-D) hdr="$2"; shift 2;;
			-H|-u|--cacert|--connect-timeout|--max-time|--retry) shift 2;;
			http*) url="$1"; shift;;
			*) shift;;
		esac
	done
	echo "curl $url" >> "${SHIM_LOG:-/dev/null}"
	code=404
	case "$url" in
		*/v2/) code="${FAKE_V2_CODE:-200}";;
		*/manifests/*) code="${FAKE_MANIFEST_CODE:-200}";;
	esac
	[ -n "$out" ] && [ "$out" != /dev/null ] && echo '{"errors":[{"message":"fake registry error"}]}' > "$out"
	[ -n "$hdr" ] && : > "$hdr"
	[ -n "$w" ] && printf '%s' "$code"
	exit 0
	EOF
	cat > "$root/bin/openshift-install" <<-'EOF'
	#!/usr/bin/bash
	echo "openshift-install $FAKE_INSTALL_VERSION"
	echo "built from commit 0123456789abcdef0123456789abcdef01234567"
	echo "release image ${FAKE_INSTALL_RELEASE_IMAGE}"
	echo "release architecture ${FAKE_INSTALL_ARCH:-amd64}"
	EOF
	# oc: "adm release extract" leaves an openshift-install that reports the release ref it was asked for
	cat > "$root/bin/oc" <<-'EOF'
	#!/usr/bin/bash
	echo "oc $*" >> "${SHIM_LOG:-/dev/null}"
	case "$*" in
		*"adm release extract"*)
			ref=""; for a in "$@"; do case "$a" in *release-images*) ref="$a";; esac; done
			[ -n "${FAKE_EXTRACT_FAIL:-}" ] && { echo "error: extract failed" >&2; exit 1; }
			for a in "$@"; do case "$a" in --idms-file=*) cp "${a#--idms-file=}" "${SHIM_LOG%/*}/idms-used.yaml" 2>/dev/null;; esac; done
			{
				echo '#!/usr/bin/bash'
				echo "echo 'openshift-install $FAKE_INSTALL_VERSION'"
				echo "echo 'built from commit 0123456789abcdef0123456789abcdef01234567'"
				echo "echo 'release image ${FAKE_EXTRACT_RELEASE_IMAGE:-$ref}'"
				echo "echo 'release architecture amd64'"
			} > openshift-install
			chmod +x openshift-install;;
	esac
	exit 0
	EOF
	chmod +x "$root/bin/curl" "$root/bin/oc" "$root/bin/openshift-install"
	cp "$root/bin/openshift-install" "$root/home/bin/openshift-install"

	okd_fx_run_in "$root" "$root" bash -c "
		export domain=example.com
		scripts/j2 templates/aba.conf.j2 > aba.conf
		sed -i 's/^ocp_version=.*/ocp_version=$ver/; s/^ocp_channel=.*/ocp_channel=stable/; s#^machine_network=.*#machine_network=10.0.0.0/20#; s/^next_hop_address=.*/next_hop_address=10.0.0.1/; s/^dns_servers=.*/dns_servers=10.0.0.1/; s/^ntp_servers=.*/ntp_servers=10.0.0.1/; s/^verify_conf=.*/verify_conf=all/; s/^ask=.*/ask=false/' aba.conf
		case '$dist' in
			-) sed -i '/^distribution=/d' aba.conf;;
			*) sed -i 's/^distribution=.*/distribution=$dist/' aba.conf;;
		esac
		ln -fs ../templates/Makefile.mirror mirror/Makefile
		( cd mirror && make mirror.conf )
		sed -i 's/^reg_host=.*/reg_host=registry.example.com/; s#^reg_path=.*#reg_path=/ocp4/openshift4#' mirror/mirror.conf
		mkdir demo; cd demo
		ln -fs ../templates/Makefile.cluster Makefile
		make cluster.conf name=demo type=compact starting_ip=10.0.1.10 image_source=$isrc api_vip=10.0.1.5 ingress_vip=10.0.1.6
		sed -i 's/^api_vip=.*/api_vip=10.0.1.5/; s/^ingress_vip=.*/ingress_vip=10.0.1.6/' cluster.conf
	" >/dev/null 2>&1
	[ -s "$root/demo/cluster.conf" ] && [ -s "$root/mirror/mirror.conf" ]
}

# okd_fx_run_in <root> <dir> <cmd...>
okd_fx_run_in() {
	local root="$1" dir="$2"; shift 2
	( cd "$dir" && env -i PATH="$root/bin:$root/home/bin:/usr/sbin:/usr/bin:/bin" HOME="$root/home" TMPDIR="$root/tmp" \
		LC_ALL=C.UTF-8 TERM=dumb PLAIN_OUTPUT=1 SHIM_LOG="$root/shim.log" \
		FAKE_INSTALL_VERSION="${FAKE_INSTALL_VERSION:-}" FAKE_INSTALL_RELEASE_IMAGE="${FAKE_INSTALL_RELEASE_IMAGE:-}" \
		FAKE_EXTRACT_RELEASE_IMAGE="${FAKE_EXTRACT_RELEASE_IMAGE:-}" FAKE_EXTRACT_FAIL="${FAKE_EXTRACT_FAIL:-}" \
		FAKE_V2_CODE="${FAKE_V2_CODE:-}" FAKE_MANIFEST_CODE="${FAKE_MANIFEST_CODE:-}" \
		http_proxy="${http_proxy:-}" https_proxy="${https_proxy:-}" no_proxy="${no_proxy:-}" \
		"$@" )
}

okd_fx_run() {
	local root="$1"; shift
	okd_fx_run_in "$root" "$root/demo" "$@"
}

okd_fx_creds() {
	local root="$1" kind="$2" ca="${3:-with-ca}" d="$1/home/.aba/mirror/mirror" auth
	rm -rf "$root/home/.aba/mirror"; mkdir -p "$d"
	auth=$(printf 'init:p4ssw0rd' | base64 -w0)
	case "$kind" in
		mirror) printf '{"auths":{"registry.example.com:8443":{"auth":"%s"}}}\n' "$auth" > "$d/pull-secret-mirror.json";;
		full)   printf '{"auths":{"registry.example.com:8443":{"auth":"%s"}}}\n' "$auth" > "$d/pull-secret-full.json";;
	esac
	[ "$ca" = with-ca ] && [ "$kind" != none ] && printf -- '-----BEGIN CERTIFICATE-----\nFAKEROOTCA\n-----END CERTIFICATE-----\n' > "$d/rootCA.pem"
	printf '{"auths":{"quay.io":{"auth":"%s"}}}\n' "$auth" > "$root/home/.pull-secret.json"
	[ -f "$root/home/.ssh/id_rsa" ] || ssh-keygen -q -t rsa -f "$root/home/.ssh/id_rsa" -N '' >/dev/null 2>&1
	ln -sfn "$d" "$root/demo/regcreds"
	return 0
}

# oc-mirror output for the mirror under <root>/mirror/data/working-dir, in the layout the real tool leaves:
# cluster-resources/idms-oc-mirror.yaml (+ signature-configmap.json) and signatures/<version>-sha256-<hex>.
# okd_fx_mirror_output <root> <version> <hex64> [idms-file]
okd_fx_mirror_output() {
	local root="$1" ver="$2" hex="$3" idms="${4:-$OKD_FX_REPO/test/func/fixtures/okd-idms-oc-mirror.yaml}"
	local wd="$root/mirror/data/working-dir"
	mkdir -p "$wd/cluster-resources" "$wd/signatures"
	[ -n "$idms" ] && cp "$idms" "$wd/cluster-resources/idms-oc-mirror.yaml"
	: > "$wd/signatures/${ver}-sha256-${hex}"
	printf '{"kind":"ConfigMap","apiVersion":"v1","binaryData":{"sha256-%s-1":"AAAA"}}\n' "$hex" > "$wd/cluster-resources/signature-configmap.json"
}
