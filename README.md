# LAN-only Kubernetes ingress with DNS-01 TLS

An OrbStack Kubernetes demo that serves private LAN applications through Traefik or ingress-nginx with publicly trusted Let's Encrypt certificates issued by cert-manager and Cloudflare DNS-01 validation.

This repository uses the reserved `example.com` domain as a placeholder. The setup script asks for a domain and ingress controller at runtime.

## Overview

The deployment provides:

- A choice of Traefik or ingress-nginx.
- Host-based routing for two NGINX frontends.
- Automatic HTTP-to-HTTPS redirects.
- A publicly trusted wildcard certificate without a public application endpoint.
- Private DNS resolution for clients on the same LAN.
- An optional HTTPS-only Traefik dashboard protected by Basic Auth.

Example endpoints:

- `https://frontend-1.demo.example.com`
- `https://frontend-2.demo.example.com`
- `https://traefik.demo.example.com/dashboard/` when using Traefik

## Architecture

Application traffic remains on the local network:

```text
Client device on the same LAN
  -> private DNS resolver
  -> macOS host LAN IP on ports 80/443
  -> OrbStack LoadBalancer
  -> selected ingress controller
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

Cloudflare is used only for DNS validation and does not proxy application traffic. DNS-01 avoids exposing an HTTP challenge endpoint and supports wildcard certificates. When selected, Traefik keeps its API port private and exposes the dashboard only through an authenticated HTTPS route.

Certificate Transparency logs permanently record the issued wildcard hostname. The ACME TXT record is also publicly queryable while validation is in progress.

## Prerequisites

- macOS with OrbStack installed and Kubernetes enabled.
- `kubectl` configured with the `orbstack` context.
- Kubernetes 1.33-1.36 with Traefik, or 1.33-1.35 with ingress-nginx.
- Helm 3.9 or later when using Traefik, installed with `brew install helm` if needed.
- `htpasswd` when using Traefik, included with macOS.
- A DNS zone managed by Cloudflare.
- Permission to create a scoped Cloudflare API token.
- A router or local DNS server that supports private DNS records.
- A client device connected to the same non-isolated LAN.

## Runtime configuration

During setup, enter:

1. A lowercase Cloudflare-managed base domain you control.
2. `traefik` or `nginx` as the ingress controller.

The script renders the placeholder manifests in memory, so your domain is not written to tracked files. For a base domain represented by `example.com`, it creates these hostnames:

- `frontend-1.demo.example.com`
- `frontend-2.demo.example.com`
- `traefik.demo.example.com` when using Traefik

Traefik also prompts for dashboard credentials. ingress-nginx does not provide a dashboard in this project.

> **Warning:** ingress-nginx was retired in March 2026 and no longer receives security fixes. Its upstream manifest also grants cluster-wide read access to Kubernetes Secrets. Traefik is recommended for new deployments; select NGINX only on a dedicated, trusted local cluster for comparison or an existing environment.

## Deployment

### 1. Start Kubernetes

```bash
orb start k8s
kubectl config use-context orbstack
kubectl get nodes
```

The node must report `Ready`.

### 2. Enable LAN access

In **OrbStack Settings > Kubernetes**, enable **Expose services to local network devices**.

Assign the Mac a DHCP reservation so its LAN address remains stable. For Wi-Fi, retrieve the current address with:

```bash
ipconfig getifaddr en0
```

Use the active Ethernet interface instead when applicable. Do not configure router port forwarding, Cloudflare Tunnel, or Cloudflare proxying.

### 3. Configure private DNS

Always add both frontend records to the router or local DNS server. Add the dashboard record only when using Traefik. Replace the placeholder domain and IP address with your values:

```text
frontend-1.demo.example.com -> 192.168.1.50
frontend-2.demo.example.com -> 192.168.1.50
traefik.demo.example.com    -> 192.168.1.50  # Traefik only
```

Clients must use the private DNS resolver and remain on a non-isolated LAN. VPNs, iCloud Private Relay, and custom DNS services may bypass local DNS.

Verify private resolution:

```bash
dig +short frontend-1.demo.example.com
dig +short frontend-2.demo.example.com
dig +short traefik.demo.example.com # Traefik only
```

The commands for your selected hostnames should return the Mac's LAN IP. Confirm that no public address is published:

```bash
dig +short @1.1.1.1 A frontend-1.demo.example.com
dig +short @1.1.1.1 AAAA frontend-1.demo.example.com
dig +short @1.1.1.1 A frontend-2.demo.example.com
dig +short @1.1.1.1 AAAA frontend-2.demo.example.com
dig +short @1.1.1.1 A traefik.demo.example.com    # Traefik only
dig +short @1.1.1.1 AAAA traefik.demo.example.com # Traefik only
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

The selected domain and controller are locked on the first run and reused on subsequent runs. To change either value, run `./scripts/cleanup.sh` first; cleanup removes shared and cluster-wide resources, so do not use it when other applications depend on them.

```bash
./scripts/setup.sh
```

Enter the base domain, ingress controller, and Cloudflare token at the prompts. Traefik additionally requests dashboard credentials with a minimum 12-character password. Password and token input is hidden. The script:

- Installs Traefik `v3.7.6` from Helm chart `41.0.2` or ingress-nginx `controller-v1.15.1`.
- Installs cert-manager `v1.21.0`.
- Configures public resolvers for cert-manager's DNS-01 self-check.
- Stores the Cloudflare token and, for Traefik, a bcrypt dashboard credential hash in local Kubernetes Secrets.
- Deploys the frontends, Services, Issuer, Certificate, and controller-specific routing resources.
- Waits for the certificate and workloads to become ready.

Initial certificate issuance can take several minutes. The script is idempotent and can be rerun.

For noninteractive domain and controller selection:

```bash
BASE_DOMAIN=your-domain.tld INGRESS_CONTROLLER=traefik ./scripts/setup.sh
```

Use `INGRESS_CONTROLLER=nginx` to select ingress-nginx after reviewing its retirement warning. Secret values are still requested through hidden prompts unless their Kubernetes Secrets already exist.

## Verification

Check the deployed resources:

```bash
kubectl get pods,services -n ingress-demo
kubectl get certificate,certificaterequest,order,challenge -n ingress-demo
```

Inspect the selected controller's routing resources:

```bash
kubectl get ingressroute,middleware -n ingress-demo # Traefik
kubectl get ingress -n ingress-demo                 # ingress-nginx
```

The `frontends` Certificate should report `READY=True`. A completed Challenge normally disappears after issuance.

Verify redirects, TLS, and host-based routing from the Mac:

```bash
curl -I http://frontend-1.demo.example.com
curl https://frontend-1.demo.example.com
curl https://frontend-2.demo.example.com
```

The HTTP request should return `308 Permanent Redirect`; the HTTPS requests should return the corresponding frontend messages. A browser on any device connected to the same LAN should trust the certificate without installing a private CA.

When using Traefik, open `https://traefik.demo.example.com/`; the root redirects to `/dashboard/`, where you can authenticate with the dashboard credentials entered during setup.

## Updating the frontends

The stock NGINX containers mount HTML from Kustomize-generated ConfigMaps. After editing either frontend, rerun setup with the same domain and controller, then wait for both deployments:

```bash
BASE_DOMAIN=your-domain.tld INGRESS_CONTROLLER=traefik ./scripts/setup.sh
kubectl rollout status deployment/frontend-1 -n ingress-demo
kubectl rollout status deployment/frontend-2 -n ingress-demo
```

Use `INGRESS_CONTROLLER=nginx` when applicable. Kustomize updates the affected ConfigMap name, which triggers a rollout without requiring a container build.

## Troubleshooting

Inspect certificate state, events, and cert-manager logs:

```bash
kubectl describe certificate frontends -n ingress-demo
kubectl get certificate,certificaterequest,order,challenge -n ingress-demo
kubectl get events -n ingress-demo --sort-by=.lastTimestamp
kubectl logs -n cert-manager deployment/cert-manager --since=10m
```

Inspect the selected ingress controller:

```bash
kubectl logs -n traefik deployment/traefik --since=10m
kubectl logs -n ingress-nginx deployment/ingress-nginx-controller --since=10m
```

Run only the command for the installed controller.

If a client cannot connect, verify that OrbStack LAN exposure is enabled, the private DNS records use the Mac's current LAN IP, the client uses the private resolver, and client isolation is disabled. Temporarily disable VPN or privacy services that override DNS.

## Cleanup

Run cleanup while the cluster is online so cert-manager can remove any active DNS challenge:

```bash
./scripts/cleanup.sh
```

The script removes the demo namespace, either supported ingress controller, cert-manager, and their cluster-wide resources. Do not run it when other local applications share those installations.

Afterward, remove the private DNS records and revoke the Cloudflare API token. Certificate Transparency entries are permanent and cannot be removed.

## License

Licensed under the [MIT License](LICENSE).
