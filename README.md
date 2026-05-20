# Mox Helm Chart

[![CI](https://github.com/thenotary/mox-helm/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/thenotary/mox-helm/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/thenotary/mox-helm?label=release)](https://github.com/thenotary/mox-helm/releases/latest)

A Helm chart for deploying the [mox](https://github.com/mjl-/mox) mail server to Kubernetes, with first-class support for Azure AKS.

## Prerequisites

- Kubernetes 1.24+
- Helm 3.x
- [cert-manager](https://cert-manager.io/) installed in the cluster (for TLS certificates)
- **Optional:** [Azure Service Operator v2](https://azure.github.io/azure-service-operator/) for managing Azure Public IP with reverse DNS from Kubernetes

## Quick Start

```bash
# Add your configuration
cat > my-values.yaml <<EOF
hostname: mail.example.com

publicIPs:
  ipv4: "203.0.113.5"   # Your LoadBalancer public IP

admin:
  passwordHash: "\$2b\$10\$..."   # bcrypt hash

domains:
  example.com:
    dkim:
      selectors:
        sel1:
          algorithm: ed25519
          existingSecret: my-dkim-secret
      sign:
        - sel1
    dmarc:
      localpart: dmarcreports
      account: postmaster
      mailbox: DMARC
    mtasts:
      mode: enforce
      maxAge: 86400
    tlsrpt:
      localpart: tlsreports
      account: postmaster
      mailbox: TLSRPT

accounts:
  postmaster:
    domain: example.com
    fullName: "Postmaster"
    destinations:
      postmaster@example.com:
        mailbox: Inbox

certManager:
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
EOF

# Install
helm install mox ./helm_chart/mox -f my-values.yaml
```

## Azure AKS Guide

### Port 25 Outbound Restrictions

Azure **blocks outbound port 25** on most subscription types:

| Subscription Type | Port 25 Status |
|---|---|
| Enterprise Agreement (EA) / MCA-E | **Allowed** |
| Pay-As-You-Go, MSDN, Visual Studio | **Blocked** |
| Free Trial | **Blocked** |

If port 25 is blocked, you **must** use a smarthost relay for outbound mail:

```yaml
transport:
  enabled: true
  type: submissions
  host: smtp.sendgrid.net    # or smtp.azurecomm.net, smtp-relay.gmail.com
  port: 465
  auth:
    username: apikey
    existingSecret: sendgrid-credentials
    mechanisms:
      - PLAIN
```

### Reverse DNS (PTR Records)

Reverse DNS is **critical** for mail deliverability. Most receiving servers check that the sending IP's PTR record matches the mail server hostname.

**Option A: Pre-provision and configure manually**

1. Create a static Azure Public IP with a DNS name label:
   ```bash
   az network public-ip create \
     --name mox-mail-ip \
     --resource-group my-rg \
     --location eastus \
     --sku Standard \
     --allocation-method Static \
     --dns-name mail
   ```

2. Set the reverse FQDN (forward A record must resolve first):
   ```bash
   az network public-ip update \
     --name mox-mail-ip \
     --resource-group my-rg \
     --reverse-fqdn mail.example.com. \
     --dns-name mail
   ```

3. Reference the IP in values.yaml:
   ```yaml
   service:
     azure:
       resourceGroup: my-rg
       pipName: mox-mail-ip
   publicIPs:
     ipv4: "203.0.113.5"
   ```

**Option B: Use Azure Service Operator**

```yaml
azure:
  serviceOperator:
    enabled: true
    resourceGroup: my-rg
    location: eastus
    publicIP:
      name: mox-mail-ip
      domainNameLabel: mail
      reverseFqdn: "mail.example.com."
```

> **Note:** Azure only supports IPv4 reverse DNS. Forward DNS (A record) must resolve to the Public IP before Azure will accept the `reverseFqdn`.

### Source IP Preservation

The chart sets `externalTrafficPolicy: Local` by default. This is **critical** for mox because it preserves the real client source IP for spam filtering, DNSBL checks, and rate limiting. Do not change this unless you understand the security implications.

## DNS Record Checklist

For each hosted domain, create these DNS records:

| Record | Name | Value |
|---|---|---|
| **A** | `mail.example.com` | `<public-ip>` |
| **MX** | `example.com` | `10 mail.example.com.` |
| **SPF** | `example.com` | `"v=spf1 ip4:<public-ip> ~all"` |
| **DKIM** | `sel1._domainkey.example.com` | `"v=DKIM1; k=ed25519; p=<public-key>"` |
| **DMARC** | `_dmarc.example.com` | `"v=DMARC1; p=reject; rua=mailto:dmarcreports@example.com"` |
| **MTA-STS** | `_mta-sts.example.com` | `"v=STSv1; id=<policy-id>"` |
| **TLSRPT** | `_smtp._tls.example.com` | `"v=TLSRPTv1; rua=mailto:tlsreports@example.com"` |

If DNSSEC is enabled on your DNS provider (Required: Route53, Cloudflare. **Not supported:** Azure DNS):

| Record | Name | Value |
|---|---|---|
| **TLSA** | `_25._tcp.mail.example.com` | `3 1 1 <cert-fingerprint>` |

## Uninstall & Cleanup

When you run `helm uninstall`, the chart automatically cleans up external resources via **pre-delete hooks**:

| Hook Weight | Job | What it does |
|---|---|---|
| 0 | Route53 credentials secret | Makes AWS credentials available for cleanup hooks |
| 1 | Reverse DNS delete | Removes `reverseFqdn` from ASO PublicIPAddress |
| 2 | DANE TLSA delete | Deletes `_25._tcp` and `_465._tcp` TLSA records from Route53 |
| 5 | DNS delete | Deletes all managed DNS records (A, MX, SPF, DKIM, DMARC, MTA-STS, TLSRPT, SRV, CNAME) |
| 8 | DNSSEC delete | Disables DNSSEC zone signing (**opt-in only**) |

### DNSSEC Teardown (Opt-in)

DNSSEC teardown is **disabled by default** because it is zone-scoped and destructive — disabling DNSSEC affects *all* records in the hosted zone, breaks DANE validation and DS record trust chains. To enable automatic DNSSEC teardown on uninstall:

```yaml
route53:
  dnssec:
    deleteOnUninstall: true
```

When enabled, the teardown hook will: disassociate the DS record from the registrar, disable zone signing, deactivate and delete the KSK. The KMS key is **never deleted** (it is reusable and has no idle cost).

### Resources NOT cleaned up by uninstall

| Resource | Reason |
|---|---|
| ASO `PublicIPAddress` CRD | Has `helm.sh/resource-policy: keep` — preserves the IP across upgrades. Delete manually with `kubectl delete publicipaddress <name>` before deleting the namespace. |
| Azure Public IP (if ASO PIP orphaned) | Only cleaned up if ASO processes the CRD deletion. |
| cert-manager Certificate & TLS Secret | Has `helm.sh/resource-policy: keep` — avoids Let's Encrypt rate limits. |

## Values Reference

| Key | Description | Default |
|---|---|---|
| `image.repository` | Container image repository | `r.xmox.nl/mox` |
| `image.tag` | Container image tag | `latest` |
| `hostname` | Mail server FQDN | `mail.example.com` |
| `publicIPs.ipv4` | Public IPv4 (for NATIPs/SPF) | `""` |
| `publicIPs.ipv6` | Public IPv6 (optional) | `""` |
| `logLevel` | Log level | `info` |
| `admin.passwordHash` | Bcrypt hash of admin password | `""` |
| `admin.existingSecret` | Existing secret with admin password | `""` |
| `domains` | Email domains to host | `{}` |
| `accounts` | User accounts | `{}` |
| `listeners.smtp.enabled` | Enable SMTP (port 25) | `true` |
| `listeners.submissions.enabled` | Enable SMTPS (port 465) | `true` |
| `listeners.submission.enabled` | Enable Submission (port 587) | `true` |
| `listeners.imaps.enabled` | Enable IMAPS (port 993) | `true` |
| `listeners.imap.enabled` | Enable IMAP (port 143) | `true` |
| `listeners.webmail.enabled` | Enable webmail | `true` |
| `listeners.webapi.enabled` | Enable WebAPI | `false` |
| `listeners.admin.enabled` | Enable admin panel | `true` |
| `listeners.metrics.enabled` | Enable Prometheus metrics | `true` |
| `service.type` | Service type | `LoadBalancer` |
| `service.externalTrafficPolicy` | Traffic policy | `Local` |
| `service.loadBalancerIP` | Pre-provisioned LB IP | `""` |
| `service.azure.resourceGroup` | Azure RG for pre-provisioned IP | `""` |
| `service.azure.pipName` | Azure Public IP name | `""` |
| `transport.enabled` | Enable smarthost relay | `false` |
| `transport.host` | Relay hostname | `""` |
| `certManager.enabled` | Use cert-manager for TLS | `true` |
| `certManager.issuerRef.name` | cert-manager issuer name | `letsencrypt-prod` |
| `certManager.issuerRef.kind` | Issuer kind | `ClusterIssuer` |
| `dnssec.enabled` | Enable DNSSEC/DANE support | `false` |
| `persistence.enabled` | Enable persistent storage | `true` |
| `persistence.size` | Storage size | `10Gi` |
| `persistence.storageClassName` | Storage class | `""` (default) |
| `azure.serviceOperator.enabled` | Use ASO for Public IP | `false` |
| `route53.enabled` | Enable Route53 DNS management | `false` |
| `route53.dnssec.enabled` | Enable Route53 DNSSEC signing | `false` |
| `route53.dnssec.deleteOnUninstall` | Tear down DNSSEC on `helm uninstall` | `false` |
| `metrics.serviceMonitor.enabled` | Create ServiceMonitor | `false` |
| `networkPolicy.enabled` | Create NetworkPolicy | `false` |
| `podDisruptionBudget.enabled` | Create PDB | `false` |

## Cutting a Release

Just push a semver tag.

```sh
gtag v0.2.0
```
