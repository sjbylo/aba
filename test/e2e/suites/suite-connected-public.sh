#!/usr/bin/env bash
# =============================================================================
# Suite: Connected Public (rewrite of test3)
# =============================================================================
# Purpose: Install from public registry (no mirror). Test direct and proxy
#          internet modes. Verify install-config.yaml assertions.
#
# This is the simplest suite -- no mirror, no air-gap, no internal bastion.
# =============================================================================

set -u

_SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SUITE_DIR/../lib/framework.sh"
source "$_SUITE_DIR/../lib/config-helpers.sh"
source "$_SUITE_DIR/../lib/setup.sh"

# --- Configuration ----------------------------------------------------------

NTP_IP="${NTP_SERVER:-10.0.1.8}"
CON_HOST="con${POOL_NUM:-1}.${VM_BASE_DOMAIN:-example.com}"

# Pool-unique cluster names (avoid VM collisions when pools run in parallel)
SNO="$(pool_cluster_name sno)"

# --- Suite ------------------------------------------------------------------

e2e_setup

plan_tests \
    "Setup: install aba and configure" \
    "Direct mode: create SNO config" \
    "Direct mode: verify install-config.yaml" \
    "Proxy mode: create SNO config" \
    "Proxy mode: verify install-config.yaml" \
    "Proxy mode: install SNO cluster" \
    "Proxy mode: verify and shutdown" \
    "Direct+mirror mode: config verification" \
    "Proxy-only mode: verify without direct internet" \
    "no_proxy validation"

suite_begin "connected-public"

# ============================================================================
# 1. Setup
# ============================================================================
test_begin "Setup: install aba and configure"

setup_aba_from_scratch

e2e_run "Install aba" "./install"

e2e_run "Configure aba.conf" \
    "aba --noask --platform vmw --channel ${TEST_CHANNEL:-stable} --version ${OCP_VERSION:-p} --base-domain $(pool_domain)"

# Simulate manual edit: set dns_servers to the pool's dnsmasq host (conN)
e2e_run "Set dns_servers manually" \
    "sed -i 's/^dns_servers=.*/dns_servers=$(pool_dns_server)/' aba.conf"

e2e_run "Copy vmware.conf" "cp -v ${VMWARE_CONF:-~/.vmware.conf} vmware.conf"
e2e_run "Set VC_FOLDER" \
    "sed -i 's#^VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER:-/Datacenter/vm/aba-e2e}#g' vmware.conf"

e2e_run "Set NTP servers" "aba --ntp $NTP_IP ntp.example.com"

test_end

# ============================================================================
# 2. Direct mode: unset proxy, create SNO config with -I direct
# ============================================================================
test_begin "Direct mode: create SNO config"

# True direct mode: bastion must not have proxy env vars set.
_saved_http_proxy="${http_proxy:-}"
_saved_https_proxy="${https_proxy:-}"
_saved_no_proxy="${no_proxy:-}"
unset http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY
[ -f ~/.proxy-unset.sh ] && source ~/.proxy-unset.sh

e2e_run "Verify proxy is unset" "test -z \"\${http_proxy:-}\" && echo 'proxy unset OK'"

e2e_run "Clean sno cluster dir" "rm -rf $SNO"
e2e_run "Create SNO config with -I direct" \
    "aba cluster -n $SNO -t sno -i $(pool_sno_ip) -I direct --step cluster.conf"
e2e_run "Generate agent config" "aba -d $SNO agentconf"

test_end

# ============================================================================
# 3. Direct mode: verify install-config.yaml content
# ============================================================================
test_begin "Direct mode: verify install-config.yaml"

# Direct mode should NOT have mirror/digest sources or proxy config
assert_file_exists "$SNO/install-config.yaml"
e2e_run "Verify no ImageDigestSources in direct mode" \
    "! grep ImageDigestSources $SNO/install-config.yaml"
e2e_run "Verify no imageContentSources in direct mode" \
    "! grep imageContentSources $SNO/install-config.yaml"
e2e_run "Verify no additionalTrustBundle in direct mode" \
    "! grep additionalTrustBundle $SNO/install-config.yaml"
e2e_run "Verify no proxy block in direct mode" \
    "! grep httpProxy $SNO/install-config.yaml"
e2e_run "Verify public registry references" \
    "grep registry.redhat.io $SNO/install-config.yaml || grep quay.io $SNO/install-config.yaml"

test_end

# ============================================================================
# 4. Proxy mode: restore proxy, create SNO config with -I proxy
# ============================================================================
test_begin "Proxy mode: create SNO config"

# Restore proxy environment for proxy mode tests
[ -f ~/.proxy-set.sh ] && source ~/.proxy-set.sh
if [ -z "${http_proxy:-}" ] && [ -n "$_saved_http_proxy" ]; then
    export http_proxy="$_saved_http_proxy"
    export https_proxy="$_saved_https_proxy"
    export no_proxy="$_saved_no_proxy"
fi

e2e_run "Verify proxy is set" "test -n \"\${http_proxy:-}\" && echo \"proxy set: \$http_proxy\""

e2e_run "Clean sno cluster dir" "rm -rf $SNO"
e2e_run "Create SNO config with -I proxy" \
    "aba cluster -n $SNO -t sno -i $(pool_sno_ip) -I proxy --step cluster.conf"
e2e_run "Generate agent config" "aba -d $SNO agentconf"

test_end

# ============================================================================
# 5. Proxy mode: verify install-config has proxy block
# ============================================================================
test_begin "Proxy mode: verify install-config.yaml"

assert_file_exists "$SNO/install-config.yaml"
e2e_run "Verify proxy block in proxy mode" \
    "grep httpProxy $SNO/install-config.yaml"
e2e_run "Verify httpsProxy in proxy mode" \
    "grep httpsProxy $SNO/install-config.yaml"
e2e_run "Verify noProxy in proxy mode" \
    "grep noProxy $SNO/install-config.yaml"
e2e_run "Verify no ImageDigestSources in proxy mode" \
    "! grep ImageDigestSources $SNO/install-config.yaml"

test_end

# ============================================================================
# 6. Proxy mode: install SNO cluster from public registry
# ============================================================================
test_begin "Proxy mode: install SNO cluster"

e2e_run "Install SNO from public registry (proxy mode)" \
    "aba -d $SNO install"

test_end

# ============================================================================
# 7. Proxy mode: verify and shutdown
# ============================================================================
test_begin "Proxy mode: verify and shutdown"

e2e_run "Show cluster operator status" "aba --dir $SNO run"
e2e_poll 600 30 "Wait for all operators fully available" \
    "aba --dir $SNO run | tail -n +2 | awk '{print \$3,\$4,\$5}' | tail -n +2 | grep -v '^True False False\$' | wc -l | grep ^0\$"
e2e_diag "Show cluster operators" "aba --dir $SNO run --cmd 'oc get co'"
e2e_run "Shutdown cluster" "yes | aba --dir $SNO shutdown --wait"

test_end

# ============================================================================
# 8. Direct+mirror mode: config verification (no proxy, uses mirror registry)
# ============================================================================
test_begin "Direct+mirror mode: config verification"

# Unset proxy to simulate a bastion with direct internet and a local mirror
unset http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY
[ -f ~/.proxy-unset.sh ] && source ~/.proxy-unset.sh

# Ensure the pre-populated pool registry is running on conN.
# setup-pool-registry.sh is idempotent: skips install/sync if already done.
_ocp_version=$(grep '^ocp_version=' aba.conf | cut -d= -f2 | awk '{print $1}')
_ocp_channel=$(grep '^ocp_channel=' aba.conf | cut -d= -f2 | awk '{print $1}')

e2e_run "Ensure pre-populated registry (OCP ${_ocp_channel} ${_ocp_version})" \
    "test/e2e/scripts/setup-pool-registry.sh --channel ${_ocp_channel} --version ${_ocp_version} --host ${CON_HOST}"

SNO_MIRROR="$(pool_cluster_name sno-mirror)"

e2e_run "Clean sno-mirror cluster dir" "rm -rf $SNO_MIRROR"

# Default int_connection (empty) = mirror mode.
# Create mirror.conf pointing at the pool registry on conN.
e2e_run "Create mirror.conf" "aba -d mirror mirror.conf"
e2e_run "Set reg_host to local registry" \
    "sed -i 's/^reg_host=.*/reg_host=${CON_HOST}/g' mirror/mirror.conf"
e2e_run "Clear reg_ssh_key (local registry)" \
    "sed -i 's/^reg_ssh_key=.*/reg_ssh_key=/g' mirror/mirror.conf"
e2e_run "Clear reg_ssh_user (local registry)" \
    "sed -i 's/^reg_ssh_user=.*/reg_ssh_user=/g' mirror/mirror.conf"

# Set up regcreds/ with the pre-populated registry's CA and pull secret
e2e_run "Create regcreds directory" "mkdir -p ~/.aba/mirror/mirror/"
e2e_run "Copy Quay root CA to regcreds" \
    "cp -v ~/quay-install/quay-rootCA/rootCA.pem ~/.aba/mirror/mirror/"
e2e_run "Copy pull secret from pool registry" \
    "cp -v ~/.e2e-pool-registry/quay-creds.json ~/.aba/mirror/mirror/pull-secret-mirror.json"

e2e_run "Verify mirror registry access" "aba -d mirror verify"

e2e_run "Create SNO config (mirror mode, no proxy)" \
    "aba cluster -n $SNO_MIRROR -t sno -i $(pool_sno_ip) --step cluster.conf"
e2e_run "Generate agent config" "aba -d $SNO_MIRROR agentconf"

# Verify: mirror sources present, no proxy block
assert_file_exists "$SNO_MIRROR/install-config.yaml"
e2e_run "Verify mirror sources in install-config" \
    "grep 'imageDigestSources\|ImageDigestSources\|imageContentSources' $SNO_MIRROR/install-config.yaml"
e2e_run "Verify no httpProxy in mirror+direct mode" \
    "! grep httpProxy $SNO_MIRROR/install-config.yaml"
e2e_run "Verify additionalTrustBundle present for mirror CA" \
    "grep additionalTrustBundle $SNO_MIRROR/install-config.yaml"

e2e_run "Clean up sno-mirror cluster dir" "rm -rf $SNO_MIRROR"

test_end

# ============================================================================
# 9. Proxy-only mode: verify aba works without direct internet route
# ============================================================================
test_begin "Proxy-only mode: verify without direct internet"

# Restore proxy
[ -f ~/.proxy-set.sh ] && source ~/.proxy-set.sh

# Block direct outbound HTTP/HTTPS (ports 80,443) while allowing proxy traffic.
# This simulates an enterprise bastion that can ONLY reach internet via proxy.
PROXY_IP="${http_proxy#http://}"
PROXY_IP="${PROXY_IP%%:*}"

e2e_run "Block direct internet (keep proxy)" \
    "sudo iptables -I OUTPUT -d $PROXY_IP -p tcp -j ACCEPT && \
     sudo iptables -A OUTPUT -p tcp --dport 443 -j DROP && \
     sudo iptables -A OUTPUT -p tcp --dport 80  -j DROP"

e2e_run "Verify direct curl fails" \
    "! curl --noproxy '*' --connect-timeout 5 -sk https://quay.io/v2/ 2>/dev/null"

e2e_run "Verify proxy curl works" \
    "curl --connect-timeout 10 -sk https://quay.io/v2/"

# Create a proxy-mode cluster config and verify it generates correctly
SNO_PROXY_ONLY="$(pool_cluster_name sno-proxyonly)"
e2e_run "Clean sno-proxyonly cluster dir" "rm -rf $SNO_PROXY_ONLY"
e2e_run "Create SNO config with -I proxy (proxy-only bastion)" \
    "aba cluster -n $SNO_PROXY_ONLY -t sno -i $(pool_sno_ip) -I proxy --step cluster.conf"

assert_file_exists "$SNO_PROXY_ONLY/cluster.conf"
e2e_run "Verify int_connection=proxy in cluster.conf" \
    "grep 'int_connection=proxy' $SNO_PROXY_ONLY/cluster.conf"

e2e_run "Clean up sno-proxyonly cluster dir" "rm -rf $SNO_PROXY_ONLY"

# Restore direct internet
e2e_run "Restore direct internet" \
    "sudo iptables -D OUTPUT -p tcp --dport 443 -j DROP; \
     sudo iptables -D OUTPUT -p tcp --dport 80  -j DROP; \
     sudo iptables -D OUTPUT -d $PROXY_IP -p tcp -j ACCEPT"

e2e_run "Verify direct curl restored" \
    "curl --noproxy '*' --connect-timeout 10 -sk https://quay.io/v2/"

test_end

# ============================================================================
# 10. no_proxy validation: verify aba scripts set no_proxy correctly
# ============================================================================
test_begin "no_proxy validation"

# Verify the bastion's no_proxy covers all required local addresses
e2e_run "Verify no_proxy includes localhost" \
    "echo \"\$no_proxy\" | grep localhost"
e2e_run "Verify no_proxy includes 127.0.0.1" \
    "echo \"\$no_proxy\" | grep '127.0.0.1'"
e2e_run "Verify no_proxy includes .example.com" \
    "echo \"\$no_proxy\" | grep '.example.com'"
e2e_run "Verify no_proxy includes 10.0.0.0/8 or broad local range" \
    "echo \"\$no_proxy\" | grep -E '10\\.0\\.0\\.0|10\\.0\\.' "

# Verify aba's monitor/wait scripts append rendezvous IP to no_proxy.
# Create a cluster dir and check agent-related scripts handle proxy correctly.
SNO_NOPROXY="$(pool_cluster_name sno-noproxy)"
e2e_run "Clean sno-noproxy cluster dir" "rm -rf $SNO_NOPROXY"
e2e_run "Create SNO config with -I proxy" \
    "aba cluster -n $SNO_NOPROXY -t sno -i $(pool_sno_ip) -I proxy --step cluster.conf"
e2e_run "Generate ISO (runs agent config + ISO validation)" "aba -d $SNO_NOPROXY iso"

# Verify rendezvousIP file is created and contains a valid IP
assert_file_exists "$SNO_NOPROXY/iso-agent-based/rendezvousIP"
e2e_run "Verify rendezvousIP is a valid IP" \
    "grep -E '^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+\$' $SNO_NOPROXY/iso-agent-based/rendezvousIP"

# Verify install-config noProxy includes essential exclusions
assert_file_exists "$SNO_NOPROXY/install-config.yaml"
e2e_run "Verify install-config noProxy includes node subnet or domain" \
    "grep -A5 'noProxy' $SNO_NOPROXY/install-config.yaml | grep -E '10\\.' || \
     grep -A5 'noProxy' $SNO_NOPROXY/install-config.yaml | grep example.com"

e2e_run "Clean up sno-noproxy cluster dir" "rm -rf $SNO_NOPROXY"

test_end

# ============================================================================

suite_end

echo "SUCCESS: suite-connected-public.sh"
