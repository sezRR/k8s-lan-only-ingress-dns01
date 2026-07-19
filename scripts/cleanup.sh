#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TRAEFIK_CRDS="$ROOT_DIR/k8s/traefik-crds"
LEGACY_INGRESS_NGINX_VERSION="controller-v1.15.1"
LEGACY_INGRESS_NGINX_MANIFEST="https://raw.githubusercontent.com/kubernetes/ingress-nginx/${LEGACY_INGRESS_NGINX_VERSION}/deploy/static/provider/cloud/deploy.yaml"
CERT_MANAGER_VERSION="v1.21.0"
CERT_MANAGER_MANIFEST="https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "Required command not found: kubectl" >&2
  exit 1
fi

if [[ "$(kubectl config current-context)" != "orbstack" ]]; then
  echo "Refusing to delete resources outside the orbstack kubectl context." >&2
  exit 1
fi

echo "Removing the demo and allowing cert-manager to clean up active DNS challenges..."
if kubectl get certificate frontends --namespace ingress-demo >/dev/null 2>&1; then
  kubectl delete certificate frontends \
    --namespace ingress-demo \
    --cascade=foreground \
    --wait=true \
    --timeout=180s
fi
if kubectl get customresourcedefinition challenges.acme.cert-manager.io >/dev/null 2>&1; then
  kubectl delete challenges.acme.cert-manager.io \
    --all \
    --namespace ingress-demo \
    --ignore-not-found \
    --wait=true \
    --timeout=180s
fi
kubectl delete namespace ingress-demo --ignore-not-found --wait=true --timeout=180s
if command -v helm >/dev/null 2>&1 && helm status traefik --namespace traefik >/dev/null 2>&1; then
  helm uninstall traefik --namespace traefik --wait --timeout=180s
fi
kubectl delete namespace traefik --ignore-not-found --wait=true --timeout=180s
kubectl delete -k "$TRAEFIK_CRDS" --ignore-not-found --wait=true --timeout=180s
kubectl delete -f "$LEGACY_INGRESS_NGINX_MANIFEST" --ignore-not-found --wait=true --timeout=180s
kubectl delete -f "$CERT_MANAGER_MANIFEST" --ignore-not-found --wait=true --timeout=180s
kubectl delete lease \
  cert-manager-cainjector-leader-election \
  cert-manager-cainjector-leader-election-core \
  cert-manager-controller \
  --namespace kube-system \
  --ignore-not-found

echo
echo "Local resources are removed. Delete the router DNS records and revoke the"
echo "scoped Cloudflare API token to remove the remaining external configuration."
