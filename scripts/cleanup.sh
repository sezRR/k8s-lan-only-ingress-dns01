#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
INGRESS_NGINX_VERSION="controller-v1.15.1"
INGRESS_NGINX_MANIFEST="https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/cloud/deploy.yaml"
CERT_MANAGER_VERSION="v1.21.0"
CERT_MANAGER_MANIFEST="https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"

if [[ "$(kubectl config current-context)" != "orbstack" ]]; then
  echo "Refusing to delete resources outside the orbstack kubectl context." >&2
  exit 1
fi

echo "Removing the demo and allowing cert-manager to clean up active DNS challenges..."
kubectl delete -k "$ROOT_DIR" --ignore-not-found --wait=true --timeout=180s
kubectl delete -f "$INGRESS_NGINX_MANIFEST" --ignore-not-found --wait=true --timeout=180s
kubectl delete -f "$CERT_MANAGER_MANIFEST" --ignore-not-found --wait=true --timeout=180s

echo
echo "Local resources are removed. Delete the two router DNS records and revoke the"
echo "scoped Cloudflare API token to remove the remaining external configuration."
