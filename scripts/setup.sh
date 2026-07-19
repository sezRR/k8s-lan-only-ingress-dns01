#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TRAEFIK_CHART_VERSION="41.0.2"
TRAEFIK_CHART_REPOSITORY="https://traefik.github.io/charts"
TRAEFIK_CRDS="$ROOT_DIR/k8s/traefik-crds"
INGRESS_NGINX_VERSION="controller-v1.15.1"
INGRESS_NGINX_MANIFEST="https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/cloud/deploy.yaml"
CERT_MANAGER_VERSION="v1.21.0"
CERT_MANAGER_MANIFEST="https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"

export -n CLOUDFLARE_API_TOKEN TRAEFIK_DASHBOARD_USERNAME TRAEFIK_DASHBOARD_PASSWORD

for command in kubectl sed; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required command not found: $command" >&2
    exit 1
  fi
done

if [[ "$(kubectl config current-context)" != "orbstack" ]]; then
  echo "Refusing to deploy outside the orbstack kubectl context." >&2
  exit 1
fi

kubectl get nodes >/dev/null

if [[ -z "${BASE_DOMAIN:-}" ]]; then
  if [[ ! -t 0 ]]; then
    echo "Set BASE_DOMAIN or run this script in an interactive terminal." >&2
    exit 1
  fi

  read -r -p "Cloudflare base domain: " BASE_DOMAIN
fi

if (( ${#BASE_DOMAIN} > 237 )) || [[ ! "$BASE_DOMAIN" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
  echo "BASE_DOMAIN must be a valid lowercase DNS name." >&2
  exit 1
fi

if [[ "$BASE_DOMAIN" =~ (^|\.)example\.(com|net|org)$ ]]; then
  echo "BASE_DOMAIN must be a domain you control, not a reserved example domain." >&2
  exit 1
fi

if [[ -z "${INGRESS_CONTROLLER:-}" ]]; then
  if [[ ! -t 0 ]]; then
    echo "Set INGRESS_CONTROLLER to traefik or nginx, or run this script interactively." >&2
    exit 1
  fi

  read -r -p "Ingress controller [traefik/nginx] (default: traefik): " INGRESS_CONTROLLER
  INGRESS_CONTROLLER="${INGRESS_CONTROLLER:-traefik}"
fi

case "$INGRESS_CONTROLLER" in
  traefik)
    for command in helm htpasswd; do
      if ! command -v "$command" >/dev/null 2>&1; then
        echo "Required command for Traefik not found: $command" >&2
        if [[ "$command" == "helm" ]]; then
          echo "Install Helm with: brew install helm" >&2
        fi
        exit 1
      fi
    done

    if kubectl get namespace ingress-nginx >/dev/null 2>&1; then
      echo "ingress-nginx is installed. Run ./scripts/cleanup.sh before switching to Traefik." >&2
      exit 1
    fi
    ;;
  nginx)
    if kubectl get namespace traefik >/dev/null 2>&1; then
      echo "Traefik is installed. Run ./scripts/cleanup.sh before switching to ingress-nginx." >&2
      exit 1
    fi

    echo "WARNING: ingress-nginx is retired and no longer receives security fixes." >&2
    echo "Its upstream manifest also grants cluster-wide Secret read access; use a dedicated trusted cluster." >&2
    echo "Traefik is recommended for new deployments." >&2
    if [[ -t 0 ]]; then
      read -r -p "Continue with ingress-nginx? [y/N]: " NGINX_CONFIRMATION
      if [[ "$NGINX_CONFIRMATION" != "y" && "$NGINX_CONFIRMATION" != "Y" ]]; then
        echo "Deployment cancelled." >&2
        exit 1
      fi
      unset NGINX_CONFIRMATION
    fi
    ;;
  *)
    echo "INGRESS_CONTROLLER must be either traefik or nginx." >&2
    exit 1
    ;;
esac

DEPLOYED_BASE_DOMAIN="$(kubectl get namespace ingress-demo \
  -o jsonpath='{.metadata.annotations.ingress-demo-base-domain}' 2>/dev/null || true)"

if [[ -z "$DEPLOYED_BASE_DOMAIN" ]]; then
  DEPLOYED_CERTIFICATE_NAME="$(kubectl get certificate frontends \
    --namespace ingress-demo \
    -o jsonpath='{.spec.dnsNames[0]}' 2>/dev/null || true)"
  if [[ "$DEPLOYED_CERTIFICATE_NAME" == \*.demo.* ]]; then
    DEPLOYED_BASE_DOMAIN="${DEPLOYED_CERTIFICATE_NAME#\*.demo.}"
  fi
fi

if [[ -n "$DEPLOYED_BASE_DOMAIN" && "$DEPLOYED_BASE_DOMAIN" != "$BASE_DOMAIN" ]]; then
  echo "This deployment already uses ${DEPLOYED_BASE_DOMAIN}. Run ./scripts/cleanup.sh before changing domains." >&2
  exit 1
fi

DEPLOYED_INGRESS_CONTROLLER="$(kubectl get namespace ingress-demo \
  -o jsonpath='{.metadata.annotations.ingress-demo-ingress-controller}' 2>/dev/null || true)"

if [[ -n "$DEPLOYED_INGRESS_CONTROLLER" && "$DEPLOYED_INGRESS_CONTROLLER" != "$INGRESS_CONTROLLER" ]]; then
  echo "This deployment already uses ${DEPLOYED_INGRESS_CONTROLLER}. Run ./scripts/cleanup.sh before switching controllers." >&2
  exit 1
fi

if [[ "$INGRESS_CONTROLLER" == "traefik" ]]; then
  DASHBOARD_AUTH_EXISTS=false
  if kubectl get secret traefik-dashboard-auth --namespace ingress-demo >/dev/null 2>&1; then
    DASHBOARD_AUTH_EXISTS=true
  fi

  if [[ "$DASHBOARD_AUTH_EXISTS" == "false" || -n "${TRAEFIK_DASHBOARD_USERNAME:-}" || -n "${TRAEFIK_DASHBOARD_PASSWORD:-}" ]]; then
    if [[ -z "${TRAEFIK_DASHBOARD_USERNAME:-}" ]]; then
      if [[ ! -t 0 ]]; then
        echo "Set TRAEFIK_DASHBOARD_USERNAME or run this script in an interactive terminal." >&2
        exit 1
      fi

      read -r -p "Traefik dashboard username [admin]: " TRAEFIK_DASHBOARD_USERNAME
      TRAEFIK_DASHBOARD_USERNAME="${TRAEFIK_DASHBOARD_USERNAME:-admin}"
    fi

    if [[ -z "${TRAEFIK_DASHBOARD_PASSWORD:-}" ]]; then
      if [[ ! -t 0 ]]; then
        echo "Set TRAEFIK_DASHBOARD_PASSWORD or run this script in an interactive terminal." >&2
        exit 1
      fi

      read -r -s -p "Traefik dashboard password: " TRAEFIK_DASHBOARD_PASSWORD
      echo
      read -r -s -p "Confirm Traefik dashboard password: " TRAEFIK_DASHBOARD_PASSWORD_CONFIRMATION
      echo

      if [[ "$TRAEFIK_DASHBOARD_PASSWORD" != "$TRAEFIK_DASHBOARD_PASSWORD_CONFIRMATION" ]]; then
        echo "Traefik dashboard passwords do not match." >&2
        exit 1
      fi
      unset TRAEFIK_DASHBOARD_PASSWORD_CONFIRMATION
    fi

    if (( ${#TRAEFIK_DASHBOARD_PASSWORD} < 12 )); then
      echo "Traefik dashboard password must contain at least 12 characters." >&2
      exit 1
    fi
  fi
else
  unset TRAEFIK_DASHBOARD_USERNAME TRAEFIK_DASHBOARD_PASSWORD
fi

CLOUDFLARE_TOKEN_EXISTS=false
if kubectl get secret cloudflare-api-token --namespace ingress-demo >/dev/null 2>&1; then
  CLOUDFLARE_TOKEN_EXISTS=true
fi

if [[ "$CLOUDFLARE_TOKEN_EXISTS" == "false" && -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  if [[ ! -t 0 ]]; then
    echo "Set CLOUDFLARE_API_TOKEN or run this script in an interactive terminal." >&2
    exit 1
  fi

  read -r -s -p "Cloudflare API token: " CLOUDFLARE_API_TOKEN
  echo

  if [[ -z "$CLOUDFLARE_API_TOKEN" ]]; then
    echo "Cloudflare API token cannot be empty." >&2
    exit 1
  fi
fi

render_file() {
  sed "s/example\\.com/${BASE_DOMAIN}/g" "$1"
}

kubectl apply -f "$ROOT_DIR/k8s/namespace.yaml"
kubectl annotate namespace ingress-demo \
  "ingress-demo-base-domain=$BASE_DOMAIN" \
  "ingress-demo-ingress-controller=$INGRESS_CONTROLLER" \
  --overwrite >/dev/null

if [[ "$INGRESS_CONTROLLER" == "traefik" && -n "${TRAEFIK_DASHBOARD_PASSWORD:-}" ]]; then
  printf '%s' "$TRAEFIK_DASHBOARD_PASSWORD" | \
    htpasswd -niB -C 10 "$TRAEFIK_DASHBOARD_USERNAME" | \
    kubectl create secret generic traefik-dashboard-auth \
      --namespace ingress-demo \
      --from-file="users=/dev/stdin" \
      --dry-run=client \
      -o yaml | kubectl apply -f -
  unset TRAEFIK_DASHBOARD_USERNAME TRAEFIK_DASHBOARD_PASSWORD
fi

if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  printf '%s' "$CLOUDFLARE_API_TOKEN" | kubectl create secret generic cloudflare-api-token \
    --namespace ingress-demo \
    --from-file="api-token=/dev/stdin" \
    --dry-run=client \
    -o yaml | kubectl apply -f -
  unset CLOUDFLARE_API_TOKEN
fi

if [[ "$INGRESS_CONTROLLER" == "traefik" ]]; then
  echo "Installing Traefik Helm chart ${TRAEFIK_CHART_VERSION}..."
  kubectl apply --server-side --force-conflicts -k "$TRAEFIK_CRDS" >/dev/null
  helm repo add traefik "$TRAEFIK_CHART_REPOSITORY" --force-update >/dev/null
  helm repo update traefik >/dev/null
  HELM_FAILURE_ARGS=(--atomic)
  if [[ "$(helm version --template '{{.Version}}')" == v4.* ]]; then
    HELM_FAILURE_ARGS=(--rollback-on-failure --wait)
  fi
  helm upgrade --install traefik traefik/traefik \
    --namespace traefik \
    --create-namespace \
    --version "$TRAEFIK_CHART_VERSION" \
    --values "$ROOT_DIR/k8s/traefik-values.yaml" \
    --skip-crds \
    "${HELM_FAILURE_ARGS[@]}" \
    --timeout=180s
else
  echo "Installing ingress-nginx ${INGRESS_NGINX_VERSION}..."
  kubectl apply -f "$INGRESS_NGINX_MANIFEST"
  kubectl wait \
    --namespace ingress-nginx \
    --for=condition=Available \
    deployment/ingress-nginx-controller \
    --timeout=180s

  echo "Waiting for the ingress-nginx admission webhook..."
  INGRESS_NGINX_WEBHOOK_READY=false
  for ((attempt = 1; attempt <= 90; attempt++)); do
    if kubectl apply --dry-run=server -f - >/dev/null 2>&1 <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: webhook-readiness
  namespace: ingress-demo
spec:
  ingressClassName: nginx
  rules:
    - host: webhook-readiness.invalid
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: webhook-readiness
                port:
                  number: 80
EOF
    then
      INGRESS_NGINX_WEBHOOK_READY=true
      break
    fi
    sleep 2
  done

  if [[ "$INGRESS_NGINX_WEBHOOK_READY" != "true" ]]; then
    echo "ingress-nginx admission webhook did not become ready within 180 seconds." >&2
    exit 1
  fi
fi

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

echo "Waiting for the cert-manager webhook..."
CERT_MANAGER_WEBHOOK_READY=false
for ((attempt = 1; attempt <= 90; attempt++)); do
  if kubectl apply --dry-run=server -f - >/dev/null 2>&1 <<'EOF'
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: webhook-readiness
  namespace: ingress-demo
spec:
  selfSigned: {}
EOF
  then
    CERT_MANAGER_WEBHOOK_READY=true
    break
  fi
  sleep 2
done

if [[ "$CERT_MANAGER_WEBHOOK_READY" != "true" ]]; then
  echo "cert-manager webhook did not become ready within 180 seconds." >&2
  exit 1
fi

kubectl kustomize "$ROOT_DIR" | sed "s/example\\.com/${BASE_DOMAIN}/g" | kubectl apply -f -

if [[ "$INGRESS_CONTROLLER" == "traefik" ]]; then
  kubectl delete ingress frontends --namespace ingress-demo --ignore-not-found >/dev/null
  render_file "$ROOT_DIR/k8s/ingress-traefik.yaml" | kubectl apply --namespace ingress-demo -f -
  render_file "$ROOT_DIR/k8s/dashboard.yaml" | kubectl apply --namespace ingress-demo -f -
  INGRESS_SERVICE_NAMESPACE="traefik"
  INGRESS_SERVICE_NAME="traefik"
else
  render_file "$ROOT_DIR/k8s/ingress-nginx.yaml" | kubectl apply --namespace ingress-demo -f -
  INGRESS_SERVICE_NAMESPACE="ingress-nginx"
  INGRESS_SERVICE_NAME="ingress-nginx-controller"
fi

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

INGRESS_ADDRESS="$(kubectl get service "$INGRESS_SERVICE_NAME" \
  --namespace "$INGRESS_SERVICE_NAMESPACE" \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}')"

echo
echo "Deployment is ready with ${INGRESS_CONTROLLER}. Ingress address: ${INGRESS_ADDRESS:-not assigned yet}"
echo "Frontend 1: https://frontend-1.demo.${BASE_DOMAIN}"
echo "Frontend 2: https://frontend-2.demo.${BASE_DOMAIN}"
if [[ "$INGRESS_CONTROLLER" == "traefik" ]]; then
  echo "Traefik dashboard: https://traefik.demo.${BASE_DOMAIN}/dashboard/"
fi
echo "See README.md for the private DNS records required by devices on your network."
