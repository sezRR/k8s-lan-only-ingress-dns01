#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
INGRESS_NGINX_VERSION="controller-v1.15.1"
INGRESS_NGINX_MANIFEST="https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/cloud/deploy.yaml"
CERT_MANAGER_VERSION="v1.21.0"
CERT_MANAGER_MANIFEST="https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"

if [[ "$(kubectl config current-context)" != "orbstack" ]]; then
  echo "Refusing to deploy outside the orbstack kubectl context." >&2
  exit 1
fi

kubectl get nodes >/dev/null

echo "Installing ingress-nginx ${INGRESS_NGINX_VERSION}..."
kubectl apply -f "$INGRESS_NGINX_MANIFEST"
kubectl wait \
  --namespace ingress-nginx \
  --for=condition=Available \
  deployment/ingress-nginx-controller \
  --timeout=180s
kubectl wait \
  --namespace ingress-nginx \
  --for=jsonpath='{.endpoints[0].addresses[0]}' \
  endpointslice \
  --selector=kubernetes.io/service-name=ingress-nginx-controller-admission \
  --timeout=60s

if ! kubectl get deployment cert-manager --namespace cert-manager >/dev/null 2>&1; then
  echo "Installing cert-manager ${CERT_MANAGER_VERSION}..."
  kubectl apply -f "$CERT_MANAGER_MANIFEST"
else
  echo "cert-manager ${CERT_MANAGER_VERSION} is already installed."
fi
kubectl wait \
  --namespace cert-manager \
  --for=condition=Available \
  deployment \
  --all \
  --timeout=180s

CERT_MANAGER_ARGS="$(kubectl get deployment cert-manager \
  --namespace cert-manager \
  -o jsonpath='{.spec.template.spec.containers[0].args}')"
CERT_MANAGER_PATCHED=false

if [[ "$CERT_MANAGER_ARGS" != *"--dns01-recursive-nameservers-only"* ]]; then
  kubectl patch deployment cert-manager \
    --namespace cert-manager \
    --type=json \
    --patch='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--dns01-recursive-nameservers-only"}]'
  CERT_MANAGER_PATCHED=true
fi

if [[ "$CERT_MANAGER_ARGS" != *"--dns01-recursive-nameservers=1.1.1.1:53,8.8.8.8:53"* ]]; then
  kubectl patch deployment cert-manager \
    --namespace cert-manager \
    --type=json \
    --patch='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--dns01-recursive-nameservers=1.1.1.1:53,8.8.8.8:53"}]'
  CERT_MANAGER_PATCHED=true
fi

if [[ "$CERT_MANAGER_PATCHED" == "true" ]]; then
  kubectl rollout status deployment/cert-manager \
    --namespace cert-manager \
    --timeout=180s
fi

kubectl apply -f "$ROOT_DIR/k8s/namespace.yaml"

if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]] && ! kubectl get secret cloudflare-api-token --namespace ingress-demo >/dev/null 2>&1; then
  if [[ ! -t 0 ]]; then
    echo "Set CLOUDFLARE_API_TOKEN or run this script in an interactive terminal." >&2
    exit 1
  fi

  read -r -s -p "Cloudflare API token: " CLOUDFLARE_API_TOKEN
  echo
fi

if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  export -n CLOUDFLARE_API_TOKEN
  printf '%s' "$CLOUDFLARE_API_TOKEN" | kubectl create secret generic cloudflare-api-token \
    --namespace ingress-demo \
    --from-file="api-token=/dev/stdin" \
    --dry-run=client \
    -o yaml | kubectl apply -f -
  unset CLOUDFLARE_API_TOKEN
fi

kubectl apply -k "$ROOT_DIR"
kubectl rollout status deployment/frontend-1 --namespace ingress-demo --timeout=180s
kubectl rollout status deployment/frontend-2 --namespace ingress-demo --timeout=180s
kubectl wait \
  --namespace ingress-demo \
  --for=condition=Ready \
  issuer/letsencrypt-cloudflare \
  --timeout=180s
kubectl wait \
  --namespace ingress-demo \
  --for=condition=Ready \
  certificate/frontends \
  --timeout=300s

INGRESS_IP="$(kubectl get service ingress-nginx-controller \
  --namespace ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"

echo
echo "Deployment is ready. Ingress IP: ${INGRESS_IP:-not assigned yet}"
echo "See README.md for the LAN-only DNS records required by devices on your network."
