# LAN-only Kubernetes ingress with DNS-01 TLS

An OrbStack Kubernetes demo that serves private LAN applications through ingress-nginx with publicly trusted Let's Encrypt certificates issued by cert-manager and Cloudflare DNS-01 validation.

This repository uses the reserved `example.com` domain as a placeholder. Complete [Configure your domain](#configure-your-domain) before deploying.

## Overview

The deployment provides:

- Host-based routing for two NGINX frontends.
- Automatic HTTP-to-HTTPS redirects.
- A publicly trusted wildcard certificate without a public application endpoint.
- Private DNS resolution for clients on the same LAN.

Example endpoints:

- `https://frontend-1.demo.example.com`
- `https://frontend-2.demo.example.com`

## Architecture

Application traffic remains on the local network:

```text
Client device on the same LAN
  -> private DNS resolver
  -> macOS host LAN IP on ports 80/443
  -> OrbStack LoadBalancer
  -> ingress-nginx
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

Cloudflare is used only for DNS validation and does not proxy application traffic. DNS-01 avoids exposing an HTTP challenge endpoint and supports wildcard certificates.

Certificate Transparency logs permanently record the issued wildcard hostname. The ACME TXT record is also publicly queryable while validation is in progress.

## Prerequisites

- macOS with OrbStack installed and Kubernetes enabled.
- `kubectl` configured with the `orbstack` context.
- A DNS zone managed by Cloudflare.
- Permission to create a scoped Cloudflare API token.
- A router or local DNS server that supports private DNS records.
- A client device connected to the same non-isolated LAN.

## Configure your domain

`example.com` is reserved for documentation and cannot be used for certificate issuance. Before running the setup script:

1. In `k8s/certificate.yaml`, replace `example.com` in `dnsZones` and `*.demo.example.com` in `dnsNames`.
2. In `k8s/ingress.yaml`, replace the `frontend-1.demo.example.com` and `frontend-2.demo.example.com` host values.
3. Use the same hostnames in your private DNS records and verification commands.
4. Scope the Cloudflare API token to the same DNS zone.

Keep the `demo.` prefix or replace it consistently in the certificate, ingress, and private DNS configuration. Avoid committing personalized domain values to a public fork if you prefer not to publish them.

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

Add records for both frontends to the router or local DNS server. Replace the placeholder domain and IP address with your values:

```text
frontend-1.demo.example.com -> 192.168.1.50
frontend-2.demo.example.com -> 192.168.1.50
```

Clients must use the private DNS resolver and remain on a non-isolated LAN. VPNs, iCloud Private Relay, and custom DNS services may bypass local DNS.

Verify private resolution:

```bash
dig +short frontend-1.demo.example.com
dig +short frontend-2.demo.example.com
```

Both commands should return the Mac's LAN IP. Confirm that no public address is published:

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

Enter the Cloudflare token at the hidden prompt. The script:

- Installs ingress-nginx `controller-v1.15.1` and cert-manager `v1.21.0`.
- Configures public resolvers for cert-manager's DNS-01 self-check.
- Stores the token in the local `cloudflare-api-token` Kubernetes Secret.
- Deploys the frontends, Services, Issuer, Certificate, and Ingress.
- Waits for the certificate and workloads to become ready.

Initial certificate issuance can take several minutes. The script is idempotent and can be rerun.

## Verification

Check the deployed resources:

```bash
kubectl get pods,services,ingress -n ingress-demo
kubectl get certificate,certificaterequest,order,challenge -n ingress-demo
```

The `frontends` Certificate should report `READY=True`. A completed Challenge normally disappears after issuance.

Verify redirects, TLS, and host-based routing from the Mac:

```bash
curl -I http://frontend-1.demo.example.com
curl https://frontend-1.demo.example.com
curl https://frontend-2.demo.example.com
```

The HTTP request should return `308 Permanent Redirect`; the HTTPS requests should return the corresponding frontend messages. A browser on any device connected to the same LAN should trust the certificate without installing a private CA.

## Updating the frontends

The stock NGINX containers mount HTML from Kustomize-generated ConfigMaps. After editing either frontend, apply the change and wait for both deployments:

```bash
kubectl apply -k .
kubectl rollout status deployment/frontend-1 -n ingress-demo
kubectl rollout status deployment/frontend-2 -n ingress-demo
```

Kustomize updates the affected ConfigMap name, which triggers a rollout without requiring a container build.

## Troubleshooting

Inspect certificate state, events, and cert-manager logs:

```bash
kubectl describe certificate frontends -n ingress-demo
kubectl get certificate,certificaterequest,order,challenge -n ingress-demo
kubectl get events -n ingress-demo --sort-by=.lastTimestamp
kubectl logs -n cert-manager deployment/cert-manager --since=10m
```

If a client cannot connect, verify that OrbStack LAN exposure is enabled, the private DNS records use the Mac's current LAN IP, the client uses the private resolver, and client isolation is disabled. Temporarily disable VPN or privacy services that override DNS.

## Cleanup

Run cleanup while the cluster is online so cert-manager can remove any active DNS challenge:

```bash
./scripts/cleanup.sh
```

The script removes the demo namespace, ingress-nginx, cert-manager, and their cluster-wide resources. Do not run it when other local applications share those installations.

Afterward, remove the private DNS records and revoke the Cloudflare API token. Certificate Transparency entries are permanent and cannot be removed.

## License

Licensed under the [MIT License](LICENSE).
