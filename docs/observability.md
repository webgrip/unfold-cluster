# Observability and the homelab gateway

Unfold collects its own metrics and logs and sends them to the homelab over the tailnet. The homelab stores them (VictoriaMetrics, VictoriaLogs), shows them in Grafana (folder **Unfold cluster**) and alerts on them (vmalert to the homelab Alertmanager and ntfy). This is RFC 0001 delivery step 8, with the homelab as the backend until the cluster runs its own stack. The same homelab gateway also carries External Secrets' reads of the homelab OpenBao ([external-secrets](runbooks/external-secrets.md)).

## What runs where

| Piece | Where | What it does |
| --- | --- | --- |
| vmagent | Unfold, `observability`, Deployment | Scrapes the API servers, kubelets and cAdvisor, etcd (`:2383` on the control planes), node-exporter, kube-state-metrics, Cilium agent and operator, Hubble, CoreDNS, the Flux controllers and Vector. Adds `cluster=unfold`. Remote-writes to `http://unfold-gateway.webgrip.dev:8427/api/v1/write`. Buffers up to 1.8 GB in an emptyDir, which covers a homelab outage of many hours at this cluster's size. |
| Vector | Unfold, `observability`, DaemonSet, host network | Reads pod logs from `/var/log/pods`, Talos service logs on `127.0.0.1:6050` and kernel logs on `127.0.0.1:6051` (JSON lines from Talos `machine.logging` and `KmsgLogConfig`), the API server audit log `/var/log/audit/kube/*.log` on the control planes, and Hubble's egress flow log `/var/log/hubble/egress-flows.log` ([egress by name](runbooks/egress-by-name.md#flow-evidence)). Sends them to the gateway's `/insert/jsonline` and `/audit/insert/jsonline`. Buffers 2 GiB of logs and 1 GiB of audit events per node under `/var/lib/vector`. |
| node-exporter, kube-state-metrics | Unfold, `observability`, Helm charts | The usual node and object metrics. |
| Talos patches | `infra/log-shipping.tf`, `infra/metrics-ports.tf`, `infra/host-firewall.tf` | Log destinations, and host firewall rules that open the scraped ports to the pod network only. |
| unfold-gateway | homelab, `observability`, Deployment | Tailscale (userspace) joined to Unfold's Headscale as `tag:homelab-gateway`. Tailnet port 8427 goes to vmauth in the same pod, which accepts only the three write paths (metrics to `vmsingle-unfold`, logs to `vlsingle-victorialogs`, audit to `vlsingle-victorialogs-audit`) and stamps `cluster=unfold` on every log line. Tailnet port 8200 goes to the homelab OpenBao. Tailnet port 9150 goes to the homelab's `forgejo-runner-queue`, which answers only `GET /waiting-jobs/unfold-ci` with the number of waiting `unfold-ci` jobs ([ci-runners](runbooks/ci-runners.md)). |
| unfold-gateway-address | homelab, CronJob every 5 minutes | Reads the gateway's tailnet IPv4 address from its Tailscale state Secret and publishes it as `unfold-gateway.webgrip.dev` (DNS only; a `100.64.0.0/10` address, useless off the tailnet). |
| vmsingle-unfold, vmalert-unfold | homelab | Unfold's metrics, kept apart from the homelab's so no homelab dashboard or rule sums the two clusters. 30 days. |

## Who may connect

The tailnet decides. Headscale's policy (`infra/templates/headscale-acl.hujson`) lets every node role open `tag:homelab-gateway` on 8427 (Vector ships each node's logs from its host network), and `tag:cp` alone on 8200 and 9150 (External Secrets and KEDA run only on the control planes), and nothing else ([node roles](runbooks/infra-workflow.md#node-roles-on-the-tailnet)); besides them only the devices people register (`autogroup:member`) reach those ports, and only the Headscale server (`tag:headscale`) reaches 443, Authentik's way in ([browser login](runbooks/headscale-browser-login.md)). On Unfold, only the vmagent, External Secrets and KEDA operator pods have a Cilium egress rule to the gateway name, and Vector runs on the host network. Metrics and logs carry no bearer token yet; External Secrets now exists on Unfold, so a vmauth token minted in the homelab can follow.

## How the policy and the key get there, with nobody typing them

Everything below is a pull request and the `infra` apply.

1. **The program on the Headscale server.** OpenTofu reaches `unfold-headscale` only as the `tofu` user, whose SSH key may run `/usr/local/sbin/unfold-tailnet-key` and nothing else. That program (`infra/templates/unfold-tailnet-key.sh`) mints the node keys, sets the policy (`policy set`: checks it against the running Headscale, installs it, restarts Headscale, and puts the previous policy back if Headscale does not come up) and replaces itself (`install`, after a syntax check). The apply pushes it whenever the file changes (`terraform_data.tailnet_key_tool`), then the policy whenever the policy changes (`terraform_data.headscale_policy`). cloud-init installs the same program, sudoers rule and policy on a new server.
2. **The gateway's key.** The apply asks the program for a single-use `tag:homelab-gateway` key for generation `homelab_gateway_key_generation` (`infra/variables.tf`); asking again for the same generation returns the same key. The next workflow step writes it to OpenBao `secret/unfold/tailnet-homelab-gateway` (`scripts/openbao-kv.sh put authkey`, only when it changed), the homelab's External Secrets hands it to the gateway, and the gateway logs in once and keeps its identity in its own state Secret. A new key is a pull request that raises the generation. A replaced Headscale mints a new gateway key in the same apply; the gateway's old identity is then refused, its `tailscale` container falls back to `NeedsLogin` and logs in with the key it was handed (`TS_AUTH_ONCE`), so nobody deletes its state Secret ([reproducibility](reproducibility.md#headscale-survives-a-rebuild)).

`scripts/test-tailnet-key-tool.sh` (run by `infra-check`) tests the program against a stubbed Headscale; `infra/tests/homelab_gateway.tftest.hcl` pins the policy, the sudoers rule, and that the server and the apply install the same things.

### The server that existed before this

The `unfold-headscale` created on 2026-10-25 ran the first version of the program, without the `install`, `policy` and `gateway` modes, and its sudoers rule named only the old modes, so the `tofu` key could not upgrade it. Instead of a one-time command on the server, `headscale_generation` 3 replaces it through the apply: the apply lifts its delete protection, the new server starts from the current cloud-init, and every node and the gateway log in again with keys minted by the new server in the same run ([reproducibility](reproducibility.md#the-live-headscale-server)).

## Checking it works

In Grafana (Explore, datasource **VictoriaMetrics (Unfold)**):

- `count by (job) (up{cluster="unfold"} == 1)` lists every scrape job with its number of healthy targets; `up{cluster="unfold"} == 0` must be empty.
- `time() - max(timestamp(up{cluster="unfold"}))` stays under a minute.
- `etcd_server_has_leader{cluster="unfold"}` returns three series of 1.

In Grafana (datasource **VictoriaLogs**): `cluster:=unfold | stats by (source) count()` shows `pod` and `talos`. In **VictoriaLogs audit**: `cluster:=unfold job:=kube-audit | stats count()`.

On Unfold: `kubectl get clustersecretstore openbao-homelab` shows `Ready`.

## Alerts

vmalert-unfold evaluates `vmrule-unfold.yaml` in the homelab: Unfold stopped sending (only once it has sent in the last 7 days, so an unfinished setup does not page), node NotReady, no API server answering, etcd without a leader or near its quota, Flux resources not Ready, kubelet, client and cert-manager certificates close to expiry, no successful etcd backup for 7 hours, and growing send buffers.

## Known limits

- The pod path to the tailnet relies on Cilium masquerading pod traffic that leaves through `tailscale0`. If `up{cluster="unfold"}` never appears while Vector's logs arrive, that is the first suspect; running vmagent on the host network is the fallback. External Secrets takes the same path.
- The vmagent buffer is an emptyDir: a reschedule during an outage loses what it held.
- RFC 0001 wants the cluster to alert on itself without the house. Until the in-cluster stack exists, an outage of the homelab silences Unfold's alerts; only the uptime-kuma dead-man's switch notices.
