#!/bin/bash
# fix-sno-quick.sh - Quick SNO recovery after boot
# Run this EVERY TIME you start your SNO after it's been off for >20 hours.
# Takes ~60 seconds + a few minutes for pods to come up.
#
# Usage: ./fix-sno-quick.sh [ssh-host]
#   ssh-host: SSH target for the SNO node (default: core@openshift-cluster)

set -euo pipefail

SSH_HOST="${1:-core@openshift-cluster}"
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; }

echo "=========================================="
echo "  SNO Quick Recovery - Boot-time Fix"
echo "=========================================="
echo ""

# Step 1: Check if cert is actually expired
warn "Checking kubelet client certificate..."
CERT_DATES=$(ssh "$SSH_HOST" "sudo openssl x509 -noout -enddate -in /var/lib/kubelet/pki/kubelet-client-current.pem 2>/dev/null" || echo "MISSING")

if [[ "$CERT_DATES" == "MISSING" ]]; then
    warn "Certificate file not found - kubelet may already be bootstrapping."
else
    EXPIRY=$(echo "$CERT_DATES" | sed 's/notAfter=//')
    EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$EXPIRY" +%s 2>/dev/null || echo "0")
    NOW_EPOCH=$(date +%s)

    if [[ "$EXPIRY_EPOCH" -gt "$NOW_EPOCH" ]]; then
        info "Certificate is still valid (expires: $EXPIRY)"
        echo ""
        info "Your cluster might not need recovery. Check with:"
        echo "  oc get nodes"
        echo "  oc get clusteroperators | grep -v 'True.*False.*False'"
        echo ""
        read -p "Continue anyway? (y/N): " CONTINUE
        [[ "$CONTINUE" =~ ^[Yy]$ ]] || exit 0
    else
        warn "Certificate expired: $EXPIRY"
    fi
fi

# Step 2: Remove expired cert and restart kubelet
echo ""
info "Removing expired kubelet client certificate..."
ssh "$SSH_HOST" "sudo rm -f /var/lib/kubelet/pki/kubelet-client-current.pem"

info "Restarting kubelet..."
ssh "$SSH_HOST" "sudo systemctl restart kubelet"

# Step 3: Wait for kubelet to generate a CSR
echo ""
info "Waiting for CSR to appear (up to 60 seconds)..."
for i in $(seq 1 12); do
    PENDING=$(oc get csr 2>/dev/null | grep -c Pending || true)
    if [[ "$PENDING" -gt 0 ]]; then
        info "Found $PENDING pending CSR(s)!"
        break
    fi
    sleep 5
done

# Step 4: Approve CSRs - first round (client cert)
echo ""
info "Approving pending CSRs (round 1 - client cert)..."
oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' 2>/dev/null | xargs --no-run-if-empty oc adm certificate approve 2>/dev/null || warn "No CSRs to approve in round 1"

# Step 5: Wait and approve again (serving cert)
info "Waiting 30 seconds for serving CSR..."
sleep 30

info "Approving pending CSRs (round 2 - serving cert)..."
oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' 2>/dev/null | xargs --no-run-if-empty oc adm certificate approve 2>/dev/null || warn "No CSRs to approve in round 2"

# Step 6: Verify node is Ready
echo ""
info "Waiting for node to become Ready (up to 90 seconds)..."
for i in $(seq 1 18); do
    STATUS=$(oc get nodes --no-headers 2>/dev/null | awk '{print $2}' || echo "Unknown")
    if [[ "$STATUS" == "Ready" ]]; then
        info "Node is Ready!"
        break
    fi
    if [[ "$i" -eq 18 ]]; then
        error "Node still not Ready after 90 seconds. Run the full recovery script."
        exit 1
    fi
    sleep 5
done

# Step 7: Wait for operators
echo ""
info "Cluster is recovering. Waiting for operators (this takes 5-10 minutes)..."
echo "  Monitor with: watch \"oc get clusteroperators | grep -v 'True.*False.*False'\""
echo ""
info "Done! If operators are still unhealthy after 10 minutes, run fix-sno-full.sh"
