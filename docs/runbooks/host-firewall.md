# Talos host firewall

Every node runs Talos's ingress firewall: `NetworkDefaultActionConfig` with `ingress: block`, plus one `NetworkRuleConfig` per port that something outside the node must reach. The rules live in [infra/host-firewall.tf](../../infra/host-firewall.tf), and [infra/tests/host_firewall.tftest.hcl](../../infra/tests/host_firewall.tftest.hcl) pins them. The Hetzner Cloud Firewall in front stays as it is. It covers the public addresses only, and Talos covers every interface, the private network and the tailnet included.

## What is open

| Rule | Port | Nodes | Sources | Who connects |
| --- | --- | --- | --- | --- |
| `apid-ingress` | 50000/tcp | all | ADMIN_CIDRS, tailnet `100.64.0.0/10` and `fd7a:115c:a1e0::/48`, private network `10.64.0.0/16`; control planes also the pod network `10.65.0.0/16` | OpenTofu and the diagnose run (public address, from ADMIN_CIDRS), the owner over the tailnet, the etcd backup Job through the `talos` Service |
| `kube-apiserver-ingress` | 6443/tcp | control planes | the same as apid on a control plane | kubelets and KubePrism on every node, pods through the `kubernetes` Service, the owner over the tailnet, the diagnose run |
| `trustd-ingress` | 50001/tcp | control planes | private network | nodes fetching their certificates |
| `etcd-ingress` | 2379-2380/tcp | control planes | the three control planes' private addresses, `/32` each | etcd peers |
| `kubelet-ingress` | 10250/tcp | all | private network, pod network | the API server (logs, exec), later metrics-server |
| `cilium-vxlan-ingress` | 8472/udp | all | private network | Cilium's tunnel |
| `cilium-wireguard-ingress` | 51871/udp | all | private network | Cilium's pod-traffic encryption |
| `cilium-health-ingress` | 4240/tcp | all | private network | Cilium's node-to-node health probes |
| `hubble-peer-ingress` | 4244/tcp | all | private network, pod network | Hubble Relay |
| `node-metrics-ingress` | 9100, 9598, 9962-9963, 9965/tcp | all | pod network | vmagent in `observability` scraping node-exporter, Vector, the Cilium agent and operator, and Hubble ([observability](../observability.md)) |
| `etcd-metrics-ingress` | 2383/tcp | control planes | pod network | vmagent scraping etcd |

Talos accepts some traffic without a rule. In `block` mode it accepts:

- everything on `lo`, so KubePrism on `localhost:7445` and every `127.0.0.1` listener are fine;
- established and related connections;
- ICMP, at most 5 packets a second;
- traffic between the pod and Service networks;
- DNS from pods to the host resolver at `169.254.116.108`.

Every other new TCP or UDP connection to a node address is dropped, in the input chain and, for addresses of the node, already in prerouting.

## Proof against what listens

The rule set was checked on 2026-10-25 against the sockets listening on `unfold-cp-1` and `unfold-app-1`, read with `ss -ltnu` in the host network namespace of the Cilium agent (read-only). Every listener reachable from another machine is either in the table above or deliberately closed:

| Listener | Status |
| --- | --- |
| `*:10256` | kube-proxy's health port. kube-proxy is being removed. |
| `0.0.0.0:9964` | Cilium Envoy metrics. Nothing scrapes them, so the port stays closed. |
| Tailscale's UDP port | Random per start (58946, 56962 and 39830 that day), so no rule can name it. Direct paths form through NAT traversal: both peers send first, and the replies count as established. When that fails, traffic goes through the DERP relay over outbound TCP 443. |
| Everything else | Bound to `127.0.0.1`, `127.0.0.53` or the tailnet address as a client socket. |

## What the firewall does not cover

- **NodePorts and HostPorts.** Cilium's kube-proxy replacement answers them in BPF on the interface, before netfilter, so Talos's rules never see those packets. Cilium binds NodePorts on `eth0` (public), `eth1` and `tailscale0`. The Hetzner Cloud Firewall keeps them off the internet; a Service of type NodePort must still be treated as reachable from the private network and the tailnet.
- **Pod-to-pod traffic.** Cilium network policy covers it (default deny outside `kube-system` and `flux-system`).
- **Cilium's host firewall** stays off, so the two never fight over the same packets (RFC 0001).

## Lock-out risk and the way back

A wrong rule on 50000 would cut OpenTofu off from the nodes, and Talos has no shell to recover from. The design keeps two independent ways in:

1. **ADMIN_CIDRS on the public address.** apid and the API server take exactly the list the Hetzner Cloud Firewall already uses for the same two ports. A runner that reaches the nodes through the Hetzner firewall today reaches them through Talos's too, because nothing translates the source address between the two. The test fails if any ADMIN_CIDRS entry is missing from either rule.
2. **The tailnet.** The owner's devices reach every node's apid and the control planes' API server over Headscale, whatever ADMIN_CIDRS says. The test fails if the tailnet prefixes differ from the ones Headscale hands out.

Applying the rules changes no listener and needs no reboot. Talos rewrites its `talos` nftables table in place. Connections already open survive as established.

**After the apply**, run the `infra` workflow with `diagnose`. Every node must answer `talosctl version` and list its `nftableschains`, and `kubectl get nodes` must answer through 6443. If a node does not answer:

1. **The public path is broken but the tailnet works.** From a device on the tailnet, with the talosconfig from `tofu output -raw talosconfig`, check the rules with `talosctl -n <node tailnet IP> get nftableschains -o yaml`. Then fix ADMIN_CIDRS (it lives in OpenBao `secret/unfold-cluster/vars` and reaches the runners within the hour) and apply again.
2. **The rules themselves are wrong.** Set `host_firewall_enabled = false` in `infra/variables.tf` and merge. The next apply removes every firewall document, and Talos returns to accept-all in place, with no reboot. The `infra` workflow applies it if the public path answers. If only the tailnet answers, the owner pushes the same rendered machine config to the node from a tailnet device with talosctl's apply-config in no-reboot mode.
3. **Neither path answers.** This needs the tailnet and ADMIN_CIDRS to fail at the same time. The Hetzner console shows the node's Talos dashboard but takes no commands. Recovery is a rebuild of that node from the snapshot. That is a deliberate change, because servers carry delete protection and `prevent_destroy`. On a control plane, etcd keeps quorum with the other two in the meantime.
