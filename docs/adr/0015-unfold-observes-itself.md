---
status: proposed
date: 2026-10-26
---

# ADR 0015: Unfold observes itself: Alloy collects, VictoriaMetrics and VictoriaLogs store, vmalert and Alertmanager page, Grafana shows, and the homelab only reads

## Context and problem statement

Until now Unfold shipped every metric and log over the tailnet to the homelab (#61): vmagent and
Vector wrote to `unfold-gateway` port 8427, the homelab stored them in `vmsingle-unfold` and its
VictoriaLogs, and the homelab's `vmalert-unfold` and `vmalert-unfold-runtime` evaluated Unfold's
alerts and paged through the homelab's Alertmanager. #88 and #89 added Trivy and Tetragon records
to the same path. When the homelab is down, Unfold is blind and silent.

The owner decided on 2026-10-26: "I want observability to have its own thing. And then we'll
consume that grafana from that on our homelab grafana. So alloy etc." RFC 0001 section 10 says the
same: "the cluster watches itself; nothing about production alerting passes through the house".
This record decides how: the collector, the stores, the alerting path and where it pages, Grafana,
how the homelab reads, and how the old path is retired without a gap.

ADR 0013 (proposed) already decides *where* the stack runs: on a `system` node, which this change
builds behind `node_count = 0`.

## Facts the decision rests on

Checked on 2026-10-26.

* **The homelab runs the same software.** VictoriaMetrics (homelab ADR-0034) and VictoriaLogs
  (homelab ADR-0041), fed by Grafana Alloy through `loki.write`, with the Grafana Operator.
* **Alloy can do what Vector did, except one thing.** Alloy 1.21.2 has `loki.source.file` with
  CRI parsing for pod logs, `otelcol.receiver.tcplog` (experimental) for the JSON lines Talos sends
  to `127.0.0.1:6050` and `:6051`, `loki.process` with JMESPath (`stage.json`), Go templates with
  sprig (`stage.template`), regex replace and drop stages, and `prometheus.scrape` with
  `discovery.kubernetes` for every scrape vmagent did. It has no source that takes an arbitrary
  JSON webhook body: `loki.source.api` accepts the Loki push protocol and raw lines only.
* **VictoriaLogs takes the Loki push protocol,** parses a JSON line into fields, turns structured
  metadata into fields, and takes `_stream_fields` and `_msg_field` as query arguments.
* **The Alloy release binary is linked against glibc.** The `infra-runner` CI image is Alpine
  (musl) and runs as a non-root user, so it cannot run Alloy; the host toolchain of the `docker`
  runner (`webgrip/ci-runner`) can.
* **The homelab's notification channel** is its in-cluster ntfy (public at `ntfy.webgrip.dev`,
  deny-all with write-only tokens), plus a dead-man's switch on the off-site uptime-kuma
  (`uptime.webgrip.dev`, on the Hetzner box `garage-fsn1`) that the homelab's `Watchdog` beats.
  There is no Telegram bot and no SMTP relay (homelab `vmalertmanager-config.externalsecret.yaml`).
* **Volumes:** `hcloud-luks` is the only StorageClass admission allows for a normal claim; Hetzner
  sells 10 GB and up at €0.044 per GB a month, and the CSI driver rounds GiB up to whole GB.
* **The ops Gateway (#107)** serves `*.ops.unfoldhq.dev` on the API address, on the tailnet only,
  with a Let's Encrypt certificate, and `ops-auth/authentik-relay` is the one path from the cluster
  to Authentik.

## Considered options

### Collector

* **A. Alloy for metrics and node logs; the Trivy report shipper stays Vector.**
* **B. Alloy everywhere,** with the Trivy webhook through `loki.source.api`'s raw route: every
  multi-megabyte report would arrive as one log line and the counting and filtering of findings
  would move into JMESPath. Possible, but a rewrite of a tested transform for no gain.
* **C. Keep Vector and vmagent and only change where they write.** Two agents on every node, which
  the control planes have no memory for (ADR 0013), and not what the owner asked for.

### Stores and alerting

* **A. Plain manifests:** a VictoriaMetrics single StatefulSet, two VictoriaLogs single
  StatefulSets (logs 14 days, the API audit log 90 days), three vmalert Deployments (PromQL,
  LogsQL on logs, LogsQL on audit) and one Alertmanager, rules as files in git.
* **B. The VictoriaMetrics operator,** as in the homelab: VMSingle, VLSingle, VMAlert, VMRule.
  One more controller on a cluster that is short of memory, which builds pods whose images,
  sidecars and limits have to be coaxed past the Deny admission policies.

### Where alerts go

* **A. The homelab's public ntfy now, with the homelab's write-only token,** and the Watchdog to
  the off-site uptime-kuma; move to an ntfy on the off-site box when it exists.
* **B. Wait for an off-site ntfy before paging at all.**
* **C. Through the homelab Alertmanager.** Rejected by the owner's decision.

### How the homelab reads

* **A. Through the ops Gateway:** `query.ops.unfoldhq.dev` routes to a vmauth that admits one
  bearer token and read paths only; the homelab gateway reaches it over the tailnet.
* **B. A tailnet device of its own for the stack.** A second identity and a second path to
  Authentik, which #107 already provides once.

## Decision

1. **Collector: A.** `alloy-metrics` (one Deployment) scrapes everything vmagent did plus KEDA,
   the cluster-autoscaler, cert-manager, Tetragon (host port 2112, opened to the pod network in
   `infra/metrics-ports.tf`) and the observability pods. `alloy-logs` (one DaemonSet on every
   node's host network, the only grant: `observability/DaemonSet/alloy-logs`) reads pod logs, the
   Talos service and kernel streams, the API audit log, Hubble's egress flow log and Tetragon's
   export file, and writes field for field what Vector wrote, so the runtime rules move unchanged.
   The Trivy report shipper stays Vector and writes to the cluster's VictoriaLogs.
2. **Stores and alerting: A.** Retention 30 days for metrics, 14 days for logs, 90 days for the
   audit log, each with a disk cap below its volume. No VictoriaTraces: nothing in the cluster
   emits traces yet (ADR 0013 adds it at S2).
3. **Alerts: A.** Alertmanager posts `critical` and `warning` to `ntfy.webgrip.dev`
   (`alerts-critical`, `alerts-warning`, the topics the phone already reads) with the token from
   OpenBao `secret/unfold-main/alertmanager/ntfy`, and the always-firing `Watchdog` every two
   minutes to the uptime-kuma push URL in `secret/unfold-main/alertmanager/deadman`. That interim
   still needs the homelab for the ntfy hop; the off-site ntfy removes it (RFC 0001 delivery
   step 8). The homelab watches the other direction: its blackbox exporter asks
   `query.ops.unfoldhq.dev` for the firing `Watchdog` and pages `UnfoldAlertingSilent`.
4. **Grafana:** the Grafana Operator (namespace-scoped to `observability`) and one Grafana at
   `https://grafana.ops.unfoldhq.dev`, OIDC client `unfold-grafana` in the homelab access plane
   with a passkey, token exchange through `authentik-relay`, roles from `unfold-admins` (Admin)
   and `unfold-viewers` (Viewer). The operator's generated admin login is the break-glass when
   Authentik is unreachable. Data sources `unfold-prometheus`, `victorialogs`,
   `victorialogs-audit` and `alertmanager`; dashboards as GrafanaDashboard CRs, including the two
   moved from the homelab and #107's six.
5. **Homelab reads: A.** The audit store is not behind the query endpoint: homelab Grafana
   Editors can query every homelab data source, so Unfold's audit trail stays in Unfold's Grafana.
   The tailnet policy gains one rule, `tag:homelab-gateway` to `10.64.0.10:443`.
6. **Retiring the homelab path: in three steps.** This change dual-writes (Alloy's `homelab_*`
   sinks and the second remote-write endpoint) so the homelab's `vmalert-unfold` keeps working
   while this stack proves itself. Then a follow-up pull request removes the dual write and the
   tailnet's 8427 rules, and the prepared homelab change removes `vmsingle-unfold`, both
   `vmalert-unfold*`, the Unfold rules, the gateway's 8427 and the moved dashboards. Until both
   land, an Unfold alert pages twice.
7. **CI:** the observability checks run on the `docker` runner's host toolchain, because Alloy
   needs glibc.

## Consequences

* Good, because Unfold collects, stores, evaluates and notifies with the homelab down, and the
  homelab Grafana still shows Unfold's metrics and logs.
* Good, because every alert rule has a test that runs it: PromQL rules under `vmalert-tool` with a
  firing and a quiet case each, LogsQL rules against a real VictoriaLogs fed by the real Alloy
  pipeline, both with mutation tests.
* Bad, because until the off-site ntfy exists a notification still crosses the homelab's ntfy;
  only the dead-man's switch is independent. With the homelab down, Unfold's alerts are evaluated
  and visible in its Grafana but do not reach the phone.
* Bad, because until the `system` node exists the stack runs on the hub (ADR 0013's fallback),
  where it leaves room for one CI job instead of two, and its volumes are created in fsn1. A
  `system` node in nbg1 cannot attach them: moving the stack there starts the three stores empty.
* Bad, because the Trivy shipper keeps a second agent image (Vector) in the cluster.
* Neutral: the Grafana image is named three times (the CR's version, its container, the operator's
  default); `scripts/test-observability-metrics.sh` fails when they differ.

## Confirmation

* `scripts/test-observability-logs.sh --mutation-test` and
  `scripts/test-observability-metrics.sh --mutation-test` pass in `observability-check`.
* On the cluster: `count by (job) (up{cluster="unfold"} == 1)` lists every scrape job in Unfold's
  Grafana; `{cluster="unfold"} | stats by (source) count()` shows `pod`, `talos`,
  `hubble-egress` and `tetragon`; `ALERTS{alertname="Watchdog"}` is firing; uptime-kuma's
  push monitor is Up.
* From the homelab: the `unfold-metrics` data source answers, and `UnfoldAlertingSilent` stays
  quiet.
