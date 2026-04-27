#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-learning}"

echo "🐳 Waiting for Docker..."
until docker info >/dev/null 2>&1; do sleep 1; done

# Idempotent: skip creation if cluster already exists (for codespace restarts)
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "✅ Cluster '${CLUSTER_NAME}' already exists"
else
  echo "🚀 Creating KIND cluster..."
  kind create cluster \
    --name "${CLUSTER_NAME}" \
    --config .devcontainer/kind-config.yaml \
    --wait 5m
fi

# Install ingress-nginx if not already there
if ! kubectl get ns ingress-nginx >/dev/null 2>&1; then
  echo "🌐 Installing NGINX Ingress..."
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
  kubectl wait --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=300s
fi

# Optional: install k9s (nice TUI for poking around)
if ! command -v k9s >/dev/null; then
  curl -sS https://webi.sh/k9s | sh >/dev/null 2>&1 || true
fi

echo ""
echo "🎉 Ready. Try: kubectl get nodes"