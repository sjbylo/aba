#!/bin/bash -e
# Open an interactive bash session logged into the cluster.
# Sets KUBECONFIG, runs oc login, enables bash completion for oc,
# and drops into an interactive shell with a cluster-aware PS1.

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

source <(normalize-aba-conf)
source <(normalize-cluster-conf)

ensure_oc

# Resolve kubeconfig
_kc=$(cluster_kubeconfig 2>/dev/null)
[ -z "$_kc" ] && _kc="$PWD/iso-agent-based/auth/kubeconfig"
[ ! -f "$_kc" ] && aba_abort "No kubeconfig found. Is the cluster installed?"

# Cluster display name
_cl_display="${cluster_name}.${base_domain}"

# Use a throwaway copy so oc-login tokens don't contaminate the original kubeconfig
_tmp_kc=$(mktemp /tmp/.aba-kubeconfig-XXXXXX)
cp "$_kc" "$_tmp_kc"
export KUBECONFIG="$_tmp_kc"

echo "═══════════════════════════════════════════════════════════════"
echo "  Cluster Terminal: $_cl_display"
echo "  Type 'exit' or Ctrl-D to return"
echo "═══════════════════════════════════════════════════════════════"
echo

# Attempt oc login with retries (cluster may still be starting up)
_login_ok=false
for _try in 1 2; do
	if scripts/show-cluster-login.sh 2>/dev/null | bash >/dev/null 2>&1; then
		_login_ok=true
		break
	fi
	if [ $_try -lt 2 ]; then
		aba_info "Cluster API not ready — retrying in 10s ..."
		sleep 10
	fi
done

if [ "$_login_ok" != "true" ]; then
	# Login failed — try shell-only mode (KUBECONFIG without oc login)
	if cluster_api_reachable "$_tmp_kc" 2>/dev/null; then
		aba_warn "Could not log in as kubeadmin, but cluster API is reachable."
		aba_info "Entering shell with KUBECONFIG set — authenticate manually (oc login)."
	else
		echo
		aba_info "Error: Could not connect to cluster. The cluster may be shut down or still starting up."
		rm -f "$_tmp_kc"
		exit 1
	fi
fi
echo

# Build rcfile for the interactive shell
_rcfile=$(mktemp /tmp/.aba-rcfile-XXXXXX)
cat > "$_rcfile" <<-'RCEOF'
[ -f /etc/bashrc ] && source /etc/bashrc
[ -f /usr/share/bash-completion/bash_completion ] && source /usr/share/bash-completion/bash_completion
_oc_ns() { oc config view --minify -o jsonpath='{..namespace}' 2>/dev/null; }
source <(oc completion bash 2>/dev/null) 2>/dev/null
RCEOF
echo "PS1='[$_cl_display|\$(_oc_ns)] "'\$ '"'" >> "$_rcfile"
echo "trap 'rm -f $_rcfile $_tmp_kc' EXIT" >> "$_rcfile"

exec bash --rcfile "$_rcfile" -i
