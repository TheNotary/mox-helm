# Mox Helm Chart — Architecture Diagrams

## 3rd-Party Provider Automation

The chart uses Helm lifecycle hooks and Kubernetes CRDs to orchestrate external
providers during install, upgrade, and uninstall. Jobs execute in the order
determined by their hook-weight annotations.

### Install / Upgrade

#### Hook Execution Order

Hooks run sequentially by weight. Pre-install hooks generate DKIM keys and
store them in a Kubernetes Secret. Post-install hooks read those keys and
provision external resources.

```mermaid
flowchart TB
  subgraph pre["Pre-Install & Pre-Upgrade"]
    direction TB
    RBAC["RBAC Resources\n(SA, Role, RoleBinding)\nweight: -10"]
    DKIM["DKIM Keygen Job\n(alpine + openssl)\nweight: -5"]
    RBAC --> DKIM
  end

  K8S_SECRET[("K8s Secret\n(DKIM Keys)")]
  DKIM -- "writes ED25519 +\nRSA key pairs" --> K8S_SECRET

  subgraph resources["Kubernetes Resources Applied"]
    direction TB
    CERT["cert-manager Certificate CR"]
    PIP["Azure ASO PublicIPAddress CR"]
    SVC["LoadBalancer Service"]
    DEP["Mox Deployment"]
  end

  pre --> resources

  subgraph post["Post-Install & Post-Upgrade"]
    direction TB
    DNSSEC["DNSSEC Job\nweight: 2"]
    DNS["DNS Records Job\nweight: 5"]
    DANE["DANE TLSA Job\nweight: 7"]
    RDNS["Reverse DNS Job\nweight: 10"]
    DNSSEC --> DNS --> DANE --> RDNS
  end

  resources --> post
  DNS -- "reads DKIM\npublic keys" --> K8S_SECRET
```

#### External Provider Interactions

Each hook and CRD targets a specific external provider to automate
infrastructure that a mail server depends on.

```mermaid
flowchart LR
  subgraph hooks["Helm Hooks & CRDs"]
    direction TB
    DNSSEC["DNSSEC Job"]
    DNS["DNS Records Job"]
    DANE["DANE TLSA Job"]
    RDNS["Reverse DNS Job"]
    CERT["cert-manager\nCertificate CR"]
    PIP["Azure ASO\nPublicIPAddress CR"]
  end

  subgraph r53["Route 53 Hosted Zone"]
    direction TB
    R53_DNSSEC["DNSSEC zone signing"]
    R53_REC["MX, SPF, DKIM TXT,\nDMARC, MTA-STS,\nTLSRPT, autoconfig\nCNAME, SRV"]
    R53_TLSA["TLSA 3 1 1\n_25._tcp\n_465._tcp"]
  end

  KMS["AWS KMS\n(ECC_NIST_P256)"]
  R53D["Route 53 Domains\n(DS Registration)"]
  ARM["Azure ARM API\n(Public IP)"]
  CA["Let's Encrypt\nACME CA"]

  DNSSEC -- "create KMS key\ncreate KSK" --> KMS
  DNSSEC -- "enable signing" --> R53_DNSSEC
  DNSSEC -- "register DS" --> R53D

  DNS -- "UPSERT records" --> R53_REC

  DANE -- "UPSERT TLSA" --> R53_TLSA

  RDNS -- "wait for A record\npatch reverseFqdn" --> ARM

  PIP -- "provision static IP\n(Standard SKU)" --> ARM

  CERT -- "issue TLS cert\n(hostname + domains +\nautoconfig.* + mta-sts.*)" --> CA
```

### Uninstall

Cleanup hooks run in ascending weight order before resources are deleted.

```mermaid
flowchart TB
  subgraph Helm["Helm Uninstall"]
    direction TB

    subgraph pre_delete["Pre-Delete Hooks"]
      direction TB
      RDNS_DEL["Reverse DNS Delete\nweight: 1"]
      DANE_DEL["DANE Delete\nweight: 2"]
      DNS_DEL["DNS Records Delete\nweight: 5"]
      DNSSEC_DEL["DNSSEC Delete\nweight: 8\n(opt-in per domain)"]
      RDNS_DEL --> DANE_DEL --> DNS_DEL --> DNSSEC_DEL
    end
  end

  subgraph aws["AWS"]
    direction TB
    R53["Route 53\nHosted Zone"]
    KMS["KMS"]
    R53D["Route 53 Domains"]
  end

  subgraph azure["Azure"]
    ARM["ARM API\n(Public IP)"]
  end

  RDNS_DEL -- "clear reverseFqdn" --> ARM
  DANE_DEL -- "DELETE TLSA records" --> R53
  DNS_DEL -- "DELETE MX, SPF, DKIM,\nDMARC, MTA-STS, TLSRPT,\nautoconfig, SRV records" --> R53
  DNSSEC_DEL -- "disable signing\ndeactivate KSK\ndisassociate DS" --> R53
  DNSSEC_DEL -- "schedule key deletion" --> KMS
  DNSSEC_DEL -- "remove DS record" --> R53D

  NOTE["Note: cert-manager Secret\nis preserved across uninstall\n(rate-limit protection)"]

  style NOTE fill:#fff3cd,stroke:#ffc107,color:#000
```

## Inbound Traffic Flow

All mail and web traffic enters through a single `LoadBalancer` Service with
`externalTrafficPolicy: Local` to preserve the original client IP (required for
SPF validation and abuse tracking). TLS terminates at the mox process, not the
load balancer.

```mermaid
flowchart TB
  INTERNET(("Internet\n(Senders, Clients,\nBrowsers)"))

  subgraph cloud_lb["Cloud Load Balancer"]
    LB["Network Load Balancer\nStatic Public IP\n(Azure ASO or manual)"]
  end

  INTERNET --> LB

  subgraph k8s_svc["Kubernetes Service (LoadBalancer)"]
    SVC["externalTrafficPolicy: Local\n(preserves source IP)"]
  end

  LB --> SVC

  subgraph ports["TCP Port Mapping"]
    direction LR
    P25["25\nSMTP"]
    P465["465\nSubmissions\n(TLS)"]
    P587["587\nSubmission\n(STARTTLS)"]
    P993["993\nIMAPS\n(TLS)"]
    P143["143\nIMAP"]
    P80["80\nHTTP"]
    P443["443\nHTTPS"]
  end

  SVC --> ports

  subgraph pod["Mox Pod"]
    direction TB

    TLS_CERTS[/"TLS Certs\n(cert-manager Secret\nmounted at /mox/tls/)"/]

    MOX["mox process\n(handles TLS termination)"]

    subgraph listeners["Listeners"]
      direction LR
      L_SMTP["SMTP\n(inbound mail\nreception)"]
      L_SUB["Submissions /\nSubmission\n(client mail\nsubmission)"]
      L_IMAP["IMAPS / IMAP\n(mailbox\naccess)"]
      L_WEB["Webmail &\nAdmin UI"]
      L_AUTO["Autoconfig &\nMTA-STS\npolicy"]
    end

    TLS_CERTS --> MOX
    MOX --> listeners
  end

  P25 --> L_SMTP
  P465 --> L_SUB
  P587 --> L_SUB
  P993 --> L_IMAP
  P143 --> L_IMAP
  P80 --> L_AUTO
  P443 --> L_WEB

  subgraph storage["Persistent Storage"]
    PVC[("PVC\n(/mox/data/)\nBoltDB mailboxes\n+ message queue")]
  end

  L_SMTP -- "deliver to\nmailbox" --> PVC
  L_IMAP -- "read from\nmailbox" --> PVC
```

## Outbound Traffic Flow

Mox delivers outbound mail directly over SMTP port 25. A DNSSEC-validating
Unbound sidecar provides authenticated DNS resolution with Extended DNS Error
reporting. The static public IP (from Azure ASO or `staticPublicIPs`) is
configured as a NAT IP so receiving servers see a consistent, PTR-verified
source address.

```mermaid
flowchart TB
  subgraph pod["Mox Pod"]
    direction TB
    MOX["mox process"]

    subgraph sidecar["Unbound Sidecar (optional)"]
      UB["unbound\n127.0.0.1:53\nDNSSEC validation\nExtended DNS Errors"]
    end
  end

  subgraph dns_resolve["DNS Resolution"]
    direction TB
    COREDNS["CoreDNS\n(cluster default)"]

    subgraph upstream["Upstream Resolvers (DoT)"]
      direction LR
      CF["Cloudflare\n1.1.1.1:853\n1.0.0.1:853"]
      GOOG["Google\n8.8.8.8:853\n8.8.4.4:853"]
    end
  end

  MOX -- "DNS query\n(port 53)" --> UB
  UB -- "forward\n(DNS-over-TLS)" --> CF
  UB -- "forward\n(DNS-over-TLS)" --> GOOG
  MOX -. "fallback\n(no sidecar)" .-> COREDNS

  subgraph nat["Source IP"]
    NATIP["Static Public IP\n(NATIPs in mox.conf)\nfrom ASO or staticPublicIPs"]
  end

  subgraph dest_smtp["Destination Mail Servers"]
    MX["Recipient MX Servers\n(port 25)"]
  end

  subgraph dest_https["HTTPS Endpoints"]
    direction LR
    MTASTS["MTA-STS\nPolicy Servers"]
    OCSP["OCSP\nResponders"]
  end

  MOX -- "SMTP delivery\n(port 25 TCP)" --> NATIP
  NATIP -- "outbound\nSMTP" --> MX

  MOX -- "policy fetch\n(port 443)" --> MTASTS
  MOX -- "cert validation\n(port 443)" --> OCSP

  subgraph netpol["NetworkPolicy Egress Rules"]
    direction LR
    R_DNS["DNS\n53 UDP/TCP"]
    R_SMTP["SMTP\n25 TCP"]
    R_HTTPS["HTTPS\n443 TCP"]
  end

  style netpol fill:#e8f4e8,stroke:#28a745,color:#000
```
