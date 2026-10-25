# Certificates (cert-manager and Let's Encrypt)

cert-manager v1.21.3 issues public certificates from Let's Encrypt with the DNS-01 challenge on
Cloudflare. Nothing listens on the nodes for HTTP-01, so DNS-01 is the only challenge that works.

## What runs where

| Piece | Where | Owner |
| --- | --- | --- |
| controller, webhook, cainjector | `cert-manager`, on the control planes (recovery set), one replica each | Flux Kustomization `cert-manager` |
| ClusterIssuers `letsencrypt-production`, `letsencrypt-staging` | cluster-wide; solve DNS-01 for `unfoldhq.dev` only | Flux Kustomization `cert-manager-issuers` (after `cert-manager` and `external-secrets`) |
| Certificate `cert-manager/dns01-canary` | `dns01-canary.unfold.unfoldhq.dev` from the staging issuer, renewed every 30 days | same |
| Secret `cert-manager/cloudflare-dns01` | ExternalSecret from OpenBao `secret/unfold-main/cert-manager/cloudflare-dns01`, property `api-token` | same |

## The Cloudflare token is minted, not typed

The homelab's `cloudflare-dns-token-minter` CronJob (homelab-cluster ADR-0061) mints
`dns-acme-unfoldhq-dev`: Zone Read and DNS Write on the one zone `unfoldhq.dev`, the least
cert-manager can solve DNS-01 with (it reads the zone to find its ID, then writes the TXT record).
The token lives 90 days and is renewed 30 days before it expires; a PushSecret writes each new value
to the OpenBao path above, External Secrets refreshes the Secret hourly, and cert-manager reads it
on every challenge. Nobody sees or types it.

Adding a zone: add `zone=zone-id` to `ACME_DNS_ZONES` in that CronJob, a line to the
`cloudflare-dns-acme-tokens` PushSecret, and the zone to the issuers' `dnsZones`.

## Egress

The controller may open exactly `acme-v02.api.letsencrypt.org`, `acme-staging-v02.api.letsencrypt.org`,
`api.cloudflare.com` and `cloudflare-dns.com` on 443, learned through Cilium's DNS proxy. It checks
that a TXT record has propagated with DNS-over-HTTPS to Cloudflare's resolver
(`dns01RecursiveNameserversOnly`), so it needs no port 53 to the internet.

## Proving it works

Once the homelab gateway is up (External Secrets then syncs) and the minter has run once:

```sh
kubectl --kubeconfig ~/.kube/unfold.yaml -n cert-manager get externalsecret cloudflare-dns01
kubectl --kubeconfig ~/.kube/unfold.yaml get clusterissuer
kubectl --kubeconfig ~/.kube/unfold.yaml -n cert-manager get certificate dns01-canary
```

`dns01-canary` Ready means the whole chain works: OpenBao, the gateway, External Secrets, the
token's scope, Cloudflare, Let's Encrypt and the egress policy. It is a staging certificate, so it
proves the path without spending production rate limit or appearing in public CT logs as a real
certificate.

The internal CA on OpenBao PKI, trust-manager and approver-policy (RFC 0001 section 11) come later.
