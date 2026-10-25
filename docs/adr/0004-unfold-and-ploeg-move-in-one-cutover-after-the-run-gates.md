---
status: proposed
date: 2026-10-25
---

# ADR 0004: Unfold and Ploeg move in one cutover, after the Run gates are on

## Context and problem statement

Unfold ADR-0040 makes this cluster Unfold's production and the homelab its staging environment. Ploeg ADR-0107 makes this cluster the hub and lets other clusters run Runs as cells. Today everything runs in the homelab: Unfold, ploegd, the database and the Runs ([RFC 0003](../rfc/0003-moving-unfold-and-ploeg-to-production.md)).

The question is in what order the hub (Unfold, ploegd, the database) and the Runs move. Two constraints decide it:

* Agent Runs execute untrusted code, and RFC 0001 allows them here only once the runtime, isolation and egress controls are on.
* Two ploegds that watch the same boards run every ticket twice.

## Considered options

* **One cutover:** a shadow install first, then the hub and the Runs move in one window after the gates.
* **The hub first, with the homelab as a Run cell.** This needs Ploeg's `ploeg-cell` chart and the cell protocol of ADR-0107, and neither exists.
* **The hub first, with no Runs until the gates are on.** Agent work stops for as long as the gates take.

## Decision

Chosen option: one cutover.

1. Everything before the window installs into an empty **shadow** environment:
   * the `unfold` release with `ploeg.executor.enabled: false` and the Ploeg Test board only;
   * an empty `ploeg-db`;
   * LiteLLM.

   The shadow install is also ADR-0040's public install proof.
2. The executor is switched on, here, against the fixture boards (Ploeg Test and Ploeg Bench) only. That happens after every gate in RFC 0003 §5 is green.
3. In one window:
   * the homelab stops dispatching and scales to zero;
   * the data moves ([ADR 0007](0007-ploeg-and-unfold-data-move-as-encrypted-files.md));
   * this cluster's values gain the real board projects, and the homelab's lose them, in two commits merged in the same window;
   * the webhooks are wired again.
4. The homelab becomes staging on the fixture boards. A homelab CI check refuses any production project id in its values.

## Consequences

* Good, because nothing deployed before the window has to be rolled back, and the window can be rehearsed against the shadow environment.
* Good, because untrusted Runs never execute here before their controls do.
* Good, because the board never has two dispatchers.
* Bad, because the window moves everything at once. The data is about 110 MiB, which keeps it to 30 to 60 minutes.
* Bad, because the homelab keeps running production Runs until the gates are done, on the controls it has today.
* When `ploeg-cell` exists, the homelab can become a second `isolated` cell as ADR-0107 intends. That is a later change, not part of this one.

## Confirmation

* Before step 8 of RFC 0003, this cluster's `unfold` values list no real board project, and the homelab's do.
* After step 8 it is the other way round, the homelab's ploegd has 0 replicas, and a real ticket dispatched here has opened a pull request.
* The homelab CI check fails on a values file that holds a production project id, and passes on the fixture boards.
