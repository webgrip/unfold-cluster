# Operations consoles

Three web consoles show what the cluster's security and operations features are doing, on the
tailnet only, behind Authentik:

| Console | URL | What it shows | Who gets in |
| --- | --- | --- | --- |
| Hubble UI | `https://hubble.ops.unfoldhq.dev` | live flows per namespace, every egress verdict, which policy allowed or dropped a connection | `unfold-admins`, `unfold-viewers` (oauth2-proxy, client `unfold-consoles`) |
| Policy Reporter | `https://policy-reporter.ops.unfoldhq.dev` | Kyverno's PolicyReports (the webgrip image-signature audits) and Trivy's vulnerability, config-audit, RBAC and exposed-secret reports, converted to PolicyReports | `unfold-admins`, `unfold-viewers` (same) |
| Headlamp | `https://headlamp.ops.unfoldhq.dev` | the Kubernetes objects, as the signed-in person | anyone in the two groups; what they see and do is their own RBAC: `unfold-viewer` reads everything but Secrets, `unfold-operator` also deletes and evicts pods and cordons and drains ([kubernetes-login](kubernetes-login.md)) |

The Grafana dashboards for the same features are in `kubernetes/platform/ops-consoles/dashboards/`
(see [Dashboards](#dashboards)).

## How a request gets in

```
browser on the tailnet
  │  DNS: Headscale's extra_records answer *.ops.unfoldhq.dev with 10.64.0.10 (tailnet clients only)
  ▼
10.64.0.10:443, the API address, held by one control plane; the control planes route 10.64.0.0/24 to the tailnet
  │  Talos host firewall: 443 open to the tailnet prefixes and 10.64.0.0/16 only (infra/host-firewall.tf)
  ▼
Cilium's Envoy on the host network (Gateway API, Gateway ops-gateway/ops, hostNetwork mode, control planes only)
  │  TLS: *.ops.unfoldhq.dev from Let's Encrypt over DNS-01 (Certificate ops-gateway/ops-wildcard)
  ▼
HTTPRoute ── oauth2-proxy (Hubble, Policy Reporter) ── the console
         └── Headlamp, which runs its own OIDC login
```

Nothing is public: the names exist only in the tailnet's DNS, the address is private, and the
Hetzner firewall opens no port to the internet. RFC 0001 step 11 (the public gateway) is a
separate thing and is not built.

**Why the host network.** Hetzner Cloud networks route only the addresses Hetzner assigned, so a
LoadBalancer address announced by Cilium would not reach a node, and a Hetzner load balancer costs
money. The control planes already hold the one address the tailnet routes to them. In hostNetwork
mode Cilium still creates the Gateway's Service, as a NodePort with an operator-chosen port; the
`service-exposure` admission policy grants exactly `ops-gateway/cilium-gateway-ops`, and only while
a Gateway owns it.

**Why the Gateway API CRDs are vendored.** Cilium's operator looks for them once, at start. They
are in the root Kustomization next to Cilium (`kubernetes/platform/gateway-api`), so Flux applies
them before the HelmRelease that turns the Gateway controller on. `scripts/test-ops-consoles.sh`
checks the file against the pinned upstream release.

## How the logins reach Authentik

Authentik answers on the homelab LAN only; its public tunnel carries discovery and signing keys
for `unfold-kubernetes` and nothing else. The browser part of a login goes from the person's
browser (on the homelab LAN or VPN, as for kubectl). The code and refresh-token exchanges are made
by oauth2-proxy and Headlamp from inside the cluster, so they need a path:

```
oauth2-proxy / Headlamp ── HTTPS_PROXY ──▶ ops-auth/authentik-relay (Envoy, on the hub)
   CONNECT authentik.webgrip.dev:443, the only authority it accepts; anything else is a 403
  ──▶ unfold-gateway.webgrip.dev:443 over the tailnet (tag:hub may open it, ADR 0006)
  ──▶ the homelab's internal gateway ──▶ Authentik, TLS end to end against the real host name
```

Three controls hold the path: the Headscale policy lets only `tag:hub` (and the Headscale server)
open the gateway's 443; the Cilium policy lets only the relay pod open it, and only the oauth2-proxy
pods and Headlamp reach the relay; and the relay forwards one authority. `scripts/test-ops-consoles.sh
--mutation-test` proves the relay tunnels Authentik, refuses other hosts and ports, and that the
allowlist is what decides.

Clients:

- `unfold-kubernetes` (public, PKCE, passkey step) for Headlamp, so the ID token is one the API
  server accepts and RBAC applies per person. Headlamp's service account has no role; it exists
  because the in-cluster client needs a token file, and Headlamp does not use it.
- `unfold-consoles` (confidential) for oauth2-proxy. Its secret is generated in the homelab and
  read here from OpenBao `secret/unfold-main/ops-consoles/oidc` (`client_secret`). The cookie
  secrets are generated in the cluster by an External Secrets `Password` generator and never leave it.

Both ask for the scope `unfold_kubernetes`, whose claim `unfold_groups` carries only `unfold-admins`
and `unfold-viewers`; oauth2-proxy admits exactly those two.

## Footprint

| Workload | Namespace | Placement | CPU request | Memory request / limit |
| --- | --- | --- | --- | --- |
| Hubble UI (frontend + backend) | `kube-system` | system pool, else hub, else control planes | 10m | 40Mi / 160Mi |
| oauth2-proxy-hubble | `ops-auth` | same | 5m | 24Mi / 64Mi |
| oauth2-proxy-policy-reporter | `ops-auth` | same | 5m | 24Mi / 64Mi |
| authentik-relay | `ops-auth` | hub only (its tailnet tag) | 5m | 24Mi / 64Mi |
| policy-reporter | `policy-reporter` | system, hub, control planes | 10m | 48Mi / 160Mi |
| policy-reporter-ui | `policy-reporter` | same | 5m | 32Mi / 96Mi |
| trivy-operator-polr-adapter | `policy-reporter` | same | 10m | 48Mi / 192Mi |
| headlamp | `headlamp` | same | 10m | 48Mi / 192Mi |
| Gateway listener | Cilium's existing Envoy DaemonSet | control planes | 0 | 0 new pods |
| **Total** | | | **60m** | **288Mi / 992Mi** |

Every pod is pinned by digest, approved by `pinned-approved-images`, runs restricted (non-root,
no privilege escalation, all capabilities dropped, RuntimeDefault seccomp, read-only root), and has
requests, a memory and an ephemeral-storage limit and size-limited emptyDirs. The admitted fixtures
`tests/admission-policies/*/admitted-ops-consoles.yaml` are these pods.

## Egress

| Pods | Destination | Port | Why |
| --- | --- | --- | --- |
| authentik-relay | `unfold-gateway.webgrip.dev` (FQDN, DNS through Cilium's proxy) | 443 | Authentik's endpoints behind the homelab gateway |
| oauth2-proxy-* | authentik-relay | 3128 | OIDC |
| oauth2-proxy-hubble | `kube-system/hubble-ui` | 8081 | upstream |
| oauth2-proxy-policy-reporter | `policy-reporter/policy-reporter-ui` | 8080 | upstream |
| headlamp | `kube-apiserver`; authentik-relay | 6443; 3128 | the person's API calls; OIDC |
| policy-reporter, its UI, the Trivy adapter | `kube-apiserver` | 6443 | reports |
| hubble-ui (staged, kube-system) | kube-dns, `kube-apiserver`, hubble-relay | 53, any, 4245 | flows |

Ingress to oauth2-proxy and Headlamp is from Cilium's `ingress` identity (the Gateway's Envoy) only.

## Dashboards

Six GrafanaDashboard CRs, folder `unfold` of the Grafana with label
`grafana.webgrip.io/instance: unfold`: Tetragon runtime events, Trivy vulnerabilities, Kyverno
image-signature audits, admission denials from the API audit log, Hubble egress verdicts, and cost
(this cluster's requests, with a link to the homelab's **Executive / FinOps & Cost**). They name
their datasources by UID: `unfold-prometheus`, `victorialogs` and `victorialogs-audit`, which the
in-cluster observability stack defines. The directory is not yet in `kubernetes/clusters/main`:
add it to the observability stack's Kustomization (or a Flux Kustomization that depends on it)
once the Grafana operator and its CRDs run here.

## After the merge

1. The pending infra apply must have run, then this PR's apply: it opens 443 on the control planes,
   adds `tag:hub` to the gateway's 443 and pushes the Headscale DNS records.
2. Flux applies the CRDs, turns on Cilium's Gateway controller and rolls the Cilium agents, operator
   and Envoy (the values set `rollOutPods`); the DNS proxy restarts with the agent, so name
   lookups pause for a few seconds per node.
3. Checks:

   ```sh
   kubectl get gatewayclass cilium
   kubectl -n ops-gateway get gateway ops            # PROGRAMMED True
   kubectl -n ops-gateway get certificate ops-wildcard  # Ready True
   kubectl -n ops-auth get externalsecret            # SecretSynced
   kubectl get httproute -A
   dig +short hubble.ops.unfoldhq.dev                # on a tailnet device: 10.64.0.10
   curl -sI https://hubble.ops.unfoldhq.dev | head -3  # 302 to authentik.webgrip.dev
   ```

   Then sign in to each console as a viewer and as an admin: in Headlamp the viewer's delete
   button on a pod answers 403 and the admin's works.

## When it does not work

| Symptom | Look at |
| --- | --- |
| The name does not resolve | the device uses Headscale's DNS (`tailscale up --accept-dns`); `tailscale dns status` lists the records |
| Connection refused or times out | `kubectl -n ops-gateway get gateway ops -o yaml` status; the host firewall rule `ops-gateway-ingress` on the control planes; `kubectl -n kube-system logs ds/cilium-envoy` |
| Certificate warning | `kubectl -n ops-gateway describe certificate ops-wildcard`, then [certificates](certificates.md) |
| oauth2-proxy shows 500 after the login | its log; `x509` or timeouts mean the relay path: `kubectl -n ops-auth logs deploy/authentik-relay`, and Hubble on `ops-auth` drops |
| 403 from oauth2-proxy | the person holds neither group; the grant is in homelab `access-plane/model/people.yaml` |
| Headlamp signs in but shows nothing | the API server refused the token: `kubectl auth whoami` with the OIDC kubeconfig as the same person |
