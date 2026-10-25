---
status: proposed
date: 2026-10-25
---

# ADR 0009: The metal node is an EX44, because the AX41 is no longer sold

## Context and problem statement

Agent Runs of the `isolated` class need Kata, and Kata needs hardware virtualisation, which Hetzner Cloud does not expose (ADR 0001, ADR 0002). `infra/` declared an AX41-NVMe in FSN1, with a ceiling of €65 a month net and no setup fee. On 2026-10-25 the plan failed with "Robot sells no product AX41-NVMe", and Hetzner's product page now redirects to the server finder. Open PR #83 declares no metal server and adds an `adopt` mode and an `auction` mode.

No Run can move here without a metal node ([RFC 0003](../rfc/0003-moving-unfold-and-ploeg-to-production.md)).

## Facts

All checked live on 2026-10-25, excluding VAT.

| Option | CPU | Memory | Disks | Per month | Setup |
| --- | --- | --- | --- | --- | --- |
| **EX44** (FSN1, HEL1) | Intel i5-13500, 6 performance and 8 efficiency cores, 20 threads, VT-x | 64 GB DDR4 | 2 × 512 GB NVMe | €59.00, plus €1.70 for IPv4 | €0 |
| Auction, cheapest with 64 GB | Intel i7-6700, 4 cores, 8 threads | 64 GB, no ECC | 2 × 512 GB NVMe | €71.00, plus €1.70 | €0 |
| AX42 | AMD Ryzen 7 PRO 8700GE | 64 GB DDR5 ECC | 2 × 512 GB NVMe | €99.00 | €49.00 |
| CPX42, cloud, no Kata | 8 shared vCPU | 16 GB | 320 GB | €69.99 | none |

## Decision

Chosen option: an EX44 in FSN1 as `unfold-metal-1`.

* **Declaration.** It is declared in `metal_servers` with product `EX44`, and either ordered through `order` mode or adopted after a website order through `adopt` mode (PR #83). The ceiling stays at €65.
* **CPU vendor.** The node uses `kvm_intel`, which PR #83 already selects, and the `intel-ucode` extension.
* **Kata CPUs.** Kata VMs get whole cores, as RFC 0002 decided. The hybrid CPU's performance cores are not pinned at first. Pinning is a later tuning step, if Run timings vary.
* **Workload.** The node runs Runs and Unfold's workspaces under Kata. CI moves to the on-demand CPX42 once that exists, so the Run node stops sharing a kernel boundary with CI jobs (ADR 0002's consequence). Until then, CI keeps running here under gVisor.
* **Fallback.** If the EX44 is out of stock on the day, the fallback is `auction` mode with the ceiling raised to €75 (the cheapest 64 GB offer was €72.70 with IPv4), or an AX42 with the ceiling at €101 and the setup ceiling at €49. Either change is a reviewed variable and an owner decision.

## Consequences

* Good, because it fits the existing ceiling with €4.30 to spare, so no reviewed variable changes except the product.
* Good, because the 20 threads hold about 12 concurrent Kata Runs beside three CI jobs, and about 16 without them.
* Bad, because the EX44 has no ECC memory and no AMD SEV. RFC 0002's confidential class needs its own AMD node in any case, so phase 0's `kata-qemu-coco-dev` pipeline still runs here, but nothing SNP-specific does.
* Bad, because ADR 0001's Kata build and ADR 0003's encryption from first install were proven only on paper for an AMD node. The Intel node is their first real run.

## Confirmation

* The `infra` plan prints the EX44 at €60.70 or less, including IPv4, with a setup fee of €0.
* A `kata` pod on `unfold-metal-1` reports a guest kernel different from the host's.
* `diagnose` shows both NVMe volumes as LUKS2 with the KMS key slot.
