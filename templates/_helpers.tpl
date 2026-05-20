{{/*
Expand the name of the chart.
*/}}
{{- define "mox.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "mox.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "mox.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "mox.labels" -}}
helm.sh/chart: {{ include "mox.chart" . }}
{{ include "mox.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "mox.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mox.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Return the TLS secret name for cert-manager or manual certs.
*/}}
{{- define "mox.tlsSecretName" -}}
{{- printf "%s-tls" (include "mox.fullname" .) }}
{{- end }}

{{/*
Return the secret name holding mox config secrets (domains.conf, DKIM keys, admin password).
*/}}
{{- define "mox.secretName" -}}
{{- if .Values.existingSecret }}
{{- .Values.existingSecret }}
{{- else }}
{{- printf "%s-secret" (include "mox.fullname" .) }}
{{- end }}
{{- end }}

{{/*
Build the list of NATIPs from staticPublicIPs values.
Returns a YAML list suitable for embedding in mox.conf sconf format.
*/}}
{{- define "mox.natIPs" -}}
{{- if .Values.staticPublicIPs.ipv4 }}
      - {{ .Values.staticPublicIPs.ipv4 }}
{{- end }}
{{- if .Values.staticPublicIPs.ipv6 }}
      - {{ .Values.staticPublicIPs.ipv6 }}
{{- end }}
{{- end }}

{{/*
Build the list of dnsNames for the cert-manager Certificate.
Includes hostname + autoconfig/mta-sts subdomains for each domain.
The bare domain name is intentionally excluded — its A record may point
elsewhere (e.g. a static website), which would break HTTP-01 validation.
Users who need the bare domain can add it via additionalDnsNames.
*/}}
{{- define "mox.certDnsNames" -}}
- {{ .Values.hostname }}
{{- range $cfg := .Values.domains }}
- autoconfig.{{ $cfg.name }}
- mta-sts.{{ $cfg.name }}
{{- end }}
{{- if and .Values.tlsManagement.enabled .Values.tlsManagement.provider }}
  {{- $providerName := .Values.tlsManagement.provider }}
  {{- $provider := index .Values.providers $providerName }}
  {{- range (default (list) (dig "config" "additionalDnsNames" (list) $provider)) }}
- {{ . }}
  {{- end }}
{{- end }}
{{- end }}

{{/*
Split a string into 255-byte quoted chunks for DNS TXT records.
DNS TXT RRs limit each character string to 255 bytes; longer values
must be split into multiple quoted strings that receivers concatenate.
Outputs escaped-quote-delimited chunks suitable for Route53 JSON:
  \"chunk1\" \"chunk2\"
*/}}
{{- define "mox.txtChunks" -}}
{{- $s := . -}}
{{- if le (len $s) 255 -}}
\"{{ $s }}\"
{{- else -}}
\"{{ substr 0 255 $s }}\" {{ include "mox.txtChunks" (substr 255 (len $s) $s) }}
{{- end -}}
{{- end -}}

{{/*
Resolve a provider by name from the providers map.
Usage: include "mox.provider" (dict "name" "dnsProvider" "providers" .Values.providers)
Returns the full provider object (with platform and config keys).
Fails with a clear error if the provider name is not defined in the providers map.
*/}}
{{- define "mox.provider" -}}
{{- $name := .name -}}
{{- $providers := .providers -}}
{{- if not (hasKey $providers $name) -}}
{{- fail (printf "provider %q is not defined in .Values.providers — add it to the providers map" $name) -}}
{{- end -}}
{{- index $providers $name | toYaml -}}
{{- end -}}

{{/*
Resolve a provider's platform string.
Usage: include "mox.providerPlatform" (dict "name" "dnsProvider" "providers" .Values.providers)
Returns the platform string (e.g., "aws", "azureAso", "certManager").
Fails if the provider is not defined or has no platform set.
*/}}
{{- define "mox.providerPlatform" -}}
{{- $name := .name -}}
{{- $providers := .providers -}}
{{- if not (hasKey $providers $name) -}}
{{- fail (printf "provider %q is not defined in .Values.providers — add it to the providers map" $name) -}}
{{- end -}}
{{- $provider := index $providers $name -}}
{{- if not $provider.platform -}}
{{- fail (printf "provider %q has no platform set — set .Values.providers.%s.platform" $name $name) -}}
{{- end -}}
{{- $provider.platform -}}
{{- end -}}

{{/*
Resolve a provider's config map.
Usage: $cfg := include "mox.providerConfig" (dict "name" "dnsProvider" "providers" .Values.providers) | fromYaml
Returns the config map as YAML (use | fromYaml to convert to a dict).
Fails if the provider is not defined or has no config.
*/}}
{{- define "mox.providerConfig" -}}
{{- $name := .name -}}
{{- $providers := .providers -}}
{{- if not (hasKey $providers $name) -}}
{{- fail (printf "provider %q is not defined in .Values.providers — add it to the providers map" $name) -}}
{{- end -}}
{{- $provider := index $providers $name -}}
{{- if not $provider.config -}}
{{- fail (printf "provider %q has no config set — set .Values.providers.%s.config" $name $name) -}}
{{- end -}}
{{- $provider.config | toYaml -}}
{{- end -}}

{{/*
Validate that a feature's provider exists and has the expected platform.
Usage: include "mox.requireProvider" (dict "feature" "dns" "name" "dnsProvider" "expectedPlatform" "aws" "providers" .Values.providers)
Fails with a descriptive error if validation fails. Returns empty string on success.
*/}}
{{- define "mox.requireProvider" -}}
{{- $feature := .feature -}}
{{- $name := .name -}}
{{- $expected := .expectedPlatform -}}
{{- $providers := .providers -}}
{{- if not $name -}}
{{- fail (printf "feature %q has enabled: true but no provider name set — set %s.provider to a provider name from .Values.providers" $feature $feature) -}}
{{- end -}}
{{- if not (hasKey $providers $name) -}}
{{- fail (printf "feature %q references provider %q but it is not defined in .Values.providers" $feature $name) -}}
{{- end -}}
{{- $provider := index $providers $name -}}
{{- if not $provider.platform -}}
{{- fail (printf "feature %q references provider %q which has no platform set" $feature $name) -}}
{{- end -}}
{{- if ne $provider.platform $expected -}}
{{- fail (printf "feature %q requires platform %q but provider %q has platform %q" $feature $expected $name $provider.platform) -}}
{{- end -}}
{{- end -}}

{{/*
Return the DKIM provider name from the first domain that has dkim.provider set.
Used by global-scope templates (keygen job, generated secret name) that don't
have a single domain context. All domains sharing DKIM auto-generation must
reference the same provider.
Fails if no domain has a DKIM provider configured.
*/}}
{{- define "mox.dkimProviderName" -}}
{{- $found := "" -}}
{{- range $cfg := .Values.domains -}}
  {{- if and $cfg.dkim $cfg.dkim.provider (not $found) -}}
    {{- $found = $cfg.dkim.provider -}}
  {{- end -}}
{{- end -}}
{{- if not $found -}}
{{- fail "no domain has dkim.provider set — at least one domain must reference a DKIM provider" -}}
{{- end -}}
{{- $found -}}
{{- end -}}

{{/*
Return the Secret name for auto-generated DKIM keys.
Dynamically resolves the DKIM provider config via mox.dkimProviderName.
*/}}
{{- define "mox.dkimGeneratedSecretName" -}}
{{- $providerName := include "mox.dkimProviderName" . -}}
{{- $cfg := include "mox.providerConfig" (dict "name" $providerName "providers" .Values.providers) | fromYaml -}}
{{- if $cfg.secretName }}
{{- $cfg.secretName }}
{{- else }}
{{- printf "%s-dkim" (include "mox.fullname" .) }}
{{- end }}
{{- end }}

{{/*
Check whether a domain needs DKIM key auto-generation.
Precedence:
  1. Domain has explicit keys (privateKey or existingSecret) → false
  2. Domain has dkim.enabled explicitly set → use that value
  3. Otherwise → false (no global toggle)
When enabled is true, the domain must also have dkim.provider set.
Usage: include "mox.domainNeedsDkimGeneration" (dict "domain" $domainObj "global" $)
Returns "true" or "" (empty string / falsy).
*/}}
{{- define "mox.domainNeedsDkimGeneration" -}}
{{- $domain := .domain -}}
{{- $global := .global -}}
{{- $hasExplicitKeys := false -}}
{{- if $domain.dkim -}}
  {{- range $sel, $selCfg := $domain.dkim.selectors -}}
    {{- if or $selCfg.privateKey $selCfg.existingSecret -}}
      {{- $hasExplicitKeys = true -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- if $hasExplicitKeys -}}
{{- else if and $domain.dkim (hasKey $domain.dkim "enabled") -}}
  {{- if $domain.dkim.enabled -}}
    {{- if not $domain.dkim.provider -}}
      {{- fail (printf "domain %q has dkim.enabled: true but no dkim.provider set — set dkim.provider to a provider name from .Values.providers" $domain.name) -}}
    {{- end -}}
    {{- include "mox.requireProvider" (dict "feature" (printf "dkim for domain %s" $domain.name) "name" $domain.dkim.provider "expectedPlatform" "dkimKeygen" "providers" $global.Values.providers) -}}
true
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Check whether ANY domain in the chart needs DKIM key auto-generation.
Used as a guard for rendering keygen infrastructure (RBAC, Job, ConfigMap).
Returns "true" or "" (empty string / falsy).
*/}}
{{- define "mox.anyDomainNeedsDkimGeneration" -}}
{{- range $cfg := .Values.domains -}}
  {{- if include "mox.domainNeedsDkimGeneration" (dict "domain" $cfg "global" $) -}}
true
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Return the effective DKIM selectors for a domain.
If the domain has explicit selectors defined, those are returned as-is.
Otherwise, if auto-generation is enabled, returns the default selectors
from the domain's referenced DKIM provider config (map of name→algorithm).
Usage: include "mox.dkimSelectorsForDomain" (dict "domain" $domainObj "global" $)
Returns YAML map: { sel1: { algorithm: ed25519 }, rsa1: { algorithm: rsa } }
*/}}
{{- define "mox.dkimSelectorsForDomain" -}}
{{- $domain := .domain -}}
{{- $global := .global -}}
{{- if and $domain.dkim $domain.dkim.selectors -}}
{{- $domain.dkim.selectors | toYaml -}}
{{- else if include "mox.domainNeedsDkimGeneration" (dict "domain" $domain "global" $global) -}}
{{- $cfg := include "mox.providerConfig" (dict "name" $domain.dkim.provider "providers" $global.Values.providers) | fromYaml -}}
{{- range $sel, $alg := $cfg.defaultSelectors -}}
{{ $sel }}:
  algorithm: {{ $alg }}
{{ end -}}
{{- end -}}
{{- end -}}

{{/*
Check whether ANY domain has dns.enabled: true.
Used as a gate for rendering DNS hook infrastructure (Secret, ConfigMap, Job).
Returns "true" or "" (empty string / falsy).
*/}}
{{- define "mox.anyDomainHasDns" -}}
{{- range $cfg := .Values.domains -}}
  {{- if and $cfg.dns $cfg.dns.enabled -}}
true
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Check whether ANY domain has dnssec.enabled: true.
Used as a gate for rendering DNSSEC/DANE hook infrastructure.
Also used for HostPrivateKeyFiles in configmap.yaml.
Returns "true" or "" (empty string / falsy).
*/}}
{{- define "mox.anyDomainHasDnssec" -}}
{{- range $cfg := .Values.domains -}}
  {{- if and $cfg.dnssec $cfg.dnssec.enabled -}}
true
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Return the DNS provider name used by the first dns-enabled domain.
All dns-enabled domains must reference the same provider (enforced by
mox.validateSameDnsProvider). This helper extracts the shared provider name.
Fails if no domain has dns.enabled: true.
*/}}
{{- define "mox.dnsProvider" -}}
{{- $found := "" -}}
{{- range $cfg := .Values.domains -}}
  {{- if and $cfg.dns $cfg.dns.enabled $cfg.dns.provider -}}
    {{- if not $found -}}
      {{- $found = $cfg.dns.provider -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- if not $found -}}
{{- fail "no domain has dns.enabled with a provider set" -}}
{{- end -}}
{{- $found -}}
{{- end -}}

{{/*
Return the DNSSEC provider name used by the first dnssec-enabled domain.
All dnssec-enabled domains must reference the same provider (enforced by
mox.validateSameDnssecProvider). This helper extracts the shared provider name.
Fails if no domain has dnssec.enabled: true.
*/}}
{{- define "mox.dnssecProvider" -}}
{{- $found := "" -}}
{{- range $cfg := .Values.domains -}}
  {{- if and $cfg.dnssec $cfg.dnssec.enabled $cfg.dnssec.provider -}}
    {{- if not $found -}}
      {{- $found = $cfg.dnssec.provider -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- if not $found -}}
{{- fail "no domain has dnssec.enabled with a provider set" -}}
{{- end -}}
{{- $found -}}
{{- end -}}

{{/*
Validate that all dns-enabled domains reference the same provider.
Call this early in any DNS template to fail fast on misconfiguration.
Returns empty string on success; fails with a descriptive error otherwise.
*/}}
{{- define "mox.validateSameDnsProvider" -}}
{{- $first := "" -}}
{{- range $cfg := .Values.domains -}}
  {{- if and $cfg.dns $cfg.dns.enabled $cfg.dns.provider -}}
    {{- if not $first -}}
      {{- $first = $cfg.dns.provider -}}
    {{- else if ne $first $cfg.dns.provider -}}
      {{- fail (printf "all dns-enabled domains must reference the same provider, but found %q and %q — multi-provider DNS is not yet supported" $first $cfg.dns.provider) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Validate that all dnssec-enabled domains reference the same provider.
Call this early in any DNSSEC template to fail fast on misconfiguration.
Returns empty string on success; fails with a descriptive error otherwise.
*/}}
{{- define "mox.validateSameDnssecProvider" -}}
{{- $first := "" -}}
{{- range $cfg := .Values.domains -}}
  {{- if and $cfg.dnssec $cfg.dnssec.enabled $cfg.dnssec.provider -}}
    {{- if not $first -}}
      {{- $first = $cfg.dnssec.provider -}}
    {{- else if ne $first $cfg.dnssec.provider -}}
      {{- fail (printf "all dnssec-enabled domains must reference the same provider, but found %q and %q — multi-provider DNSSEC is not yet supported" $first $cfg.dnssec.provider) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Check whether the domain covering .Values.hostname has dnssec.enabled: true.
Used to gate DANE TLSA record creation (DANE is per-hostname, not per-domain).
Matches when hostname equals the domain name OR is a subdomain of it
(e.g. hostname "mail.cooperly.net" matches domain "cooperly.net").
Returns "true" or "" (empty string / falsy).
*/}}
{{- define "mox.hostnameDomainHasDnssec" -}}
{{- range $cfg := .Values.domains -}}
  {{- if or (eq $cfg.name $.Values.hostname) (hasSuffix (printf ".%s" $cfg.name) $.Values.hostname) -}}
    {{- if and $cfg.dnssec $cfg.dnssec.enabled -}}
true
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Check whether hostTlsrpt is enabled.
Returns "true" or "" (empty string / falsy).
*/}}
{{- define "mox.hostTlsrptEnabled" -}}
{{- if .Values.hostTlsrpt.enabled -}}
true
{{- end -}}
{{- end -}}

{{/*
Check whether ANY domain has tlsrpt.enabled: true.
Returns "true" or "" (empty string / falsy).
*/}}
{{- define "mox.anyDomainHasTlsrpt" -}}
{{- range $cfg := .Values.domains -}}
  {{- if and $cfg.tlsrpt $cfg.tlsrpt.enabled -}}
true
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Check whether the DNS hook infrastructure needs to render.
True when any domain has dns.enabled, or hostTlsrpt is enabled,
or any domain has tlsrpt.enabled (all create DNS records via the hook).
Returns "true" or "" (empty string / falsy).
*/}}
{{- define "mox.anyNeedsDnsHook" -}}
{{- if or (include "mox.anyDomainHasDns" .) (include "mox.hostTlsrptEnabled" .) (include "mox.anyDomainHasTlsrpt" .) -}}
true
{{- end -}}
{{- end -}}

{{/*
Validate that all tlsrpt-enabled features reference valid AWS providers and
that all tlsrpt providers match each other. When domain DNS is also enabled,
validates that tlsrpt providers match the DNS provider (the DNS hook batches
all Route53 changes into a single API call to one hosted zone).
Call this early in any DNS template that handles tlsrpt records.
Returns empty string on success; fails with a descriptive error otherwise.
*/}}
{{- define "mox.validateTlsrptProviders" -}}
{{- $first := "" -}}
{{- if .Values.hostTlsrpt.enabled -}}
  {{- include "mox.requireProvider" (dict "feature" "hostTlsrpt" "name" .Values.hostTlsrpt.provider "expectedPlatform" "aws" "providers" .Values.providers) -}}
  {{- $first = .Values.hostTlsrpt.provider -}}
{{- end -}}
{{- range $cfg := .Values.domains -}}
  {{- if and $cfg.tlsrpt $cfg.tlsrpt.enabled -}}
    {{- include "mox.requireProvider" (dict "feature" (printf "domains[%s].tlsrpt" $cfg.name) "name" $cfg.tlsrpt.provider "expectedPlatform" "aws" "providers" $.Values.providers) -}}
    {{- if not $first -}}
      {{- $first = $cfg.tlsrpt.provider -}}
    {{- else if ne $first $cfg.tlsrpt.provider -}}
      {{- fail (printf "all tlsrpt-enabled features must reference the same provider, but found %q and %q — multi-provider TLSRPT is not yet supported" $first $cfg.tlsrpt.provider) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- if and $first (include "mox.anyDomainHasDns" .) -}}
  {{- $dnsProvider := include "mox.dnsProvider" . -}}
  {{- if ne $first $dnsProvider -}}
    {{- fail (printf "tlsrpt provider %q must match the DNS provider %q — the DNS hook batches all Route53 changes into a single API call" $first $dnsProvider) -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Return the provider name for the DNS hook.
Prefers the DNS provider (from dns-enabled domains). Falls back to the
tlsrpt provider (from hostTlsrpt or tlsrpt-enabled domains) when no domain
has dns.enabled. All providers are validated to match by mox.validateTlsrptProviders.
Fails if no DNS or tlsrpt provider can be found.
*/}}
{{- define "mox.dnsHookProvider" -}}
{{- if include "mox.anyDomainHasDns" . -}}
  {{- include "mox.dnsProvider" . -}}
{{- else if .Values.hostTlsrpt.enabled -}}
  {{- .Values.hostTlsrpt.provider -}}
{{- else -}}
  {{- $found := "" -}}
  {{- range $cfg := .Values.domains -}}
    {{- if and $cfg.tlsrpt $cfg.tlsrpt.enabled $cfg.tlsrpt.provider -}}
      {{- if not $found -}}
        {{- $found = $cfg.tlsrpt.provider -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- if not $found -}}
    {{- fail "no DNS or tlsrpt provider found for the DNS hook — enable dns or tlsrpt on at least one domain, or enable hostTlsrpt" -}}
  {{- end -}}
  {{- $found -}}
{{- end -}}
{{- end -}}
