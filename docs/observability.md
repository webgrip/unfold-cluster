# Observability

Unfold collects, stores and alerts on its own metrics and logs, in the `observability` namespace,
and keeps doing so when the homelab is down ([ADR 0016](adr/0016-unfold-observes-itself.md)). The
homelab's Grafana reads Unfold's stores through one read-only endpoint. Firefighting is in the
[observability runbook](runbooks/observability.md).

## What runs where

| Piece | Kind | What it does |
| --- | --- | --- |
| `alloy-metrics` | Deployment | Scrapes the API servers, kubelets and cAdvisor, etcd (`:2383` on the control planes), node-exporter, kube-state-metrics, the Cilium agent, operator and Hubble, CoreDNS, the Flux controllers, KEDA, the cluster-autoscaler, cert-manager, Tetragon (`:2112` on each node), the Trivy operator and its report shipper, the Kyverno controllers and every observability pod (`alloy/metrics/metrics.alloy`). Adds `cluster=unfold` and writes to `vmsingle`. |
| `alloy-logs` | DaemonSet, host network | Reads pod logs from `/var/log/pods`, the Talos service and kernel logs that Talos sends as JSON lines to `127.0.0.1:6050` and `:6051` (`infra/log-shipping.tf`), the API audit log `/var/log/audit/kube/*.log` on the control planes, Hubble's egress flow log and Tetragon's export file (`alloy/logs/`). Writes the audit log to `vlsingle-audit` and everything else to `vlsingle-logs`. |
| `vmsingle` | StatefulSet, 20 GiB `hcloud-luks` | VictoriaMetrics, 30 days. |
| `vlsingle-logs` | StatefulSet, 15 GiB `hcloud-luks` | VictoriaLogs, 14 days, capped at 13 GiB. |
| `vlsingle-audit` | StatefulSet, 10 GiB `hcloud-luks` | VictoriaLogs for the API audit log, 90 days, capped at 8 GiB. |
| `vmalert-metrics`, `vmalert-logs`, `vmalert-audit` | Deployments | Evaluate `alerting/rules/cluster.yaml` and `supply-chain.yaml` (PromQL), `runtime.yaml` (LogsQL on Tetragon events) and `audit.yaml` (LogsQL on the audit log); write alert state to `vmsingle`. |
| `alertmanager` | Deployment | Routes `critical` and `warning` to ntfy and the always-firing `Watchdog` to the dead-man's switch ([alerts](#alerts)). |
| `grafana-operator`, `grafana` | HelmRelease, Grafana CR | `https://grafana.ops.unfoldhq.dev` on the tailnet, sign-in through Authentik with a passkey ([Grafana](#grafana)). |
| `vmauth-query` | Deployment | `https://query.ops.unfoldhq.dev`: the homelab Grafana's read-only way in ([the homelab reads](#the-homelab-reads)). |
| `trivy-report-shipper` | `trivy-system`, Vector | Writes one record per Trivy report to `vlsingle-logs` ([vulnerability scanning](runbooks/vulnerability-scanning.md)). |
| kube-state-metrics, node-exporter | Helm charts | The usual object and node metrics. |

Every central piece prefers the `system` pool and falls back to the hub (`node.webgrip.io/pool`
`system`, then `unfold`; `app/placement.yaml`), as [ADR 0013](adr/0013-control-planes-stay-small-and-a-system-pool-carries-the-platform.md)
decides; #106 declares that pool with `node_count = 0`.

### Fields

Log records keep the field names the homelab used, so queries and rules carry over:

| `source` | Fields besides `cluster`, `node` and the message |
| --- | --- |
| `pod` | `namespace`, `pod`, `container`, `app`, `stream` |
| `talos` | `talos_service` (`kernel` for the kernel stream), `level` |
| `hubble-egress` | the flow itself (`verdict`, `IP.destination`, `source.namespace`, ...), `source_namespace`, `source_workload`, `destination_name`, `destination_port`, `allowed_by`, `denied_by` |
| `tetragon` | the event itself (`process_exec.process.binary`, ...), `event`, `namespace`, `pod`, `container`, `workload`, `workload_kind`, `image`, `isolation_class`, `binary`, `arguments`, `uid`, `in_init_tree`, `parent_binary`, `privileges_changed`, `policy`, `function`, `action`, `path`, `daddr`, `dport`, `string_args` |
| `trivy` | see [vulnerability scanning](runbooks/vulnerability-scanning.md) |

The audit store holds the audit events as they are (`user.username`, `verb`, `objectRef.*`, ...),
with `job=kube-audit` and the request URI as the message. Routine reads by `system:` users and
status writes are dropped on the node.

## Storage and what it costs

| Store | Volume | Retention | Expected use |
| --- | --- | --- | --- |
| `vmsingle` | 20 GiB (22 GB billed) | 30 days | 60 to 100 thousand active series every 30 s at about 1 byte a sample: 5 to 8 GB at 30 days. The homelab, at 816 thousand series, holds 16 GiB at 15 days. |
| `vlsingle-logs` | 15 GiB (17 GB billed) | 14 days, 13 GiB cap | A quarter of the homelab's 112 KB/s of ingest, about 0.1 GiB a day after compression: under 2 GiB, with room for a noisy week of Tetragon or Hubble. |
| `vlsingle-audit` | 10 GiB (11 GB billed) | 90 days, 8 GiB cap | The filtered audit log, a few KB/s: 1 to 2 GiB at 90 days. 10 GB is the smallest volume Hetzner sells. |

50 GB at €0.044 per GB: **€2.20 a month** (€2.66 with VAT). The `system` node, when the owner
raises its count, is a CPX32 at €35.99 a month ([ADR 0013](adr/0013-control-planes-stay-small-and-a-system-pool-carries-the-platform.md)).
`UnfoldObservabilityVolumeFilling` fires at 85%; `hcloud-luks` grows online.

## Alerts

| Rules | Evaluated by | Against |
| --- | --- | --- |
| `alerting/rules/cluster.yaml`: delivery (Watchdog, metrics, logs, remote write, volumes, notifications), platform (nodes, API servers, etcd, Flux, certificates, etcd backups, Tetragon), the CI autoscaler | `vmalert-metrics` | `vmsingle` |
| `alerting/rules/supply-chain.yaml`: vulnerabilities, secrets in images, the scanner, unsigned webgrip images, the signature webhook | `vmalert-metrics` | `vmsingle` |
| `alerting/rules/runtime.yaml`: the 14 Tetragon detections ([runtime security](runbooks/runtime-security.md#the-alerts)) | `vmalert-logs` | `vlsingle-logs` |
| `alerting/rules/audit.yaml`: the break-glass certificate ([kubernetes login](runbooks/kubernetes-login.md#break-glass)) | `vmalert-audit` | `vlsingle-audit` |

Alertmanager (`alerting/alertmanager.yml`):

* `severity=critical` goes to `https://ntfy.webgrip.dev/alerts-critical` (urgent), `warning` to
  `alerts-warning`, with the write-only token in the Secret `alertmanager-ntfy` (OpenBao
  `secret/unfold-main/alertmanager/ntfy`, `token`, copied there from the homelab's own token by the
  homelab). These are the topics the phone already reads.
* `Watchdog`, always firing, goes every two minutes to the uptime-kuma push URL in
  `alertmanager-deadman` (OpenBao `secret/unfold-main/alertmanager/deadman`, `ping_url`). uptime-kuma
  runs on the off-site box, outside both clusters, and pages when the beat stops.
* The homelab watches the same `Watchdog` from its side: its blackbox exporter reads
  `ALERTS{alertname="Watchdog"}` through the query endpoint and fires `UnfoldAlertingSilent`.

The ntfy hop still runs in the homelab. With the homelab down, alerts fire and show in Grafana but
do not reach the phone; only the dead-man's switch stays independent. An ntfy on the off-site box
(RFC 0001 delivery step 8) removes that dependency: change the two URLs and the token's OpenBao path.

## Grafana

* `https://grafana.ops.unfoldhq.dev`, through the ops Gateway, on the tailnet only ([ops consoles](runbooks/ops-consoles.md)).
* Sign-in: Authentik client `unfold-grafana` (homelab access plane), confidential, passkey required.
  `unfold-admins` become Admin, `unfold-viewers` Viewer, anyone else is refused. Grafana's server
  calls to Authentik go through `ops-auth/authentik-relay` (`HTTPS_PROXY`); the client secret comes
  from OpenBao `secret/unfold-main/grafana/oidc`.
* Break-glass when Authentik is unreachable: the operator's generated admin login in the Secret
  `grafana-admin-credentials`; reading it needs cluster access.
* Data sources, UID and name alike: `unfold-prometheus`, `victorialogs`, `victorialogs-audit`,
  `alertmanager`. The VictoriaLogs plugin (`victoriametrics-logs-datasource` 0.33.1) is downloaded
  from grafana.com at start.
* Dashboards in folder `unfold`, as GrafanaDashboard CRs: `grafana/dashboards/` (Unfold cluster and
  supply chain, moved from the homelab; the two spend panels stay on the homelab's **Unfold cloud
  costs** dashboard) and `kubernetes/platform/ops-consoles/dashboards/`.

## The homelab reads

```
homelab Grafana ── unfold-query.observability:8481 (vmauth in the homelab gateway pod, adds the bearer token)
  ── HTTPS_PROXY: the gateway's Tailscale outbound proxy, tag:homelab-gateway
  ── tailnet, policy: tag:homelab-gateway → 10.64.0.10:443 only
  ── ops Gateway, query.ops.unfoldhq.dev ── vmauth-query (one bearer token, read paths only)
       ├── /api/v1/query, query_range, series, labels, label values, metadata ── vmsingle
       └── /select/logsql/... ── vlsingle-logs
```

The token is generated in the homelab and pushed to OpenBao `secret/unfold-main/observability/query-token`;
Unfold's External Secrets hands it to `vmauth-query`. The audit store cannot be reached this way.

## While the homelab copy still exists

This change also writes every sample and log line to the homelab gateway's 8427, so the homelab's
`vmalert-unfold` and `vmalert-unfold-runtime` keep working until this stack has proven itself. An
Unfold alert pages twice in that time. Retiring the copy is a follow-up pull request here (the
`homelab_*` sinks, the second remote-write endpoint and the tailnet's 8427 rules) and the prepared
homelab change on its branch `hl-unfold-obs-removal`.

## Tests

* `scripts/test-observability-logs.sh --mutation-test`: the real Alloy pipeline and real
  VictoriaLogs servers; every fixture in `tests/observability/fixtures` checked field by field
  (`tests/observability/expectations.json`), every LogsQL rule fired at its fixture, every pipeline
  and rule mutation caught.
* `scripts/test-observability-metrics.sh --mutation-test`: `vmalert-tool` unit tests for every
  PromQL rule (`tests/observability/rules`), a firing and a quiet case each, and each alert replaced
  by a never-firing and an always-firing expression; `vmalert -dryRun`, `amtool` and `vmauth -dryRun`
  on the configurations; the scrape relabelling on `tests/observability/pod-targets.json`; the
  Grafana image pinned alike in its three places.
* `scripts/test-admission-policies.sh`: every observability pod and volume claim
  (`tests/admission-policies/*/admitted-observability.yaml`) admitted under Deny.

## The homelab gateway

The homelab gateway (`tag:homelab-gateway`) also carries External Secrets' reads of the homelab
OpenBao (8200, [external-secrets](runbooks/external-secrets.md)), KEDA's CI job count (9150) and
Authentik for Headscale and `authentik-relay` (443).

### Who may connect

The tailnet decides. Headscale's policy (`infra/templates/headscale-acl.hujson`) lets every node role open `tag:homelab-gateway` on 8427 (alloy-logs ships a copy of each node's logs from its host network until the homelab copy is retired), `tag:cp` alone on 8200 and 9150 (External Secrets and KEDA run only on the control planes), `tag:headscale` and `tag:hub` on 443 (Headscale's browser login and `authentik-relay`), and `tag:homelab-gateway` itself only `10.64.0.10:443`, the ops Gateway ([node roles](runbooks/infra-workflow.md#node-roles-on-the-tailnet)); besides them only the devices people register (`autogroup:member`) reach those ports ([browser login](runbooks/headscale-browser-login.md)). On Unfold, only alloy-metrics, External Secrets, the KEDA operator and `authentik-relay` have a Cilium egress rule to the gateway name, and alloy-logs runs on the host network. The 8427 copy carries no bearer token; it goes away with the homelab copy.

### How the policy and the key get there, with nobody typing them

Everything below is a pull request and the `infra` apply.

1. **The program on the Headscale server.** OpenTofu reaches `unfold-headscale` only as the `tofu` user, whose SSH key may run `/usr/local/sbin/unfold-tailnet-key` and nothing else. That program (`infra/templates/unfold-tailnet-key.sh`) mints the node keys, sets the policy (`policy set`: checks it against the running Headscale, installs it, restarts Headscale, and puts the previous policy back if Headscale does not come up) and replaces itself (`install`, after a syntax check). The apply pushes it whenever the file changes (`terraform_data.tailnet_key_tool`), then the policy whenever the policy changes (`terraform_data.headscale_policy`). cloud-init installs the same program, sudoers rule and policy on a new server.
2. **The gateway's key.** The apply asks the program for a single-use `tag:homelab-gateway` key for generation `homelab_gateway_key_generation` (`infra/variables.tf`); asking again for the same generation returns the same key. The next workflow step writes it to OpenBao `secret/unfold/tailnet-homelab-gateway` (`scripts/openbao-kv.sh put authkey`, only when it changed), the homelab's External Secrets hands it to the gateway, and the gateway logs in once and keeps its identity in its own state Secret. A new key is a pull request that raises the generation. A replaced Headscale mints a new gateway key in the same apply; the gateway's old identity is then refused, its `tailscale` container falls back to `NeedsLogin` and logs in with the key it was handed (`TS_AUTH_ONCE`), so nobody deletes its state Secret ([reproducibility](reproducibility.md#headscale-survives-a-rebuild)).

`scripts/test-tailnet-key-tool.sh` (run by `infra-check`) tests the program against a stubbed Headscale; `infra/tests/homelab_gateway.tftest.hcl` pins the policy, the sudoers rule, and that the server and the apply install the same things.

### The server that existed before this

The `unfold-headscale` created on 2026-10-25 ran the first version of the program, without the `install`, `policy` and `gateway` modes, and its sudoers rule named only the old modes, so the `tofu` key could not upgrade it. Instead of a one-time command on the server, `headscale_generation` 3 replaces it through the apply: the apply lifts its delete protection, the new server starts from the current cloud-init, and every node and the gateway log in again with keys minted by the new server in the same run ([reproducibility](reproducibility.md#the-live-headscale-server)).

