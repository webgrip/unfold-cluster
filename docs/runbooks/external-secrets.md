# External Secrets: reading the homelab OpenBao

External Secrets Operator (ESO) turns values kept in OpenBao into Kubernetes Secrets. OpenBao in the
homelab is the only original of every secret; this cluster keeps copies, never originals. RFC 0001
section 8 plans an OpenBao inside this cluster (delivery step 10). Until that exists, ESO reads the
homelab one, and moving to the in-cluster OpenBao later only changes the store.

## What runs where

| Piece | Where | Owner |
| --- | --- | --- |
| ESO controller | `external-secrets`, on the control planes (recovery set) | Flux Kustomization `external-secrets` |
| ESO webhook, cert controller | `external-secrets`, on the system pool, or a control plane while that node is gone | Flux Kustomization `external-secrets` |
| ClusterSecretStore `openbao-homelab` | cluster-wide, usable only from namespaces labelled `external-secrets.webgrip.io/openbao-homelab: allowed` | Flux Kustomization `external-secrets-stores` |
| The homelab gateway, `unfold-gateway.webgrip.dev:8200` | forwards to the homelab OpenBao over the tailnet | homelab-cluster `kubernetes/apps/observability/unfold/`; see [observability](../observability.md) |
| JWT auth mount `jwt-unfold-main`, role `unfold-main-external-secrets`, policy `unfold-main-reader` | homelab OpenBao | homelab-cluster `kubernetes/apps/security/openbao/bootstrap` |
| Secret values | homelab OpenBao KV, under `secret/unfold-main/` | whatever mints them; see each consumer |

The store is split from the chart on purpose: the ClusterSecretStore kind exists only after the chart
installed its CRDs, and a Kustomization that holds both fails its dry run on a fresh cluster.

## How ESO proves who it is

No secret crosses from the homelab to this cluster to set up the trust. ESO asks the API server for a
ten-minute token for the ServiceAccount `external-secrets/openbao-homelab` with audience
`openbao-homelab`, and logs in with it at `auth/jwt-unfold-main`. The homelab OpenBao checks the
token's signature against this cluster's service-account public key, which homelab-cluster keeps in
git as a public value, and checks the issuer (`https://10.64.0.10:6443`), the audience and the subject.
The role's policy reads `secret/data/unfold-main/*` and nothing else, so this cluster cannot read the
homelab's own secrets or the OpenTofu state under `secret/unfold-cluster/`.

The ESO controller may mint tokens for that one ServiceAccount only (Role
`external-secrets-openbao-homelab-token`); the chart's cluster-wide `serviceaccounts/token` grant is
switched off.

## The link to the homelab

The homelab OpenBao is reachable only on the homelab LAN. The homelab gateway joins this cluster's
tailnet as `tag:homelab-gateway` and forwards its port 8200 to that OpenBao; the Headscale policy lets
only the control planes (`tag:cp`), where the chart pins the External Secrets controller, and the admins
open it; the workers, which run untrusted CI jobs and Runs, cannot
([node roles](infra-workflow.md#node-roles-on-the-tailnet)). The store's server is
`http://unfold-gateway.webgrip.dev:8200`, a DNS-only record that the homelab publishes with the
gateway's tailnet address. The CiliumNetworkPolicy `external-secrets-openbao-homelab` lets the ESO
controller resolve that one name and open port 8200 on the address it resolves to, nothing else.
The traffic is plain HTTP inside the tailnet's WireGuard tunnel; OpenBao's tokens never cross the
internet. How the gateway, its key and the policy are set up, with no hand steps: [observability](../observability.md).

Until the gateway is up the store reports `NotReady` and every ExternalSecret that uses it stays
unsynced. Nothing else breaks: no consumer waits on the store's health.

## When the cluster is rebuilt

A rebuild makes a new service-account key, so every login fails on the token signature and the
store goes `NotReady`. Write the new public key as PEM into
`kubernetes/apps/security/openbao/bootstrap/unfold-main-service-account.pem` in homelab-cluster,
from this cluster's published key set (public data, nothing secret is read):

```sh
kubectl --kubeconfig ~/.kube/unfold.yaml get --raw /openid/v1/jwks | python3 -I -c '
import base64, json, sys, textwrap
k = json.load(sys.stdin)["keys"][0]
num = lambda s: int.from_bytes(base64.urlsafe_b64decode(s + "=" * (-len(s) % 4)), "big")
def der(tag, body):
    n = len(body)
    size = bytes([n]) if n < 128 else bytes([0x80 | ((n.bit_length() + 7) // 8)]) + n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([tag]) + size + body
integer = lambda i: der(2, i.to_bytes(i.bit_length() // 8 + 1, "big"))
rsa = der(0x30, integer(num(k["n"])) + integer(num(k["e"])))
spki = der(0x30, der(0x30, bytes.fromhex("06092a864886f70d0101010500")) + der(3, b"\0" + rsa))
print("-----BEGIN PUBLIC KEY-----", *textwrap.wrap(base64.b64encode(spki).decode(), 64), "-----END PUBLIC KEY-----", sep="\n")
' > unfold-main-service-account.pem
```

The key id Kubernetes publishes is the SHA-256 of that key, so this must print the `kid` from the
same JWKS:

```sh
openssl pkey -pubin -in unfold-main-service-account.pem -outform DER | openssl dgst -sha256 -binary | basenc --base64url | tr -d =
```

The `openbao-config` CronJob applies the committed key within the hour.

## Adding a consumer

1. Label the consumer's namespace `external-secrets.webgrip.io/openbao-homelab: allowed`.
2. Put the value in OpenBao under `secret/unfold-main/<area>/<name>`, minted by a homelab job, or
   provided once with `just secret-set unfold-main/<area>/<name> <key>` from homelab-cluster.
3. Add an ExternalSecret with `secretStoreRef: {kind: ClusterSecretStore, name: openbao-homelab}`,
   annotated with where its value comes from (below). `scripts/check-wellhead.sh` refuses one that
   is not, in CI (`wellhead-check`).

## Every ExternalSecret says where its value comes from

Each ExternalSecret carries [wellhead](https://github.com/wellhead-dev/wellhead) annotations
(spec `v1alpha1`):

| `wellhead.dev/origin` | Who writes the value | Here |
| --- | --- | --- |
| `minted` | a controller: an External Secrets generator in this cluster, or a homelab job or PushSecret | every generator-backed ExternalSecret; the Forgejo, Cloudflare, ntfy, query and OIDC values the homelab pushes; the tunnel token the `infra` apply writes |
| `provided` | a person, with `wellhead.dev/how` saying where to get it and `wellhead.dev/verify` how it is checked | LiteLLM's provider keys, the Vikunja bot token, the backup bucket keys, the dead-man URL |
| `preserve` | written once, never regenerated | the `hcloud-luks` passphrase: restore the escrowed value, never a new one |
| `projected` | another ExternalSecret | `agent-litellm-master`, copied from `litellm-generated` |

From a device on the tailnet, with this cluster's kubeconfig and a token for the homelab OpenBao,
`wellhead missing` lists every value the vault does not hold, and `wellhead seed` fills one: it shows
`how`, asks without echo, runs the checks, writes with check-and-set, records who seeded it and when,
and makes External Secrets sync:

```sh
export KUBECONFIG=~/.kube/unfold.yaml BAO_ADDR=http://unfold-gateway.webgrip.dev:8200
export BAO_TOKEN="$(bao print token)"   # after logging in to the homelab OpenBao
wellhead missing --verify
wellhead seed observability/alertmanager-deadman
```

A `minted` value that is missing waits for its writer; `wellhead seed` refuses it.

The chart installs only the kinds this cluster uses: ExternalSecret, SecretStore, ClusterSecretStore
and the namespaced generators (Password and the rest). ClusterExternalSecret, PushSecret,
ClusterPushSecret and ClusterGenerator are off, with their controllers, because every CRD's schema
sits in each control plane's API server memory (ADR 0013). A manifest of one of those kinds fails
Flux's dry run with `no matches for kind`; turning its `crds.create*` and `process*` values back on
in `kubernetes/platform/external-secrets/app/helmrelease.yaml` comes first, in its own pull request.

## Where the webhook and cert controller run

Only the controller reads OpenBao, so only it needs `tag:cp`. The webhook, which checks every
ExternalSecret and SecretStore Flux applies, and the cert controller, which keeps the webhook's
certificate, prefer the system pool and may fall back to a control plane. Their ValidatingWebhook
refuses writes while no webhook pod is ready (`failurePolicy: Fail`), so:

* **The system node is drained** (a Talos upgrade): both pods are evicted and start on a control
  plane within seconds; Flux retries anything refused in between.
* **The system node dies:** Kubernetes evicts its pods after five minutes `NotReady`, then the same.
  Secrets already in the cluster stay, and the controller keeps syncing them; only new or changed
  ExternalSecrets wait.
* **The node is back:** a preference never moves a running pod, so they stay on the control plane
  until the next rollout (a Renovate update, or
  `kubectl -n external-secrets rollout restart deploy/external-secrets-webhook deploy/external-secrets-cert-controller`).

## Checks

```sh
kubectl --kubeconfig ~/.kube/unfold.yaml get clustersecretstore openbao-homelab
kubectl --kubeconfig ~/.kube/unfold.yaml get externalsecret -A
kubectl --kubeconfig ~/.kube/unfold.yaml -n external-secrets logs deploy/external-secrets --tail=50
```

`Ready=True` on the store means a login worked. An ExternalSecret in a namespace without the label
is refused by the store's namespace condition, which is the restriction working.
