# Hetzner API budget and token quotes in public logs

Hetzner allows 3600 API requests an hour per Cloud project, refilled at one a second. Every token in the project draws on the same budget. A request that finds it empty fails with `429 rate_limit_exceeded`, and the error quotes the start of the token that made it:

```text
Limit of '3600' requests per hour for token '<first 32 characters>...' reached. (rate_limit_exceeded)
```

This repository's job logs are readable without signing in, so that quote is a leak. On 2026-10-25 two tokens were quoted this way and then rotated. The OpenTofu token was quoted in `plan-or-apply` run 63, before the prefix mask existed. The VIP token was quoted in `diagnose` runs 69 and 74, after it existed: Talos's VIP controller printed the quote in node logs that the diagnose report relays, and the diagnose job never holds that token, so no runner mask could know it.

## Who spends the budget

| Spender | Requests | Source of the estimate |
| --- | --- | --- |
| A plan (`plan-or-apply` on a push to `main`, or the plan half of an apply run) | about 13: one refresh each of the 12 `hcloud_*` objects in the state (5 servers, 2 firewalls, the network, its subnet, the placement group, the SSH key, the Headscale primary IP) and one `data "hcloud_images"` lookup | `infra/*.tf`; every plan log since run 76 shows 12 `hcloud_` refreshes |
| An apply that changes no Hetzner object | about 14: the plan above and one image lookup by `scripts/build-talos-snapshot.sh`. `tofu apply` applies the saved plan without refreshing again | `.forgejo/workflows/infra.yml` |
| An apply that creates servers | a few hundred: each create is one call, then the provider polls its action every 2 s (`poll_interval` in `infra/versions.tf`) until it finishes. Run 59 created five servers in 16 to 56 s each | run 59's log |
| Building the Talos snapshot when none exists | not measured: `hcloud-upload-image` runs a temporary server for about 8 minutes (run 58) and polls on its own schedule | run 58's log |
| `diagnose` | 1: `GET /v1/locations?per_page=1` for the headers | `scripts/diagnose-cluster.sh` |
| Talos's HCloud VIP controller, per control plane | 2 per reconcile: `Server.GetByID` and `Network.GetByID` in `GetNetworkAndDeviceIDs`. The controller reconciles on every `LinkStatus` change on the node, not only on config changes | Talos v1.13.0, `internal/app/machined/pkg/controllers/network/operator_vip_config.go` and `operator/vip/hcloud.go` |
| The cloud controller and CSI driver | steady and small once nodes are initialised; more while the cloud controller keeps failing to initialise nodes (see `4e8d6c4`) | not measured |

The CI workflows cannot use the budget up on their own. `infra` runs one job at a time (`concurrency: infra-state`), so even a plan on every push stays near 1% of an hour's budget. The pull-request check (`infra-check`) runs with no token and makes no Hetzner calls.

## What emptied it on 2026-10-25

`diagnose` runs 66, 69 and 74 (11:29 to 11:45 UTC) read `RateLimit-Remaining: 0`. In the same reports, every control plane's `OperatorVIPConfigController` logged `found private network for private vip (alias IP)` every 2 to 6 seconds: 11 to 19 lookups per control plane in each 60 to 85 second window, two requests each. That added up to 1.2 to 1.4 requests a second across the three control planes, more than the refill, so the controllers took every request as soon as it came back. Plans 63, 68 and 75 failed on their first Hetzner call. At the time kube-apiserver was crash-looping on every control plane (an invalid PodSecurity configuration). The controller reconciles on link changes, so that churn is the likely trigger. The reports do not show which links changed.

By run 76 (12:33 UTC) plans passed again. The logs do not show which change stopped the churn.

Cutting the workflow's requests would not have prevented this: they were already small, and they were the ones refused. The steady spender is the VIP controller's lookup on every link event. Changing that is an upstream Talos change or a different way to move the API address, which this runbook does not make. Signs it is happening again: plans fail with `rate_limit_exceeded` while nobody is applying, and the diagnose report shows `RateLimit-Remaining` near 0 with many `found private network` lines per control plane.

A second token buys no headroom. A second Hetzner project would, but the VIP token has to live in the same project as the servers.

## How a token quote stays out of the log

* `scripts/mask-hcloud-token-prefixes.sh` runs right after the OpenBao read in both `infra` jobs. For each Hetzner token in the environment it registers an `::add-mask::` for the whole token and for every prefix of 16 characters or more. forgejo-runner's log reporter replaces masks as plain substrings, longest first (`internal/pkg/report/mask.go`), so a quote cut at any length from 16 up becomes `***...`, and a whole token is a single `***`.
* The `diagnose` job holds only the OpenTofu token, but it prints node and cloud-controller logs that quote other tokens. `scripts/diagnose-cluster.sh` therefore redacts every `for token '...'` quote, whatever token it belongs to.
* `scripts/test-mask-hcloud-token-prefixes.sh` checks both with fake tokens, applying the masks the way the reporter does. It includes a control case that must still show the quote with no masks, and it takes `MASK_SCRIPT` for mutation checks. A mask script that masks only whole tokens fails 6 cases. One that masks only the 32-character prefix, the rule before this runbook, fails the 3 shorter-quote cases. Removing the diagnose rule fails its case.
* `infra-check` runs that test on pull requests. Its `token-mask-canary` job also masks a fake token on a real runner and prints Hetzner's 429 line for it. `token-mask-proof` then downloads that job's public log anonymously and fails if the fake token's first 16 characters appear, or if the line is not there as `***...`.

A token whose characters ever reached a log is rotated: generate a new one in the Hetzner Console, `bao kv put` it at the same path, run an apply when it is the cluster or VIP token (they reach the nodes only through an apply), then delete the old one.
