# k8s-lan-only-ingress-dns01

An OrbStack Kubernetes demo for LAN-only ingress with split DNS and publicly trusted Let's Encrypt TLS through DNS-01 validation.

This repository uses the reserved `example.com` domain as a placeholder. Complete [Use your own domain](#use-your-own-domain) before deploying.

This project reproduces a LAN-only Kubernetes ingress with a publicly trusted Let's Encrypt certificate:

- `https://frontend-1.demo.example.com` serves `Hello, from FRONTEND-1`.
- `https://frontend-2.demo.example.com` serves `Hello, from FRONTEND-2`.
- HTTP requests receive a `308 Permanent Redirect` to HTTPS.
- No application port or public A/AAAA record is exposed to the internet.
- Phones and other LAN devices trust the certificate without installing a private CA.

## How it works

Application traffic follows this private path:

```text
Phone or Mac
  -> router private DNS
  -> Mac LAN IP on ports 80/443
  -> OrbStack LoadBalancer
  -> ingress-nginx
  -> frontend-1 or frontend-2 Service
```

Certificate issuance uses a separate public DNS-01 path:

```text
cert-manager
  -> Cloudflare API creates a temporary ACME TXT record
  -> Let's Encrypt verifies domain control
  -> cert-manager stores the certificate in the frontends-tls Secret
  -> Cloudflare TXT record is removed
```

Cloudflare is used only for domain validation. It does not proxy application traffic.

Public Certificate Transparency logs permanently contain `*.demo.example.com`. The temporary `_acme-challenge.demo.example.com` TXT record is also publicly visible during issuance.

## What DNS-01 means

DNS-01 is an ACME domain-ownership challenge used by certificate authorities such as Let's Encrypt. The `01` is the challenge type name, not a port or DNS version.

For this demo, the validation lifecycle is:

1. Let's Encrypt gives cert-manager a unique challenge token.
2. cert-manager uses the Cloudflare API to create a temporary TXT record at `_acme-challenge.demo.example.com`.
3. Let's Encrypt queries public DNS and verifies the token.
4. Let's Encrypt issues the wildcard certificate.
5. cert-manager stores it in the `frontends-tls` Kubernetes Secret and deletes the TXT record.

The TXT record is needed only while proving domain ownership. Browsers subsequently validate the signed certificate without querying that record. At renewal time, cert-manager repeats the process with a new token.

DNS-01 is used instead of HTTP-01 because the application remains private. HTTP-01 would require Let's Encrypt to reach a challenge endpoint through public port 80. DNS-01 requires no public application address, supports wildcard certificates, and works with LAN-only services.

## Use your own domain

`example.com` is reserved for documentation and cannot be used for this deployment. Replace it locally with a Cloudflare-managed DNS zone you control before running the setup script:

1. In `k8s/certificate.yaml`, replace `example.com` in `dnsZones` and `*.demo.example.com` in `dnsNames`.
2. In `k8s/ingress.yaml`, replace the four `frontend-1.demo.example.com` and `frontend-2.demo.example.com` host values.
3. Use the same hostnames in the private router DNS records and verification commands shown below.
4. Scope the Cloudflare API token to the same DNS zone.

Keep the `demo.` prefix or replace it consistently in both manifests and your private DNS records. Do not commit personalized domain values if you want to keep them out of a public fork.

## Prerequisites

- macOS with OrbStack installed and Kubernetes enabled
- `kubectl` configured with the `orbstack` context
- A Cloudflare-managed DNS zone, represented by `example.com` in this README
- Permission to create a scoped Cloudflare API token
- A router or local DNS server that supports private DNS records
- A phone and Mac connected to the same non-isolated LAN

## Reproduce from scratch

### 1. Start Kubernetes

Start OrbStack Kubernetes and verify the context and node:

```bash
orb start k8s
kubectl config use-context orbstack
kubectl get nodes
```

The node should report `Ready`.

### 2. Enable LAN access

In **OrbStack Settings > Kubernetes**, enable **Expose services to local network devices**.

Do not configure router port forwarding, Cloudflare Tunnel, or Cloudflare proxying. Give the Mac a DHCP reservation so its LAN address remains stable.

Find the Mac's Wi-Fi address:

```bash
ipconfig getifaddr en0
```

If the Mac uses Ethernet, obtain the address from the active Ethernet interface instead. The example below uses `192.168.1.50`.

### 3. Configure private router DNS

Add these records to the router's private or local DNS configuration:

```text
frontend-1.demo.example.com -> 192.168.1.50
frontend-2.demo.example.com -> 192.168.1.50
```

Replace `192.168.1.50` with the Mac's reserved LAN IP.

Do not create public Cloudflare A or AAAA records for these names. The phone must use the router's DNS and must not be connected to an isolated guest network. Temporarily disable VPNs, iCloud Private Relay, or custom DNS services if they bypass LAN DNS.

Verify private DNS from the Mac:

```bash
dig +short frontend-1.demo.example.com
dig +short frontend-2.demo.example.com
```

Both commands should return the Mac's LAN IP.

Verify that no public address is published:

```bash
dig +short @1.1.1.1 A frontend-1.demo.example.com
dig +short @1.1.1.1 AAAA frontend-1.demo.example.com
dig +short @1.1.1.1 A frontend-2.demo.example.com
dig +short @1.1.1.1 AAAA frontend-2.demo.example.com
```

These commands should produce no output.

### 4. Create a scoped Cloudflare token

In Cloudflare, open **My Profile > API Tokens > Create Token > Create Custom Token** and configure:

```text
Permissions:
Zone / DNS / Edit
Zone / Zone / Read

Zone Resources:
Include / Specific zone / example.com
```

Do not use the Global API Key and do not put the token in this repository. The setup script reads it from a hidden prompt and stores it only in the local Kubernetes `cloudflare-api-token` Secret.

### 5. Deploy the demo

From this directory, run:

```bash
./scripts/setup.sh
```

Enter the scoped Cloudflare token when prompted. The script performs these operations:

- Installs ingress-nginx `controller-v1.15.1`.
- Installs cert-manager `v1.21.0`.
- Configures public recursive resolvers for the DNS-01 self-check.
- Creates the Cloudflare token Secret in `ingress-demo`.
- Deploys both NGINX frontends and Services.
- Creates the Let's Encrypt Issuer and wildcard Certificate.
- Creates the host-based Ingress with forced HTTPS redirects.
- Waits until the Issuer, Certificate, and Deployments are ready.

Initial issuance can take several minutes. The script is idempotent and can be rerun.

### 6. Check Kubernetes resources

```bash
kubectl get pods,services,ingress -n ingress-demo
kubectl get certificate,certificaterequest,order,challenge -n ingress-demo
```

Expected certificate status:

```text
NAME        READY   SECRET          ISSUER
frontends   True    frontends-tls   letsencrypt-cloudflare
```

The Challenge resource normally disappears after successful issuance. Cloudflare may display a message that TXT content requires quotation marks; this is informational and requires no manual change.

### 7. Verify redirects, TLS, and routing

From the Mac:

```bash
curl -I http://frontend-1.demo.example.com
curl https://frontend-1.demo.example.com
curl https://frontend-2.demo.example.com
```

Expected results:

```text
HTTP/1.1 308 Permanent Redirect
Location: https://frontend-1.demo.example.com

Hello, from FRONTEND-1
Hello, from FRONTEND-2
```

Open these addresses on a phone connected to the same LAN:

- `https://frontend-1.demo.example.com`
- `https://frontend-2.demo.example.com`

The browser should trust HTTPS without installing a certificate profile.

## Update frontend HTML

The frontends use stock NGINX images and mount the HTML from Kustomize-generated ConfigMaps, so no Docker build is required. After editing `frontend-1/index.html` or `frontend-2/index.html`, run:

```bash
kubectl apply -k .
kubectl rollout status deployment/frontend-1 -n ingress-demo
kubectl rollout status deployment/frontend-2 -n ingress-demo
```

Kustomize changes the affected ConfigMap name, which updates the Deployment and starts a Pod with the new HTML. Refresh the browser after the rollout completes.

## Troubleshooting

Inspect the current ACME state and events:

```bash
kubectl describe certificate frontends -n ingress-demo
kubectl get certificate,certificaterequest,order,challenge -n ingress-demo
kubectl get events -n ingress-demo --sort-by=.lastTimestamp
kubectl logs -n cert-manager deployment/cert-manager --since=10m
```

If Kubernetes works but the phone cannot connect, verify that OrbStack LAN exposure is enabled, the router records point to the current Mac LAN IP, the phone uses router DNS, and guest-network client isolation is disabled.

## Remove all leftovers

Run cleanup while the cluster is online so cert-manager can remove any active DNS challenge:

```bash
./scripts/cleanup.sh
```

This removes the demo namespace, ingress-nginx, cert-manager, CRDs, RBAC resources, webhooks, TLS Secrets, and the Cloudflare token Secret. Do not run it if other local applications share this ingress-nginx or cert-manager installation.

Complete the external cleanup manually:

- Remove both private DNS records from the router.
- Revoke the scoped API token in Cloudflare.

Certificate Transparency entries are permanent public records and cannot be removed.
