#!/bin/bash
# fix-sno-full.sh - Full SNO recovery after prolonged cert expiry
# Use this when the cluster has been RUNNING with expired certs and
# the quick fix alone isn't enough (pods have stale tokens, 401 errors, etc.)
#
# This automates everything we did to recover:
#   1. Fix kubelet cert + approve CSRs
#   2. Bounce networking pods (Multus, OVN)
#   3. Restart kube-apiserver static pod
#   4. Restart openshift/oauth apiservers
#   5. Restart router
#   6. Verify recovery
#
# Usage: ./fix-sno-full.sh [ssh-host]
#   ssh-host: SSH target for the SNO node (default: core@openshift-cluster)

set -euo pipefail

SSH_HOST="${1:-core@openshift-cluster}"
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; }
step()  { echo -e "\n${BLUE}--- $1 ---${NC}"; }

approve_csrs() {
    local approved
    approved=$(oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' 2>/dev/null | xargs --no-run-if-empty oc adm certificate approve 2>/dev/null || true)
    if [[ -n "$approved" ]]; then
        info "Approved CSRs"
    fi
}

wait_for_pods() {
    local namespace="$1"
    local timeout="${2:-120}"
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        local not_ready
        not_ready=$(oc get pods -n "$namespace" --no-headers 2>/dev/null | grep -cv "Running\|Completed" || true)
        if [[ "$not_ready" -eq 0 ]]; then
            return 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done
    return 1
}

echo "============================================"
echo "  SNO Full Recovery - Deep Fix"
echo "============================================"
echo ""
warn "This script performs a full cluster recovery."
warn "It will restart networking, API servers, and the router."
echo ""
read -p "Continue? (y/N): " CONTINUE
[[ "$CONTINUE" =~ ^[Yy]$ ]] || exit 0

# --------------------------------------------
step "Step 1/7: Fix kubelet certificate"
# --------------------------------------------

CERT_DATES=$(ssh "$SSH_HOST" "sudo openssl x509 -noout -dates -in /var/lib/kubelet/pki/kubelet-client-current.pem 2>/dev/null" || echo "MISSING")
echo "  Current cert: $CERT_DATES"

info "Removing kubelet client certificate..."
ssh "$SSH_HOST" "sudo rm -f /var/lib/kubelet/pki/kubelet-client-current.pem"

info "Restarting kubelet..."
ssh "$SSH_HOST" "sudo systemctl restart kubelet"

info "Waiting for CSRs..."
sleep 15

# --------------------------------------------
step "Step 2/7: Approve CSRs"
# --------------------------------------------

# Try multiple rounds to catch both client and serving CSRs
for round in 1 2 3 4; do
    approve_csrs
    sleep 15
done

# Verify node is Ready
info "Checking node status..."
for i in $(seq 1 18); do
    STATUS=$(oc get nodes --no-headers 2>/dev/null | awk '{print $2}' || echo "Unknown")
    if [[ "$STATUS" == "Ready" ]]; then
        info "Node is Ready!"
        break
    fi
    if [[ "$i" -eq 18 ]]; then
        error "Node still not Ready. Check manually with: oc get nodes"
        error "You may need to run 'oc get csr | grep Pending' and approve manually."
        exit 1
    fi
    sleep 5
done

# --------------------------------------------
step "Step 3/7: Restart networking pods"
# --------------------------------------------

info "Restarting OVN pods..."
oc delete pod -n openshift-ovn-kubernetes --all --grace-period=0 --force 2>/dev/null || true

info "Restarting Multus pods..."
# Only restart the running daemonset pods (not the admission controller deployment)
for pod in $(oc get pods -n openshift-multus --no-headers 2>/dev/null | grep Running | awk '{print $1}'); do
    oc delete pod -n openshift-multus "$pod" --grace-period=0 --force 2>/dev/null || true
done

info "Waiting for networking to stabilize (60 seconds)..."
sleep 60

# Check if OVN is up
if wait_for_pods openshift-ovn-kubernetes 120; then
    info "OVN pods are running"
else
    warn "OVN pods may still be starting..."
fi

# --------------------------------------------
step "Step 4/7: Restart kube-apiserver static pod"
# --------------------------------------------

info "Restarting kube-apiserver (brief API downtime expected)..."
ssh "$SSH_HOST" "sudo crictl pods --name kube-apiserver -q | xargs sudo crictl stopp 2>/dev/null; sudo crictl pods --name kube-apiserver -q | xargs sudo crictl rmp 2>/dev/null" || true

info "Waiting for kube-apiserver to come back (up to 90 seconds)..."
sleep 15
for i in $(seq 1 15); do
    if oc get nodes &>/dev/null; then
        info "kube-apiserver is back!"
        break
    fi
    sleep 5
done

# Also restart kube-controller-manager to refresh CA bundles
info "Restarting kube-controller-manager..."
ssh "$SSH_HOST" "sudo crictl pods --name kube-controller-manager -q | xargs sudo crictl stopp 2>/dev/null; sudo crictl pods --name kube-controller-manager -q | xargs sudo crictl rmp 2>/dev/null" || true
sleep 15

# --------------------------------------------
step "Step 5/7: Restart OpenShift API servers"
# --------------------------------------------

info "Restarting openshift-apiserver pods..."
oc delete pods --all -n openshift-apiserver --grace-period=0 --force 2>/dev/null || true

info "Restarting openshift-oauth-apiserver pods..."
oc delete pods --all -n openshift-oauth-apiserver --grace-period=0 --force 2>/dev/null || true

info "Restarting openshift-controller-manager pods..."
oc delete pods --all -n openshift-controller-manager --grace-period=0 --force 2>/dev/null || true

info "Restarting authentication pods..."
oc delete pods --all -n openshift-authentication --grace-period=0 --force 2>/dev/null || true

info "Waiting for API servers to come up (120 seconds)..."
sleep 120

# --------------------------------------------
step "Step 6/7: Restart router and console"
# --------------------------------------------

info "Restarting router..."
oc delete pods --all -n openshift-ingress --grace-period=0 --force 2>/dev/null || true

info "Restarting console..."
oc delete pods --all -n openshift-console --grace-period=0 --force 2>/dev/null || true

info "Waiting for router and console (60 seconds)..."
sleep 60

# --------------------------------------------
step "Step 7/7: Verify cluster health"
# --------------------------------------------

echo ""
info "Node status:"
oc get nodes 2>/dev/null || error "Cannot reach API server"

echo ""
info "Unhealthy operators:"
UNHEALTHY=$(oc get clusteroperators 2>/dev/null | grep -v "True.*False.*False" | grep -v "^NAME" || true)
if [[ -z "$UNHEALTHY" ]]; then
    echo -e "${GREEN}  All operators healthy!${NC}"
else
    echo "$UNHEALTHY"
    echo ""
    warn "Some operators are still recovering. This is normal - give it 5 more minutes."
    echo "  Monitor with: watch \"oc get clusteroperators | grep -v 'True.*False.*False'\""
fi

echo ""
info "Remaining non-running pods:"
NOT_RUNNING=$(oc get pods -A --no-headers 2>/dev/null | grep -cv "Running\|Completed" || true)
echo "  $NOT_RUNNING pods not yet running"

echo ""
echo "============================================"
info "Recovery complete!"
echo "  If the web console shows an auth error,"
echo "  try an incognito/private browser window."
echo "============================================"
