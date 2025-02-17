#!/bin/bash
set -euo pipefail

# This script bootstraps a new RKE2 cluster
# It should be run on the controller node

# Configuration
KUBE_CONFIG="$HOME/.kube/config"
LONGHORN_REPO_URL=${LONGHORN_REPO_URL:-"https://charts.longhorn.io"}
TRAEFIK_REPO_URL=${TRAEFIK_REPO_URL:-"https://helm.traefik.io/traefik"}
METALLB_VERSION=${METALLB_VERSION:-"v0.14.9"}

# Function for logging
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Redirect output to console and log file
exec > >(tee "script_output.log") 2>&1

# Initialize Kubernetes configuration
init_kube_config() {
    log "Initializing Kubernetes configuration..."
    mkdir -p "$HOME/.kube"
    
    if [ -f /etc/rancher/rke2/rke2.yaml ]; then
        sudo cp /etc/rancher/rke2/rke2.yaml "$KUBE_CONFIG"
        sudo chown "$(whoami)" "$KUBE_CONFIG"
        chmod 600 "$KUBE_CONFIG"
    else
        log "Error: RKE2 config not found"
        exit 1
    fi

    if ! grep -q "KUBECONFIG=$KUBE_CONFIG" "$HOME/.bashrc"; then
        echo "export KUBECONFIG=$KUBE_CONFIG" >> "$HOME/.bashrc"
        export KUBECONFIG=$KUBE_CONFIG
    fi
}

# Install required tools
install_tools() {
    log "Installing kubectl and helm via snap..."
    sudo snap install kubectl --classic
    sudo snap install helm --classic
}

# Install Longhorn
install_longhorn() {
    log "Installing Longhorn..."
    helm repo add longhorn "${LONGHORN_REPO_URL}"
    helm repo update
    
    kubectl create namespace longhorn-system --dry-run=client -o yaml | kubectl apply -f -
    
    helm upgrade --install longhorn longhorn/longhorn \
        --namespace longhorn-system \
        --create-namespace \
        --wait \
        --timeout 10m
    
    kubectl -n longhorn-system rollout status deploy/longhorn-driver-deployer --timeout=5m
}

# Install MetalLB
install_metallb() {
    log "Installing MetalLB..."
    kubectl apply -f "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml"
    
    # Wait for namespace to be ready
    kubectl wait --namespace metallb-system \
        --for=condition=ready pod \
        --selector=app=metallb \
        --timeout=90s

    # Create MetalLB configuration
    cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: first-pool
  namespace: metallb-system
spec:
  addresses:
  - <IP_RANGE>
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: advertise-first-pool
  namespace: metallb-system
EOF
}

# Install Traefik
install_traefik() {
    log "Installing Traefik..."
    helm repo add traefik "${TRAEFIK_REPO_URL}"
    helm repo update
    
    kubectl create namespace traefik --dry-run=client -o yaml | kubectl apply -f -
    
    helm upgrade --install traefik traefik/traefik \
        --namespace traefik \
        --wait \
        --timeout 5m
}

# Main execution
main() {
    log "Starting cluster bootstrap..."
    
    init_kube_config
    install_tools
    install_longhorn
    install_metallb
    install_traefik
    
    log "Cluster bootstrap completed successfully"
}

# Execute main function
main