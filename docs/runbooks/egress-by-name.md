# Egress by name

Every egress rule in this cluster names its destination: a pod, an entity such as `kube-apiserver`, or a host name through Cilium's DNS proxy (`toFQDNs`). There are no `world` rules. RFC 0001 section 4 and delivery step 7.

## How a name becomes an allowed address

A pod's DNS lookups go to kube-dns, or for a pod with `dnsPolicy: Default` to the Talos host resolver at `169.254.116.108`. A `rules: dns` section on that egress rule sends the lookups through Cilium's DNS proxy, which records the answers. A `toFQDNs` rule then allows the addresses the proxy saw for that name, for as long as the answer's TTL lasts. A pod whose lookups bypass the proxy never gets its FQDN rule filled in, so every policy with `toFQDNs` also carries the DNS rule for the resolver that pod actually uses.

## Where each namespace stands

| Namespace | Default deny | Egress policy |
| --- | --- | --- |
| every namespace except `kube-system` and `flux-system` | enforced by the `default-deny` CiliumClusterwideNetworkPolicy; DNS to kube-dns is allowed | its own CiliumNetworkPolicy (`etcd-backup`, and `zot` once it lands) |
| `flux-system` | not yet | [flux-system-egress.yaml](../../kubernetes/platform/network-policy/flux-system-egress.yaml), staged |
| `kube-system` | not yet | [kube-system-egress.yaml](../../kubernetes/platform/network-policy/kube-system-egress.yaml), staged |

**Staged** means each policy sets `enableDefaultDeny: {egress: false}`. The allow rules are in place and the pods' DNS already passes the proxy (with `matchPattern: "*"`, so no name is refused), but traffic the policy does not name still flows. A wrong or missing rule cannot break Flux or the cloud integration while the list is proven. Flux is the path that would deliver a fix, so a mistake there would need a hand repair.

## Every flow, and why

### flux-system

| Pods | Destination | Port | Why |
| --- | --- | --- | --- |
| all five | kube-dns | 53 | name lookups, through the DNS proxy |
| all five | `kube-apiserver` | any | read and apply cluster state |
| source-controller | `github.com` | 443 | the GitRepository `flux-system` (this repository) |
| source-controller | `charts.hetzner.cloud` | 443 | the `hetzner` HelmRepository index and its chart archives, served from the same host |
| source-controller | `ghcr.io`, `pkg-containers.githubusercontent.com` | 443 | OCI charts on ghcr.io (Zot, External Secrets, Flux operator charts); blob downloads redirect to the second host |
| source-controller | `quay.io`, `*.quay.io` | 443 | the Cilium chart; blob downloads redirect to `cdn*.quay.io` |
| flux-operator | `ghcr.io`, `pkg-containers.githubusercontent.com` | 443 | the `flux-operator-manifests` distribution artifact |
| kustomize-controller, helm-controller | source-controller | 9090 | artifacts, through the `source-controller` Service |

Forgejo is not on the list: Flux reads this repository from GitHub. A new Flux source on another host adds that host here in the same pull request.

### kube-system

| Pods | Destination | Port | Why |
| --- | --- | --- | --- |
| hcloud-cloud-controller-manager | Talos host resolver `169.254.116.108` (as CIDR and as the `host` entity) | 53 | its pod uses `dnsPolicy: Default`, so its lookups skip kube-dns |
| hcloud-cloud-controller-manager | `kube-apiserver` | any | node addresses, labels and taints |
| hcloud-cloud-controller-manager | `api.hetzner.cloud` | 443 | server metadata |
| hcloud-csi controller | kube-dns, `kube-apiserver` | 53, any | lookups; PersistentVolumes and VolumeAttachments |
| hcloud-csi controller | `api.hetzner.cloud` | 443 | create, attach, resize volumes |
| hcloud-csi controller and node | metadata service `169.254.169.254` | 80 | server ID and location |
| hcloud-csi node | kube-dns | 53 | lookups |
| CoreDNS | `kube-apiserver` | any | Services and EndpointSlices |
| CoreDNS | Talos host resolver `169.254.116.108` (CIDR and `host`) | 53 | forwarding every name outside the cluster; no DNS proxy on this hop |
| hubble-relay | kube-dns | 53 | the `hubble-peer` Service |
| hubble-relay | `host`, `remote-node` | 4244 | each Cilium agent's Hubble server |
| hubble-generate-certs job, kube-proxy-removal job | kube-dns, `kube-apiserver` | 53, any | their only work is through the API |

The Cilium agent, operator and envoy, kube-proxy (while it still exists) and the control-plane static pods run on the host network. Pod policies do not select them; Talos's host firewall covers the nodes ([host firewall](host-firewall.md)).

## Enforcing a staged policy

1. Collect the namespace's egress flows for a few days: Hubble flow export to VictoriaLogs (RFC 0001 section 4, flow evidence) with the verdict and destination names. Until that export exists, Hubble Relay is the only source, and reading it needs `kubectl port-forward` into `kube-system`.
2. Every flow from the namespace must match a rule above. A flow that does not is either added here with its reason or is a finding.
3. In one pull request per namespace, set `enableDefaultDeny.egress` to `true` (or remove the field) and remove the namespace from the `default-deny` exclusion list. Flux first: if Flux loses GitHub, the fix reaches the cluster only by hand.
4. After the merge, watch for dropped flows from that namespace and for Flux's `Ready` condition.
