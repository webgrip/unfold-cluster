---
status: proposed
date: 2026-10-25
---

# ADR 0007: Production runs its own LiteLLM, with its own provider keys

## Context and problem statement

Every model call from Unfold and Ploeg goes through LiteLLM (homelab ADR-0044). Three consumers depend on it:

* **ploegd** holds LiteLLM's master key and mints a virtual key for each Run, with a budget and a 4-hour lifetime.
* **Unfold** calls its decider model with its own key.
* **Runs** call models with their per-Run key, through a proxy that keeps the key out of the pod.

Unfold ADR-0040 and RFC 0001 both place a LiteLLM in this cluster. Its job includes the guardrails and the judge models of RFC 0001's agent oversight. When Unfold and Ploeg move ([RFC 0003](../rfc/0003-moving-unfold-and-ploeg-to-production.md)), the question is where their model gateway lives.

## Considered options

* **Its own LiteLLM here**, with production provider keys, its own database and its own budgets.
* **The homelab's LiteLLM through the gateway.** ploegd here would hold the homelab's master key. A production compromise could then mint homelab keys and spend the homelab's budgets, and every prompt carrying client code would pass through the house.
* **Provider keys straight in ploegd.** There would be no per-Run budget and no metering, which breaks homelab ADR-0044.

## Decision

Chosen option: its own LiteLLM here.

* **Pool.** It runs on the hub pool, with Valkey and a CNPG database `litellm-db` (one instance, then three when the hub grows).
* **Provider keys.** Each provider gets a key issued for production only, at `secret/unfold-main/litellm/providers/<provider>`, provided by the owner with `bao kv put`.
* **Master key.** Generated in this cluster. No key crosses between the clusters.
* **Budgets.** The €100 a month model cap of ADR-0040 is set as LiteLLM budgets: one team for `ploeg-crews`, one key for Unfold's decider, and the guardrail and judge models of RFC 0001 under their own budget.
* **Start state.** It starts empty. Spend history stays with the homelab's LiteLLM, and production's ledger starts on the day of cutover.
* **Models.** Only providers reachable from this cluster are configured. A model that only the homelab serves stays out until a route for it is decided.
* **Exposure.** The Runs' egress rule names LiteLLM's Service, not the internet. LiteLLM itself reaches the providers by FQDN.

## Consequences

* Good, because client code never transits the house.
* Good, because a production compromise spends only production's budgets, behind production's keys, which can be revoked on their own.
* Good, because RFC 0001's model gateway guards can be built where the Runs are.
* Bad, because the hub needs about 1.3 GiB of memory more, and there is one more database to back up and drill.
* Bad, because the owner manages a second set of provider keys, and spend is reported in two places until a shared dashboard reads both.

## Confirmation

* A model call from a shadow Run is metered against its per-Run key's budget in this cluster's LiteLLM, and the homelab's spend log shows no entry for it.
* `bao kv list secret/unfold-main/litellm` lists only production provider keys, and the master key ploegd uses here is the one this cluster generated.
* A key whose budget is exhausted gets an error, never a silent fallback to another model. The fallback was a homelab incident on 2026-09-28. The check is a test request with `disable_fallbacks`.
