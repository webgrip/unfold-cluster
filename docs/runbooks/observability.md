# Observability runbook

How the stack is built: [observability](../observability.md). Why: [ADR 0016](../adr/0016-unfold-observes-itself.md).

## After the merge

1. The pending infra apply must have run; then this change's apply opens Tetragon's metrics port
   (2112) to the pod network, adds `grafana` and `query` to Headscale's `ops.unfoldhq.dev`
   records, and lets `tag:homelab-gateway` reach `10.64.0.10:443`.
2. Flux applies the stack; `observability-secrets` waits for External Secrets, `grafana` for the
   operator and the secrets.
3. Checks:

   ```sh
   kubectl -n observability get pods,pvc
   kubectl -n observability get externalsecret          # all SecretSynced, except alertmanager-deadman until it is seeded
   kubectl -n observability get grafana,grafanadatasource,grafanadashboard
   kubectl get httproute -n observability               # grafana and query Accepted
   ```

   In Grafana (`https://grafana.ops.unfoldhq.dev`), Explore:
   * `count by (job) (up{cluster="unfold"} == 1)` lists every scrape job; `up{cluster="unfold"} == 0` is empty.
   * `etcd_server_has_leader{cluster="unfold"}` returns three series of 1.
   * `ALERTS{alertname="Watchdog",alertstate="firing"}` returns one series.
   * VictoriaLogs: `cluster:=unfold | stats by (source) count()` shows `pod`, `talos`, `hubble-egress`, `tetragon` (and `trivy` after a scan).
   * VictoriaLogs audit: `cluster:=unfold job:=kube-audit | stats count()`.

## Watchdog

`Watchdog` always fires. Alertmanager sends it every two minutes to uptime-kuma's push monitor, and
the homelab's blackbox exporter reads it through `query.ops.unfoldhq.dev`. If uptime-kuma or the
homelab's `UnfoldAlertingSilent` pages:

1. `kubectl -n observability get pods`: is `vmalert-metrics`, `alertmanager` or `vmsingle` down?
2. `kubectl -n observability logs deploy/alertmanager | grep -i deadman`: a missing or wrong
   `ping_url` shows here.
3. Only `UnfoldAlertingSilent` and Unfold looks healthy: the read path. From the homelab,
   `kubectl -n observability logs deploy/unfold-gateway -c unfold-query`; on Unfold,
   `kubectl -n observability logs deploy/vmauth-query` and the HTTPRoute `query`.

## No metrics

`UnfoldMetricsAbsent` or `UnfoldRemoteWriteBacklog`: `alloy-metrics` does not write to `vmsingle`.

* `kubectl -n observability logs deploy/alloy-metrics | grep -i "error\|remote"`.
* Its debug UI: `kubectl -n observability port-forward deploy/alloy-metrics 12345` and open
  `http://localhost:12345`; a red component names the failing scrape or write.
* A target missing from `up`: Hubble's verdicts for `observability/alloy-metrics` show a Cilium
  drop (each scraped namespace admits alloy-metrics on its metrics port, `networkpolicy-metrics.yaml`).

## Logs dropped

`UnfoldLogShipperDropping` or `UnfoldLogsNotArriving`.

* `kubectl -n observability logs ds/alloy-logs --all-containers --prefix | grep -i "error\|drop"`.
* `vlsingle-logs` or `vlsingle-audit` not ready: `kubectl -n observability describe pod vlsingle-logs-0`.
* Talos logs missing but pod logs arrive: Talos sends to `127.0.0.1:6050` and `:6051` on each node;
  `talosctl -n <node> logs machined | grep -i log` names a refused connection.

## Volumes

`UnfoldObservabilityVolumeFilling`: lower the retention or the disk cap first (the args of the
StatefulSet), which needs no new volume. To grow a volume, a StatefulSet's `volumeClaimTemplates`
cannot change in place: add the larger size to the template and a Kustomize patch for the existing
claim (`storage-vmsingle-0`, `storage-vlsingle-logs-0`, `storage-vlsingle-audit-0`) in the same pull
request, and let Flux recreate the StatefulSet object with `kustomize.toolkit.fluxcd.io/force: enabled`
on it for that one reconcile. `hcloud-luks` grows the volume online.

## Notifications

`UnfoldAlertNotificationsFailing`: Alertmanager cannot deliver.

* `kubectl -n observability logs deploy/alertmanager | grep -i notify`.
* 401 or 403 from ntfy: the token in `alertmanager-ntfy` is wrong or was rotated in the homelab;
  `kubectl -n observability get externalsecret alertmanager-ntfy`.
* Timeouts: ntfy runs in the homelab until the off-site ntfy exists. With the homelab down,
  alerts still fire and show in Grafana's **Alerting** list (data source `alertmanager`).

## Moving the stack to the system node

The stack prefers the `system` pool and falls back to the hub. Raising `node_count` of the `system`
pool in `infra/variables.tf` (ADR 0013, declared by #106) adds the node; pods move to it the next time they are
scheduled. The three volumes were created in fsn1 with the hub; a `system` node in nbg1 cannot
attach them, so the stores start empty there: delete the three PVCs in the same reviewed change.
