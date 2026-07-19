# LAN-only Kubernetes ingress with DNS-01 TLS

An OrbStack Kubernetes demo that serves private LAN applications through Traefik with publicly trusted Let's Encrypt certificates issued by cert-manager and Cloudflare DNS-01 validation.

The tracked manifests use the reserved `example.com` domain as a placeholder. The setup script asks for a domain at runtime and never writes it to tracked files.

## Overview

The deployment provides:

- Host-based routing for two unprivileged NGINX frontends.
- Automatic HTTP-to-HTTPS redirects.
- A publicly trusted wildcard certificate without a public application endpoint.
- Private DNS resolution for clients on the same LAN.
- An optional Traefik dashboard protected by Basic Auth, rate limiting, and a private-address allowlist.
- Restricted pod security settings, namespace-scoped Traefik RBAC, and frontend network isolation.

Example endpoints:

- `https://frontend-1.demo.example.com`
- `https://frontend-2.demo.example.com`
- `https://traefik.demo.example.com/dashboard/` when the dashboard is explicitly enabled

## Architecture

Application traffic remains on the local network:

```text
Client device on the same LAN
  -> private DNS resolver
  -> macOS host LAN IP on ports 80/443
  -> OrbStack LoadBalancer
  -> Traefik
  -> frontend Service
```

Certificate issuance uses a separate public DNS path:

```text
cert-manager
  -> Cloudflare API creates a temporary ACME TXT record
  -> Let's Encrypt validates domain control
  -> cert-manager stores the certificate in frontends-tls
  -> Cloudflare TXT record is removed
```

Cloudflare validates DNS ownership but does not proxy application traffic. DNS-01 avoids exposing an HTTP challenge endpoint and supports wildcard certificates. Certificate Transparency logs permanently record the issued wildcard hostname, and the ACME TXT record is publicly queryable while validation is active.

The Cloudflare token is stored in the `cert-manager` namespace. Traefik uses namespace-scoped RBAC and watches only `ingress-demo`, so it cannot read that credential.

## Prerequisites

- macOS with OrbStack installed and Kubernetes enabled.
- `kubectl` configured with the `orbstack` context.
- Kubernetes 1.33 or later.
- Helm 3.9 or later, installed with `brew install helm` if needed.
- `curl`, `shasum`, and `htpasswd` from macOS; `htpasswd` is required only for the optional dashboard.
- A DNS zone managed by Cloudflare.
- Permission to create a scoped Cloudflare API token.
- A router or local DNS server that supports private DNS records.
- A client device connected to the same non-isolated LAN.

## Deployment

### 1. Start Kubernetes

```bash
orb start k8s
kubectl config use-context orbstack
kubectl get nodes
```

The node must report `Ready`. The scripts refuse to operate on any other kubectl context.

### 2. Enable LAN access

In **OrbStack Settings > Kubernetes**, enable **Expose services to local network devices**.

Assign the Mac a DHCP reservation so its LAN address remains stable. For Wi-Fi, retrieve the current address with:

```bash
ipconfig getifaddr en0
```

Use the active Ethernet interface instead when applicable. Do not configure router port forwarding, Cloudflare Tunnel, or Cloudflare proxying.

### 3. Configure private DNS

Add both frontend records to the router or local DNS server. Add the dashboard record only if you plan to enable it. Replace the placeholder domain and IP address with your values:

```text
frontend-1.demo.example.com -> 192.168.1.50
frontend-2.demo.example.com -> 192.168.1.50
traefik.demo.example.com    -> 192.168.1.50  # Optional dashboard
```

Clients must use the private DNS resolver and remain on a non-isolated LAN. VPNs, iCloud Private Relay, and custom DNS services may bypass local DNS.

Verify private resolution:

```bash
dig +short frontend-1.demo.example.com
dig +short frontend-2.demo.example.com
```

These commands should return the Mac's LAN IP. Confirm that no public application address is published:

```bash
dig +short @1.1.1.1 A frontend-1.demo.example.com
dig +short @1.1.1.1 AAAA frontend-1.demo.example.com
dig +short @1.1.1.1 A frontend-2.demo.example.com
dig +short @1.1.1.1 AAAA frontend-2.demo.example.com
```

These commands should produce no output.

### 4. Create a Cloudflare API token

Create a custom token under **Cloudflare > My Profile > API Tokens** with these permissions:

```text
Permissions:
Zone / DNS / Edit
Zone / Zone / Read

Zone Resources:
Include / Specific zone / example.com
```

Select your actual DNS zone instead of `example.com`. Use a scoped API token rather than the Global API Key, and never commit the token.

### 5. Deploy

```bash
./scripts/setup.sh
```

Enter the base domain and Cloudflare token at the hidden prompts. The script:

- Downloads Traefik chart `41.0.2`, its required CRDs, and cert-manager `v1.21.0` over TLS and verifies fixed SHA-256 checksums before use.
- Runs Traefik `v3.7.8`, cert-manager, and the frontend image by immutable multi-platform container digests.
- Installs Traefik with namespace-scoped RBAC and only the CRDs required by this project.
- Uses an existing cert-manager installation without modifying or claiming it, or installs and labels its own instance.
- Stores the Cloudflare token in `cert-manager`, separate from the ingress controller.
- Deploys the frontends, network policy, certificate, and Traefik route.
- Refuses to modify namespaces, CRDs, issuers, or Secrets not owned by this project.

Initial certificate issuance can take several minutes. Setup is idempotent for the same domain.

For noninteractive domain selection, set `BASE_DOMAIN`. Secret values must be supplied in the environment if no project-owned Secret exists:

```bash
BASE_DOMAIN=your-domain.tld CLOUDFLARE_API_TOKEN="$CLOUDFLARE_API_TOKEN" ./scripts/setup.sh
```

### Optional dashboard

The Traefik API and dashboard are disabled by default. Enable them explicitly:

```bash
ENABLE_TRAEFIK_DASHBOARD=true ./scripts/setup.sh
```

Setup prompts for a username and a password of at least 12 characters. The route is HTTPS-only, preserves the LoadBalancer source address, accepts source addresses only from loopback, RFC 1918, or IPv6 ULA ranges, and applies a request rate limit. Rerunning setup without `ENABLE_TRAEFIK_DASHBOARD=true` disables the API and removes project-owned dashboard resources.

## Verification

Check the deployed resources:

```bash
kubectl get pods,services,networkpolicy -n ingress-demo
kubectl get certificate,certificaterequest,order,challenge -n ingress-demo
kubectl get clusterissuer ingress-demo-letsencrypt-cloudflare
kubectl get ingressroute,middleware -n ingress-demo
```

The `frontends` Certificate should report `READY=True`. A completed Challenge normally disappears after issuance.

Verify redirects, TLS, and host-based routing from the Mac:

```bash
curl -I http://frontend-1.demo.example.com
curl https://frontend-1.demo.example.com
curl https://frontend-2.demo.example.com
```

The HTTP request should redirect permanently to HTTPS. The HTTPS requests should return the corresponding frontend messages. A browser on any device connected to the same LAN should trust the certificate without installing a private CA.

When enabled, open `https://traefik.demo.example.com/`; the root redirects to `/dashboard/`, where Basic Auth is required.

## Updating the frontends

The unprivileged NGINX containers mount HTML from Kustomize-generated ConfigMaps. After editing either frontend, rerun setup with the same domain:

```bash
BASE_DOMAIN=your-domain.tld ./scripts/setup.sh
kubectl rollout status deployment/frontend-1 -n ingress-demo
kubectl rollout status deployment/frontend-2 -n ingress-demo
```

Kustomize updates the affected ConfigMap name, which triggers a rollout without requiring a container build.

## Migrating an older release

Older revisions supported the now-retired ingress-nginx controller and created resources without ownership labels. Setup intentionally refuses to adopt those resources. Remove the old deployment first while the cluster is online:

```bash
# Older ingress-nginx deployment
./scripts/cleanup.sh --remove-legacy-ingress-nginx

# Older Traefik deployment
./scripts/cleanup.sh --remove-legacy-traefik --remove-traefik-crds
```

The command requires typing `ingress-demo` before deletion. It recognizes a legacy installation only when the old demo namespace contains the expected controller annotation. The old cert-manager installation is preserved because it has no reliable ownership marker and is treated as externally managed.

## Troubleshooting

Inspect certificate state, events, and logs:

```bash
kubectl describe certificate frontends -n ingress-demo
kubectl describe clusterissuer ingress-demo-letsencrypt-cloudflare
kubectl get certificate,certificaterequest,order,challenge -n ingress-demo
kubectl get events -n ingress-demo --sort-by=.lastTimestamp
kubectl logs -n cert-manager deployment/cert-manager --since=10m
kubectl logs -n traefik deployment/traefik --since=10m
```

If a client cannot connect, verify that OrbStack LAN exposure is enabled, the private DNS records use the Mac's current LAN IP, the client uses the private resolver, and client isolation is disabled. Temporarily disable VPN or privacy services that override DNS.

An externally managed cert-manager installation is not patched by setup. If DNS-01 self-checks resolve private split-horizon records instead of authoritative public DNS, configure that installation to use appropriate public recursive resolvers.

## Cleanup

Run cleanup while the cluster is online so cert-manager can remove any active DNS challenge:

```bash
./scripts/cleanup.sh
```

Cleanup displays its target and requires typing `ingress-demo`. Project-owned namespaces are deleted with all of their contents; other individual resources require this project's ownership marker. Legacy resources require a matching migration option. Traefik CRDs are preserved by default and can be removed only when no Traefik custom resources exist:

```bash
./scripts/cleanup.sh --remove-traefik-crds
```

cert-manager is preserved by default even when setup originally installed it. Remove it only when no other workload depends on it:

```bash
./scripts/cleanup.sh --remove-cert-manager
```

The script still refuses cert-manager removal if cert-manager custom resources remain. It retains the `cert-manager` namespace without the project ownership marker to avoid cascading unrelated objects that may have been added later. A provenance annotation lets setup safely reuse that namespace only while no cert-manager components have appeared in it. For automation, `--yes` skips the typed confirmation but does not bypass ownership or dependency checks.

Afterward, remove the private DNS records and revoke the Cloudflare API token. Certificate Transparency entries are permanent and cannot be removed.

## Security

See [SECURITY.md](SECURITY.md) for vulnerability reporting. Automated checks scan committed content and history for secrets, validate Kubernetes manifests, and scan pinned container images and repository configuration for known vulnerabilities and misconfigurations.

## License

Licensed under the [MIT License](LICENSE).
