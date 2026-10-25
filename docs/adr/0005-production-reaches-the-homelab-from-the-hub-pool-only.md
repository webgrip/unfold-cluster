---
status: proposed
date: 2026-10-25
---

# ADR 0005: Production reaches the homelab from the hub pool only

## Context and problem statement

After the move ([RFC 0003](../rfc/0003-moving-unfold-and-ploeg-to-production.md)), Forgejo, Vikunja, Authentik, OpenBao, Omnigraph and the observability backend stay in the homelab. This cluster reaches them through the homelab gateway, `unfold-gateway`, which joins this cluster's tailnet as `tag:homelab-gateway` and forwards named ports.

The tailnet policy today lets `tag:cp` and `tag:node` open the gateway on 8200 (OpenBao) and 8427 (metrics and log writes), and lets `tag:node` alone open 9150 (CI queue length). Every worker joins as `tag:node`: the hub, the CI node and the metal node.

The move adds:

* **Vikunja's API and Authentik's token endpoint** behind the gateway;
* **the application's tokens** under `secret/unfold-main/`;
* **Runs on the metal node** that execute untrusted code.

So a Run that escapes to its node would be one control away from those tokens: the OpenBao role's subject binding. RFC 0001 asks for two independent controls per critical boundary.

## Considered options

* Keep `tag:node` for every worker and rely on the OpenBao role's binding.
* **One tag per node role**, each allowed only the gateway ports that role needs.
* A second gateway per role in the homelab.

## Decision

Chosen option: one tag per node role.

| Tag | Nodes | May open on `tag:homelab-gateway` |
| --- | --- | --- |
| `tag:cp` | control planes | 8200, 8427 |
| `tag:hub` | the hub pool (`node.webgrip.io/pool=unfold`) | 8200, 8427, the Vikunja API port, 443 (Authentik), and the vmauth read path of RFC 0003 D7 |
| `tag:ci` | CI nodes | 8427, 9150 |
| `tag:runs` | the metal node and any later Run node | 8427 |

Each pool's worker key is minted with its own tag. Within this cluster, Cilium egress rules allow the gateway's name only from the workloads that need it:

* External Secrets and vmagent: OpenBao and writes, from the control planes and the hub;
* ploegd and the tracker-wiring Job: Vikunja;
* Unfold and ploegd: Authentik;
* KEDA: the queue-length port.

Run pods get no rule to the gateway at all.

The homelab reaches this cluster only through the public webhook endpoint, which checks HMAC. The tailnet gives the gateway no way to open a connection into this cluster.

## Consequences

* Good, because a Run escape now needs to break the tailnet policy *and* the OpenBao binding before it can read a production token. The Cilium rule in the pod network is a third control.
* Good, because the policy states what each node role does, in the file the Headscale tests already pin.
* Bad, because a node changing pools needs a new key. Pools are fixed per server today, so this costs nothing yet.
* Vector runs on the host network on every node, so every tag keeps 8427.

## Confirmation

* `infra/tests/homelab_gateway.tftest.hcl` asserts each row of the table: what each tag may open, and that it can open nothing else.
* A live probe from the metal node and from a CI pod gets a refusal on 8200, the Vikunja port and 443, and a success on 8427.
* The same probe from a hub pod gets a success on each of its ports.
