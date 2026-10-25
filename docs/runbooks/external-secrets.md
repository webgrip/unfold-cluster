# External Secrets: reading the homelab OpenBao

External Secrets Operator (ESO) turns values kept in OpenBao into Kubernetes Secrets. OpenBao in the
homelab is the only original of every secret; this cluster keeps copies, never originals. RFC 0001
section 8 plans an OpenBao inside this cluster (delivery step 10). Until that exists, ESO reads the
homelab one, and moving to the in-cluster OpenBao later only changes the store.

## What runs where

| Piece | Where | Owner |
| --- | --- | --- |
| ESO controller, webhook, cert controller | `external-secrets`, on the control planes (recovery set) | Flux Kustomization `external-secrets` |
| ClusterSecretStore `openbao-homelab` | cluster-wide, usable only from namespaces labelled `external-secrets.webgrip.io/openbao-homelab: allowed` | Flux Kustomization `external-secrets-stores` |
| Service `openbao-homelab` in `external-secrets`, port 8200 | endpoints point at the homelab OpenBao | the homelab link (not built yet, see below) |
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

## The missing link

The homelab OpenBao is reachable only on the homelab LAN, and the homelab is not on this cluster's
tailnet: only admin devices and the cluster nodes are, and the tailnet policy lets only admins open
connections. Until a link exists, the store reports `NotReady` and every ExternalSecret that uses it
stays unsynced. Nothing else breaks: no consumer waits on the store's health.

The link has to provide exactly one thing: a Service `openbao-homelab` in `external-secrets` whose
endpoints reach the homelab OpenBao on port 8200. The CiliumNetworkPolicy
`external-secrets-openbao-homelab` already allows the ESO controller to that Service and nothing else.

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
3. Add an ExternalSecret with `secretStoreRef: {kind: ClusterSecretStore, name: openbao-homelab}`.

## Checks

```sh
kubectl --kubeconfig ~/.kube/unfold.yaml get clustersecretstore openbao-homelab
kubectl --kubeconfig ~/.kube/unfold.yaml get externalsecret -A
kubectl --kubeconfig ~/.kube/unfold.yaml -n external-secrets logs deploy/external-secrets --tail=50
```

`Ready=True` on the store means a login worked. An ExternalSecret in a namespace without the label
is refused by the store's namespace condition, which is the restriction working.
