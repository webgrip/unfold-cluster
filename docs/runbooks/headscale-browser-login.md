# Headscale browser login

A device joins the Unfold tailnet with `tailscale up` and a browser login through the homelab's
Authentik, confirmed with a passkey. Nobody runs `headscale nodes register` on the server any more.
The servers (`tag:cp`, `tag:node`, `tag:homelab-gateway`, `tag:headscale`) keep joining with
pre-auth keys the apply mints, and never expire.

## Joining a device

You need the homelab LAN or its WireGuard VPN, because the Authentik login page is not public.

```sh
tailscale up --login-server=https://headscale.webgrip.dev
```

1. `tailscale` prints a URL on `https://headscale.webgrip.dev/register/…`; open it.
2. Headscale sends the browser to Authentik, which signs you in through Google.
3. Authentik asks for your passkey or security key. Without one registered it refuses: register it
   first under **Settings → MFA Devices → Enroll → Passkey or security key** on
   `https://authentik.<homelab domain>/if/user/`.
4. The browser lands back on Headscale's success page; `tailscale status` lists the nodes.

The device belongs to the Headscale user named after your Authentik user name and expires after
30 days (`node.expiry`); run `tailscale up --login-server=https://headscale.webgrip.dev` again to
renew it, browser and passkey included.

## Who may join

Two gates, both from homelab git:

| Gate | Where | What refuses you |
| --- | --- | --- |
| Authentik application `unfold-headscale` | homelab `kubernetes/apps/security/access-plane/`: the application in `tofu/broker/applications.tf`, the `unfold-admins` binding from capability `unfold-cluster-operate` in `model/capabilities.yaml` | Not in `unfold-admins`: Authentik's "Permission denied". No passkey: the passkey stage. |
| Headscale `oidc.allowed_groups: [unfold-admins]` | `infra/headscale-oidc.tf` | A token without `unfold-admins` in its `groups` claim: Headscale answers `unauthorised group`. |

The passkey is demanded by the application's authorization flow `webgrip-passkey-authorization`
(an authenticator validation stage that accepts only WebAuthn, with user verification required,
every time), so an existing Authentik session without the passkey does not get through.

Every device a person registers is `autogroup:member` in the tailnet policy and reaches every
tagged node, the cluster's subnet and port 8200, 8427 and 9150 of the homelab gateway. Only
`tag:headscale` reaches the gateway's port 443 (`infra/tests/headscale_oidc.tftest.hcl` fails on
any rule, wildcard, range or prefix that would let anything else in).

## How Headscale reaches a LAN-only Authentik

```
Headscale ──/etc/hosts: authentik.webgrip.dev = gateway's tailnet IPv4──▶ tailscaled on the server (tag:headscale)
  ──tailnet, ACL tag:headscale → tag:homelab-gateway:443──▶ homelab unfold-gateway pod
  ──TCP forward──▶ envoy-internal.network:443 ──▶ Authentik
```

TLS is end to end between Headscale and envoy-internal, so the certificate is checked against the
real host name. Nothing about Authentik becomes public; from the internet the server answers only
HTTPS and ACME on 443 and 80, STUN on UDP 3478, and UDP 41641, the WireGuard port of its own
tailnet node.

On the server:

| Piece | Made by |
| --- | --- |
| Tailscale, pinned version and sha256 in `infra/headscale-oidc.tf` | `unfold-tailnet-key host apply`, from cloud-init on a new server and from every apply that changes the version or the program |
| The server's own node, `unfold-headscale`, `tag:headscale` | `unfold-tailnet-key idp reconcile` (timer `unfold-headscale-idp.timer`, every 2 minutes): when Tailscale is not running it mints a single-use, one-hour `tag:headscale` key from Headscale's own socket and runs `tailscale up` with it. The key never touches the command line or the disk beyond that call. |
| The `/etc/hosts` line for Authentik | the same reconcile: the IPv4 address of the newest online `tag:homelab-gateway` node, read from Headscale's own node list |
| `/etc/headscale/config.yaml` | `infra/templates/headscale-config.yaml.tftpl`, written by cloud-init on a new server and by `config set` from every apply that changes it; a configuration Headscale cannot start with is rolled back |
| `/etc/headscale/oidc_client_secret` (`root:headscale`, `0640`) | empty from cloud-init; filled by `oidc-secret set` from the apply, which reads OpenBao `secret/authentik/unfold-headscale-oidc` (`client_secret`) with role `ci-unfold-cluster`. It is never in cloud-init, the plan or the log. |

The client secret is generated in the homelab (`kubernetes/apps/authentik/app/unfold-headscale-oidc-client.*`),
which pushes it to OpenBao; Authentik's provider reads the same path. Nobody types it.

## When Authentik is down

Nothing that already joined notices: OIDC is used only to register or renew a person's device.
Tagged nodes never expire and keep their keys, and the data plane does not involve Headscale.

- Headscale starts without its identity provider (`only_start_if_oidc_is_available: false`). It
  then falls back to command-line registration and logs `falling back to CLI based authentication`.
  `scripts/test-headscale-config.sh` proves both on the pinned Headscale binary in CI.
- `idp reconcile` sees that line in the journal of Headscale's current run. Once the discovery
  document at `https://authentik.webgrip.dev/application/o/unfold-headscale/.well-known/openid-configuration`
  answers through the tailnet, it restarts Headscale, at most once every 10 minutes. A restart
  drops the control connections for seconds; nodes keep their tunnels.
- This happens after every reboot as well: Headscale starts before its own tailnet node is up, so
  the first start falls back and the reconcile restarts it within about three minutes.
- No deadlock: Headscale needs nothing from the tailnet to start; its own node uses a pre-auth key
  and a tag, never OIDC; and UDP 41641 is open so the path to the homelab gateway is direct and
  does not depend on the DERP relay inside Headscale, which is down while Headscale restarts.

While it lasts, a new device cannot join by browser. Break-glass: `ssh admin@headscale.webgrip.dev`,
then `sudo headscale nodes register --user ryan --key <key from the URL>`.

## Checking it

On the server (`ssh admin@headscale.webgrip.dev`):

```sh
systemctl list-timers unfold-headscale-idp.timer
sudo journalctl -u unfold-headscale-idp.service -n 20 -o cat
tailscale status
getent hosts authentik.webgrip.dev
curl -fsS https://authentik.webgrip.dev/application/o/unfold-headscale/.well-known/openid-configuration | jq .issuer
sudo journalctl -u headscale -b -o cat | grep -i oidc
```

Expect `headscale runs with OIDC`, the server's own node and the homelab gateway in the status,
a `100.64.0.0/10` address for Authentik, and the issuer printed.

| Symptom | Cause | Fix |
| --- | --- | --- |
| The register page shows a `headscale nodes register` command instead of Authentik | Headscale runs without OIDC | Read the reconcile's journal: `does not answer` means the path below is broken; `waiting` means a restart happened less than 10 minutes ago. |
| `no tag:homelab-gateway node with an IPv4 address` | The homelab gateway is not on the tailnet | homelab runbook `unfold-gateway` |
| `could not join its own tailnet` | Headscale's health URL or certificate is not ready, or Tailscale is missing | `sudo journalctl -u headscale`; `unfold-tailnet-key host apply` runs from the next apply |
| Authentik says Permission denied | You are not in `unfold-admins` | homelab `people.yaml`: a grant of `unfold-cluster-operate` |
| Authentik asks for a passkey you do not have | No WebAuthn device | Enroll one under Settings → MFA Devices first |
| Headscale says `unauthorised group` | The token has no `unfold-admins` in `groups` | Check the scope mapping `groups` on the provider in `applications.tf` |

## Proving it after the apply

1. From a laptop on the homelab LAN that has never joined: the steps under "Joining a device".
   `tailscale status` lists the nodes and `ssh admin@headscale.webgrip.dev sudo headscale nodes list`
   shows the device under your Authentik user name with an expiry 30 days out.
2. With an Authentik user that is not in `unfold-admins` (a test person in `people.yaml`
   without `unfold-cluster-operate`), the same steps end at Authentik's Permission denied, and
   `headscale nodes list` shows no new node.
3. Without a passkey enrolled, step 3 is refused.
