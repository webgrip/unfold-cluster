# External dependencies: what production leans on outside the cluster

Every piece outside `unfold-main` that production needs, what stops when it is down, what an attacker
who holds it can do to production, and where it should end up. The target architecture is
[ADR 0015](../adr/0015-production-stays-operable-without-the-homelab.md); what to do when one of these is
down is the [break-glass runbook](../runbooks/break-glass.md).

Facts checked on 2026-10-26 against `main` at `1df9e35`, the open pull requests #93 to #103, the
in-flight observability stack, homelab-cluster `main`, and both clusters read-only. Prices exclude VAT,
Hetzner list prices of October 2026.

## The rule

Production must keep running **and stay operable** when the homelab is down: deploy, rotate a secret,
let a person log in, alert, back up, reboot or add a node, and rebuild. "Running" alone is not enough;
today it is the only thing that survives.

## What a homelab outage does today, and in the target

| Capability | Today, homelab down | Target (ADR 0015), homelab down |
| --- | --- | --- |
| Running workloads | keep running | keep running |
| Deploy a merged change | **no**: Forgejo is down, so nothing reaches the GitHub mirror Flux reads | yes, break-glass: an owner-signed commit pushed straight to the GitHub mirror (E05) |
| Rotate a secret | **no**: every value lives in the homelab OpenBao (E01) | yes: production's own OpenBao |
| Infra plan or apply | **no**: the runner, the Forgejo queue and every credential are in the homelab; the plan itself stops at `disk-kms-key.sh` ("OpenBao could not be read") | yes, break-glass: a laptop apply from the offline seed (E08); with only part of the homelab down, the Unfold runner pool |
| Human login | admin kubeconfig only (break-glass); no OIDC, no new tailnet device, no Grafana | yes: Google directly (ADR 0014) |
| Alerting | **none**: rules run in the homelab and ntfy is in the homelab | yes: in-cluster rules, a second receiver outside the homelab, an external dead-man's switch |
| etcd backup | written (garage-fsn1 is not in the homelab), never restore-checked | written to two providers and restore-checked in the cluster |
| Node reboot | works while `unfold-headscale` (the disk KMS) is up | works while either of two KMS servers is up |
| Add a node | **no**: needs an apply | yes, through the break-glass apply |
| CI for other repositories | **no**, accepted: Forgejo is the forge | **no**, accepted |
| Rebuild the cluster | **no**: the Talos secrets bundle, the disk master key, every token and the volume passphrase are read from the homelab OpenBao | yes: the offline seed plus a restore of production's OpenBao snapshot |

### It is not hypothetical

On 2026-10-26, eleven hours after the cluster was last rebuilt, the homelab gateway was in
`CreateContainerConfigError`: its tailnet key (`secret/unfold/tailnet-homelab-gateway`, written by an
`infra` apply) was missing from OpenBao, so the gateway never joined, the homelab never published
`unfold-gateway.webgrip.dev`, and on Unfold the ClusterSecretStore `openbao-homelab` reported
`InvalidProviderConfig` (`lookup unfold-gateway.webgrip.dev ... no such host`). Through that one
missing value, External Secrets, and with it the Kustomizations `ci-runners`, `cert-manager-issuers`,
`volume-encryption` and `external-secrets-stores`, the metrics and log shipping and the KEDA CI trigger
were all down at once. Nothing alerted, because the alerts run in the homelab and need the same
gateway.

## The inventory

Direction: `U→X` means Unfold calls X; `X→U` means X calls into or writes to Unfold.
Class: **(a)** must stay external, fine; **(b)** move into Unfold; **(c)** keep, make Unfold degrade
gracefully; **(d)** replace with a provider-neutral or self-hosted equivalent outside the homelab.
Effort: S (a pull request), M (days, several pull requests), L (a week or more). Euro amounts are the
monthly change the target adds.

### The homelab

| # | Dependency | Dir. | Used by | Breaks when it is down | If compromised: can it change production? | Today's mitigation | Class | Target | Effort | €/month |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| E01 | Homelab OpenBao (`secret/unfold-main/*`, `secret/unfold-cluster/*`, `secret/hetzner/unfold-*`) | U→X | External Secrets (runner registration token, DNS-01 token, `hcloud-luks` passphrase, ntfy and dead-man URLs); every `infra` run (14 values); the escrow of the Talos secrets bundle; the original of the disk KMS master key; the Headscale address and the gateway's tailnet key | Running pods keep their Secrets. New and rotated values stop syncing; a namespace added later never gets its Secrets; plan and apply fail; a Headscale rebuild cannot read the master key; a rebuilt cluster cannot open existing encrypted volumes (the passphrase) | **Yes, fully.** It holds the three Hetzner tokens (rescue mode or an image of any disk), the state passphrase, the Talos CA bundle (admin certificates) and the disk master key | CI role bound to `main` and named actors; ESO policy reads only `secret/unfold-main/*`; passphrase, age key, tokens and bundle also in the password manager | b | Production's own OpenBao in the cluster, static seal on the KMS-encrypted STATE partition; homelab vault separate (ADR 0015 §1) | L | 0,00 |
| E02 | Homelab Forgejo, the git source of truth | X→U | Every change: pull requests, review, the protected `main`, the push mirror to GitHub | No new commit reaches the mirror, so nothing deploys through a pull request. Flux keeps applying the last verified commit | **Yes.** A Forgejo admin can push to `main`, which mirrors to GitHub; the merge is signed by the instance key Flux trusts (E03) | Branch protection in `repo-config`; the GitHub ruleset `main: no rollback` | c | Stays the source (Unfold ADR-0040); break-glass is an owner-signed push to GitHub | S | 0,00 |
| E03 | Forgejo instance signing key, a trusted signer | X→U | Flux's signature check (`verify.mode: HEAD`) accepts every merge-button commit | Nothing: verification is offline | **Yes.** Anyone who can create a repository on the instance can get an arbitrary tree signed; it still has to reach the mirror's `main` | Mirror ruleset; protected `main`; owner decision of 2026-10-25 to trust it | c | Owner decision D6: keep, or trust only owner-held keys | S | 0,00 |
| E04 | Forgejo Actions and its OIDC issuer | X→U | Every check, `infra` plan, apply and diagnose, the daily etcd restore check, the rebuild drill; OIDC tokens that OpenBao's `ci-unfold-cluster` role accepts | No plan, apply, diagnose, drill or restore check | **Yes.** A workflow run on `main` by a listed actor reads every credential through the OIDC role | Role bound to repository, ref, event and actor; plans need a digest to apply | c | Stays; the apply gets a laptop break-glass and an Unfold runner pool (E08) | M | 0,00 |
| E05 | GitHub mirror `webgrip/unfold-cluster`, Flux's source | U→X | `GitRepository flux-system` (the Talos seed and Flux) | No deploys; the last verified commit stays applied. A source-controller restart while it is down leaves Kustomizations on what they last applied | **No** unsigned change deploys. A force-push of an older signed commit would roll back, which the ruleset refuses. The mirror token's expiry silently freezes deploys | Signature check; ruleset `main: no rollback` (hand-made) | c | A warm second source on Forgejo with the same signature check, and a break-glass that points Flux at it (this repository, `flux-fallback-source`) | S | 0,00 |
| E06 | Forgejo packages: private `webgrip-talos` registry | U→X | The metal node's Kata installer and disk image (`talos/metal-image.yaml`), pulled from Hetzner's rescue system and at upgrades | No metal install or upgrade (no metal node exists yet) | No: pinned by digest; a new pin is a reviewed pull request | Digest pin; read-only pull token | d | A second copy of each pinned digest in object storage outside the homelab | S | 0,00 |
| E07 | Forgejo CI job count (`forgejo-runner-queue` behind the gateway's 9150) and the runner registration token (homelab `unfold-ci-runner-provisioner`) | U→X | KEDA starts `unfold-ci` jobs; the registration init container | No CI on Unfold; Forgejo is usually down too | Only the count: up to six runner pods and an autoscaled CPX42 (cost) | Count-only endpoint; ephemeral runners | c | Stays: CI belongs to the forge | – | 0,00 |
| E08 | Homelab `forgejo-runner-infra` (label `unfold-infra`) | X→U | `infra` plan, apply and diagnose; rebuild drill; etcd restore check | No apply, diagnose, drill or restore check; the runners' address is also in `ADMIN_CIDRS` (E28) | **Yes.** The job holds every Hetzner token and the state passphrase, on homelab nodes shared with other repositories' jobs (RFC 0001 residual risk) | Repository-scoped runner; one job per fresh pod; OIDC role | b | A second `unfold-infra` pool in Unfold on trusted nodes; the homelab pool stays for rebuilds; a documented laptop apply for a homelab outage | M | 0,00 |
| E09 | Homelab Harbor | U→X | The `infra-runner` image of every check and of the infra pool | No CI | No: pinned by digest | Digest pins | c | Stays for CI; the Unfold infra pool pulls the same digest through Zot | S | 0,00 |
| E10 | Homelab variables bridge (`forgejo-actions-secrets`) | X→U | `ADMIN_CIDRS`, `STATE_*`, `ETCD_BACKUP_*`, `REBUILD_DRILL` on this repository | Variables go stale, nothing else | **Partly**: it can widen `ADMIN_CIDRS` (the Talos and Kubernetes API firewall) or point the state at another bucket on the next apply | Hourly copy from OpenBao | b | The values move with E01; the variables become reads from production's OpenBao | S | 0,00 |
| E11 | Homelab gateway `unfold-gateway` (tailnet 8200, 8427, 9150) | U→X | External Secrets to OpenBao, vmagent and Vector, KEDA; Headscale's OIDC calls on 443 | **Down on 2026-10-26** (above). Secrets stop syncing, telemetry buffers (vmagent 1,8 GB, Vector 2 GiB per node) then drops, CI does not scale, new tailnet devices cannot log in | **Yes, Secret values:** the OpenBao leg is plain HTTP inside WireGuard, so a compromised gateway can answer External Secrets with forged values (a LUKS passphrase, a DNS token). It cannot open connections into the cluster | Tailnet policy per tag; Cilium egress per workload | c | Nothing production-critical crosses it after E01 and E15 move; it stays for optional telemetry copies to the homelab | M | 0,00 |
| E12 | Homelab DNS publishers (`unfold-headscale-address`, `unfold-gateway-address`, `cloudflare-dns`) | X→U | The A records of `headscale.webgrip.dev` (the KMS and Headscale endpoint) and `unfold-gateway.webgrip.dev` | A Headscale in a new Hetzner project never gets its name, so it never gets a certificate, so **no encrypted node can unlock or join**. Within one project the primary IP survives and nothing breaks | **Yes:** the webgrip.dev DNS token can point the KMS name at a host the attacker controls, get a certificate for it, refuse every reboot, and seal the keys of a new node with its own key | Primary IP kept across rebuilds | b | The apply publishes its own names in a zone it owns with a zone-scoped token; the second KMS's name in a zone not on Cloudflare (ADR 0015 §5) | S | 0,00 |
| E13 | Homelab Authentik | U→X | Kubernetes OIDC (JWKS through the homelab's tunnel), Headscale browser login, Grafana login (in-flight stack); later the Unfold app and ploeg-mcp | No OIDC `kubectl`, no new tailnet device, no Grafana; break-glass admin kubeconfig still works | **Partly:** a token with `unfold-admins` gives the operator role (pods, evictions, cordon; no Secrets) and registers tailnet devices | Passkey on the Headscale flow; break-glass kubeconfig | d | Google Workspace directly for operators (ADR 0014) | M | 0,00 |
| E14 | Homelab Cloudflare tunnel connector | U→X | Serves `forgejo.webgrip.dev`, Authentik's public JWKS and `ntfy.webgrip.dev` | Same as E02, E13 and E15 together | Through what it fronts | – | c | Leaves the production path with E13 and E15 | – | 0,00 |
| E15 | Homelab alerting: `vmalert-unfold`, `vmsingle-unfold`, Alertmanager and ntfy | U→X | Every Unfold alert today; the in-flight in-cluster Alertmanager still delivers to `ntfy.webgrip.dev` | No alert is evaluated today; after the in-cluster stack, alerts are evaluated but not delivered | No change to production; it can hide alerts | uptime-kuma dead-man's switch on garage-fsn1 | c | In-cluster rules (in flight) plus a second receiver outside the homelab: email through Google Workspace's SMTP relay | S | 0,00 |
| E16 | Homelab image signing key (OpenBao Transit `cosign-webgrip`) | X→U | Signatures Kyverno checks on webgrip images (Audit) | No new signed images; CI is down anyway | Can sign any image as ours; the policy only audits today | `failurePolicy: Ignore`, Audit | c | Stays with CI; production verifies with the public key it already carries | – | 0,00 |
| E17 | Homelab Renovate | X→U | Version pull requests | Updates, security fixes included, wait | No: it opens pull requests the owner merges | Branch protection | c | Stays | – | 0,00 |
| E18 | Homelab stock watcher (`hetzner-stock-watch`) | X→U | Alerts when an EX44 or AX41 is for sale | A sale is missed | No | – | c | Stays | – | 0,00 |
| E19 | Homelab LiteLLM | U→X | Unfold's decider key today; ploegd and Runs after the move | Model calls fail | Through its master key it could spend budgets and read prompts | ADR 0007 already moves it | b | Production's own LiteLLM (ADR 0007) | M | 0,00 |
| E20 | Vikunja (Ploeg's tracker) | U→X, X→U | ploegd intake and the tracker wiring through a gateway port; webhooks into the public endpoint | Intake stops; Runs in flight finish (RFC 0003 R7, accepted) | It steers Runs, which treat tracker text as untrusted; no infrastructure write | HMAC on webhooks; ploegd re-reads the API | c | Stays, accepted | – | 0,00 |
| E21 | Omnigraph | U→X | Off at cutover (RFC 0003 D9) | Nothing | Graph writers could steer Runs | Off | c | Stays off, later through the gateway | – | 0,00 |
| E22 | Homelab outside-in probes and cost export (`blackbox-exporter`, `hcloud-cost-exporter`) | X→U | An outside view of Unfold's endpoints, the Hetzner bill | No outside view | No (read-only Hetzner token) | – | c | Stays; the dead-man's switch covers silence | – | 0,00 |
| E23 | Homelab token minters (`cloudflare-dns-token-minter` for `unfoldhq.dev`, `unfold-metal-image-provisioner`) | X→U | The DNS-01 token (90 days, renewed 30 days early); the metal pull token | Nothing for weeks: the DNS token outlives a 30-day outage and certificates another 30 | The minter can issue DNS write on `unfoldhq.dev` | Zone-scoped tokens | c | Stays, with the expiry visible as an alert in the cluster | S | 0,00 |

### Outside the homelab

| # | Dependency | Dir. | Used by | Breaks when it is down | If compromised: can it change production? | Today's mitigation | Class | Target | Effort | €/month |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| E24 | garage-fsn1, the owner's Garage box in Falkenstein | U→X | OpenTofu state; etcd snapshots every 6 hours; the 30-day lifecycle rule | No plan or apply (no state), no rebuild; backups fail and alert after 7 hours | **Not directly:** the state is encrypted with the passphrase. It can delete every snapshot and the state, and replace the lifecycle rule (Garage's `write` includes delete) | Write-only key in name; daily restore check; password-manager passphrase | d | Hetzner Object Storage in a separate project plus an OVHcloud copy with a 30-day compliance lock; state on OVHcloud with a Scaleway copy (RFC 0001 step 3) | M | 10,29 |
| E25 | `unfold-headscale` (Headscale and its DERP relay) | U→X | The admin tailnet; the apply mints node keys there | Admins lose the tailnet (the public API path for `ADMIN_CIDRS` stays); applies that create nodes wait up to 25 minutes, then fail | **Partly:** root on it can join a device tagged anything; the node APIs still want certificates | Rebuilt by one apply, no backup needed | c | Stays single; the tailnet carries only convenience once E01, E11 and E15 move | – | 0,00 |
| E26 | Disk KMS on `unfold-headscale` | U→X | Every encrypted node's STATE and EPHEMERAL unlock, at every boot | **A rebooting node stays locked**: Talos upgrades, kernel crashes and Hetzner host maintenance take nodes out until it is back; a new node cannot join | **Yes, disks:** its master key plus a disk image reads every node. The same project's tokens can image the box silently (ADR 0003) | Firewall to node addresses; unattended reboot at 04:30 is a minute | c, d | A second KMS in a separate Hetzner project as LUKS key slot 1, with its name in a zone not on Cloudflare; both master keys in the offline escrow (ADR 0015 §5) | M | 5,99 |
| E27 | Cloudflare (DNS for `webgrip.dev` and `unfoldhq.dev`; DNS-01; later the public tunnel and Access) | U→X | Name of the KMS and Headscale; cert-manager; RFC 0003's public endpoints | After resolver TTLs, nodes cannot find the KMS and cannot reboot; certificate renewals fail; public access stops | **Yes, through DNS:** see E12, plus certificates for any name | Zone-scoped tokens | a, c | Stays; the second KMS's name lives elsewhere so a Cloudflare outage cannot stop reboots | S | 0,00 |
| E28 | `ADMIN_CIDRS`, the homelab's and the owner's public addresses | U→X | Host firewall on 50000 and 6443; the KMS firewall | A changed home address locks CI and the owner out of the public API path until the variable changes | Whoever holds those addresses reaches the API ports, still needing credentials | Credentials on every port | c | Shrinks to the owner's devices once the runner moves into the cluster (E08) | S | 0,00 |
| E29 | Hetzner Cloud API | U→X | Cloud controller, CSI driver (volume attach), the API VIP's failover, cluster-autoscaler, OpenTofu | The VIP cannot move off a dead control plane (in-cluster clients use KubePrism and keep working); a pod with a volume cannot move; no autoscaling, no apply | **Yes, fully** | One token per job; delete protection; rate budget watch | a | Stays | – | 0,00 |
| E30 | Hetzner Console and account | U→X | Tokens, projects, rescue, support | Nothing at runtime | **Yes, fully**, including every project of the account | – | a | Stays; the backup and KMS project in a separate account limits a lost account (D3) | – | 0,00 |
| E31 | Hetzner Robot | U→X | Ordering, rescue and vSwitch for the metal node | No metal changes | **Yes**, for the metal node | Robot webservice user in OpenBao | a | Stays | – | 0,00 |
| E32 | Hetzner metadata service | U→X | Talos platform config on every boot (addresses, hostname), cloud-init on Headscale | A booting node cannot configure its network | Hetzner, as E29 | – | a | Stays | – | 0,00 |
| E33 | Let's Encrypt | U→X | The KMS's and Headscale's certificate; cert-manager | Renewals fail; an expired KMS certificate stops every reboot. Five certificates a week per name (rebuild drills count) | Mis-issuance only | 90-day certificates | a, c | Stays; a second ACME issuer in cert-manager and a certificate-expiry alert on the KMS endpoints | S | 0,00 |
| E34 | Upstream registries: `ghcr.io`, `quay.io`, `docker.io`, `registry.k8s.io` | U→X | Every image; Zot pulls through them and containerd falls back to them | New images and nodes cannot pull what is not cached. A booting node always pulls Cilium and the control plane upstream, before Zot runs. Zot forgets mirrored images not pulled in 30 days | No: everything is pinned by digest | Zot pull-through with fallback (`skipFallback: false`) | c | Talos image cache in the snapshot for the boot set; Zot keeps every pinned digest | M | 1,00 |
| E35 | `code.forgejo.org` registry | U→X | The CI runner image | No new CI pods | No: digest pin | – | c | Mirrored through Zot like the other four | S | 0,00 |
| E36 | Zot (in the cluster) | – | The pull-through cache, CI pushes, the Trivy database, signature lookups | containerd falls back upstream; CI pushes fail. One replica on the hub, an unencrypted volume | It serves digests only | Fallback by design | b | Already in; keep the boot set in it (E34) | – | 0,00 |
| E37 | Chart sources: `helm.cilium.io`, `charts.hetzner.cloud`, the `github.io` chart pages, OCI charts on `ghcr.io` and `quay.io`, the Flux distribution on `ghcr.io` | U→X | Flux source-controller and flux-operator | No upgrades; after a source-controller restart, releases cannot be re-rendered (running pods stay) | No: chart digests and versions are pinned | – | c | OCI charts pulled through Zot once Zot is not needed to install itself | M | 0,00 |
| E38 | Sidero Image Factory (`factory.talos.dev`) and the Talos installer | U→X | The Talos snapshot build, every Talos upgrade (the installer is named by tag) | No new Talos version or schematic; scaling from the existing snapshot still works | **Yes, at the next upgrade:** the installer is pulled by tag (digest pinning is in flight) | – | d | Installer pinned by digest and mirrored; the factory is self-hostable (MPL) if Sidero's terms change | M | 0,00 |
| E39 | Talos discovery service (`discovery.talos.dev`, the default) | U→X | Member hints for `talosctl get members`; KubeSpan is off | Nothing the cluster needs | Sees encrypted membership data; BUSL licence | – | b | Switch the service registry off | S | 0,00 |
| E40 | NTP (Talos default `time.cloudflare.com`) | U→X | Node clocks | Drift, tolerable for days | Time skew could expire certificates early | – | a | Add Hetzner's NTP servers as more sources | S | 0,00 |
| E41 | Headscale's install sources (`github.com` releases, `pkgs.tailscale.com`, the Ubuntu archive) | U→X | cloud-init of a new `unfold-headscale`; its unattended upgrades | A Headscale rebuild fails; security updates wait | Pinned versions and checksums | Pins | c | Stays; the rebuild drill proves it | – | 0,00 |
| E42 | CI tool downloads (`dl.k8s.io`, `github.com` releases) | U→X | `diagnose-cluster.sh`, the disk-encryption rollout | No diagnose run | No: checksums pinned | Checksums | c | Stays | – | 0,00 |
| E43 | Google Workspace | U→X | Upstream of Authentik today; the operators' IdP and an alert mail relay in the target | No human OIDC login | **Partly:** an operator identity, as E13 | Workspace 2-step verification | a | Stays (ADR 0014) | – | 0,00 |
| E44 | Model providers | U→X | LiteLLM's calls (ADR 0007) | Runs and the decider stop | No infrastructure change | Budgets per key | a | Stays | – | usage |
| E45 | The owner's password manager and offline copy (the T0 seed) | – | Break-glass for everything; the rebuild | – | It opens everything | Holds the passphrase, the age key, the tokens and the Talos bundle. **Gap:** not the disk KMS master key or the `hcloud-luks` passphrase, both only in the homelab OpenBao (and the state) | a | Add both now ([break-glass](../runbooks/break-glass.md#the-offline-seed)) | S | 0,00 |

## Classification

| Class | Items |
| --- | --- |
| (a) stays external, fine | E29 Hetzner Cloud API, E30 Hetzner account, E31 Robot, E32 metadata, E33 Let's Encrypt, E40 NTP, E43 Google Workspace, E44 model providers, E45 the offline seed; E27 Cloudflare with (c) |
| (b) moves into Unfold | E01 OpenBao, E08 the infra runner (as a second pool), E10 the variables, E12 the DNS records the apply needs, E19 LiteLLM, E39 discovery (off), E36 Zot (done) |
| (c) keeps, Unfold degrades gracefully | E02 to E05 (Forgejo, its key, Actions, the GitHub mirror), E07, E09, E11, E14 to E18, E20 to E23, E25, E26 with (d), E28, E34, E35, E37, E41, E42 |
| (d) replaced outside the homelab | E06 the Kata image copy, E13 Authentik by Google, E24 garage-fsn1 by two object-storage providers, E26's second KMS, E38 the installer mirror |

## Top risks

Ranked by what an outage stops times how likely it is, and by what a compromise can change.

1. **E01 homelab OpenBao.** One outage stops rotation, applies and rebuilds; one compromise owns production.
2. **E26 the disk KMS.** A single CX23 every reboot depends on; its master key is not in the offline seed (E45).
3. **E08 and E04 the homelab runner and Actions.** Every Hetzner token passes through shared homelab nodes, and no apply works without them.
4. **E11 the homelab gateway.** Down on 2026-10-26; a compromise can forge Secret values.
5. **E12 the homelab DNS publishers.** A Headscale in a new project gets no name, so no node unlocks.
6. **E24 garage-fsn1.** State and backups on one hand-run box in the same region, deletable with the write key.
7. **E15 alerting.** None of the above alerts while the homelab is down.
8. **E03 the Forgejo instance key.** A homelab compromise can get a tree signed that Flux accepts.
9. **E13 Authentik.** Operator sessions and tailnet devices are minted in the homelab.
10. **E38 the Talos installer by tag.** A compromised factory reaches every node at the next upgrade.

## Hosts the code names

`scripts/check-external-dependencies.sh` fails a pull request when the code names a host outside the
cluster that is not listed here, so a new dependency cannot land without a row above. Each host points
at its row.

| Host | Row |
| --- | --- |
| `unfold-gateway.webgrip.dev` | E11 |
| `headscale.webgrip.dev`, `headscale-drill.webgrip.dev` | E25, E26, E12 |
| `forgejo.webgrip.dev` | E02, E04, E06 |
| `harbor.webgrip.dev` | E09 |
| `authentik.webgrip.dev` | E13 |
| `s3-offsite.webgrip.dev` | E24 |
| `github.com` | E05, E41, E42 |
| `api.hetzner.cloud` | E29 |
| `robot-ws.your-server.de` | E31 |
| `api.cloudflare.com`, `cloudflare-dns.com` | E27 |
| `dns01-canary.unfold.unfoldhq.dev` | E27, E33 |
| `acme-v02.api.letsencrypt.org`, `acme-staging-v02.api.letsencrypt.org` | E33 |
| `ghcr.io`, `pkg-containers.githubusercontent.com` | E34, E37 |
| `quay.io`, `*.quay.io`, `cdn*.quay.io` | E34, E37 |
| `docker.io`, `registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com`, `production.cloudfront.docker.com`, `docker-images-prod.*.r2.cloudflarestorage.com` | E34 |
| `registry.k8s.io`, `cdn.registry.k8s.io`, `*-docker.pkg.dev` | E34 |
| `code.forgejo.org` | E35 |
| `helm.cilium.io`, `charts.hetzner.cloud`, `kedacore.github.io`, `prometheus-community.github.io`, `kubernetes.github.io`, `aquasecurity.github.io` | E37 |
| `factory.talos.dev` | E38 |
| `pkgs.tailscale.com` | E41 |
| `dl.k8s.io` | E42 |
| `slsa.dev`, `spdx.dev` | none: predicate type identifiers in attestations, never contacted |
| `ploeg.webgrip.dev` | none: a label and annotation prefix, never contacted |
