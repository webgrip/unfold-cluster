---
status: proposed
date: 2026-10-26
---

# ADR 0014: Operators sign in to production through Google Workspace directly; the homelab Authentik leaves the production login path

## Context and problem statement

People sign in to this cluster's Kubernetes API and join its tailnet through the homelab
Authentik ([kubernetes-login](../runbooks/kubernetes-login.md),
[headscale-browser-login](../runbooks/headscale-browser-login.md)). Authentik itself signs people in
through Google Workspace (homelab ADR-0057). Production login therefore needs Google **and** the
homelab (Authentik, its database, the Cloudflare tunnel for the signing keys, the homelab gateway
for Headscale), and is lost if Google **or** the homelab is compromised: whoever controls Authentik
can issue a token with `unfold_groups: [unfold-admins]` and register a tailnet device. RFC 0001's
threat model lists that homelab-to-production edge as open.

RFC 0001 section 2 designed one issuer, Google, with CEL claim rules. The cluster was built on
Authentik instead, because Authentik could carry a groups claim and a passkey step. The homelab made
the opposite choice for its own API in ADR-0059: "Authentication must not depend on a component
that runs on the cluster it protects", and Google is the identity provider that runs on neither.

The owner asked who can log in to production, and how. The full access matrix, the roles and the
gaps are in [identity and access](../architecture/identity-and-access.md).

## Facts the decision rests on

Read from source on 2026-10-26.

- `infra/kube-apiserver.tf`: one JWT issuer, `https://authentik.webgrip.dev/application/o/unfold-kubernetes/`,
  claim rules on `unfold_groups`, a 960-second lifetime cap and a plain user name.
- `infra/headscale-oidc.tf`: issuer `.../unfold-headscale/`, `allowed_groups: [unfold-admins]`.
  The passkey step is the Authentik flow `webgrip-passkey-authorization`; the Kubernetes application
  has no passkey step.
- Both people have `webgrip.nl` Google Workspace accounts; homelab ADR-0059 runs its own API on
  Google with `hd=webgrip.nl` and has done since 2026-09-15.
- Google ID tokens carry no groups claim at any Workspace edition (ADR-0059). Kubernetes structured
  authentication accepts several issuers at once.
- Headscale accepts any OIDC issuer and can restrict by `allowed_users` and `allowed_domains`.
- The Unfold app has its own login (OIDC client `unfold`) and will serve client tenants; client
  people are not in our Workspace.

## Options

- (a) Keep the homelab Authentik for everything.
- (b) Run a production Authentik in this cluster, with the homelab federated into it.
- (c) Google Workspace directly for operators.
- (d) A hosted EU identity provider.

## Decision

Chosen: **(c) for the operator plane, and a separate product IdP for client tenants later.**

1. The Kubernetes API, the tailnet, this cluster's Grafana and OpenBao's production paths trust
   Google (`https://accounts.google.com`) directly, with claim rules `hd == "webgrip.nl"`,
   `email_verified`, a lifetime of at most 960 seconds, and user name `oidc:` + email.
2. Membership stays in homelab git, in the access plane's `people.yaml`, as today. The access plane
   renders it into a per-user `access/members.yaml` here through a sync pull request; RBAC bindings,
   the Headscale `allowed_users` and the Grafana role mapping are generated from that file. A CI check
   refuses a members file that disagrees with the model's export.
3. Groups become `unfold-viewers`, `unfold-operators`, `unfold-admins`, `unfold-security-auditors`,
   `unfold-billing` and `unfold-app-admins` (the architecture page maps each). Today's `unfold-admins`
   holds what `unfold-operators` will hold.
4. Phishing-resistant sign-in is a Workspace policy: an organisational unit for `unfold-admins`
   with 2-step verification restricted to security keys, and two YubiKeys before the first client
   (RFC 0002). A scheduled check reads the policy (Cloud Identity Policy API, or the Admin SDK Reports API's 2SV-setting events; which one works on our edition is the first task of step 1) and alerts when it changes.
5. The Unfold app stays on the homelab Authentik while only the owner uses it. Before the first
   client, a separate ADR chooses the product IdP together with the tenant model. Client people never
   get an operator identity.
6. The admin kubeconfig and `os:admin` talosconfig stay break-glass, age-encrypted to a YubiKey,
   with an alert on any use.

(b) was not chosen for operators because it puts the IdP on the cluster it protects: when the
cluster's login breaks, the IdP needed to fix it is inside. It remains a candidate for the product
IdP, where that objection does not apply. (d) adds a SaaS to the ops path and a monthly bill for
two people, and still needs Google or its own factor; it is the fallback if Workspace is ever
dropped.

## Consequences

Good:

- Production login works while the house is down; the break-glass kubeconfig is for broken
  clusters, not for a broken homelab.
- A homelab compromise no longer issues production sessions or registers tailnet devices. The
  remaining homelab edges are OpenBao (every production secret) and the infra runner (RFC 0001).
- Headscale no longer needs the `tag:headscale → tag:homelab-gateway:443` path or its `/etc/hosts`
  reconcile.
- €0,00 a month: no new service, no new seats.

Bad, accepted:

- The passkey requirement is console state at Google, not code in git, and Google's ID token does
  not say which factor was used. The scheduled policy check is the compensating control.
- Group changes reach production through a sync pull request and Flux (minutes), not through the IdP
  at the next login.
- User names change from `oidc:ryangr0` to `oidc:ryan@webgrip.nl`; audit queries and alert rules
  are updated in the same change.
- Google remains a single point of compromise for operator logins, as it already is today through
  Authentik.

## Migration

Each step is one pull request with its proof, both issuers running side by side until step 6.

1. A Google OAuth client `unfold-kubernetes` (public, PKCE), recorded as an external dependency in
   `docs/reproducibility.md`; Google added as a second issuer in `infra/kube-apiserver.tf`, run
   through a real API server before merging (the kubernetes-login runbook's lesson).
2. `access/members.yaml`, its sync from homelab-cluster and the generated per-user bindings.
3. A second kubeconfig context; the proofs below.
4. Headscale on Google with `allowed_users`.
5. This cluster's Grafana on Google.
6. After two weeks, the Authentik issuer, the `unfold-headscale` and `unfold-kubernetes` Authentik
   applications and the tunnel's public JWKS path are removed.

## Confirmation

1. With the homelab Authentik scaled to zero (or its tunnel path closed), `kubectl auth whoami`
   shows `oidc:ryan@webgrip.nl` and the operator group, and a new device joins the tailnet.
2. A Google account outside `webgrip.nl`, and a `webgrip.nl` account not in `members.yaml`, get
   `401` from the API server and `unauthorised` from Headscale.
3. A token minted by the homelab Authentik for `unfold-kubernetes` is refused after step 6.
4. The policy check fires when the admin OU's 2SV methods are widened.
5. Every case above appears in the audit log with the expected user and code.
