# Unfold staging's public edge

[ADR 0017](../adr/0017-staging-runs-here-with-agents-under-gvisor-on-the-hub.md) puts Unfold staging at
`staging-app.unfoldhq.dev`, public through a Cloudflare Tunnel. This page covers the part OpenTofu
owns in [infra/unfold-staging-edge.tf](../../infra/unfold-staging-edge.tf): the tunnel, its routes,
the DNS record and Cloudflare Access. The `cloudflared` connector that runs in the cluster is part of
the staging manifests under `kubernetes/apps/unfold-staging/`.

## How a request gets in

```text
browser, editor, forge or tracker
  │  DNS: staging-app.unfoldhq.dev, a proxied CNAME to <tunnel id>.cfargotunnel.com
  ▼
Cloudflare edge: TLS, then Access
  │  /webhooks/*  → Access application "Unfold staging webhooks", bypass for everyone
  │  everything else → Access application "Unfold staging"
  │      a person in a browser: Google Workspace (or a one-time PIN until the Google client exists), listed addresses only, 8 h session
  │      a client without a browser: the service token "unfold-staging editors <generation>", in the headers CF-Access-Client-Id and CF-Access-Client-Secret
  │      anything else: 302 to the Access sign-in
  ▼
tunnel unfold-staging (remotely managed; the routes live in OpenTofu)
  │  ^/webhooks/  → http://ploeg.unfold-staging.svc.cluster.local:8080   ploegd checks each webhook's HMAC
  │  rest of host → http://unfold.unfold-staging.svc.cluster.local:4080  Unfold's own sign-in
  │  anything else → 404
  ▼
cloudflared in unfold-staging-edge, which dials out to Cloudflare; no port opens on any node
```

Two controls stand in front of the UI: Access, then Unfold's sign-in. A client with the service
token passes the first with a secret its holders share, not with an identity; Unfold's sign-in
still says who it is ([clients without a browser](#clients-without-a-browser)). The webhook path has
one control at the edge (none: forges cannot answer Access) and one at the origin (ploegd's HMAC,
after which ploegd re-reads the tracker and never acts on the body).

`infra/tests/unfold_staging_edge.tftest.hcl` pins the route order and the final 404, that only
`/webhooks/` bypasses Access, that the service-token policy is Service Auth for that one token and
nothing wider, that the record is proxied, and that nothing is declared unless the edge is enabled.

## The certificate at the edge

Cloudflare's free Universal SSL covers `unfoldhq.dev` and `*.unfoldhq.dev`, one level only, so the
hostname stays a first-level name: `staging-app.unfoldhq.dev`, not `staging.app.unfoldhq.dev`. The
variable's validation refuses a deeper name, which would need Advanced Certificate Manager (about
€9.50 a month) before a browser could reach it.

## Turning it on

Nobody types a Cloudflare value. The homelab's `cloudflare-token-minter` (homelab-cluster ADR-0061)
uses the account's token manager to create the token `unfold-staging-edge`, with **Account ·
Cloudflare Tunnel · Edit**, **Account · Access: Apps and Policies · Edit**, **Account · Access:
Organizations, Identity Providers, and Groups · Edit**, **Account · Access: Service Tokens · Edit**
and **Zone · DNS · Edit** on `unfoldhq.dev` only, verifies it, and writes `api-token`, `token-id`,
`account-id` and `zone-id` to OpenBao `secret/cloudflare/unfold-tunnel`.

Every `infra` run reads that path. When all three values are there, the run declares the edge; when
the path is missing or unreadable, the step's failure is ignored and the run leaves the edge out with
a notice, so infrastructure runs never wait on the minter. Set the repository variable
`UNFOLD_STAGING_EDGE` to `disabled` to skip the read altogether. The rebuild drill does not run this
workflow, so a throwaway cluster never takes the staging hostname or a second tunnel.

Access lets in anyone with an address in `unfold_staging_access_email_domains` (default
`webgrip.nl`), plus any address in the optional repository variable `UNFOLD_STAGING_ACCESS_EMAILS`
(a JSON list). They sign in with Google Workspace once its client is in OpenBao, and with a one-time
PIN until then.

### Sign in with Google Workspace

People sign in with their Google Workspace account, through one Google OAuth client. Google offers
no API to create an OAuth client for a web application, so a person makes it once; everything after
that is code. Customers will sign in through Unfold's own identity broker instead
([customer environments](https://forgejo.webgrip.dev/webgrip/unfold/src/branch/development/docs/concepts/customer-environments.md)),
which can reuse this client to federate the Webgrip staff.

1. In the Google Cloud project that holds the Workspace's internal OAuth consent screen: APIs &
   Services → Credentials → Create credentials → OAuth client ID → Web application, named
   `Unfold staging`, with two authorised redirect URIs:
   `https://<team name>.cloudflareaccess.com/cdn-cgi/access/callback` (the team name is under Zero
   Trust → Settings) and `https://staging-app.unfoldhq.dev/api/auth/oidc/callback` (for Unfold's own
   sign-in).
2. From a homelab-cluster checkout, store both values without echoing them:
   `just secret-set unfold-main/staging/google-oidc client-id` and
   `just secret-set unfold-main/staging/google-oidc client-secret`.
3. OpenBao's role `ci-unfold-cluster` reads `secret/data/unfold-main/staging/google-oidc`
   (homelab-cluster, `kubernetes/apps/security/openbao/bootstrap/ci-unfold-cluster.hcl`).
4. Run `infra` plan-only: one identity provider `Google Workspace` to add and the application
   `Unfold staging` to change. Apply with its digest.

The application then offers Google Workspace alone and redirects to it, so a person signs in once.
The one-time PIN identity provider stays declared: removing the client from OpenBao and applying
brings the PIN back. `infra/tests/unfold_staging_edge.tftest.hcl` pins both states.

### Clients without a browser

An editor extension, a script or any other client that cannot follow the Access sign-in gets a `302`
to it on every request. For those, OpenTofu declares one Access service token, named
`unfold-staging editors` and its generation, and a second policy on the application
`Unfold staging`: Service Auth, for that token and nothing else. Access evaluates Service Auth
policies before the people policy, whatever their order
([Access policies](https://developers.cloudflare.com/cloudflare-one/access-controls/policies/)). A
request with both headers reaches Unfold, which still asks for its own sign-in:

```text
CF-Access-Client-Id: <client id>
CF-Access-Client-Secret: <client secret>
```

Whoever holds the pair passes Access without signing in, so it goes only to someone Access already
lets in as a person. The pair is shared: Access records the token, not who used it, and taking it
away from one person means replacing it for everyone ([Rotating](#rotating)). A client that cannot
send request headers still meets the Access sign-in.

Nobody copies the pair out of Cloudflare, which shows a client secret once. The apply that makes the
token writes both values to OpenBao `secret/cloudflare/unfold-staging-access`, as
`CF_ACCESS_CLIENT_ID` and `CF_ACCESS_CLIENT_SECRET`, through `scripts/openbao-kv.sh put
access-client-id` and `put access-client-secret`; the second masks the secret. The path is outside
`secret/unfold-main/`, so the cluster's External Secrets role cannot read it: `ci-unfold-cluster`
writes it and only an OpenBao administrator reads it. From a homelab-cluster checkout,

```sh
eval "$(mise exec -- just secret-env cloudflare/unfold-staging-access)"
```

exports both names into that shell. Give the client the two values as those request headers, kept
in its own secret store and never in a settings file.

The token lives one year from the apply that made it. An `infra` apply prints the date as the output
`unfold_staging_editor_token_expires_at`. Cloudflare's notification *Expiring Access Service Token
Alert* warns a week ahead; it is set in the dashboard and not declared here.

On an edge that already exists the homelab goes first, because the apply needs two things it does
not have yet: the edge token with **Access: Service Tokens · Edit**, which the minter mints on its
next run (daily at 03:17) once its permission groups change, and `ci-unfold-cluster`'s right to write
the path. Without the first the apply fails on the service token and the application keeps its one
policy; without the second it fails on the write, and the next apply writes the pair.

### The one step in Cloudflare's dashboard

Cloudflare Access needs a Zero Trust organisation on the account, and the account has to take the
Zero Trust Free plan in the dashboard: the plan is a subscription, and Cloudflare offers no API to
take one. Without it every Access call answers `access.api.error.not_enabled: Access is not
enabled`. It is done once per account, and it was done on 2026-10-29
(Zero Trust Free). For a new account: Cloudflare dashboard → Zero Trust →
choose a team name → Free plan. Everything after that is code.

The token write and the DNS record wait for both Access applications, so an apply that fails on
Access publishes neither the hostname nor the connector token, and `cloudflared` never serves the
host without Access in front of it. On 2026-10-29 the first apply ran before that ordering existed:
it created the tunnel, its configuration, the DNS record and the token, and failed on Access.

1. OpenBao's role `ci-unfold-cluster` (homelab-cluster,
   `kubernetes/apps/security/openbao/bootstrap/`) reads `secret/data/cloudflare/unfold-tunnel` and
   writes `secret/data/unfold-main/staging/cloudflare-tunnel` and
   `secret/data/cloudflare/unfold-staging-access`.
2. Run `infra` plan-only, read the plan (one tunnel, one config, one CNAME, one identity provider, one
   service token and its generation, three policies, two Access applications, the two token writes),
   then apply with its digest.
3. The apply writes the connector token to `secret/unfold-main/staging/cloudflare-tunnel` (`token`),
   through `scripts/openbao-kv.sh put tunnel-token`, which masks it. External Secrets hands it to
   `cloudflared`. It writes the service token's pair to `secret/cloudflare/unfold-staging-access`
   ([clients without a browser](#clients-without-a-browser)).

If the apply fails on the identity provider because the account already has a One-time PIN login
method, import it once instead of creating a second: add
`import { to = cloudflare_zero_trust_access_identity_provider.one_time_pin["unfold-staging"], id = "accounts/<account id>/<identity provider id>" }`
to the configuration in a pull request, apply, then remove the block.

## Checks after an apply

* `https://staging-app.unfoldhq.dev/` redirects to Google (or asks for a one-time PIN before the Google client exists), and only an allowed domain or address gets in.
* `curl -sS -o /dev/null -w '%{http_code}' -X POST https://staging-app.unfoldhq.dev/webhooks/tracker/clickup`
  answers 401 from ploegd, not an Access redirect.
* With the pair in the shell ([clients without a browser](#clients-without-a-browser)),
  `curl -sS -o /dev/null -w '%{http_code} %{content_type}\n' -H "CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}" -H "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}" https://staging-app.unfoldhq.dev/api/auth/methods`
  answers `200 application/json` from Unfold; the same request without the two headers answers 302
  to the Access sign-in.
* `curl -sS -o /dev/null -w '%{http_code}' -H 'Host: other.unfoldhq.dev' …` through the tunnel answers 404.
* The tunnel shows two healthy connectors in Zero Trust → Networks → Tunnels.

## Rotating

* **The API token:** a new value in `secret/cloudflare/unfold-tunnel`, an `infra` plan to prove it works,
  then revoke the old one in Cloudflare.
* **The connector token:** it is derived from the tunnel's secret. To change it, raise
  `unfold_staging_tunnel_generation` in a pull request and apply; the tunnel is recreated with a new
  id, the record follows, and the apply writes the new token. `cloudflared` reconnects when External Secrets refreshes the Secret and the pod restarts.
* **The service token:** raise `unfold_staging_editor_token_generation` in a pull request and apply.
  The apply makes a new token with a new client id, secret and year, points the policy at it, deletes
  the old one and writes the new pair to `secret/cloudflare/unfold-staging-access`. The old pair
  stops working in that apply, so everyone who still needs it reads the new one. Do this before the
  token expires, when someone who held the pair should lose it, and when the pair may have leaked.
