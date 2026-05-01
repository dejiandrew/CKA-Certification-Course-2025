#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-learning}"
INGRESS_YAML_LOCAL="/tmp/ingress-nginx.yaml"
INGRESS_YAML_URL="https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml"

# Images and their digests (as referenced by the ingress YAML).
# Pre-loaded into KIND nodes for offline support.
# Format: "image:tag|sha256:digest"
INGRESS_IMAGES=(
  "registry.k8s.io/ingress-nginx/controller:v1.15.1|sha256:594ceea76b01c592858f803f9ff4d2cb40542cae2060410b2c95f75907d659e1"
  "registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.6.9|sha256:01038e7de14b78d702d2849c3aad72fd25903c4765af63cf16aa3398f5d5f2dd"
)

echo "🐳 Waiting for Docker..."
until docker info >/dev/null 2>&1; do sleep 1; done

# Idempotent: skip creation if cluster already exists
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "✅ Cluster '${CLUSTER_NAME}' already exists"
else
  echo "🚀 Creating KIND cluster..."
  kind create cluster \
    --name "${CLUSTER_NAME}" \
    --config .devcontainer/kind-config.yaml \
    --wait 5m
fi

# Pre-load cached images into KIND nodes for offline support.
# Bypasses `kind load` (which uses --all-platforms and chokes on multi-arch manifests)
# and additionally registers digest references so pods that pin by digest find local images.
load_image_offline() {
  local image_tag="${1%%|*}"
  local digest="${1##*|}"
  local image_name="${image_tag%:*}"
  local tar="/tmp/$(echo "$image_tag" | tr '/:' '__').tar"

  if ! docker image inspect "$image_tag" >/dev/null 2>&1; then
    return 0  # not cached, online flow will pull it
  fi

  echo "📦 Loading $image_tag into KIND..."
  if [ ! -f "$tar" ]; then
    docker save "$image_tag" -o "$tar"
  fi
  for node in $(kind get nodes --name "${CLUSTER_NAME}"); do
    docker exec -i "$node" ctr --namespace=k8s.io images import --digests --snapshotter=overlayfs - < "$tar" >/dev/null
    # Register the digest reference so pods pinning by @sha256:... find the image locally
    docker exec "$node" ctr --namespace=k8s.io images tag --force \
      "$image_tag" "${image_name}@${digest}" >/dev/null 2>&1 || true
  done
}

for entry in "${INGRESS_IMAGES[@]}"; do
  load_image_offline "$entry"
done

# Install ingress-nginx if not already there
if ! kubectl get ns ingress-nginx >/dev/null 2>&1; then
  echo "🌐 Installing NGINX Ingress..."
  if [ -f "${INGRESS_YAML_LOCAL}" ]; then
    kubectl apply -f "${INGRESS_YAML_LOCAL}"
  else
    kubectl apply -f "${INGRESS_YAML_URL}"
  fi
  kubectl wait --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=300s
fi

# Optional: install k9s (online only — silently skips if no internet)
if ! command -v k9s >/dev/null; then
  curl -sS https://webi.sh/k9s | sh >/dev/null 2>&1 || true
fi

echo ""
echo "🎉 Ready. Try: kubectl get nodes"
