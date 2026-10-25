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
| source-controller, kustomize-controller, helm-controller | notification-controller | 9090 | their Kubernetes events, through the `notification-controller` Service |
| source-controller | `github.com` | 443 | the GitRepository `flux-system` (this repository) |
| source-controller | `charts.hetzner.cloud` | 443 | the `hetzner` HelmRepository index and its chart archives, served from the same host |
| source-controller | `helm.cilium.io` | 443 | the `cilium` HelmRepository index and the Tetragon chart archive ([runtime security](runtime-security.md)) |
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

## Flow evidence

Every Cilium agent writes each new egress connection (not replies) to `/var/log/hubble/egress-flows.log` on its node, through Hubble's static exporter (`hubble.export.static` in [the Cilium values](../../kubernetes/platform/cilium/values.yaml), 10 MB, two rotations). Each record keeps only these fields:

- the verdict and drop reason
- the source namespace, pod and workload
- the destination pod, workload, DNS names and address
- the port
- `egress_allowed_by` and `egress_denied_by`: the policies that allowed or refused the flow

Vector reads the file through its existing read-only `/var/log` mount and sends it to the homelab VictoriaLogs as `source:=hubble-egress`. Besides the flow itself, each record carries flat fields for queries: `source_namespace`, `source_workload`, `destination_name` (the DNS names, or the address when there is none), `destination_port`, `allowed_by` and `denied_by` (`kind/namespace/name` of each policy). The message reads `<namespace>/<workload> -> <destination>:<port> <verdict>`.

The policy names are the evidence a flip needs: a flow is covered only if `allowed_by` names this namespace's CiliumNetworkPolicy.

```logsql
cluster:=unfold source:=hubble-egress source.namespace:=flux-system
  | stats by (source_workload, destination_name, destination_port, allowed_by) count()
```

```logsql
cluster:=unfold source:=hubble-egress verdict:=DROPPED | stats by (source_namespace, source_workload, destination_name, destination_port, denied_by) count()
```

### What the evidence said on 2026-10-25

The export did not exist yet and the homelab gateway was offline, so the only evidence was each agent's Hubble metrics: `hubble_policy_verdicts_total`, read through the API server's pod proxy. These counters cover about four hours since the agents last restarted. The worker `unfold-app-1` could not be read that way.

- **flux-system cannot be enforced by flipping this policy alone.** The FluxInstance sets `cluster.networkPolicy: true`, so the Flux distribution installs the NetworkPolicy `allow-egress`. It allows all egress from every pod in `flux-system`, and network policies only add. Flows covered by nothing but that policy show up with `match="all"`.
  - The event flows from kustomize-controller (512 in four hours), helm-controller and source-controller to notification-controller had no rule. They are now named above.
  - Their API server calls also report `match="all"`, so the verdict alone cannot show which rule matched. The export's `allowed_by` can.
  - The flip has to replace Flux's own NetworkPolicies, with `cluster.networkPolicy: false` and this namespace's own ingress rules. A Cilium-only flip blocks nothing.
- **kube-system:** every flow reported a named match (`l3-only`, `l3-l4` or `l7/dns`). But the counters do not say which destination name or port matched, and four hours do not cover a daily job.
- **Drops in enforced namespaces:** `external-secrets-cert-controller` (19) and `kube-state-metrics` (20) were refused egress to `remote-node` (`match="none"`, `POLICY_DENIED`). The export names the address and port; it is either a missing rule or traffic that should stay refused.

No namespace was flipped on this evidence.

## Enforcing a staged policy

1. Let the export run for a week, so it covers the six-hourly etcd backup, the daily scrubs and a Renovate bump.
2. Every flow from the namespace must have `allowed_by` naming the namespace's own policy (first query above). A flow that does not is either added here with its reason or is a finding.
3. In one pull request per namespace, set `enableDefaultDeny.egress` to `true` (or remove the field) and remove the namespace from the `default-deny` exclusion list. For flux-system, also turn off Flux's own NetworkPolicies (see above). Flux first: if Flux loses GitHub, the fix reaches the cluster only by hand.
4. After the merge, watch for dropped flows from that namespace (second query above) and for Flux's `Ready` condition.
