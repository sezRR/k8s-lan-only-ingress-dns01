#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MANAGED_BY="ingress-demo-setup"

TRAEFIK_CHART_VERSION="41.0.2"
TRAEFIK_CHART_URL="https://traefik.github.io/charts/traefik/traefik-${TRAEFIK_CHART_VERSION}.tgz"
TRAEFIK_CHART_SHA256="71685966a482dfa2c2b39fedf7ae9b1391251314f87f4d05faa84e4848b8d3c2"
TRAEFIK_CRD_BASE_URL="https://raw.githubusercontent.com/traefik/traefik-helm-chart/2b1428f503bd86072ddc65c7fc1cbc65607a9e12/traefik/crds"

CERT_MANAGER_VERSION="v1.21.0"
CERT_MANAGER_MANIFEST="https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
CERT_MANAGER_SHA256="6e499c3f1ab356abe79a7853911f80cb09c213885bfdf81092fdff142ba63c4a"
CERT_MANAGER_CONTROLLER_IMAGE="quay.io/jetstack/cert-manager-controller:v1.21.0@sha256:e370f7800a53078e9d74324287a7d52b553864e55f5b4e521f911c3f6c7da203"
CERT_MANAGER_CAINJECTOR_IMAGE="quay.io/jetstack/cert-manager-cainjector:v1.21.0@sha256:ad1dcc5b2fccc420f9b3fbee7ce8a869450c540fd4f2f41de2d95b1ca0c4d701"
CERT_MANAGER_WEBHOOK_IMAGE="quay.io/jetstack/cert-manager-webhook:v1.21.0@sha256:c33cca307541e2d58861a55b1af5f390b7e19c8741e48b433693b73a7cce88b3"

TRAEFIK_CRD_FILES=(
  traefik.io_ingressroutes.yaml
  traefik.io_ingressroutetcps.yaml
  traefik.io_ingressrouteudps.yaml
  traefik.io_middlewares.yaml
  traefik.io_middlewaretcps.yaml
  traefik.io_serverstransports.yaml
  traefik.io_serverstransporttcps.yaml
  traefik.io_tlsoptions.yaml
  traefik.io_tlsstores.yaml
  traefik.io_traefikservices.yaml
)
TRAEFIK_CRD_SHA256=(
  6c78d0550ca4dcce238b4a6b470f7e98b8ca834a02b5103b5c29e2dbdc05ad8a
  c136e95e25ca2ccf9c8a9f481018ef82795a3bdb7a5e1216d4606eb87cd75bdf
  ae071b931020038031f04e26ecbf08dc05261446c51d06bac629f8e1c637d97f
  0ff75808cf3a872c064599960e65fe5ed0bffee8361e45d29d98a76dfcd8220b
  d9f8fba46ba6f96273de5c126175a7d222f9f9c3458b3df38d603bbf30e69bb5
  164d529984ce726950383a34ea38c5cfd5aedb67dc6e04dfd1ea0854f28cb954
  5029d3326548033343dca5c9676a34699cf8c4e6327744902b705d845872fb97
  d3f7095426cf8e899d3062fadb460cf1b6749f86af2616b50ff6a6c1c1e1ce21
  b649ddb4c1be3304f2edac2dc4fc16a93d44738968dcb2a810bc4dedef8f48a9
  3ef2d4c3badc9119a967be771176b0c604aacbe489ed770f9642c330dab943e5
)

TRAEFIK_CRD_NAMES=(
  ingressroutes.traefik.io
  ingressroutetcps.traefik.io
  ingressrouteudps.traefik.io
  middlewares.traefik.io
  middlewaretcps.traefik.io
  serverstransports.traefik.io
  serverstransporttcps.traefik.io
  tlsoptions.traefik.io
  tlsstores.traefik.io
  traefikservices.traefik.io
)

TEMP_DIR=""
cleanup_local() {
  unset CLOUDFLARE_API_TOKEN TRAEFIK_DASHBOARD_USERNAME TRAEFIK_DASHBOARD_PASSWORD
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf -- "$TEMP_DIR"
  fi
}
trap cleanup_local EXIT

# Keep secrets out of subprocess environments and command arguments.
export -n CLOUDFLARE_API_TOKEN TRAEFIK_DASHBOARD_USERNAME TRAEFIK_DASHBOARD_PASSWORD 2>/dev/null || true

for command in curl helm kubectl mktemp sed shasum; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required command not found: $command" >&2
    exit 1
  fi
done

CLUSTER_SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
if [[ "$(kubectl config current-context)" != "orbstack" || \
  ( "$CLUSTER_SERVER" != https://127.0.0.1:* && "$CLUSTER_SERVER" != https://localhost:* ) ]]; then
  echo "Refusing to deploy outside the orbstack kubectl context." >&2
  exit 1
fi

kubectl get nodes >/dev/null
if ! kubectl get node orbstack >/dev/null 2>&1; then
  echo "The selected context does not expose the expected OrbStack node; refusing to deploy." >&2
  exit 1
fi

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

ENABLE_TRAEFIK_DASHBOARD="${ENABLE_TRAEFIK_DASHBOARD:-false}"
case "$ENABLE_TRAEFIK_DASHBOARD" in
  true|false) ;;
  *)
    echo "ENABLE_TRAEFIK_DASHBOARD must be true or false." >&2
    exit 1
    ;;
esac

namespace_owner() {
  kubectl get namespace "$1" \
    -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}'
}

cluster_resource_owner() {
  kubectl get "$1" "$2" \
    -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}'
}

namespaced_resource_owner() {
  kubectl get "$1" "$2" --namespace "$3" \
    -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}'
}

resource_exists() {
  local resource_name
  if ! resource_name="$(kubectl get "$@" --ignore-not-found -o name)"; then
    echo "Unable to verify Kubernetes resource ownership; refusing to continue." >&2
    exit 1
  fi
  [[ -n "$resource_name" ]]
}

INGRESS_DEMO_EXISTS=false
if resource_exists namespace ingress-demo; then
  INGRESS_DEMO_EXISTS=true
  INGRESS_DEMO_OWNER="$(namespace_owner ingress-demo)"
  if [[ "$INGRESS_DEMO_OWNER" != "$MANAGED_BY" ]]; then
    LEGACY_CONTROLLER="$(kubectl get namespace ingress-demo \
      -o jsonpath='{.metadata.annotations.ingress-demo-ingress-controller}')"
    if [[ -n "$LEGACY_CONTROLLER" ]]; then
      echo "A legacy ${LEGACY_CONTROLLER} demo is installed. Run ./scripts/cleanup.sh before deploying the hardened configuration." >&2
    else
      echo "Namespace ingress-demo exists but is not owned by this project; refusing to modify it." >&2
    fi
    exit 1
  fi

  DEPLOYED_BASE_DOMAIN="$(kubectl get namespace ingress-demo \
    -o jsonpath='{.metadata.annotations.ingress-demo-base-domain}')"
  if [[ -z "$DEPLOYED_BASE_DOMAIN" ]] && \
    resource_exists customresourcedefinition certificates.cert-manager.io && \
    resource_exists certificate frontends --namespace ingress-demo; then
    DEPLOYED_CERTIFICATE_NAME="$(kubectl get certificate frontends \
      --namespace ingress-demo \
      -o jsonpath='{.spec.dnsNames[0]}')"
    if [[ "$DEPLOYED_CERTIFICATE_NAME" == \*.demo.* ]]; then
      DEPLOYED_BASE_DOMAIN="${DEPLOYED_CERTIFICATE_NAME#\*.demo.}"
    else
      echo "The existing deployment has no recoverable base-domain metadata; refusing to rewrite it." >&2
      exit 1
    fi
  fi
  if [[ -z "$DEPLOYED_BASE_DOMAIN" ]]; then
    echo "The existing deployment has no base-domain metadata; refusing to rewrite it." >&2
    exit 1
  fi
  if [[ -n "$DEPLOYED_BASE_DOMAIN" && "$DEPLOYED_BASE_DOMAIN" != "$BASE_DOMAIN" ]]; then
    echo "This deployment already uses ${DEPLOYED_BASE_DOMAIN}. Run ./scripts/cleanup.sh before changing domains." >&2
    exit 1
  fi
fi

if resource_exists namespace traefik && [[ "$(namespace_owner traefik)" != "$MANAGED_BY" ]]; then
  echo "Namespace traefik exists but is not owned by this project; refusing to modify it." >&2
  exit 1
fi

for crd in "${TRAEFIK_CRD_NAMES[@]}"; do
  if resource_exists customresourcedefinition "$crd" && \
    [[ "$(cluster_resource_owner customresourcedefinition "$crd")" != "$MANAGED_BY" ]]; then
    echo "Traefik CRD ${crd} exists but is not owned by this project; refusing to modify it." >&2
    exit 1
  fi
done

if resource_exists customresourcedefinition clusterissuers.cert-manager.io && \
  resource_exists clusterissuer ingress-demo-letsencrypt-cloudflare && \
  [[ "$(cluster_resource_owner clusterissuer ingress-demo-letsencrypt-cloudflare)" != "$MANAGED_BY" ]]; then
  echo "ClusterIssuer ingress-demo-letsencrypt-cloudflare exists but is not owned by this project." >&2
  exit 1
fi

CERT_MANAGER_OWNED=false
CERT_MANAGER_INSTALL=false
CERT_MANAGER_NAMESPACE_EXISTS=false
if resource_exists namespace cert-manager; then
  CERT_MANAGER_NAMESPACE_EXISTS=true
  if [[ "$(namespace_owner cert-manager)" == "$MANAGED_BY" ]]; then
    CERT_MANAGER_OWNED=true
    CERT_MANAGER_INSTALL=true
  elif [[ "$(kubectl get namespace cert-manager \
    -o jsonpath='{.metadata.annotations.ingress-demo-cert-manager-state}')" == "removed" ]]; then
    for deployment in cert-manager cert-manager-cainjector cert-manager-webhook; do
      if resource_exists deployment "$deployment" --namespace cert-manager; then
        echo "The retained cert-manager namespace now contains an external installation; refusing to adopt it." >&2
        exit 1
      fi
    done
    for resource in \
      customresourcedefinition/certificates.cert-manager.io \
      mutatingwebhookconfiguration/cert-manager-webhook \
      validatingwebhookconfiguration/cert-manager-webhook \
      clusterrole/cert-manager-controller-issuers; do
      if resource_exists "$resource"; then
        echo "The retained cert-manager namespace has unexpected cluster-scoped resources; refusing to reinstall." >&2
        exit 1
      fi
    done
    CERT_MANAGER_OWNED=true
    CERT_MANAGER_INSTALL=true
  else
    for deployment in cert-manager cert-manager-cainjector cert-manager-webhook; do
      if ! kubectl get deployment "$deployment" --namespace cert-manager >/dev/null 2>&1; then
        echo "The external cert-manager installation does not use the supported standard component layout." >&2
        exit 1
      fi
    done
    EXTERNAL_CERT_MANAGER_ARGS="$(kubectl get deployment cert-manager \
      --namespace cert-manager \
      -o jsonpath='{.spec.template.spec.containers[0].args}')"
    POD_NAMESPACE_CLUSTER_RESOURCE_ARG="--cluster-resource-namespace=\$(POD_NAMESPACE)"
    if [[ "$EXTERNAL_CERT_MANAGER_ARGS" != *"$POD_NAMESPACE_CLUSTER_RESOURCE_ARG"* && \
      "$EXTERNAL_CERT_MANAGER_ARGS" != *'--cluster-resource-namespace=cert-manager'* ]]; then
      echo "The external cert-manager installation uses an unsupported cluster resource namespace." >&2
      exit 1
    fi
  fi
else
  for resource in \
    customresourcedefinition/certificates.cert-manager.io \
    mutatingwebhookconfiguration/cert-manager-webhook \
    validatingwebhookconfiguration/cert-manager-webhook \
    clusterrole/cert-manager-controller-issuers; do
    if resource_exists "$resource"; then
      echo "Found cluster-scoped cert-manager resources without an owned cert-manager namespace; refusing to adopt them." >&2
      exit 1
    fi
  done
  CERT_MANAGER_OWNED=true
  CERT_MANAGER_INSTALL=true
fi

CLOUDFLARE_TOKEN_EXISTS=false
if [[ "$CERT_MANAGER_NAMESPACE_EXISTS" == "true" ]] && \
  resource_exists secret ingress-demo-cloudflare-api-token --namespace cert-manager; then
  if [[ "$(namespaced_resource_owner secret ingress-demo-cloudflare-api-token cert-manager)" != "$MANAGED_BY" ]]; then
    echo "Secret cert-manager/ingress-demo-cloudflare-api-token is not owned by this project." >&2
    exit 1
  fi
  CLOUDFLARE_TOKEN_EXISTS=true
fi

if [[ "$CERT_MANAGER_NAMESPACE_EXISTS" == "true" ]] && \
  resource_exists secret ingress-demo-letsencrypt-cloudflare-account --namespace cert-manager && \
  [[ "$(namespaced_resource_owner secret ingress-demo-letsencrypt-cloudflare-account cert-manager)" != "$MANAGED_BY" ]]; then
  echo "Secret cert-manager/ingress-demo-letsencrypt-cloudflare-account is not owned by this project." >&2
  exit 1
fi

if [[ "$CLOUDFLARE_TOKEN_EXISTS" == "false" && -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  if [[ ! -t 0 ]]; then
    echo "Set CLOUDFLARE_API_TOKEN or run this script in an interactive terminal." >&2
    exit 1
  fi
  read -r -s -p "Cloudflare API token: " CLOUDFLARE_API_TOKEN
  echo
fi

if [[ "$CLOUDFLARE_TOKEN_EXISTS" == "false" && -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  echo "Cloudflare API token cannot be empty." >&2
  exit 1
fi

DASHBOARD_AUTH_EXISTS=false
if [[ "$INGRESS_DEMO_EXISTS" == "true" ]] && \
  resource_exists secret traefik-dashboard-auth --namespace ingress-demo; then
  if [[ "$(namespaced_resource_owner secret traefik-dashboard-auth ingress-demo)" != "$MANAGED_BY" ]]; then
    echo "Secret ingress-demo/traefik-dashboard-auth is not owned by this project." >&2
    exit 1
  fi
  DASHBOARD_AUTH_EXISTS=true
fi

if [[ "$ENABLE_TRAEFIK_DASHBOARD" == "true" && \
  ( "$DASHBOARD_AUTH_EXISTS" == "false" || -n "${TRAEFIK_DASHBOARD_USERNAME:-}" || -n "${TRAEFIK_DASHBOARD_PASSWORD:-}" ) ]]; then
  if ! command -v htpasswd >/dev/null 2>&1; then
    echo "Required command not found: htpasswd" >&2
    exit 1
  fi

  if [[ -z "${TRAEFIK_DASHBOARD_USERNAME:-}" ]]; then
    if [[ ! -t 0 ]]; then
      echo "Set TRAEFIK_DASHBOARD_USERNAME or run this script in an interactive terminal." >&2
      exit 1
    fi
    read -r -p "Traefik dashboard username [admin]: " TRAEFIK_DASHBOARD_USERNAME
    TRAEFIK_DASHBOARD_USERNAME="${TRAEFIK_DASHBOARD_USERNAME:-admin}"
  fi

  if [[ ! "$TRAEFIK_DASHBOARD_USERNAME" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
    echo "Traefik dashboard username may contain only letters, numbers, dots, underscores, and hyphens." >&2
    exit 1
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

download_verified() {
  local url="$1"
  local destination="$2"
  local checksum="$3"

  curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
    "$url" --output "$destination"
  if ! printf '%s  %s\n' "$checksum" "$destination" | shasum -a 256 --check --status; then
    echo "Checksum verification failed for ${url}." >&2
    exit 1
  fi
}

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ingress-demo.XXXXXX")"
TRAEFIK_CHART="$TEMP_DIR/traefik-${TRAEFIK_CHART_VERSION}.tgz"
CERT_MANAGER_DOWNLOAD="$TEMP_DIR/cert-manager-upstream.yaml"
CERT_MANAGER_FILE="$TEMP_DIR/cert-manager.yaml"
TRAEFIK_CRDS_DIR="$TEMP_DIR/traefik-crds"
mkdir "$TRAEFIK_CRDS_DIR"

echo "Downloading and verifying deployment artifacts..."
download_verified "$TRAEFIK_CHART_URL" "$TRAEFIK_CHART" "$TRAEFIK_CHART_SHA256"
if [[ "$CERT_MANAGER_INSTALL" == "true" ]]; then
  download_verified "$CERT_MANAGER_MANIFEST" "$CERT_MANAGER_DOWNLOAD" "$CERT_MANAGER_SHA256"
  sed \
    -e "s#quay.io/jetstack/cert-manager-controller:v1.21.0#${CERT_MANAGER_CONTROLLER_IMAGE}#g" \
    -e "s#quay.io/jetstack/cert-manager-cainjector:v1.21.0#${CERT_MANAGER_CAINJECTOR_IMAGE}#g" \
    -e "s#quay.io/jetstack/cert-manager-webhook:v1.21.0#${CERT_MANAGER_WEBHOOK_IMAGE}#g" \
    "$CERT_MANAGER_DOWNLOAD" > "$CERT_MANAGER_FILE"
fi

for index in "${!TRAEFIK_CRD_FILES[@]}"; do
  crd_file="${TRAEFIK_CRD_FILES[$index]}"
  crd_download="$TEMP_DIR/${crd_file}"
  download_verified \
    "$TRAEFIK_CRD_BASE_URL/$crd_file" \
    "$crd_download" \
    "${TRAEFIK_CRD_SHA256[$index]}"
  kubectl label --local -f "$crd_download" \
    "app.kubernetes.io/managed-by=$MANAGED_BY" \
    "app.kubernetes.io/part-of=ingress-demo" \
    -o yaml > "$TRAEFIK_CRDS_DIR/$crd_file"
done

kubectl apply -f "$ROOT_DIR/k8s/namespace.yaml"
kubectl annotate namespace ingress-demo \
  "ingress-demo-base-domain=$BASE_DOMAIN" \
  "ingress-demo-ingress-controller=traefik" \
  --overwrite >/dev/null

if ! resource_exists namespace traefik; then
  kubectl create namespace traefik >/dev/null
fi
kubectl label namespace traefik \
  "app.kubernetes.io/managed-by=$MANAGED_BY" \
  "app.kubernetes.io/part-of=ingress-demo" \
  "pod-security.kubernetes.io/audit=restricted" \
  "pod-security.kubernetes.io/enforce=restricted" \
  "pod-security.kubernetes.io/warn=restricted" \
  --overwrite >/dev/null

if [[ "$CERT_MANAGER_INSTALL" == "true" ]]; then
  if ! resource_exists namespace cert-manager; then
    kubectl create namespace cert-manager >/dev/null
  fi
  kubectl label namespace cert-manager \
    "app.kubernetes.io/managed-by=$MANAGED_BY" \
    "app.kubernetes.io/part-of=ingress-demo" \
    --overwrite >/dev/null
  kubectl annotate namespace cert-manager \
    ingress-demo-cert-manager-state- \
    >/dev/null 2>&1 || true

  echo "Installing cert-manager ${CERT_MANAGER_VERSION} from its verified manifest..."
  kubectl apply -f "$CERT_MANAGER_FILE"
else
  echo "Using the existing externally managed cert-manager installation without modifying it."
fi

kubectl wait \
  --namespace cert-manager \
  --for=condition=Available \
  deployment/cert-manager \
  deployment/cert-manager-cainjector \
  deployment/cert-manager-webhook \
  --timeout=180s

if [[ "$CERT_MANAGER_OWNED" == "true" ]]; then
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

if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  printf '%s' "$CLOUDFLARE_API_TOKEN" | \
    kubectl create secret generic ingress-demo-cloudflare-api-token \
      --namespace cert-manager \
      --from-file="api-token=/dev/stdin" \
      --dry-run=client \
      -o yaml | kubectl apply -f -
  kubectl label secret ingress-demo-cloudflare-api-token \
    --namespace cert-manager \
    "app.kubernetes.io/managed-by=$MANAGED_BY" \
    "app.kubernetes.io/part-of=ingress-demo" \
    --overwrite >/dev/null
  unset CLOUDFLARE_API_TOKEN
fi

if [[ "$ENABLE_TRAEFIK_DASHBOARD" == "true" && -n "${TRAEFIK_DASHBOARD_PASSWORD:-}" ]]; then
  printf '%s' "$TRAEFIK_DASHBOARD_PASSWORD" | \
    htpasswd -niB -C 10 "$TRAEFIK_DASHBOARD_USERNAME" | \
    kubectl create secret generic traefik-dashboard-auth \
      --namespace ingress-demo \
      --from-file="users=/dev/stdin" \
      --dry-run=client \
      -o yaml | kubectl apply -f -
  kubectl label secret traefik-dashboard-auth \
    --namespace ingress-demo \
    "app.kubernetes.io/component=dashboard" \
    "app.kubernetes.io/managed-by=$MANAGED_BY" \
    "app.kubernetes.io/part-of=ingress-demo" \
    --overwrite >/dev/null
  unset TRAEFIK_DASHBOARD_USERNAME TRAEFIK_DASHBOARD_PASSWORD
fi

echo "Installing Traefik Helm chart ${TRAEFIK_CHART_VERSION} from its verified archive..."
kubectl apply --server-side --force-conflicts -f "$TRAEFIK_CRDS_DIR" >/dev/null
HELM_FAILURE_ARGS=(--atomic)
if [[ "$(helm version --template '{{.Version}}')" == v4.* ]]; then
  HELM_FAILURE_ARGS=(--rollback-on-failure --wait)
fi
helm upgrade --install traefik "$TRAEFIK_CHART" \
  --namespace traefik \
  --version "$TRAEFIK_CHART_VERSION" \
  --values "$ROOT_DIR/k8s/traefik-values.yaml" \
  --set "api.dashboard=${ENABLE_TRAEFIK_DASHBOARD}" \
  --skip-crds \
  "${HELM_FAILURE_ARGS[@]}" \
  --timeout=180s

sed "s/example\\.com/${BASE_DOMAIN}/g" "$ROOT_DIR/k8s/cluster-issuer.yaml" | kubectl apply -f -
kubectl kustomize "$ROOT_DIR" | sed "s/example\\.com/${BASE_DOMAIN}/g" | kubectl apply -f -
sed "s/example\\.com/${BASE_DOMAIN}/g" "$ROOT_DIR/k8s/ingress-traefik.yaml" | \
  kubectl apply --namespace ingress-demo -f -

if [[ "$ENABLE_TRAEFIK_DASHBOARD" == "true" ]]; then
  sed "s/example\\.com/${BASE_DOMAIN}/g" "$ROOT_DIR/k8s/dashboard.yaml" | \
    kubectl apply --namespace ingress-demo -f -
else
  kubectl delete ingressroute,middleware,secret \
    --namespace ingress-demo \
    --selector="app.kubernetes.io/component=dashboard,app.kubernetes.io/managed-by=${MANAGED_BY}" \
    --ignore-not-found >/dev/null
fi

kubectl rollout status deployment/frontend-1 --namespace ingress-demo --timeout=180s
kubectl rollout status deployment/frontend-2 --namespace ingress-demo --timeout=180s
kubectl wait \
  --for=condition=Ready \
  clusterissuer/ingress-demo-letsencrypt-cloudflare \
  --timeout=180s
kubectl label secret ingress-demo-letsencrypt-cloudflare-account \
  --namespace cert-manager \
  "app.kubernetes.io/managed-by=$MANAGED_BY" \
  "app.kubernetes.io/part-of=ingress-demo" \
  --overwrite >/dev/null
kubectl wait \
  --namespace ingress-demo \
  --for=condition=Ready \
  certificate/frontends \
  --timeout=300s

FRONTEND_1_CONFIGMAP="$(kubectl get deployment frontend-1 \
  --namespace ingress-demo \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="html")].configMap.name}')"
FRONTEND_2_CONFIGMAP="$(kubectl get deployment frontend-2 \
  --namespace ingress-demo \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="html")].configMap.name}')"
while IFS= read -r config_map; do
  if [[ "$config_map" == frontend-*-html-* && \
    "$config_map" != "$FRONTEND_1_CONFIGMAP" && \
    "$config_map" != "$FRONTEND_2_CONFIGMAP" ]]; then
    kubectl delete configmap "$config_map" --namespace ingress-demo >/dev/null
  fi
done < <(kubectl get configmap \
  --namespace ingress-demo \
  --selector="app.kubernetes.io/managed-by=${MANAGED_BY},app.kubernetes.io/part-of=ingress-demo" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

INGRESS_ADDRESS="$(kubectl get service traefik \
  --namespace traefik \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}')"

echo
echo "Deployment is ready with Traefik. Ingress address: ${INGRESS_ADDRESS:-not assigned yet}"
echo "Frontend 1: https://frontend-1.demo.${BASE_DOMAIN}"
echo "Frontend 2: https://frontend-2.demo.${BASE_DOMAIN}"
if [[ "$ENABLE_TRAEFIK_DASHBOARD" == "true" ]]; then
  echo "Traefik dashboard: https://traefik.demo.${BASE_DOMAIN}/dashboard/"
fi
echo "See README.md for the private DNS records required by devices on your network."
