#!/usr/bin/env bash
set -euo pipefail

MANAGED_BY="ingress-demo-setup"
CERT_MANAGER_VERSION="v1.21.0"
CERT_MANAGER_MANIFEST="https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
CERT_MANAGER_SHA256="6e499c3f1ab356abe79a7853911f80cb09c213885bfdf81092fdff142ba63c4a"
LEGACY_INGRESS_NGINX_MANIFEST="https://raw.githubusercontent.com/kubernetes/ingress-nginx/0a5901f3c64f11e92e487799b8da3f00cca37515/deploy/static/provider/cloud/deploy.yaml"
LEGACY_INGRESS_NGINX_SHA256="502fddca66b09c20dd48b6d0a792a9671cd663a3a0d2a8bda5ae990d13b6c5b2"

ASSUME_YES=false
REMOVE_CERT_MANAGER=false
REMOVE_LEGACY_INGRESS_NGINX=false
REMOVE_LEGACY_TRAEFIK=false
REMOVE_TRAEFIK_CRDS=false

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

CERT_MANAGER_CRD_NAMES=(
  certificates.cert-manager.io
  certificaterequests.cert-manager.io
  issuers.cert-manager.io
  clusterissuers.cert-manager.io
  orders.acme.cert-manager.io
  challenges.acme.cert-manager.io
)

usage() {
  cat <<'EOF'
Usage: ./scripts/cleanup.sh [options]

Options:
  --yes                           Skip the interactive confirmation.
  --remove-cert-manager           Remove an unused project-owned cert-manager installation.
  --remove-traefik-crds           Remove unused Traefik CRDs owned by this project.
  --remove-legacy-ingress-nginx   Remove ingress-nginx installed by an older release.
  --remove-legacy-traefik         Remove Traefik installed by an older release.
  --help                          Show this help.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --yes) ASSUME_YES=true ;;
    --remove-cert-manager) REMOVE_CERT_MANAGER=true ;;
    --remove-traefik-crds) REMOVE_TRAEFIK_CRDS=true ;;
    --remove-legacy-ingress-nginx) REMOVE_LEGACY_INGRESS_NGINX=true ;;
    --remove-legacy-traefik) REMOVE_LEGACY_TRAEFIK=true ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if ! command -v kubectl >/dev/null 2>&1; then
  echo "Required command not found: kubectl" >&2
  exit 1
fi

CLUSTER_SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
if [[ "$(kubectl config current-context)" != "orbstack" || \
  ( "$CLUSTER_SERVER" != https://127.0.0.1:* && "$CLUSTER_SERVER" != https://localhost:* ) ]]; then
  echo "Refusing to delete resources outside the orbstack kubectl context." >&2
  exit 1
fi

kubectl get nodes >/dev/null
if ! kubectl get node orbstack >/dev/null 2>&1; then
  echo "The selected context does not expose the expected OrbStack node; refusing cleanup." >&2
  exit 1
fi

namespace_owner() {
  kubectl get namespace "$1" \
    -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true
}

cluster_resource_owner() {
  kubectl get "$1" "$2" \
    -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true
}

namespaced_resource_owner() {
  kubectl get "$1" "$2" --namespace "$3" \
    -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true
}

INGRESS_DEMO_OWNED=false
LEGACY_DEMO=false
LEGACY_CONTROLLER=""
if kubectl get namespace ingress-demo >/dev/null 2>&1; then
  if [[ "$(namespace_owner ingress-demo)" == "$MANAGED_BY" ]]; then
    INGRESS_DEMO_OWNED=true
  else
    LEGACY_CONTROLLER="$(kubectl get namespace ingress-demo \
      -o jsonpath='{.metadata.annotations.ingress-demo-ingress-controller}' 2>/dev/null || true)"
    if [[ "$LEGACY_CONTROLLER" == "traefik" || "$LEGACY_CONTROLLER" == "nginx" ]]; then
      LEGACY_DEMO=true
    else
      echo "Namespace ingress-demo is not owned by this project; it will not be removed." >&2
    fi
  fi
fi

TRAEFIK_OWNED=false
if kubectl get namespace traefik >/dev/null 2>&1 && [[ "$(namespace_owner traefik)" == "$MANAGED_BY" ]]; then
  TRAEFIK_OWNED=true
fi

CERT_MANAGER_OWNED=false
if kubectl get namespace cert-manager >/dev/null 2>&1 && [[ "$(namespace_owner cert-manager)" == "$MANAGED_BY" ]]; then
  CERT_MANAGER_OWNED=true
fi

if [[ "$LEGACY_CONTROLLER" == "nginx" && "$REMOVE_LEGACY_INGRESS_NGINX" != "true" ]]; then
  echo "A legacy ingress-nginx demo requires --remove-legacy-ingress-nginx for cleanup." >&2
  exit 1
fi

if [[ "$LEGACY_CONTROLLER" == "traefik" && "$REMOVE_LEGACY_TRAEFIK" != "true" ]]; then
  echo "A legacy Traefik demo requires --remove-legacy-traefik for cleanup." >&2
  exit 1
fi

if [[ "$REMOVE_LEGACY_INGRESS_NGINX" == "true" && "$LEGACY_CONTROLLER" != "nginx" ]]; then
  echo "Refusing legacy ingress-nginx removal because no matching legacy demo annotation was found." >&2
  exit 1
fi

if [[ "$REMOVE_LEGACY_TRAEFIK" == "true" && "$LEGACY_CONTROLLER" != "traefik" ]]; then
  echo "Refusing legacy Traefik removal because no matching legacy demo annotation was found." >&2
  exit 1
fi

if [[ "$REMOVE_LEGACY_TRAEFIK" == "true" ]] && ! command -v helm >/dev/null 2>&1; then
  echo "Required command for legacy Traefik removal not found: helm" >&2
  exit 1
fi

if [[ "$REMOVE_TRAEFIK_CRDS" == "true" ]]; then
  for crd in "${TRAEFIK_CRD_NAMES[@]}"; do
    CRD_RESOURCE="$(kubectl get customresourcedefinition "$crd" --ignore-not-found -o name)"
    if [[ -z "$CRD_RESOURCE" ]]; then
      continue
    fi

    CRD_OWNER="$(cluster_resource_owner customresourcedefinition "$crd")"
    if [[ "$CRD_OWNER" != "$MANAGED_BY" && "$REMOVE_LEGACY_TRAEFIK" != "true" ]]; then
      echo "Traefik CRD ${crd} is not owned by this project; refusing to remove it." >&2
      exit 1
    fi

    CR_NAMESPACES="$(kubectl get "$crd" --all-namespaces \
      -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}')"
    while IFS= read -r namespace; do
      if [[ -n "$namespace" && "$namespace" != "ingress-demo" ]]; then
        echo "Traefik resources exist outside ingress-demo; refusing to remove the CRDs." >&2
        exit 1
      fi
    done <<< "$CR_NAMESPACES"
  done
fi

echo "Cleanup target: kubectl context orbstack (${CLUSTER_SERVER})"
[[ "$INGRESS_DEMO_OWNED" == "true" ]] && echo "- Project-owned ingress-demo namespace and all of its contents"
[[ "$LEGACY_DEMO" == "true" ]] && echo "- Legacy ingress-demo namespace and all of its contents"
[[ "$TRAEFIK_OWNED" == "true" ]] && echo "- Project-owned Traefik release and namespace"
[[ "$REMOVE_CERT_MANAGER" == "true" && "$CERT_MANAGER_OWNED" == "true" ]] && echo "- Unused components from the project-owned cert-manager installation"
[[ "$REMOVE_TRAEFIK_CRDS" == "true" ]] && echo "- Unused project-owned Traefik CRDs"
[[ "$REMOVE_LEGACY_INGRESS_NGINX" == "true" ]] && echo "- Legacy ingress-nginx installation"
[[ "$REMOVE_LEGACY_TRAEFIK" == "true" ]] && echo "- Legacy Traefik release and namespace"
echo "- Project-owned ClusterIssuer and credential Secrets"

if [[ "$ASSUME_YES" != "true" ]]; then
  if [[ ! -t 0 ]]; then
    echo "Run interactively or pass --yes to confirm cleanup." >&2
    exit 1
  fi
  read -r -p "Type ingress-demo to continue: " CONFIRMATION
  if [[ "$CONFIRMATION" != "ingress-demo" ]]; then
    echo "Cleanup cancelled." >&2
    exit 1
  fi
fi

TEMP_DIR=""
cleanup_local() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf -- "$TEMP_DIR"
  fi
}
trap cleanup_local EXIT

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

if [[ "$REMOVE_LEGACY_INGRESS_NGINX" == "true" || \
  ( "$REMOVE_CERT_MANAGER" == "true" && "$CERT_MANAGER_OWNED" == "true" ) ]]; then
  for command in curl mktemp shasum; do
    if ! command -v "$command" >/dev/null 2>&1; then
      echo "Required command not found: $command" >&2
      exit 1
    fi
  done
  TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ingress-demo-cleanup.XXXXXX")"
fi

LEGACY_MANIFEST=""
if [[ "$REMOVE_LEGACY_INGRESS_NGINX" == "true" ]]; then
  LEGACY_MANIFEST="$TEMP_DIR/ingress-nginx.yaml"
  download_verified "$LEGACY_INGRESS_NGINX_MANIFEST" "$LEGACY_MANIFEST" "$LEGACY_INGRESS_NGINX_SHA256"
fi

CERT_MANAGER_FILE=""
CERT_MANAGER_RESOURCES_FILE=""
if [[ "$REMOVE_CERT_MANAGER" == "true" && "$CERT_MANAGER_OWNED" == "true" ]]; then
  CERT_MANAGER_FILE="$TEMP_DIR/cert-manager.yaml"
  CERT_MANAGER_RESOURCES_FILE="$TEMP_DIR/cert-manager-resources.yaml"
  download_verified "$CERT_MANAGER_MANIFEST" "$CERT_MANAGER_FILE" "$CERT_MANAGER_SHA256"
  # Keep the namespace so unrelated objects added later are never cascaded.
  sed '1,/^---$/d' "$CERT_MANAGER_FILE" > "$CERT_MANAGER_RESOURCES_FILE"
fi

if [[ "$REMOVE_LEGACY_INGRESS_NGINX" == "true" ]]; then
  kubectl delete -f "$LEGACY_MANIFEST" --ignore-not-found --wait=true --timeout=180s
fi

if [[ "$TRAEFIK_OWNED" == "true" || "$REMOVE_LEGACY_TRAEFIK" == "true" ]]; then
  if command -v helm >/dev/null 2>&1 && helm status traefik --namespace traefik >/dev/null 2>&1; then
    helm uninstall traefik --namespace traefik --wait --timeout=180s
  fi
  kubectl delete namespace traefik --ignore-not-found --wait=true --timeout=180s
fi

if [[ "$INGRESS_DEMO_OWNED" == "true" || "$LEGACY_DEMO" == "true" ]]; then
  echo "Removing the demo and allowing cert-manager to clean up active DNS challenges..."
  if kubectl get certificate frontends --namespace ingress-demo >/dev/null 2>&1; then
    kubectl delete certificate frontends \
      --namespace ingress-demo \
      --cascade=foreground \
      --wait=true \
      --timeout=180s
  fi
  if [[ -n "$(kubectl get customresourcedefinition challenges.acme.cert-manager.io --ignore-not-found -o name)" ]]; then
    kubectl delete challenges.acme.cert-manager.io \
      --all \
      --namespace ingress-demo \
      --ignore-not-found \
      --wait=true \
      --timeout=180s
  fi
  kubectl delete namespace ingress-demo --wait=true --timeout=180s
fi

if kubectl get clusterissuer ingress-demo-letsencrypt-cloudflare >/dev/null 2>&1 && \
  [[ "$(cluster_resource_owner clusterissuer ingress-demo-letsencrypt-cloudflare)" == "$MANAGED_BY" ]]; then
  kubectl delete clusterissuer ingress-demo-letsencrypt-cloudflare --wait=true --timeout=180s
fi

for secret in ingress-demo-letsencrypt-cloudflare-account ingress-demo-cloudflare-api-token; do
  if kubectl get secret "$secret" --namespace cert-manager >/dev/null 2>&1 && \
    [[ "$(namespaced_resource_owner secret "$secret" cert-manager)" == "$MANAGED_BY" ]]; then
    kubectl delete secret "$secret" --namespace cert-manager
  fi
done

if [[ "$REMOVE_TRAEFIK_CRDS" == "true" ]]; then
  for crd in "${TRAEFIK_CRD_NAMES[@]}"; do
    CRD_RESOURCE="$(kubectl get customresourcedefinition "$crd" --ignore-not-found -o name)"
    if [[ -n "$CRD_RESOURCE" ]]; then
      CR_INSTANCES="$(kubectl get "$crd" --all-namespaces -o name)"
      if [[ -n "$CR_INSTANCES" ]]; then
        echo "Traefik resources appeared during cleanup; preserving the CRDs." >&2
        exit 1
      fi
    fi
  done
  kubectl delete customresourcedefinition \
    "${TRAEFIK_CRD_NAMES[@]}" \
    --ignore-not-found \
    --wait=true \
    --timeout=180s
else
  echo "Preserving Traefik CRDs. Pass --remove-traefik-crds to remove them when unused."
fi

if [[ "$REMOVE_CERT_MANAGER" == "true" ]]; then
  if [[ "$CERT_MANAGER_OWNED" != "true" ]]; then
    echo "cert-manager is externally managed; preserving it." >&2
  else
    CERT_MANAGER_RESOURCES_REMAIN=false
    for crd in "${CERT_MANAGER_CRD_NAMES[@]}"; do
      CRD_RESOURCE="$(kubectl get customresourcedefinition "$crd" --ignore-not-found -o name)"
      if [[ -z "$CRD_RESOURCE" ]]; then
        continue
      fi
      CR_INSTANCES="$(kubectl get "$crd" --all-namespaces -o name)"
      if [[ -n "$CR_INSTANCES" ]]; then
        CERT_MANAGER_RESOURCES_REMAIN=true
        break
      fi
    done

    if [[ "$CERT_MANAGER_RESOURCES_REMAIN" == "true" ]]; then
      echo "cert-manager resources still exist outside the demo; preserving cert-manager." >&2
    else
      kubectl delete -f "$CERT_MANAGER_RESOURCES_FILE" --ignore-not-found --wait=true --timeout=180s
      kubectl delete lease \
        cert-manager-cainjector-leader-election \
        cert-manager-cainjector-leader-election-core \
        cert-manager-controller \
        --namespace kube-system \
        --ignore-not-found
      kubectl annotate namespace cert-manager \
        ingress-demo-cert-manager-state=removed \
        --overwrite >/dev/null
      kubectl label namespace cert-manager \
        app.kubernetes.io/managed-by- \
        app.kubernetes.io/part-of- \
        --overwrite >/dev/null
      echo "cert-manager components were removed; the non-cascading cert-manager namespace was retained."
    fi
  fi
elif [[ "$CERT_MANAGER_OWNED" == "true" ]]; then
  echo "Preserving cert-manager. Pass --remove-cert-manager to remove it when unused."
fi

echo
echo "Selected local resources are removed. Delete the private DNS records and revoke"
echo "the scoped Cloudflare API token to remove the remaining external configuration."
