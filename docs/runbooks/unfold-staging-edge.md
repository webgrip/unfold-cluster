# Unfold staging's public edge

[ADR 0017](../adr/0017-staging-runs-here-with-agents-under-gvisor-on-the-hub.md) puts Unfold staging at
`staging-app.unfoldhq.dev`, public through a Cloudflare Tunnel. This page covers the part OpenTofu
owns in [infra/unfold-staging-edge.tf](../../infra/unfold-staging-edge.tf): the tunnel, its routes,
the DNS record and Cloudflare Access. The `cloudflared` connector that runs in the cluster is part of
the staging manifests under `kubernetes/apps/unfold-staging/`.

## How a request gets in

```text
browser, forge or tracker
  │  DNS: staging-app.unfoldhq.dev, a proxied CNAME to <tunnel id>.cfargotunnel.com
  ▼
Cloudflare edge: TLS, then Access
  │  /webhooks/*  → Access application "Unfold staging webhooks", bypass for everyone
  │  everything else → Access application "Unfold staging", one-time PIN, listed addresses only, 8 h session
  ▼
tunnel unfold-staging (remotely managed; the routes live in OpenTofu)
  │  ^/webhooks/  → http://ploeg.unfold-staging.svc.cluster.local:8080   ploegd checks each webhook's HMAC
  │  rest of host → http://unfold.unfold-staging.svc.cluster.local:4080  Unfold's own sign-in
  │  anything else → 404
  ▼
cloudflared in unfold-staging-edge, which dials out to Cloudflare; no port opens on any node
```

Two controls stand in front of the UI: Access, then Unfold's sign-in. The webhook path has one
control at the edge (none: forges cannot answer Access) and one at the origin (ploegd's HMAC, after
which ploegd re-reads the tracker and never acts on the body).

`infra/tests/unfold_staging_edge.tftest.hcl` pins the route order and the final 404, that only
`/webhooks/` bypasses Access, that the record is proxied, and that nothing is declared unless the edge
is enabled.

## The certificate at the edge

Cloudflare's free Universal SSL covers `unfoldhq.dev` and `*.unfoldhq.dev`, one level only, so the
hostname stays a first-level name: `staging-app.unfoldhq.dev`, not `staging.app.unfoldhq.dev`. The
variable's validation refuses a deeper name, which would need Advanced Certificate Manager (about
€9.50 a month) before a browser could reach it.

## Turning it on

The edge is declared only while the repository variable `UNFOLD_STAGING_EDGE` is `enabled`. The
rebuild drill never sets it, so a throwaway cluster never takes the staging hostname or a second tunnel.

1. Create a Cloudflare API token with **Account · Cloudflare Tunnel · Edit**, **Account · Access: Apps
   and Policies · Edit**, **Account · Access: Organizations, Identity Providers, and Groups · Edit** and
   **Zone · DNS · Edit** on `unfoldhq.dev` only. Store it from the homelab:

   ```sh
   just secret-set cloudflare/unfold-tunnel api-token
   ```

2. Add the plain variables (the homelab's `forgejo-actions-secrets` bridge copies them at minute 23):

   ```sh
   just secret-set unfold-cluster/vars CLOUDFLARE_ACCOUNT_ID
   just secret-set unfold-cluster/vars CLOUDFLARE_ZONE_ID_UNFOLDHQ
   just secret-set unfold-cluster/vars UNFOLD_STAGING_ACCESS_EMAILS
   just secret-set unfold-cluster/vars UNFOLD_STAGING_EDGE
   ```

   `just secret-set` asks for the value without echoing it, keeps the other keys at the path, and
   leaves nothing in shell history. The access list is a JSON list, such as `["owner@example.com"]`;
   the edge switch is `enabled`.

3. OpenBao's role `ci-unfold-cluster` (homelab-cluster,
   `kubernetes/apps/security/openbao/bootstrap/ci-unfold-cluster.hcl`) must read
   `secret/data/cloudflare/unfold-tunnel` and write `secret/data/unfold-main/staging/cloudflare-tunnel`.
4. Run `infra` plan-only, read the plan (one tunnel, one config, one CNAME, one identity provider, two
   policies, two Access applications, the token write), then apply with its digest.
5. The apply writes the connector token to `secret/unfold-main/staging/cloudflare-tunnel` (`token`),
   through `scripts/openbao-kv.sh put tunnel-token`, which masks it. External Secrets hands it to
   `cloudflared`.

If the apply fails on the identity provider because the account already has a One-time PIN login
method, import it once instead of creating a second: add
`import { to = cloudflare_zero_trust_access_identity_provider.one_time_pin["unfold-staging"], id = "accounts/<account id>/<identity provider id>" }`
to the configuration in a pull request, apply, then remove the block.

## Checks after an apply

* `https://staging-app.unfoldhq.dev/` asks for an Access one-time PIN, and only a listed address gets one.
* `curl -sS -o /dev/null -w '%{http_code}' -X POST https://staging-app.unfoldhq.dev/webhooks/vikunja`
  answers 401 from ploegd, not an Access redirect.
* `curl -sS -o /dev/null -w '%{http_code}' -H 'Host: other.unfoldhq.dev' …` through the tunnel answers 404.
* The tunnel shows two healthy connectors in Zero Trust → Networks → Tunnels.

## Rotating

* **The API token:** a new value in `secret/cloudflare/unfold-tunnel`, an `infra` plan to prove it works,
  then revoke the old one in Cloudflare.
* **The connector token:** it is derived from the tunnel's secret. To change it, raise
  `unfold_staging_tunnel_generation` in a pull request and apply; the tunnel is recreated with a new
  id, the record follows, and the apply writes the new token. `cloudflared` reconnects when External Secrets refreshes the Secret and the pod restarts.
