#!/bin/bash
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

e2e_run "Copy vmware.conf" "cp -v ${VMWARE_CONF:-~/.vmware.conf} vmware.conf"
e2e_run "Set VC_FOLDER" \
    "sed -i 's#^VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER:-/Datacenter/vm/abatesting}#g' vmware.conf"

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

e2e_run "Clean sno dir" "rm -rfv $SNO"
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
    "! grep -q ImageDigestSources $SNO/install-config.yaml"
e2e_run "Verify no imageContentSources in direct mode" \
    "! grep -q imageContentSources $SNO/install-config.yaml"
e2e_run "Verify no additionalTrustBundle in direct mode" \
    "! grep -q additionalTrustBundle $SNO/install-config.yaml"
e2e_run "Verify no proxy block in direct mode" \
    "! grep -q httpProxy $SNO/install-config.yaml"
e2e_run "Verify public registry references" \
    "grep -q registry.redhat.io $SNO/install-config.yaml || grep -q quay.io $SNO/install-config.yaml"

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

e2e_run "Clean sno dir" "rm -rfv $SNO"
e2e_run "Create SNO config with -I proxy" \
    "aba cluster -n $SNO -t sno -i $(pool_sno_ip) -I proxy --step cluster.conf"

test_end

# ============================================================================
# 5. Proxy mode: verify install-config has proxy block
# ============================================================================
test_begin "Proxy mode: verify install-config.yaml"

assert_file_exists "$SNO/install-config.yaml"
e2e_run "Verify proxy block in proxy mode" \
    "grep -q httpProxy $SNO/install-config.yaml"
e2e_run "Verify httpsProxy in proxy mode" \
    "grep -q httpsProxy $SNO/install-config.yaml"
e2e_run "Verify noProxy in proxy mode" \
    "grep -q noProxy $SNO/install-config.yaml"
e2e_run "Verify no ImageDigestSources in proxy mode" \
    "! grep -q ImageDigestSources $SNO/install-config.yaml"

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

e2e_run "Verify cluster operators" "aba --dir $SNO run"
e2e_run -r 30 10 "Wait for all operators fully available" \
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

SNO_MIRROR="$(pool_cluster_name sno-mirror)"

e2e_run "Clean sno-mirror dir" "rm -rfv $SNO_MIRROR"

# Default int_connection (empty) = mirror mode.
# Create mirror.conf pointing at the pool registry so aba generates mirror sources.
e2e_run "Create mirror.conf" "aba -d mirror mirror.conf"
e2e_run "Set mirror host to pool registry" \
    "sed -i \"s/registry.example.com/$(pool_registry_host)/g\" mirror/mirror.conf"

e2e_run "Create SNO config (mirror mode, no proxy)" \
    "aba cluster -n $SNO_MIRROR -t sno -i $(pool_sno_ip) --step cluster.conf"
e2e_run "Generate agent config" "aba -d $SNO_MIRROR agentconf"

# Verify: mirror sources present, no proxy block
assert_file_exists "$SNO_MIRROR/install-config.yaml"
e2e_run "Verify mirror sources in install-config" \
    "grep -q 'imageDigestSources\|ImageDigestSources\|imageContentSources' $SNO_MIRROR/install-config.yaml"
e2e_run "Verify no httpProxy in mirror+direct mode" \
    "! grep -q httpProxy $SNO_MIRROR/install-config.yaml"
e2e_run "Verify additionalTrustBundle present for mirror CA" \
    "grep -q additionalTrustBundle $SNO_MIRROR/install-config.yaml"

e2e_run "Clean up sno-mirror dir" "rm -rfv $SNO_MIRROR"

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
e2e_run "Clean sno-proxyonly dir" "rm -rfv $SNO_PROXY_ONLY"
e2e_run "Create SNO config with -I proxy (proxy-only bastion)" \
    "aba cluster -n $SNO_PROXY_ONLY -t sno -i $(pool_sno_ip) -I proxy --step cluster.conf"

assert_file_exists "$SNO_PROXY_ONLY/cluster.conf"
e2e_run "Verify int_connection=proxy in cluster.conf" \
    "grep -q 'int_connection=proxy' $SNO_PROXY_ONLY/cluster.conf"

e2e_run "Clean up sno-proxyonly dir" "rm -rfv $SNO_PROXY_ONLY"

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
    "echo \"\$no_proxy\" | grep -q localhost"
e2e_run "Verify no_proxy includes 127.0.0.1" \
    "echo \"\$no_proxy\" | grep -q '127.0.0.1'"
e2e_run "Verify no_proxy includes .example.com" \
    "echo \"\$no_proxy\" | grep -q '.example.com'"
e2e_run "Verify no_proxy includes 10.0.0.0/8 or broad local range" \
    "echo \"\$no_proxy\" | grep -qE '10\\.0\\.0\\.0|10\\.0\\.' "

# Verify aba's monitor/wait scripts append rendezvous IP to no_proxy.
# Create a cluster dir and check agent-related scripts handle proxy correctly.
SNO_NOPROXY="$(pool_cluster_name sno-noproxy)"
e2e_run "Clean sno-noproxy dir" "rm -rfv $SNO_NOPROXY"
e2e_run "Create SNO config with -I proxy" \
    "aba cluster -n $SNO_NOPROXY -t sno -i $(pool_sno_ip) -I proxy --step cluster.conf"
e2e_run "Generate agent config" "aba -d $SNO_NOPROXY agentconf"

# Verify rendezvousIP file is created and contains a valid IP
assert_file_exists "$SNO_NOPROXY/iso-agent-based/rendezvousIP"
e2e_run "Verify rendezvousIP is a valid IP" \
    "grep -qE '^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+\$' $SNO_NOPROXY/iso-agent-based/rendezvousIP"

# Verify install-config noProxy includes essential exclusions
e2e_run "Verify install-config noProxy includes node subnet" \
    "grep -A5 'noProxy' $SNO_NOPROXY/install-config.yaml | grep -qE '10\\.' || \
     grep -A5 'noProxy' $SNO_NOPROXY/install-config.yaml | grep -q example.com"

e2e_run "Clean up sno-noproxy dir" "rm -rfv $SNO_NOPROXY"

test_end

# ============================================================================

suite_end

echo "SUCCESS: suite-connected-public.sh"
