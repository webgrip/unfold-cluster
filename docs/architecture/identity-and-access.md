# Identity and access

Who can sign in to the Unfold production cluster and everything around it, what each identity may
do there, how it proves who it is, where that is written down, and how it is taken away. The
decision this page leads to is [ADR 0014](../adr/0014-operators-sign-in-to-production-through-google-directly.md).

Everything below was read from source on 2026-10-26: this repository at PR #85's head (which
contains #83 to #89), and homelab-cluster `main` (`kubernetes/apps/security/access-plane/`,
`kubernetes/apps/security/openbao/bootstrap/`, `kubernetes/apps/repo-config/`). No live system was
changed. Where a row says "unverified", only the source was read.

## Words used here

| Word | Meaning |
| --- | --- |
| IdP | Identity provider: the service that checks who you are and hands out a signed token saying so. Today that is the homelab Authentik, which in turn signs people in through Google Workspace. |
| OIDC | OpenID Connect, the protocol those tokens follow. A token carries claims (user name, groups, expiry) signed by the IdP; the receiving service checks the signature against the IdP's published keys (JWKS). |
| Passkey, security key | A WebAuthn credential: a private key on a device (laptop TPM, phone, YubiKey) that signs a login challenge for one website only, so it cannot be phished onto a fake page. A hardware key is a passkey on a dedicated USB/NFC token. |
| Step-up | Asking for a fresh, strong proof right before a dangerous action, even inside an existing session. |
| Break-glass | A credential that works when the normal login path is down, kept offline and alarmed on use. |
| Workload identity | A machine proving who it is with a short-lived token its platform issues (a Kubernetes service-account token, a Forgejo Actions OIDC token), instead of a stored password. |

## The identities

| Identity | Who or what | Exists as |
| --- | --- | --- |
| Owner | Ryan, forge user `ryangr0` | homelab `people.yaml` id `ryan`, role `platform-engineer` |
| Colleague | Yon, forge user `yon` | homelab `people.yaml` id `yon`, role `developer`, **no Unfold grant** |
| Future client users | People of a paying tenant, in the Unfold app only | nothing yet; the homelab role `client` exists for previews |
| CI jobs | Forgejo Actions runs of `webgrip/unfold-cluster` and the image repositories | Forgejo OIDC tokens, exchanged at the homelab OpenBao (`auth/forgejo`) |
| Agents and Runs | Ploeg Runs (model-written code), Claude Code on the owner's workstation, the Forgejo bots `agent-builder` and `agent-reviewer`, Vikunja `bot-ploeg` | Runs: per-Run LiteLLM keys and a proxy-held forge token (RFC 0003 G2, G6). Claude Code: acts as the owner (`delegates_to`) |
| Service accounts | In-cluster workloads: Flux, External Secrets, cert-manager, CNPG, the CI runners, Zot's credential Job | Kubernetes ServiceAccounts; the cluster's service-account key is trusted by the homelab OpenBao at `auth/jwt-unfold-main` |

## Access matrix

"Declared in" names the file that grants the access. `hl:` means homelab-cluster, `uc:` this
repository. Revocation is how the access ends, and how fast.

### Kubernetes API (OIDC)

| Identity | Access | How they authenticate | Declared in | Revoked by |
| --- | --- | --- | --- | --- |
| Owner | `unfold-operator`: read all but Secrets; delete and evict pods; cordon and drain. No exec, no spec changes, no Secrets | Authentik, which signs in through Google (Google's 2-step verification). **No passkey step on this application** | `hl:access-plane/model/people.yaml` grant `unfold-cluster-operate`; `uc:kubernetes/platform/human-access/`; `uc:infra/kube-apiserver.tf` | Remove the grant; ID tokens die within 15 minutes, the refresh token on Authentik's next refresh (12 h ceiling) |
| Colleague | None. `unfold-viewers` exists but he holds no grant | (would be the same) | `hl:people.yaml` | n/a |
| Client users | None, ever | n/a | n/a | n/a |
| CI jobs | None today (the infra job reaches the API with the admin kubeconfig from the state, below) | n/a | n/a | n/a |
| Agents, Runs | None. README: "agents get no Kubernetes token at all"; Runs mount no service-account token (G2) | n/a | `uc:README.md`; Ploeg `workerAdmission` | n/a |
| Service accounts | Per their own Role/ClusterRole | Bound, audience-scoped service-account tokens | `uc:kubernetes/**` | Delete the binding (immediate) |

### Break-glass kubeconfig and talosconfig

| Identity | Access | Authenticate | Declared in | Revoked by |
| --- | --- | --- | --- | --- |
| Owner | `system:masters` (kube) and `os:admin` (Talos) | Client certificate in a file (`~/.kube/unfold-break-glass.yaml`, `tofu output -raw talosconfig`) | `uc:infra/outputs.tf`, the Talos secrets bundle in OpenBao `secret/unfold-cluster/talos-secrets` | Only by rotating the cluster CA. Not revocable per holder |
| CI jobs (infra apply) | Same: the job reads both from the encrypted state every run | The state passphrase and bucket keys from OpenBao role `ci-unfold-cluster` | `hl:openbao/bootstrap/config.sh`, `ci-unfold-cluster.hcl` | Remove the role or rotate the CA |
| Anyone with the state passphrase and state bucket keys | Same | Decrypting the state | OpenBao `secret/unfold-cluster/tofu-state`, password manager copy | Rotate passphrase and CA |
| Everyone else | None | | | |

### Talos API (apid, port 50000)

| Identity | Access | Authenticate | Declared in | Revoked by |
| --- | --- | --- | --- | --- |
| Owner | `os:admin` from the tailnet (and from home, `ADMIN_CIDRS`). RFC 0001's day-to-day `os:reader` config is **not issued**: the only talosconfig is the admin one | mTLS client certificate | `uc:infra/outputs.tf`, `uc:infra/host-firewall.tf` | CA rotation |
| CI jobs | `os:admin` over the internet from `ADMIN_CIDRS` | Same certificate, read from the state | `uc:.forgejo/workflows/infra.yml` | CA rotation; remove the runner address from `ADMIN_CIDRS` |
| etcd backup Job | `os:etcd:backup` only | Talos `kubernetesTalosAPIAccess` service-account bridge | `uc:infra/talos.tf` | Remove the role from `allowedRoles` |
| Others | Network: anyone on the home network or the tailnet reaches the port; without a certificate they get nothing | | | |

### Headscale and the tailnet

| Identity | Access | Authenticate | Declared in | Revoked by |
| --- | --- | --- | --- | --- |
| Owner | A device in `autogroup:member`: **every port** on every tagged node, the cluster subnet, other members' devices, homelab gateway 8200/8427/9150 | Authentik (Google), then a passkey with user verification, every registration; device expires after 30 days | `hl:people.yaml` (`unfold-cluster-operate`), `hl:access-plane/tofu/broker/applications.tf` (`passkey_required`), `uc:infra/headscale-oidc.tf` (`allowed_groups`), `uc:infra/templates/headscale-acl.hujson` | Remove the grant: no new device. Existing devices live until expiry (≤ 30 d) unless `headscale nodes expire` is run on the server |
| Colleague, viewers | None. Only `unfold-admins` may register, so a future `unfold-viewers` holder **cannot reach the API at all** (it is tailnet-only) | | | |
| Nodes, gateway, Headscale itself | Tagged, per the ACL | Single-use pre-auth keys minted by the apply; never expire | `uc:infra/headscale.tf`, `uc:infra/tailnet.tf` | New key generation through a PR and apply |
| Client users, agents, CI | None (CI is not on the tailnet yet) | | | |

### Grafana and Alertmanager

| Identity | Access | Authenticate | Declared in | Revoked by |
| --- | --- | --- | --- | --- |
| Owner | Homelab Grafana admin, including folder **Unfold cluster**, the Unfold metrics and the Unfold kube audit stream; homelab Alertmanager | Authentik (Google) | `hl:people.yaml` via role `platform-engineer` → `grafana-admin` | Remove the grant |
| Colleague | **Homelab Grafana edit**, so he reads Unfold metrics, logs and the Unfold audit log today although he holds no Unfold grant | Authentik (Google) | `hl:access-plane/model/roles.yaml` role `developer` → `grafana-edit` | Change his role |
| Unfold's own Grafana | Coming (another stream), with OIDC. This page proposes its role mapping below | | | |
| Others | None | | | |

### OpenBao paths (homelab OpenBao, the only original of every production secret)

| Identity | Access | Authenticate | Declared in | Revoked by |
| --- | --- | --- | --- | --- |
| Owner | `*` with `sudo` (policy `admins`, external group `openbao-admins` aliased from Authentik `homelab-admins`) | OIDC through Authentik (Google MFA) | `hl:openbao/bootstrap/admins.hcl`, `hl:access-plane/tofu/broker/openbao.tf` | Leave `homelab-admins` |
| Colleague | None | | | |
| CI: `unfold-cluster` infra job | Policy `ci-unfold-cluster`: every Hetzner token, state passphrase and keys, Robot credentials, Talos bundle (read/write), disk KMS key, Headscale OIDC secret | Forgejo OIDC token, audience `openbao-ci`, bound to repository `webgrip/unfold-cluster`, ref `main`, events push/schedule/workflow_dispatch, actor **`ryangr0`, `yon` or `forgejo-actions`**; 10-minute token | `hl:openbao/bootstrap/config.sh`, `ci-unfold-cluster.hcl` | Edit the role; takes effect at the next `openbao-config` run (hourly) |
| CI: signing | Transit `cosign-webgrip` sign, for seven repositories, events release or workflow_dispatch, **any `refs/heads/*`** | Forgejo OIDC, audience `openbao-cosign` | `hl:config.sh` role `cosign-signer` | Edit the role |
| Unfold External Secrets | `secret/data/unfold-main/*` read | The cluster's service-account JWT, subject `external-secrets:openbao-homelab`, 10-minute token | `hl:config.sh` `jwt-unfold-main`, `unfold-main-reader.hcl` | Edit the role or the committed public key |
| Runs, agents, client users | None | | | |

### Forgejo `webgrip/unfold-cluster`, the GitHub mirror and Flux

| Identity | Access | Authenticate | Declared in | Revoked by |
| --- | --- | --- | --- | --- |
| Owner | Push and merge to protected `main` | Forgejo session through Authentik; pushes over the owner's SSH key | `hl:repo-config/model/repos.yaml` (`unfold-cluster.main.push/merge`) | Edit the model (applied hourly) |
| Colleague | **Merge to protected `main`.** The merge commit is signed with Forgejo's instance key, which Flux trusts, so his merge deploys to production with Flux's cluster-admin. The model sets no required status checks for this repository | Forgejo session | `hl:repos.yaml` (`merge: [ryangr0, yon]`, `status_checks: []`); `uc:kubernetes/clusters/main/flux-system/trusted-signers/forgejo.sshpub` | Edit the model |
| Agents | `agent-builder` may push branches and open PRs, never push or merge `main`; `agent-reviewer` comments only | Bot tokens | `hl:people.yaml`, the Forgejo teams | Remove from team; rotate token |
| GitHub mirror | Forgejo's push mirror writes `main`; GitHub ruleset blocks force-push and deletion | Mirror token in Forgejo settings | GitHub ruleset (outside git, noted in README "Open") | Rotate the token |
| Flux | Applies `main` from the GitHub mirror only if HEAD is signed by a key in `trusted-signers/` | SSH signature check (`verify.mode: HEAD`) | `uc:kubernetes/clusters/main/flux-system/` | Remove the key in a signed PR |

### The infra workflow (plan, apply, diagnose)

| Identity | Access | Authenticate | Declared in | Revoked by |
| --- | --- | --- | --- | --- |
| Owner | Dispatch `apply` with the plan digest he reviewed | Forgejo session; the job's OIDC token names him as actor | `uc:.forgejo/workflows/infra.yml`; `hl:config.sh` | Edit the role |
| Colleague | **The same.** He is on the role's actor list and has write access, so he can dispatch an apply that reads every Hetzner token | Forgejo session | `hl:config.sh` | Remove `yon` from the actor list |
| Push to `main` | Plan-only runs with the same credentials (plan never changes Hetzner, but holds the tokens) | `push` event | `infra.yml` | |
| Pull requests | `infra-check` only, no credentials | | `infra.yml` `if:` | |

### Hetzner Cloud, Robot and Cloudflare

| Identity | Access | Authenticate | Declared in | Revoked by |
| --- | --- | --- | --- | --- |
| Owner | Hetzner account owner: console, Robot, every project; Cloudflare account owner | Account password plus the second factor each provider offers. Which factor is set is account state, not in git (unverified) | Nowhere in git | Provider console |
| CI jobs | Four project-wide Hetzner Cloud tokens (`unfold-tofu`, `-cluster`, `-vip`, `-autoscaler`), Robot credentials, one Cloudflare DNS read token for `unfoldhq.dev` (ci-unfold) | Read from OpenBao per run | `hl:ci-unfold-cluster.hcl`, `ci-unfold.hcl`; `uc:README.md` "Credentials and rotation" | Revoke the token at Hetzner, then `bao kv patch` |
| Service accounts | hcloud CCM/CSI token in `kube-system`; VIP token in control-plane machine configs; cert-manager DNS-01 token; later the tunnel token | ExternalSecret / machine config | `uc:infra/cluster-secrets.tf`, `uc:kubernetes/platform/cert-manager/issuers/` | Revoke at provider; next sync |
| Colleague, clients, agents | None | | | |

### The Unfold app

| Identity | Access | Authenticate | Declared in | Revoked by |
| --- | --- | --- | --- | --- |
| Owner | App `admin`: every session and budget | Unfold's own login: OIDC client `unfold` at the homelab Authentik (Google); after the move also behind Cloudflare Access (RFC 0003 D6) | `hl:capabilities.yaml` `unfold-admin`, which binds the group **`homelab-admins`** | Leave the group |
| Colleague | Not the app; `ploeg-read`/`ploeg-operate` are not granted to him | | `hl:people.yaml` | |
| Client users | Nothing yet. Tenants need their own login (below) | | | |
| Agents | `ploegd` mints a LiteLLM key per Run; MCP clients use the person's own OIDC token (`unfold-mcp`, 10-minute access tokens) | | `hl:applications.tf` | Remove the person's grant |

### Zot and the CNPG databases

| Identity | Access | Authenticate | Declared in | Revoked by |
| --- | --- | --- | --- | --- |
| Nodes, Trivy, Kyverno, `ci` pods | Pull everything, anonymously, if the network policy lets them reach Zot | None (network policy only) | `uc:kubernetes/platform/zot` | Network policy |
| CI pods (namespace `ci`) | Push `webgrip/**`, no delete | Shared user `ci` with a generated password | `zot-push-credentials` Job, `CONSUMER_NAMESPACES` | Delete the Secret; next hourly Job makes a new one |
| Apps | Their own database role | scram-sha-256 password from CNPG over TLS; certificate-only `pg_hba` is RFC 0001 design | `uc:kubernetes/platform/cloudnative-pg`, the app's Cluster | Rotate the role password |
| People | **No path by design**: no exec, no port-forward, no Secrets in the operator role. Data access is a break-glass act | | `uc:kubernetes/platform/human-access/` | |
| Runs | None: refused by default-deny before Zot or Postgres (G3) | | | |

## Roles and groups

Least privilege, one group per job to be done. Membership is a grant in homelab
`kubernetes/apps/security/access-plane/model/people.yaml` with `until`, `owner` and `reason`,
projected by the access plane into whatever IdP signs people in. Nobody is added in a UI; the
access plane reverts a clicked change.

| Group | For | Kubernetes RBAC | Tailnet | Grafana (Unfold org) | OpenBao | Forgejo `unfold-cluster` | Unfold app | Talos |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `unfold-viewers` | Looking, debugging without changing | `unfold-viewer` (exists) | Join allowed; ACL `tag:cp:6443` only | Viewer, Unfold folders; not the audit datasource | none | read | none | none |
| `unfold-operators` | Day-to-day operations | `unfold-operator` (exists today under the name `unfold-admins`) | Join; ACL to `tag:cp:6443,50000` and the cluster subnet, no member-to-member | Editor; may silence in Alertmanager | none | read, open PRs | none | `os:reader` |
| `unfold-admins` | Changing production | `unfold-operator`. Still no `cluster-admin`; changes go through Git | as operators | Admin | write `secret/unfold-main/*`, `secret/unfold-cluster/*` through OIDC with a passkey | merge `main`; dispatch infra apply (actor list) | none by default | `os:reader`; `os:admin` only from break-glass |
| `unfold-security-auditors` | Reviewing evidence | `unfold-viewer` | as viewers | Viewer including the audit and Tetragon datasources | read the OpenBao audit log (once it exists) | read | read the app's audit trail | none |
| `unfold-billing` | Money | none | none | Viewer, cost dashboards only | none | none | `billing`: spend and budgets, read | none |
| `unfold-app-admins` | Running the product | none | none | none | none | none | `admin` | none |
| `unfold-tenant-<client>` and `-<client>-admins` (later) | A client's own people | none | none | none, unless a tenant dashboard is sold | none | none | tenant `member` / tenant `admin`, scoped to their tenant | none |

Three changes against today:

1. Today's `unfold-admins` holds the operator role and nothing more. It is split: `unfold-operators`
   takes that role, and `unfold-admins` adds the non-Kubernetes rights that today belong to whoever
   happens to be on a list (repo-config merge list, the OpenBao actor list).
2. `unfold-admin` (the Unfold app admin capability) binds `homelab-admins`, the group that the
   homelab OpenBao maps to `*` with `sudo`. Granting someone Unfold app admin would make them root
   of the vault that holds every production credential. It gets its own group,
   `unfold-app-admins`.
3. Tailnet access follows the group instead of "any registered device reaches everything".

The access plane renders these into three places: Authentik groups (today) or per-user lists
(after ADR 0014), `uc:kubernetes/platform/human-access/` bindings, and the Headscale ACL groups.
The colleague's current rights on this repository move into the model the same way: either he
gets a dated grant of `unfold-admins` with a reason, or his name leaves the merge list and the
actor list.

## The IdP dependency decision

Production login today depends on the homelab: Authentik, its CNPG database, the Cloudflare tunnel
for the JWKS, and for Headscale the `unfold-gateway` pod and its tailnet path. Authentik itself
signs people in through Google Workspace (homelab ADR-0057). So the chain is Google **and**
homelab for availability, and Google **or** homelab for compromise.

| | (a) Keep the homelab Authentik | (b) Production Authentik in Unfold, homelab federated | (c) Google Workspace directly | (d) Hosted EU IdP |
| --- | --- | --- | --- | --- |
| Log in when the house is down | No. Break-glass only; issued tokens live ≤ 15 min | Yes, while the cluster is up. If the cluster's own login breaks, so does the IdP it runs on (the reason homelab ADR-0059 refused an on-cluster IdP) | Yes. Google is up whenever the internet is | Yes, subject to the vendor |
| Homelab compromise mints production tokens | Yes: Authentik can issue `unfold_groups: [unfold-admins]` and register tailnet devices | Only if production trusts the homelab as a federated source; one-way federation (production is the root) closes it | No. The homelab is out of the login path | No |
| Google compromise mints production tokens | Yes (Authentik trusts Google) | Yes if Google stays the upstream | Yes; mitigated by security-key-only 2SV for the admin OU | Only if it federates to Google |
| Passkey proof | In git: `passkey_required` flow, provable per application | Same, in this repository | Workspace policy (2SV "security key only"), console state, not git. Google's ID token carries no claim saying which factor was used | Per vendor; most can require WebAuthn and emit `amr` |
| Groups in the token | Yes (`unfold_groups` scope) | Yes | No: Google ID tokens carry no groups at any edition (ADR-0059). Membership becomes per-user bindings rendered from the model | Yes |
| Client tenants | Poor: homelab identities and client identities in one instance | Good: one tenant per client, client IdPs as sources, brands | None: clients are not in our Workspace | Good: most are built multi-tenant |
| Cost | €0,00 | €0,00 in money; about 1 GiB RAM and a Postgres on the hub, plus another stateful service to upgrade and back up | €0,00: Workspace seats exist for both people (`hd=webgrip.nl`) | Free tiers exist; paid tiers are tens to low hundreds of euros a month (check current prices) and add a SaaS to the ops path, which the owner has declined before |
| Effort | none | L: deploy, back up, migrate clients, federate | M: one OAuth client, a second issuer in `kube-apiserver.tf`, per-user bindings, Headscale and Grafana issuers | M to L, plus a vendor review and DPA |

**Recommendation: (c) for operators, now; a product IdP for clients, later.** Split by audience:

- **Operator plane** (kube API, tailnet, Unfold's Grafana, OpenBao for production paths): Google
  Workspace directly, as the homelab already chose for its own API (ADR-0059). It removes the
  homelab from the login path, so the house being down no longer locks you out and a homelab
  compromise no longer mints production sessions. It costs nothing and uses the identity both
  people already have. The model in homelab git stays the one source of membership; it renders
  per-user lists instead of Authentik groups. Phishing resistance moves to a Workspace policy:
  an `unfold-admins` organisational unit with 2SV restricted to security keys, enforced in the
  Workspace admin console and checked by a scheduled job (gap G-12).
- **Product plane** (Unfold app, client users, tenant admins): stays on the homelab Authentik
  while only the owner uses it. Before the first client, the product gets its own IdP in
  production (option b scoped to the product, or Unfold's own per-tenant OIDC federation), decided
  in a separate ADR with the tenant model. Client people never get an operator identity.

Migration path, each step one PR with its proof:

1. Create a Google OAuth client `unfold-kubernetes` (public, PKCE) and record it as an external
   dependency in `docs/reproducibility.md`. Add Google as a **second** issuer in
   `infra/kube-apiserver.tf` (structured authentication allows several), with claim rules:
   `hd == "webgrip.nl"`, `email_verified`, lifetime ≤ 960 s, user name `oidc:` + email.
2. Render per-user `ClusterRoleBinding`s from a committed `access/members.yaml`, kept in step with
   the homelab model by a sync pull request from the access plane (reuse order: generate, then
   sync PR). A CI check refuses a member file that disagrees with the model's export.
3. Ship a second kubeconfig context, prove whoami, the `403`s and the `401` for a non-member,
   as in [kubernetes-login](../runbooks/kubernetes-login.md).
4. Headscale: issuer `accounts.google.com`, `allowed_users` from `members.yaml`. This also removes
   the `tag:headscale → tag:homelab-gateway:443` rule and the `/etc/hosts` reconcile.
5. Unfold's Grafana: Google OAuth with `allowed_domains`, `role_attribute_strict`, roles from
   `members.yaml`.
6. After two weeks with both issuers, remove the Authentik issuer and the tunnel's public JWKS
   path in homelab-cluster.

## Strong authentication

| Surface | Factor today | Target | Before the first client |
| --- | --- | --- | --- |
| Google Workspace (root of every human login) | 2SV, method not in git | Passkeys on laptop TPM and phone (RFC 0002, decided 2026-10-24) | 2SV restricted to security keys for the admin OU; two YubiKey 5 NFC (about €110,00 together) |
| Tailnet device join | Passkey every time | same | YubiKey |
| Kubernetes API | Google 2SV via Authentik | Google security-key 2SV | same |
| Forgejo | Authentik session | WebAuthn on the Forgejo account | same |
| OpenBao (admin) | Authentik (Google MFA) | OIDC role requiring the passkey flow, 1 h token | same |
| Hetzner, Cloudflare | account second factor, unverified | strongest factor each offers, checked and noted in `docs/` | security key where offered |

**Session lifetimes**

| Session | Lifetime |
| --- | --- |
| Kubernetes ID token | 15 min, enforced by the API server rule `exp - iat ≤ 960` |
| kubelogin refresh | 12 h, then a browser login |
| Tailnet device | 30 days |
| Unfold Grafana | 8 h, idle 1 h (proposed) |
| OpenBao CI tokens | 10 min |
| OpenBao human token | 1 h (proposed; today the Authentik role's default) |
| Unfold app | 12 h refresh (homelab provider) |

**Step-up for dangerous actions**

| Action | Today | Proposed |
| --- | --- | --- |
| Merge to protected `main` (= deploy) | Merge button; colleague included; no required checks | Merge list = `unfold-admins` from the model; the PR's `*-check` workflows required; Flux keeps refusing unsigned HEADs |
| Infra apply dispatch | Plan digest must match; actor list of three | Actor list = `unfold-admins`; plus an approval token: the admin signs in to OpenBao with a passkey and writes `secret/unfold-cluster/apply-approval/<digest>` (TTL 30 min), which the apply job requires and deletes |
| Break-glass use | File on disk | Age-encrypted to the YubiKey (`age-plugin-yubikey`); decrypting needs the touch. Every audit event as `admin` pages the owner |

**Audit trails and alerts**

| Trail | State | Alert |
| --- | --- | --- |
| Kubernetes API audit log | Built: shipped to homelab VictoriaLogs (`cluster=unfold`, `job=kube-audit`) | The homelab `KubernetesBreakGlassCertificateUsed` rule probably matches Unfold records (unverified): it has no `cluster` label and its exclusion for Talos's own calls lists homelab node addresses. Needs an Unfold-specific rule |
| Talos API | apid logs calls; not shipped as an audit stream | none |
| Authentik events | Built; ntfy on break-glass password login and users created outside the roster | Add: any token issued for `unfold-kubernetes` or `unfold-headscale` outside `members.yaml` |
| OpenBao | **No audit device declared in git** (homelab) | none |
| Forgejo | Action feed and logs only | none |
| Headscale | Journal on the server | none |

## Machines and agents

**Workload identity.** External Secrets is the one Unfold workload that reaches OpenBao, with a
10-minute JWT bound to one ServiceAccount; its policy reads all of `secret/unfold-main/*`. That
is one key ring for every namespace. Proposed: one OpenBao role per namespace,
`unfold-main-<namespace>`, bound to a namespaced `SecretStore` service account and a policy on
`secret/data/unfold-main/<namespace>/*`, so a compromised namespace reads only its own secrets.
Zot moves from the shared `ci` password to service-account bearer tokens once the API server's
discovery document is readable anonymously (already noted in the Zot runbook).

**CI identities.** The pattern is right: Forgejo OIDC, audience-scoped, bound to repository, ref,
event and actor, 10-minute tokens, no Forgejo secrets. Three bindings need tightening: the actor
list (colleague, `forgejo-actions`), the signing role's `refs/heads/*` (any branch, dispatched by
anyone with write, can get the estate signature that Kyverno trusts), and the Talos/kube admin
certificates every apply run holds.

**Runs.** No standing credentials, per RFC 0003's gates: no service-account token (G2), egress
only through the FQDN gateway (G3), per-Run LiteLLM keys of 4 hours with a budget and the forge
token held by the proxy (G6). A Run never holds an OIDC identity of its own. What a Run does is
attributed through the Work Item to the person who assigned it.

**Agents from Ploeg.** Agent identities are forge and tracker bots (`agent-builder`,
`agent-reviewer`, `bot-ploeg`) with per-cluster tokens and no rights on protected branches.
Claude Code on the owner's workstation acts as the owner and is attributed to him; it gets no
production identity of its own. If an agent ever needs to read production, it gets a dedicated
read-only principal (`oidc:agent-<name>` or a kubernetes-mcp ServiceAccount with
`unfold-viewer`), declared in `people.yaml` as `kind: machine`, never the owner's token.

## Gaps and follow-ups

Severity is what an attacker or an outage gains today. Effort: S hours, M days, L a week or more.

| # | Gap | Severity | Follow-up | Effort |
| --- | --- | --- | --- | --- |
| G-01 | The colleague can merge to `unfold-cluster` `main` (Forgejo's instance key signs the merge, Flux trusts it and applies with cluster-admin), and the model requires no status checks there | High | Merge list from the model's `unfold-admins`; add the repository's `*-check` contexts to `status_checks` in `hl:repos.yaml` | S |
| G-02 | The colleague can dispatch an infra apply that reads every Hetzner token; `forgejo-actions` is also an accepted actor | High | Actor list = owner (and later `unfold-admins` rendered from the model); find which runs carry `forgejo-actions` and drop it if none need it | S |
| G-03 | Unfold app admin binds `homelab-admins`, which is OpenBao `*` + `sudo` | High (latent: only the owner holds it) | Group `unfold-app-admins` in `hl:capabilities.yaml` | S |
| G-04 | `cosign-signer` signs for any branch on `workflow_dispatch`; Kyverno in Unfold trusts that key | High once image policies Deny | Bind signing to `refs/tags/*` and `refs/heads/main`, or to a dedicated signing workflow (`job_workflow_ref`) | S |
| G-05 | Homelab in the production login path (availability and compromise) | Medium | ADR 0014 migration, steps 1–6 | M |
| G-06 | No passkey on the Kubernetes API login (only on tailnet join) | Medium | `passkey_required = true` on `unfold-kubernetes` now; Google security-key OU after ADR 0014 | S |
| G-07 | Only an `os:admin` talosconfig exists; the API ports also answer from the home address | Medium | Generate an `os:reader` talosconfig output for daily use; close `ADMIN_CIDRS` when CI joins the tailnet (README "Open") | S / M |
| G-08 | Every registered human device reaches every port on every node and every other device | Medium | ACL per group (`unfold-viewers` → 6443; operators → 6443, 50000, subnet); drop `autogroup:member:*` | S |
| G-09 | No break-glass alert written for Unfold; Talos API use is not audited | Medium | VictoriaLogs rule on `cluster:=unfold job:=kube-audit` user `admin` minus the apply's own calls; ship apid logs | M |
| G-10 | No OpenBao audit device declared in git, so reads of production secrets leave no trail | Medium | Enable a file or socket audit device in `hl:openbao/bootstrap/init.sh`/`config.sh`, ship it to VictoriaLogs, alert on reads of `unfold-*` paths by humans | M |
| G-11 | Metrics and log writes to the homelab gateway carry no token, so any tailnet device can write fake Unfold audit records | Medium | vmauth bearer token minted in the homelab, delivered by External Secrets (already planned in `observability.md`) | S |
| G-12 | Hardware keys (RFC 0002 "before the first client") not yet bought or enforced; Hetzner and Cloudflare second factors not recorded | Medium | Two YubiKeys; Workspace admin OU with security-key-only 2SV; a docs page listing each account's factor, rechecked quarterly | S |
| G-13 | `unfold-viewers` cannot reach the API (Headscale admits only `unfold-admins`) | Low | Allow viewer join with the narrow ACL of G-08 | S |
| G-14 | One OpenBao identity reads every `unfold-main/*` secret | Low now, Medium with clients | Per-namespace roles and `SecretStore`s | M |
| G-15 | No step-up on apply or merge | Medium | Approval token in OpenBao bound to the plan digest | M |
| G-16 | The colleague reads the Unfold audit log and metrics through his homelab Grafana edit role | Low | Unfold folder and datasources restricted to `unfold-*` groups, or moved to Unfold's Grafana | S |
| G-17 | RFC 0001 still describes Google as the issuer while the cluster runs Authentik | Low | ADR 0014 records the actual and target state; RFC 0001 links it | S |
| G-18 | Client tenants have no IdP | n/a until the first client | Product IdP ADR with the tenant model | L |
