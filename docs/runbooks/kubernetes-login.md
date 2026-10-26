# Kubernetes login

People reach this cluster's Kubernetes API as themselves, through Authentik in the homelab. The
admin kubeconfig from `tofu output -raw kubeconfig` is break-glass only. RFC 0001, section 2.

## Daily use

You need the tailnet (the API is `https://10.64.0.10:6443`) and the homelab LAN or its
WireGuard VPN (the Authentik login page is not public). Then, from this repository:

```sh
mise install
export KUBECONFIG="$PWD/access/unfold-oidc.kubeconfig.yaml"
mise exec -- kubectl auth whoami
mise exec -- k9s
```

The first call opens a browser on `http://localhost:8000` (or `18000` when 8000 is taken): sign
in to Authentik, which signs you in through Google, then asks for your passkey or security key
(the homelab `unfold-kubernetes` application runs the `webgrip-passkey-authorization` flow, user
verification required). Without an enrolled passkey the login is refused; enroll one first under
Authentik **Settings → MFA Devices → Passkey or security key**. kubelogin's PKCE login runs in your
browser, which performs the WebAuthn step, so nothing changes on the command line. Expect
`Username: oidc:<your Authentik user name>` and `Groups: [oidc:unfold-admins system:authenticated]`.
The ID token lives 15 minutes; kubelogin renews it silently with the refresh token for 12 hours,
without the passkey, then opens the browser again and asks for it.
Tokens are cached in `~/.kube/cache/oidc-login`; delete that directory to sign out.

The kubeconfig is committed and holds no secret: a public client, the cluster address and the
cluster's CA certificate. k9s reads the same `KUBECONFIG`; its `:ctx` view shows one context,
`unfold-oidc`. Run both through `mise exec --` (or with mise activated in your shell), because
kubectl finds the `oidc-login` plugin on the `PATH` mise sets.

## Who may do what

Membership is declared in homelab-cluster, `kubernetes/apps/security/access-plane/model/`:
a grant in `people.yaml` of a capability in `capabilities.yaml`. Nobody is added in the
Authentik UI; the access plane reverts it.

| Authentik group | Capability | ClusterRole here | May | May not |
| --- | --- | --- | --- | --- |
| `unfold-viewers` | `unfold-cluster-view` | `unfold-viewer` | read every resource in every namespace except Secrets, plus nodes, CRDs, storage, admission policies, RBAC and Cilium policies | change anything |
| `unfold-admins` | `unfold-cluster-operate` | `unfold-operator` | everything a viewer may, plus delete pods, evict pods and cordon or drain nodes | read Secrets; `exec`, `attach`, `port-forward`; change any spec, Flux object or RBAC |

Changes to what runs go through Git. Patching a Flux object is left out on purpose: a patched
Kustomization applies anything with Flux's own rights. `exec` is left out because a shell in a
pod reads every Secret the pod mounts.

The roles are in `kubernetes/platform/human-access/`. `unfold-viewer` aggregates the built-in
`view` (which Flux's CRDs also aggregate into) and `unfold-viewer-cluster-scope`;
`unfold-operator` aggregates those and `unfold-operator-actions`.

## How the API server checks a token

`infra/kube-apiserver.tf` gives Talos a `KubeAuthenticationConfig` (Kubernetes'
`AuthenticationConfiguration`; Talos passes `--authentication-config` itself and rejects
`--oidc-*` flags):

| Setting | Value |
| --- | --- |
| Issuer | `https://authentik.webgrip.dev/application/o/unfold-kubernetes/` |
| Audience | `unfold-kubernetes`, the client id |
| User name | `preferred_username`, prefixed `oidc:` |
| Groups | the claim `unfold_groups`, prefixed `oidc:` |
| UID | `sub` |

Three claim rules reject a token with `401` before RBAC runs:

1. `unfold_groups` must hold `unfold-admins` or `unfold-viewers`. Authentik's own `groups`
   claim lists every homelab group; `unfold_groups` comes from the scope `unfold_kubernetes`
   and carries only these two, so no homelab group name reaches this cluster.
2. `exp - iat` must be at most 960 seconds, so a misconfigured provider cannot hand out
   long-lived tokens.
3. `preferred_username` must be a plain lower-case name.

The `oidc:` prefix means every legitimate principal is `system:…` or `oidc:…`; anything else
calling the API is the admin certificate.

The API servers fetch the issuer's discovery document and signing keys over the internet.
Authentik is LAN-only, so homelab-cluster's Cloudflare tunnel publishes exactly those two paths
for this provider and answers 404 to everything else on that host name (homelab-cluster
`docs/techdocs/docs/general/authentik.md`, "The one public path"). Check it:

```sh
curl -s --doh-url https://1.1.1.1/dns-query https://authentik.webgrip.dev/application/o/unfold-kubernetes/jwks/
```

### What this depends on, and what it costs

- **The homelab.** Signing in needs Authentik, its database and the tunnel. When the homelab is
  down, nobody signs in and the break-glass kubeconfig is the way in. Tokens already issued keep
  working until they expire.
- **A compromised homelab is a compromised login.** Whoever controls Authentik can mint a token
  with `unfold_groups: [unfold-admins]`. The blast radius is the operator role above, not
  cluster-admin, and every call lands in the audit log under the name in the token. This is one
  of the homelab-to-production edges RFC 0001's threat model still lists as open.

## Audit log

`infra/kube-apiserver.tf` also gives Talos a `KubeAuditPolicyConfig`. Talos writes the log on
each control plane at `/var/log/audit/kube/kube-apiserver.log` (JSON lines, rotated at 100 MB,
10 files, 30 days). The log-shipping stream reads that file.

| Level | What |
| --- | --- |
| None | health, version, metrics and discovery URLs; every `watch`; leases; events; `selfsubject*reviews`; `get` and `list` by kubelets (`system:nodes`) |
| Metadata | Secrets, ConfigMaps, `serviceaccounts/token`, TokenReviews: who and what, never the body |
| RequestResponse | `exec`, `attach`, `port-forward`, ephemeral containers and the proxy subresources; writes to RBAC, admission policies and webhooks, CRDs, network policies (Kubernetes and Cilium), CSRs and namespaces |
| Metadata | everything else |

Rejected tokens are logged as `401` events with the request URI, so a run of failed sign-ins
is visible.

## Break-glass

The Talos-issued admin kubeconfig is in `system:masters` and bypasses RBAC; it cannot be
revoked short of rotating the cluster CA. Keep it in a file that takes a deliberate flag:

```sh
chmod 600 ~/.kube/unfold-break-glass.yaml
mise exec -- kubectl --kubeconfig ~/.kube/unfold-break-glass.yaml get nodes
```

Use it only when OIDC itself is broken: the homelab or the tunnel is down, Authentik rejects
you, or the API server rejects every token. Missing permissions are a change to `people.yaml`.
Every call it makes shows in the audit log as user `admin`.

## When the cluster CA changes

A rebuild or a CA rotation gives the API server a new certificate. Replace
`certificate-authority-data` in `access/unfold-oidc.kubeconfig.yaml` with the one in
`tofu output -raw kubeconfig`, in the same pull request.

## Proving it after the merge

Run after the infra apply has reached all three control planes.

1. The config is live: `mise exec -- kubectl --kubeconfig ~/.kube/unfold-break-glass.yaml -n
   kube-system logs kube-apiserver-unfold-cp-1 | grep -i 'jwt\|oidc'` shows no initialisation
   error.
2. The owner gets in: `mise exec -- kubectl auth whoami` shows `oidc:ryangr0` in
   `oidc:unfold-admins`; `mise exec -- kubectl get nodes` lists four nodes.
3. RBAC holds (`403`): `mise exec -- kubectl get secrets -A` and
   `mise exec -- kubectl auth can-i create pods --subresource=exec -A` (prints `no`) are refused.
4. A token without the group is refused (`401`): sign in once without the scope that carries
   the group, then call the API with that token.

   ```sh
   mise exec -- kubectl oidc-login get-token \
     --oidc-issuer-url=https://authentik.webgrip.dev/application/o/unfold-kubernetes/ \
     --oidc-client-id=unfold-kubernetes --oidc-pkce-method=S256 \
     --oidc-extra-scope=profile --token-cache-storage=none \
     | jq -r .status.token > /tmp/no-group.jwt
   mise exec -- kubectl --token="$(cat /tmp/no-group.jwt)" auth whoami
   rm /tmp/no-group.jwt
   ```

   Expect `error: You must be logged in to the server (Unauthorized)`. Then step 2 again: the
   same person with the scope gets in, so the rule and not the person made the difference.
5. The audit log has both: `talosctl -n 10.64.0.11 read /var/log/audit/kube/kube-apiserver.log
   | jq -c 'select(.user.username=="oidc:ryangr0") | {verb, code: .responseStatus.code}' | tail`
   shows your `200`s and the `403`s from step 3; the `401` from step 4 shows as an event with
   `responseStatus.code` 401.

### Proving the passkey step

Two checks: the passkey is asked, and refusing it ends the login.

1. Sign out (`rm -rf ~/.kube/cache/oidc-login`) and run `mise exec -- kubectl auth whoami`. After
   the Google sign-in, Authentik shows **Confirm with your passkey**; touch the key or unlock the
   device. `whoami` then shows `oidc:<you>`. In Authentik **Settings → MFA Devices**, the passkey's
   *Last used* time is now.
2. Sign out again, run the same command and cancel the passkey prompt. Authentik refuses the
   authorization, kubelogin gets no token, and kubectl fails. No token was issued, so the API
   server sees no request.

### Proven before the merge

The same `AuthenticationConfiguration`, audit policy and roles were run on
`registry.k8s.io/kube-apiserver:v1.37.1` and `kube-controller-manager:v1.37.1` in Docker, with
a local issuer standing in for Authentik (only the issuer URL and its CA differed):

| Token | Result |
| --- | --- |
| admin group | `oidc:ryangr0`, groups `oidc:unfold-admins`; list nodes yes, delete pods yes, evict yes, cordon yes; Secrets, exec, port-forward, patch deployments, create bindings no |
| viewer group | `oidc:yon`; list pods, nodes, CRDs yes; delete pods, evict, Secrets no |
| no `unfold_groups` claim; only a homelab group; wrong audience; one-hour lifetime; user name `system:admin` | `401 Unauthorized` |

A Secret created and read through the break-glass token appeared in the audit log at
`Metadata` with no body and its value nowhere in the file; a ClusterRoleBinding create was
logged at `RequestResponse`. The first version of the group rule did not compile in the API
server (`claims.?x.orValue([])` is typed `any`, not a list): `talosctl validate` accepted it,
and on the nodes it would have stopped all three API servers. Run a changed rule through a real
API server before merging.
