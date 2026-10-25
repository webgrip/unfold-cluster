# Zot registry

Zot is the cluster's own OCI registry: a pull-through cache for the four public registries the platform uses, and the place CI pushes our images to. It is step 9 of [RFC 0001](../rfc/0001-security-architecture.md#6-images-and-supply-chain). Everything below is in `kubernetes/platform/zot`, reconciled by Flux.

| | |
| --- | --- |
| Address in the cluster | `zot.zot.svc.cluster.local:5000`, plain HTTP |
| Address for the nodes' containerd | `127.0.0.1:30500` on every node (a NodePort; the Talos mirror config uses it) |
| Mirrors | `docker.io/…`, `ghcr.io/…`, `quay.io/…`, `registry.k8s.io/…` under the same path in Zot, e.g. `zot.zot.svc.cluster.local:5000/quay.io/cilium/cilium@sha256:…` |
| Our images | `webgrip/…`, pushed by CI as user `ci` |
| Runs on | the hub pool (`node.webgrip.io/pool=unfold`), one replica |
| Storage | PVC `zot-data`, 20 GiB on `hcloud-volumes` |

## Pulling through the mirror

A request for an image Zot does not hold is fetched from upstream on the spot and then served; later pulls of the same digest never leave the cluster. A request for a tag is checked against upstream at most once an hour per tag (`manifestCheckInterval`). Pull by `docker.io/library/<name>` for Docker Hub's official images, the same name containerd uses.

Digests stay exactly as upstream publishes them, Docker media types included (`http.compat: docker2s2`), so a digest pinned in this repository resolves the same through Zot as it does upstream.

What is mirrored is filtered by path: a repository outside the four mirror prefixes, such as `webgrip/…`, is never looked up upstream. A missing `webgrip/foo` answers 404; it can never be fetched from Docker Hub's `webgrip/foo`.

Only the parts a client asks for are stored. Pulling a multi-arch image on an amd64 node stores the index and the amd64 image, not every platform.

## Who can read and push

| Caller | Read | Push |
| --- | --- | --- |
| Anyone who reaches the Service, without credentials | everything | nothing |
| `ci` with its password | everything | `webgrip/**`: create and update tags; no delete |
| `ci` on a mirror path or the top level | yes | refused (403) |

Reads are anonymous because the nodes' containerd pulls without credentials and everything outside `webgrip/` is public anyway. Who can reach Zot at all is the network policy's job: only the nodes (`host`, `remote-node`, that is containerd and the kubelet's probes), pods in the `ci` namespace, the Trivy scanner in `trivy-system` (the vulnerability database, the check bundle and the images it scans, [vulnerability-scanning](vulnerability-scanning.md)) and Kyverno's admission controller (webgrip image signatures, [image-signatures](image-signatures.md)). Agent Run pods and every other namespace are refused by the default-deny policy before they reach Zot.

### The push credential

Nobody makes or types it. The Job `zot-push-credentials` creates the Secret `zot/zot-push-credentials` (keys `username`, `password`, `htpasswd`) the first time it runs, with a random 40-character password and its SHA-512 crypt hash. Zot mounts only the `htpasswd` key and reloads it when it changes.

The Job finishes in seconds and deletes itself an hour later; Flux recreates it at its next reconcile, so it runs about once an hour. Each run leaves an existing credential alone and refreshes the copies in consumer namespaces. To rotate the password, delete `zot/zot-push-credentials`: the next run makes a new one and updates every copy.

A namespace that needs to push opts in with one RoleBinding to the ClusterRole `zot-push-credentials-consumer`, and is listed in the Job's `CONSUMER_NAMESPACES` (today: `ci`). The Job then writes a `kubernetes.io/dockerconfigjson` Secret `zot-push-credentials` there, with `username` and `password` beside `.dockerconfigjson`. The ClusterRole lets it create Secrets and change only that one name. Until the RoleBinding exists the Job logs `skipped <namespace>` and carries on.

The RoleBinding for `ci` belongs with the CI runners:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: zot-push-credentials
  namespace: ci
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: zot-push-credentials-consumer
subjects:
  - kind: ServiceAccount
    name: zot-push-credentials
    namespace: zot
```

CI pods also need an egress rule to Zot (`toEndpoints` with `k8s:io.kubernetes.pod.namespace: zot` and `app.kubernetes.io/name: zot`, port 5000).

### Why not workload identity

Zot can verify Kubernetes service-account tokens itself (`auth.bearer.oidc`), which would remove the password entirely: a CI pod would push with a projected token for audience `zot`. It needs the API server's OIDC discovery document to be readable without credentials, and on this cluster it is not: `/.well-known/openid-configuration` answers 401 to an anonymous request. Opening it is an API-server authentication change for the Talos config, so it waits for the authentication work in delivery step 5. When discovery is reachable, switch Zot to bearer OIDC and delete the Job.

## Retention and disk

The disk holds only what is in use, so it cannot grow without bound:

| Content | Kept |
| --- | --- |
| Mirrored images | anything pulled in the last 30 days; the rest is deleted and fetched again on the next pull |
| `webgrip/**` release tags (`v1.2.3`) | the 20 most recently pushed per repository |
| `webgrip/**` other tags | the 10 most recently pushed, plus any pulled in the last 30 days |
| Untagged manifests | those pulled in the last 30 days; others after a 24-hour grace |
| Signatures and other referrers | as long as the image they refer to |

Garbage collection runs every 6 hours and removes blobs unreferenced for an hour; identical layers are stored once (`dedupe`). A scrub checks every stored blob against its digest once a day.

The volume is 20 GiB, which costs about €1 a month (Hetzner bills volumes at about €0,05 per GB per month; the CSI driver rounds 20 GiB up to 22 GB). To grow it, raise `storage` in `persistentvolumeclaim.yaml`; the StorageClass allows online expansion, and Hetzner volumes only grow, never shrink. The class keeps the volume on `Retain`: deleting the PVC leaves the Hetzner volume, and its bill, behind until it is deleted in the Hetzner Console.

There is no metric or alert on disk use yet; the observability stack (delivery step 8) adds Zot's `/metrics` and a disk alert. Until then the kubelet reports it, read-only: `kubectl get --raw "/api/v1/nodes/$(kubectl -n zot get pod zot-0 -o jsonpath='{.spec.nodeName}')/proxy/stats/summary" | jq '.pods[] | select(.podRef.namespace == "zot") | .volume[]? | select(.name == "zot-data") | {usedBytes, capacityBytes}'`.

## Signatures

Zot copies an image's OCI referrers and cosign signatures along with the image when it syncs it. A Sigstore bundle attached to `quay.io/cilium/cilium` upstream is listed by `regctl artifact list zot.zot.svc.cluster.local:5000/quay.io/cilium/cilium@sha256:…` too. So signature checks can run against Zot without reaching upstream: Talos `ImageVerificationConfig` at pull time and Kyverno at admission, both in step 9's second half. CI's own signatures (cosign through OpenBao Transit) are pushed next to our images in `webgrip/…` the same way.

Zot does not yet refuse unsigned images. RFC 0001's target, serving only signed upstream images and re-signing the rest after a scan, needs `onlySigned` plus a scan-and-sign job, and comes with the image policies.

## Network

The policy `zot` allows the pod to reach these names on 443 and nothing else; a redirect to a new CDN host shows up as a dropped flow in Hubble and a failed sync in Zot's log:

| Registry | Hosts |
| --- | --- |
| Docker Hub | `registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com`, `production.cloudfront.docker.com`, `docker-images-prod.*.r2.cloudflarestorage.com` |
| GitHub | `ghcr.io`, `pkg-containers.githubusercontent.com` |
| Quay | `quay.io`, `cdn*.quay.io` |
| Kubernetes | `registry.k8s.io`, `cdn.registry.k8s.io`, `*-docker.pkg.dev` |

Docker Hub limits anonymous pulls per source address. Zot pulls each digest once, which keeps the count low; if it runs into the limit, give Zot a Docker Hub token through `extensions.sync.credentialsFile`.

The NodePort 30500 listens on every node address. From outside, the Hetzner Cloud Firewall admits only ICMP and the admin ports, and the policy above refuses any source that is not a node or a `ci` pod, so the port answers only the nodes themselves.

The traffic is plain HTTP inside the cluster. Pod-to-pod traffic across nodes is WireGuard-encrypted by Cilium; the push password travels that way. TLS on Zot itself comes with cert-manager in step 10. Image content needs no secrecy and is checked by digest.

## Checks

- `kubectl -n zot get pods,pvc,job` — `zot-0` Running and Ready, `zot-data` Bound, the Job Complete (or recently deleted).
- `kubectl -n zot logs zot-0 | grep -i error` — no errors except `image is filtered out by sync config`, which is a pull of a missing `webgrip/` image.
- From a pod in `ci`: `regctl manifest head zot.zot.svc.cluster.local:5000/ghcr.io/siderolabs/talos-backup@sha256:05c86663b251a407551dc948097e32e163a345818117eb52c573b0447bd0c7a7` prints the same digest.
- The authorisation matrix above was run against this exact configuration (Zot v2.1.22) before it merged: anonymous push 401, `ci` push to a mirror path 403, `ci` delete 403, `ci` push to `webgrip/` accepted, anonymous read 200, and a missing `webgrip/` image 404 without an upstream lookup.
