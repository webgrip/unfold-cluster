# Observability

Unfold collects its own metrics and logs and sends them to the homelab over the tailnet. The homelab stores them (VictoriaMetrics, VictoriaLogs), shows them in Grafana (folder **Unfold cluster**) and alerts on them (vmalert to the homelab Alertmanager and ntfy). This is RFC 0001 delivery step 8, with the homelab as the backend until the cluster runs its own stack.

## What runs where

| Piece | Where | What it does |
| --- | --- | --- |
| vmagent | Unfold, `observability`, Deployment | Scrapes the API servers, kubelets and cAdvisor, etcd (`:2383` on the control planes), node-exporter, kube-state-metrics, Cilium agent and operator, Hubble, CoreDNS, the Flux controllers and Vector. Adds `cluster=unfold`. Remote-writes to `http://unfold-ingest.webgrip.dev:8427/api/v1/write`. Buffers up to 1.8 GB in an emptyDir, which covers a homelab outage of many hours at this cluster's size. |
| Vector | Unfold, `observability`, DaemonSet, host network | Reads pod logs from `/var/log/pods`, Talos service logs on `127.0.0.1:6050` and kernel logs on `127.0.0.1:6051` (both JSON lines, sent by Talos `machine.logging` and `KmsgLogConfig`), and the API server audit log `/var/log/audit/kube/*.log` on the control planes. Sends them to the ingest's `/insert/jsonline` and `/audit/insert/jsonline`. Buffers 2 GiB of logs and 1 GiB of audit events per node on disk under `/var/lib/vector`. |
| node-exporter, kube-state-metrics | Unfold, `observability`, Helm charts | The usual node and object metrics. |
| Talos patches | `infra/log-shipping.tf`, `infra/metrics-ports.tf`, `infra/host-firewall.tf` | Log destinations, and host firewall rules that open the scraped ports to the pod network only. |
| unfold-ingest | homelab, `observability`, Deployment | A Tailscale container (userspace) joined to Unfold's Headscale as `tag:homelab-ingest`, forwarding tailnet port 8427 to vmauth in the same pod. vmauth accepts only the three write paths: metrics to `vmsingle-unfold`, logs to `vlsingle-victorialogs`, audit to `vlsingle-victorialogs-audit`. It stamps `cluster=unfold` on every log line, so Unfold cannot write as the homelab. |
| unfold-ingest-address | homelab, CronJob every 5 minutes | Reads the ingest's tailnet IPv4 address from its Tailscale state Secret and publishes it as the DNS record `unfold-ingest.webgrip.dev` (DNS only, a `100.64.0.0/10` address that is useless off the tailnet). |
| vmsingle-unfold, vmalert-unfold | homelab | Unfold's metrics are kept apart from the homelab's, so no homelab dashboard or rule sums the two clusters by accident. 30 days. |

The homelab code is in homelab-cluster `kubernetes/apps/observability/unfold/` and the Grafana objects in `kubernetes/apps/observability/grafana/app/` (dashboard `unfold-cluster`, datasource `unfold-prometheus`).

## Who may write

The tailnet decides. Headscale's policy lets `tag:cp` and `tag:node` reach `tag:homelab-ingest:8427` and nothing else; nobody else on the tailnet but the owner's devices (`group:admin`) reaches it. On Unfold, only the vmagent pod has a Cilium egress rule to the ingest name, and Vector runs on the host network. There is no bearer token yet: Unfold has no External Secrets to receive one without hand-made state. When External Secrets lands on Unfold, add a VMUser token minted in the homelab, push it to OpenBao, and read it on Unfold.

## Setting it up (owner, once)

Headscale's policy is written by cloud-init when the server is created and is not updated on a running server. The policy in `infra/templates/headscale-acl.hujson` therefore reaches the live server by hand once:

1. `ssh admin@headscale.webgrip.dev`, then replace `/etc/headscale/acl.hujson` with the rendered template (the `${admin_user}` and `${node_route}` values are already in the file there; add only the `tag:homelab-ingest` tag owner and the second `acls` entry).
2. `sudo headscale policy check -f /etc/headscale/acl.hujson` must print `Policy is valid`. Then `sudo systemctl restart headscale`.
3. Mint the ingest's key: `sudo headscale preauthkeys create --user "$(sudo headscale users list --name nodes -o json | jq -r '.[0].id')" --tags tag:homelab-ingest --expiration 2h -o json | jq -r .key`.
4. On the laptop, in `~/projects/webgrip/homelab-cluster`: `just secret-set unfold/tailnet-homelab-ingest authkey` and paste the key.

Within the hour External Secrets creates the key Secret, the ingest joins, and within five more minutes the DNS record exists. The key is single-use; the node keeps its identity in the `unfold-ingest-tailscale-state` Secret afterwards. A rebuilt Headscale needs steps 3 and 4 again.

## Checking it works

In Grafana (Explore, datasource **VictoriaMetrics (Unfold)**):

- `count by (job) (up{cluster="unfold"} == 1)` lists every scrape job with its number of healthy targets.
- `up{cluster="unfold"} == 0` must be empty.
- `time() - max(timestamp(up{cluster="unfold"}))` stays under a minute.
- `etcd_server_has_leader{cluster="unfold"}` returns three series of 1.
- `sum(vmagent_remotewrite_pending_data_bytes{cluster="unfold"})` stays small.

In Grafana (datasource **VictoriaLogs**):

- `cluster:=unfold | stats by (source) count()` shows `pod` and `talos`.
- `cluster:=unfold source:=talos | stats by (talos_service) count()` lists the Talos services, `kernel` included.

In Grafana (datasource **VictoriaLogs audit**): `cluster:=unfold job:=kube-audit | stats count()`.

On the homelab: `kubectl -n observability logs deploy/unfold-ingest -c tailscale` shows the login, and `kubectl -n observability get dnsendpoint unfold-ingest` shows the address.

## Alerts

vmalert-unfold evaluates `vmrule-unfold.yaml` in the homelab: no metrics from Unfold for 15 minutes, node NotReady, no API server answering, etcd without a leader or near its quota, Flux resources not Ready, kubelet, client and cert-manager certificates close to expiry, no successful etcd backup for 7 hours, and growing send buffers on vmagent or Vector. They route through the homelab Alertmanager like every other alert.

## Known limits

- The pod path to the tailnet relies on Cilium masquerading pod traffic that leaves through `tailscale0`. If `up{cluster="unfold"}` never appears while Vector's logs do arrive, that is the first suspect; running vmagent on the host network is the fallback.
- The vmagent buffer is an emptyDir: a reschedule of the pod during an outage loses what it held.
- RFC 0001 wants the cluster to alert on itself without the house. This setup does the opposite until the in-cluster stack exists; an outage of the homelab silences Unfold's alerts, and only the uptime-kuma dead-man's switch notices.
