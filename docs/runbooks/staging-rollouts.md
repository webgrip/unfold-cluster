# Staging rollouts

How to tell whether an Unfold release candidate reached `unfold-staging` and works. How a release gets here is [Unfold staging](unfold-staging.md#how-a-release-reaches-staging).

## Did the rollout go well?

Every rollout ends in exactly one of these, each pushed to the `alerts-warning` ntfy topic:

| You get | It means |
| --- | --- |
| `FluxHelmReleaseUpgradeSucceeded` for `unfold`, with the new `revision` | Helm upgraded staging and every Deployment of the release became ready within `timeout` (15 minutes). |
| `FluxHelmReleaseTestSucceeded` right after it | The chart's test hooks passed. The Unfold chart has none yet, so the message ends in "no test hooks" (see [Smoke test](#smoke-test)). |
| `FluxHelmReleaseUpgradeFailed`, `FluxHelmReleaseTestFailed`, then `FluxHelmReleaseRollbackSucceeded` | The candidate failed and Flux put the previous release back (`upgrade.remediation`, three retries). Staging runs the old version. |
| `UnfoldFluxReconcileFailing` for `HelmRelease flux-system/unfold` | The HelmRelease has not been Ready for 15 minutes. The `namespace` label of that alert is the flux-operator's, not the release's. |
| `UnfoldStagingRolloutLagging` | Flux fetched a chart (OCIRepository `unfold-staging/unfold`) that the HelmRelease has not been Ready on for 30 minutes: failed and rolled back, still retrying, or stuck. |
| `UnfoldStagingBehindRelease` (from the homelab) | A candidate has been on `ghcr.io` for 45 minutes and staging does not run it. Its `outcome` label says whether Renovate ran at all. |

Nothing at all after a release on GitHub means the chain stopped before this cluster: the homelab's `unfold-release-watch` raises `UnfoldStagingBehindRelease` 45 minutes after the chart, or `UnfoldReleaseWatchStale` if the watcher itself stopped ([homelab Renovate runbook](https://forgejo.webgrip.dev/webgrip/homelab-cluster/src/branch/main/docs/techdocs/docs/runbooks/renovate.md#unfold-release-candidates-reach-unfold-staging)).

The Flux events come from the `unfold-rollout` Alert in `kubernetes/apps/unfold-staging/unfold/notifications.yaml`: every info and error event of HelmRelease `unfold` and OCIRepository `unfold` (a new chart stored, upgrade, test, rollback, failures), sent to this cluster's Alertmanager with the label `rollout=unfold-staging`. Alertmanager's `rollout` route sends them to ntfy without a resolved message, one notification per event and revision.

## Check it by hand

```sh
kubectl -n unfold-staging get ocirepository unfold -o jsonpath='{.spec.ref.tag} {.status.artifact.revision}{"\n"}'
kubectl -n unfold-staging get helmrelease unfold
kubectl -n unfold-staging get helmrelease unfold -o jsonpath='{range .status.history[*]}{.chartVersion} {.status} {.testHooks}{"\n"}{end}'
kubectl -n unfold-staging get events --field-selector involvedObject.name=unfold --sort-by=.lastTimestamp | tail
```

The workbench says which version it runs and whether it may talk to ploegd:

```sh
kubectl -n unfold-staging port-forward svc/unfold 4080:4080 &
curl -s localhost:4080/readyz      # {"status":"ok","version":"0.4.0-rc.N"}
curl -s localhost:4080/healthz     # ... "ploegContract":{"state":"compatible",...}
curl -s localhost:4080/api/auth/methods   # the sign-in page's methods: oidc names the homelab login
```

`ploegContract.state` is `incompatible` when the Ploeg this release carries does not serve a contract major Unfold requires. The workbench stays ready and refuses every call to ploegd, so neither Helm nor Flux notices: only this check and the `ploeg.contract_incompatible` log line show it.

In Grafana Explore (`https://grafana.ops.unfoldhq.dev`):

```promql
flux_resource_info{cluster="unfold",exported_namespace="unfold-staging",name="unfold"}
```

The HelmRelease series carries the running chart as `revision` (`0.4.0-rc.N+<digest>`), the OCIRepository series the pinned tag as `ref`.

## When it went wrong

- **Rolled back.** `kubectl -n unfold-staging describe helmrelease unfold` names the failed step. A Secret or value the release needs and staging lacks: add it to `unfold/secrets.yaml` or `helmrelease.yaml` in a pull request; Flux upgrades again on merge. The next candidate supersedes a bad one; to skip it, close Renovate's pull request ([Unfold staging](unfold-staging.md#how-a-release-reaches-staging)).
- **Retries exhausted.** After three failed upgrades the HelmRelease stops. Fix the cause, then merge the fix: a changed chart or values starts a new attempt. Without a change, `flux reconcile helmrelease unfold -n unfold-staging --reset` clears the failure count.
- **Stuck without an event.** No upgrade event but the OCIRepository has the new chart: the HelmRelease waits for its next `interval` (10 minutes) or a dependency. `kubectl -n unfold-staging get helmrelease unfold -o yaml` shows the condition.

## Smoke test

`spec.test.enable` is on in the HelmRelease, with `test.timeout: 5m` and the default `ignoreFailures: false`, so a failed chart test after an upgrade counts as a failed upgrade and is rolled back by `upgrade.remediation`. The Unfold chart (`unfold-hq/unfold`, `apps/unfold/ops/helm/unfold`) has no `helm.sh/hook: test` template yet, so today the test step passes with "no test hooks" and adds nothing.

Proposed, not built: a test Pod in the chart that requires, within a few minutes of the upgrade,

1. `GET /readyz` answers 200 with `version` equal to the chart's `appVersion`;
2. `GET /healthz` reports `ploegContract.state: compatible` (it starts `unchecked`, so it retries);
3. `GET /api/auth/methods` answers 200 and the sign-in page `/` answers 200.

This cluster's `unfold` CiliumNetworkPolicy (`kubernetes/apps/unfold-staging/unfold/networkpolicy.yaml`) must admit the test Pod to the workbench on 4080, and the admission policies must accept it (non-root, read-only root, limits, signed image). Until it exists, run the three checks above by hand after a rollout that matters.
