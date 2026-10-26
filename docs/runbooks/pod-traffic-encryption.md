# Pod traffic encryption

Cilium encrypts pod traffic between nodes with WireGuard (`encryption.type: wireguard` in [the Cilium values](../../kubernetes/platform/cilium/values.yaml)). Strict mode turns "encrypted when Cilium knows the peer" into "dropped unless encrypted". RFC 0001 section 3 (encryption in transit).

## What strict mode enforces

| Setting | Effect |
| --- | --- |
| `strictMode.egress` with `cidr: 10.65.0.0/16` | A packet from the pod CIDR to the pod CIDR that would leave the node unencrypted is dropped (`UNENCRYPTED_TRAFFIC`). |
| `strictMode.egress.allowRemoteNodeIdentities: true` | Required in tunnel mode. A pod may still reach a node address unencrypted (the API server on 6443, the Hubble server on 4244, the kubelet). |
| `strictMode.ingress` | A VXLAN packet that did not come out of `cilium_wg0`, or a packet from a cluster pod address arriving on a NIC for a local pod, is dropped. |

Packets between pods on the same node are never encrypted and are not affected.

## Why nothing legitimate is dropped

Checked against the live cluster on 2026-10-26 (`cilium-dbg status` and `cilium-dbg encrypt status` on every agent) and the Cilium 1.20.4 datapath source (`bpf/lib/wireguard.h`, `bpf/lib/encrypt.h`, `bpf/bpf_overlay.c`, `bpf/bpf_host.c`):

| Path | Why it passes |
| --- | --- |
| Pod to pod on another node | Tunnel mode sends every VXLAN packet through `cilium_wg0`, whatever its source, so it arrives marked as decrypted. Every agent has 3 peers, one per other node. |
| Node or host-network pod (Vector, Tetragon, node-exporter, the kubelet, the API server calling a webhook) to a pod on another node | Its packets are VXLAN-encapsulated too, so they ride the same WireGuard tunnel. |
| Host-network pod to another node | Source and destination are node addresses, outside `10.65.0.0/16`, and node identities are exempt from both directions. |
| Pod to the API server (Service `10.66.0.1`, KubePrism `localhost:7445` on the host, VIP `10.64.0.10`) | The destination is a node address, not the pod CIDR. |
| The tailnet (`tailscale0`) and the homelab | The control planes advertise `10.64.0.0/24` only, never the pod CIDR, so no pod address arrives over it. Cilium manages `eth0`, `eth1` and `tailscale0`, so no interface bypasses the ingress check. |
| Zot through its NodePort, pulled by containerd on any node | The packet reaches a node address first; the socket load balancer or the NodePort translation then sends it through the tunnel. |
| Hetzner private network (`10.64.0.0/16`, both subnets) | It only carries the encrypted tunnel (UDP 51871) and node traffic. |
| A new CI node joining in `10.64.2.0/24` | Until its WireGuard key reaches the other agents, the kernel has no peer for it and drops tunnel packets to it, with or without strict mode. The host firewall already admits 8472 and 51871 from `10.64.0.0/16`. |

Not covered by strict mode: IPv6 (the cluster has no IPv6 pod CIDR) and node-to-node traffic, which stays outside WireGuard because `nodeEncryption` is off. RFC 0001 asks for node encryption as well; that is a separate change.

## Rollout

`rollOutCiliumPods: true` puts a checksum of `cilium-config` on the agent pods, so a value change restarts them; without it a new setting waits for the next unrelated restart. `updateStrategy.rollingUpdate.maxUnavailable: 1` restarts one agent at a time (the chart default is two).

While an agent restarts, existing pod connections on that node keep their datapath, new pods on that node wait for the agent, and the Cilium DNS proxy on that node is briefly unavailable, so `toFQDNs` lookups there can fail for a few seconds. Expect one short blip per node, four nodes in sequence.

Talos seeds Cilium from the same values file (`infra/bootstrap-manifests.tf`), so this change also updates the control-plane machine configs in place. Talos applies inline manifests only at bootstrap; Flux's HelmRelease performs the actual change.

## Checking it

```sh
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg encrypt status
kubectl -n kube-system get cm cilium-config -o yaml | grep strict
kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe --drop-reason-desc UNENCRYPTED_TRAFFIC --last 100
```

A drop with reason `UNENCRYPTED_TRAFFIC` is also written to the flow export ([egress by name](egress-by-name.md)), which keeps every drop.

## Rolling back

Set `strictMode.egress.enabled` and `strictMode.ingress.enabled` to `false` in a pull request. The agents roll again one at a time.
