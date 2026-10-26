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
| source-controller | `kedacore.github.io` | 443 | the `kedacore` HelmRepository index and the KEDA chart archive, served from the same host |
| source-controller | `prometheus-community.github.io`, `kubernetes.github.io`, `aquasecurity.github.io` | 443 | the `prometheus-community` (kube-state-metrics, node-exporter), `kubernetes-autoscaler` and `aqua-security` (Trivy) HelmRepository indexes |
| source-controller | `release-assets.githubusercontent.com`, `objects.githubusercontent.com` | 443 | those three indexes point their chart archives at GitHub release downloads on `github.com`, which redirect to the first host today and to the second before GitHub moved them |
| source-controller | `ghcr.io`, `pkg-containers.githubusercontent.com` | 443 | OCI charts on ghcr.io (Zot, External Secrets, Kyverno, CloudNativePG, Flux operator charts); blob downloads redirect to the second host |
| source-controller | `quay.io`, `*.quay.io` | 443 | the Cilium chart; blob downloads redirect to `cdn*.quay.io` |
| flux-operator | `ghcr.io`, `pkg-containers.githubusercontent.com` | 443 | the `flux-operator-manifests` distribution artifact |
| flux-operator | notification-controller | 9090 | its Kubernetes events |
| kustomize-controller, helm-controller | source-controller | 9090 | artifacts, through the `source-controller` Service |

Forgejo is not on the list: Flux reads this repository from GitHub. A new Flux source on another host adds that host here in the same pull request; `scripts/check-flux-source-egress.sh` (workflow `flux-source-egress-check`, on pull requests and on pushes to `main`) fails when a GitRepository, HelmRepository, OCIRepository or Bucket names a host the policy does not. Redirect targets such as CDNs cannot be read from the tree, so they stay a review item.

Ingress to flux-system is owned by [flux-system-ingress.yaml](../../kubernetes/platform/network-policy/flux-system-ingress.yaml): any flux-system pod from the others, 8080 (metrics) from any pod in the cluster, and 9292 (webhook receivers) on notification-controller from any pod in the cluster. That is exactly what the Flux distribution's `allow-egress` (its ingress half), `allow-scraping` and `allow-webhooks` NetworkPolicies admit, so adding it changes nothing while those exist: network policies only add, and the namespace is already isolated for ingress by them. The flux-operator chart's own `flux-operator-web` policy keeps 9080.

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

### cluster-autoscaler

| Pods | Destination | Port | Why |
| --- | --- | --- | --- |
| cluster-autoscaler | kube-dns | 53 | lookups of `api.hetzner.cloud` and cluster names, through the DNS proxy |
| cluster-autoscaler | `kube-apiserver` | any | pending pods, nodes, its status ConfigMap and leader lease |
| cluster-autoscaler | `api.hetzner.cloud` | 443 | lists, creates and deletes the CI overflow servers ([ci-autoscaler](ci-autoscaler.md)) |

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

### What the evidence said on 2026-10-26

Each agent's export file, read through `kubectl exec ... cat /var/log/hubble/egress-flows*.log`, covered 35 to 55 minutes per node (00:27 UTC back to 23:33). Summarised by source workload, destination name, port and `allowed_by`:

- **flux-system:** three source-controller connections were allowed by `allow-egress` and nothing else: `kubernetes.github.io`, `aquasecurity.github.io` and `release-assets.githubusercontent.com`, as was flux-operator's event flow to notification-controller. Reading every HelmRepository index in the tree showed two more hosts the window did not catch (`kedacore.github.io`, `prometheus-community.github.io`) and the release-asset redirects of three of them. All are now named above. Every other new flux-system connection named its own policy.
- **kube-system:** every new connection in the window named its own policy (CoreDNS and the cloud controller to the host resolver, the cloud controller to `api.hetzner.cloud`). The window holds no CSI provisioning, no Hubble certificate job and no daily run.
- **Drops:** only Trivy scan jobs to Cloudflare addresses on 443 (`trivy-system`, already enforced; for the Trivy policy owner). No drops from `external-secrets-cert-controller` or `kube-state-metrics`, and their Hubble counters show none since the agents restarted at 20:40.

#### The two drops found on 2026-10-25

`external-secrets-cert-controller` (19) and `kube-state-metrics` (20) were refused egress to `remote-node`. Both policies allow only the `kube-apiserver` entity, and neither pod has any other remote-node destination. Cilium gives a control plane's address the `kube-apiserver` identity only while that API server is listed in the `default/kubernetes` EndpointSlice. All three API servers restarted at 19:23 (their pods' age, and the controller manager's lost lease at the same minute), each leaving the EndpointSlice for a moment. During that moment its address is plain `remote-node`, and Cilium enforces policy on established connections too, so the last packets of the pods' open watch connections to that API server were refused. client-go then reconnects through the Service to a ready API server. The counts (about 20 packets each) fit one closed connection per restart.

These drops are correct and harmless, so no rule widens: allowing `remote-node` on 6443 would admit every node, including the CI nodes, which run no API server. If the drops recur outside an API server restart, the export now records the address and port; a control-plane address on 6443 confirms this reading.

## Egress default deny, namespace by namespace

Every namespace except kube-system and flux-system is already egress default deny through the `default-deny` CiliumClusterwideNetworkPolicy. Those two wait:

| Namespace | What it needs before `enableDefaultDeny.egress: true` | State |
| --- | --- | --- |
| flux-system | Flux's own NetworkPolicies off (`cluster.networkPolicy: false`, which removes `allow-egress`, `allow-scraping`, `allow-webhooks`), the ingress policy above in place, and a week of export in which every flux-system connection names its own policy, including a Renovate chart bump for each HelmRepository | waits: policies complete, evidence under an hour |
| kube-system | a week of export covering a volume being created and attached (CSI controller), the Hubble certificate job, a node joining (the cloud controller) and a Cilium upgrade; a policy for every new non-host pod first (a Hubble UI from the showcase stream needs one) | waits: evidence under an hour |

### Enforcing flux-system, in three steps

1. **Named policies alongside `allow-egress`.** The egress and ingress policies above, staged. Nothing changes on the wire.
2. **Evidence.** With the export keeping only policy verdicts and drops (since the Cilium values of 2026-10-26), each node's files cover days. Over a week, long enough for every HelmRepository and OCIRepository interval (12h for the longest) and a Renovate chart bump, this query must return no row whose `allowed_by` is `allow-egress` or empty:

   ```logsql
   cluster:=unfold source:=hubble-egress source.namespace:=flux-system
     | stats by (source_workload, destination_name, destination_port, allowed_by) count()
   ```

   Until Vector ships the export, read the files on each agent: `kubectl -n kube-system exec <cilium pod> -c cilium-agent -- cat /var/log/hubble/egress-flows*.log`, and keep only records with `source.namespace` `flux-system`.
3. **Remove `allow-egress`.** One pull request sets `cluster.networkPolicy: false` on the FluxInstance and `enableDefaultDeny.egress: true` on the five flux-system policies. flux-operator garbage-collects its three NetworkPolicies (they carry no `fluxcd.controlplane.io/prune: disabled` annotation; flux-operator v0.61.0 `internal/controller/fluxinstance_controller.go`). The FluxInstance is also a Talos inline manifest, so the infra plan shows the control-plane configs updated in place; Talos applies it only at bootstrap.

### Break glass: Flux cannot fetch or apply

Symptoms: the `flux-system` GitRepository or a HelmRepository stops reconciling with a timeout or `no such host`, and the export shows `DROPPED` flows from flux-system with `denied_by` empty.

A fix merged to `main` cannot arrive while source-controller cannot reach GitHub, so it needs one hand step by the owner, with the admin kubeconfig:

1. Merge the fix (or the revert of the change that broke it) in Forgejo, so `main` already holds the corrected policy when Flux recovers.
2. Remove the default deny Flux is stuck behind, for the controller that is blocked (source-controller for fetches, kustomize-controller or helm-controller for applies):

   ```sh
   kubectl -n flux-system patch ciliumnetworkpolicy source-controller-egress --type merge -p '{"spec":{"enableDefaultDeny":{"egress":false}}}'
   ```

3. `flux reconcile source git flux-system` and `flux reconcile kustomization flux-system`. Flux fetches the fixed `main` and puts the policy back as `main` has it, overwriting the hand patch.

If the API server path itself is refused (every controller fails with `dial tcp 10.66.0.1:443: i/o timeout`), patch all five policies the same way. No Flux NetworkPolicy needs restoring by hand: with `enableDefaultDeny.egress` false and no NetworkPolicy left, nothing in flux-system is refused.

## Enforcing a staged policy

1. Let the export run for a week, so it covers the six-hourly etcd backup, the daily scrubs and a Renovate bump.
2. Every flow from the namespace must have `allowed_by` naming the namespace's own policy (first query above). A flow that does not is either added here with its reason or is a finding.
3. In one pull request per namespace, set `enableDefaultDeny.egress` to `true` (or remove the field). For flux-system, also turn off Flux's own NetworkPolicies (see above) and keep the namespace out of the `default-deny` exclusion change: its own policies already name DNS and ingress, so the clusterwide policy adds nothing but a second place to get wrong. Flux first: if Flux loses GitHub, the fix reaches the cluster only by hand (break glass above).
4. After the merge, watch for dropped flows from that namespace (second query above) and for Flux's `Ready` condition.
