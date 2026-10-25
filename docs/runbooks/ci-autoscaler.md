# CI autoscaler: an overflow node that exists only while CI needs it

Up to two CI jobs run on the hub worker `unfold-app-1`. When a third is Pending, the Kubernetes
cluster-autoscaler creates one CPX42 in Nuremberg for the `ci` pool, the job runs there under gVisor,
and about ten minutes after the last job the server is deleted again. The decision and its costs
are [ADR 0004](../adr/0004-ci-baseline-on-the-hub-and-autoscaled-overflow.md); the runners
themselves are [ci-runners](ci-runners.md).

## The pieces

| Piece | Where | What it does |
| --- | --- | --- |
| cluster-autoscaler | namespace `cluster-autoscaler`, Flux Kustomization `cluster-autoscaler`, on the control planes | One node group, `--nodes=0:1:cpx42:nbg1:ci`. Every 10 s it looks for Pending pods that would fit a new `ci` node; it removes a `ci` node that has been unneeded for 10 minutes. |
| Its Secret | `cluster-autoscaler/cluster-autoscaler-hcloud`, written by the infra apply | `HCLOUD_TOKEN` (the `unfold-autoscaler` token), `HCLOUD_CLUSTER_CONFIG` (the node group's Talos worker config as user data, its labels and taint, its subnet, the snapshot selector), the network, firewall and SSH key ids. |
| Its restart trigger | `flux-system/cluster-autoscaler-revision`, written by the same apply | A digest of the Secret's contents, substituted into the pod template, so a new token, snapshot or worker config restarts the autoscaler on Flux's next reconcile (10 minutes at most). |
| The node config | `infra/ci-autoscaler.tf` | The worker config of each pool in `autoscaled_worker_pools`: registry mirrors, host firewall, log shipping, labels `node.webgrip.io/pool=ci` and `runtime.webgrip.io/gvisor=true`, taint `node.webgrip.io/pool=ci:NoSchedule`, gVisor on systrap, hostname from Hetzner. No tailnet key, no disk encryption. |
| The subnet | `hcloud_network_subnet.autoscaled`, `10.64.2.0/24` | Every autoscaled server's private address. |
| The alert | homelab `HetznerAutoscaledServerRunningLong` | A server labelled `role=autoscaled-worker` older than four hours. |

To change the server type, location or the maximum, edit `autoscalingGroups` in
`kubernetes/platform/cluster-autoscaler/app/helmrelease.yaml`; Flux rolls it out. The type must be
x86 and in stock in that location; the location must be `fsn1` or `nbg1`, in the network's
`eu-central` zone.

## The token

The autoscaler has its own Hetzner token, `unfold-autoscaler` (Read & Write, project
`unfold-cluster`). To seed or rotate it, from a homelab-cluster checkout:

```sh
just hetzner-token hetzner/unfold-autoscaler HCLOUD_TOKEN_AUTOSCALER
```

The recipe checks the token against the Hetzner API before it writes OpenBao
`secret/hetzner/unfold-autoscaler`, key `HCLOUD_TOKEN_AUTOSCALER`. The `ci-unfold-cluster` OpenBao
policy (homelab `kubernetes/apps/security/openbao/bootstrap/ci-unfold-cluster.hcl`) lets the infra
workflow read it; the next apply writes it into the cluster. After a rotation, run an apply, then
delete the old token in the Hetzner Console. Until the token exists the apply writes no autoscaler
Secret and the autoscaler pod waits in `CreateContainerConfigError`; CI still runs on the hub.

Never raise the autoscaler's log level to 5 or more: at that level the provider logs every Hetzner
request with its headers, the token included.

## Its share of the Hetzner API budget

The provider lists the project's servers about once a minute (a jittered one-minute cache) and the
server types every ten minutes: about 70 requests an hour while idle, 2% of the project's 3600. A
scale-up adds the create, the network attach, the power-on and their action polls, a few dozen
requests. See [hetzner-api-budget](hetzner-api-budget.md).

## How a node leaves

The autoscaler cordons and drains the node, then deletes the server through the API. It never
deletes the Kubernetes Node: its role has no `delete` on nodes. The cloud controller's node
lifecycle controller removes the Node once Hetzner reports the server gone. A worker is not an etcd
member, so there is nothing to remove from etcd; Talos's discovery entry for the node expires on its
own. Runner pods carry `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"`, so a node with a
running job is never chosen.

## Proving it after the apply

Merge order: the homelab policy commit (done), then the unfold-cluster pull request, then an
`infra` apply with the reviewed plan digest. Then, with
`K="kubectl --kubeconfig ~/.kube/unfold.yaml"`:

1. **The pieces run on the control planes.**
   `$K -n cluster-autoscaler get pods -o wide` and `$K -n keda get pods -o wide` show every pod
   `Running` on an `unfold-cp-*` node. `$K -n cluster-autoscaler logs deploy/cluster-autoscaler-hetzner-cluster-autoscaler | grep -i 'node group'`
   names `ci` with min 0 and max 1. `$K -n ci get scaledjob forgejo-runner` shows `READY True`.
2. **The hub is a gVisor node.** `$K get node unfold-app-1 -L runtime.webgrip.io/gvisor` shows `true`.
3. **One job stays on the hub, with no scale-up.** In Forgejo, `webgrip/unfold-cluster`, Actions,
   `ci-smoke`, Run workflow on `main`, once. Within about 30 s `$K -n ci get pods -o wide` shows one
   pod on `unfold-app-1`. The run is green and its first step prints `node: unfold-app-1`, a `/proc/version`
   and `dmesg` from gVisor (`Starting gVisor...`). During and after it, `$K get nodes -l node.webgrip.io/pool=ci`
   lists nothing, and `$K -n cluster-autoscaler get configmap cluster-autoscaler-status -o yaml`
   shows the `ci` group at `ready=0` and no `ScaleUp` in progress.
4. **A third concurrent job brings the overflow node.** Run `ci-smoke` three times within a minute.
   Two pods start on `unfold-app-1`; the third is `Pending`, and `$K -n ci describe pod <it>`
   shows the event `TriggeredScaleUp` naming group `ci`. Within about five minutes
   `$K get nodes -l node.webgrip.io/pool=ci -L runtime.webgrip.io/gvisor` lists one `ci-<hex>` node,
   `Ready`, with gVisor `true`; `$K describe node <it>` shows the taint `node.webgrip.io/pool=ci:NoSchedule`,
   an `InternalIP` in `10.64.2.0/24` and a `ProviderID` of `hcloud://...`. The third pod runs there,
   and that run's log prints `node: ci-<hex>` and gVisor in `dmesg`. All three runs are green.
5. **It leaves again.** About ten minutes after the last of them, the autoscaler's log says it
   removed the node, the Node disappears from `$K get nodes`, and the Hetzner cost dashboard no
   longer lists a server with role `autoscaled-worker`. `talosctl -n 10.64.0.11 etcd members` still
   lists the three control planes and nothing else.

## When no node comes

| Symptom | Look at |
| --- | --- |
| Autoscaler pod `CreateContainerConfigError` | Its Secret is missing: the token is not seeded, or the apply that writes it has not run. `$K -n cluster-autoscaler get secret cluster-autoscaler-hcloud`. |
| Autoscaler crash-loops at start | Its log. `subnet ip range ... is not part of network` means the apply that creates `10.64.2.0/24` has not run; `failed to get ssh key` or `network` means a wrong id or a token from another project. |
| Third pod Pending, event `NotTriggerScaleUp` | The event names the predicate. A pod that selects or requires something the `ci` template lacks (another node label, more than a CPX42 holds) never scales up. |
| Server created, never becomes a node | The server's console in Hetzner shows Talos; usually the private network (the API at `10.64.0.10`) or the user data. The autoscaler deletes it after `max-node-provision-time` (15 minutes) and retries with backoff. |
| `rate_limit_exceeded` in its log | The project's budget is empty; see [hetzner-api-budget](hetzner-api-budget.md). The quote of the token is redacted only in diagnose reports, so rotate the autoscaler token if its log left the cluster. |

## A CI node that will not go away

The homelab alert `HetznerAutoscaledServerRunningLong` fires when an autoscaled server is older than
four hours. A CI job lasts at most 90 minutes, so that is a queue that never drains or a server
nobody owns.

1. `$K -n ci get jobs,pods -o wide`: jobs still running on the node keep it, by design.
2. `$K -n cluster-autoscaler logs deploy/cluster-autoscaler-hetzner-cluster-autoscaler | grep -i 'scale.down\|unneeded\|removing'`
   says why the node is still needed.
3. A Hetzner server labelled `role=autoscaled-worker` with no Node is an orphan, left when the
   autoscaler was down during a create. Starting the autoscaler again deletes it after
   `max-node-provision-time`. If the autoscaler cannot run, delete the server in the Hetzner Console
   (project `unfold-cluster`, Servers): it is the one place a person deletes a server by hand, and
   only one labelled `hcloud/node-group=ci`.
