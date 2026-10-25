# Talos registry mirrors

Every node's containerd asks Zot first for images from `docker.io`, `ghcr.io`, `quay.io` and `registry.k8s.io`, and goes to the registry itself when Zot cannot answer. The four `RegistryMirrorConfig` documents are in [infra/registry-mirrors.tf](../../infra/registry-mirrors.tf), part of every machine config, and [infra/tests/registry_mirrors.tftest.hcl](../../infra/tests/registry_mirrors.tftest.hcl) pins them. Zot itself is in `kubernetes/platform/zot` (runbook `zot-registry.md`).

| Registry | Mirror endpoint | Fallback to upstream |
| --- | --- | --- |
| `docker.io` | `http://127.0.0.1:30500/v2/docker.io` | yes |
| `ghcr.io` | `http://127.0.0.1:30500/v2/ghcr.io` | yes |
| `quay.io` | `http://127.0.0.1:30500/v2/quay.io` | yes |
| `registry.k8s.io` | `http://127.0.0.1:30500/v2/registry.k8s.io` | yes |

`overridePath: true` makes containerd append the image path to the endpoint as given, so `quay.io/cilium/cilium` is asked for as `quay.io/cilium/cilium` in Zot, which is where Zot's sync stores it. Other registries, such as `factory.talos.dev`, are pulled directly as before.

## Why there is no chicken-and-egg

The endpoint is the Zot Service's NodePort on the node's own loopback address, not a Service IP and not a DNS name. Cilium's kube-proxy replacement translates a connection from the node's own network namespace to `127.0.0.1:<nodePort>` into a connection to the Zot pod, wherever it runs. The Talos host firewall accepts everything on `lo`.

| Situation | What containerd sees | Result |
| --- | --- | --- |
| A node boots, Cilium not yet running | nothing listens on `127.0.0.1:30500`: connection refused at once | pulls Cilium, the kubelet and everything else from upstream |
| Cilium runs, Zot has no ready pod (first install, restart, Zot's own image being pulled) | Cilium fails a connection to a Service without endpoints at once | upstream |
| Zot runs, image cached | served from Zot | nothing leaves the cluster |
| Zot runs, image not cached | Zot fetches it from upstream, then serves it | one upstream download for the whole cluster |
| Zot runs, upstream down | Zot answers an error | containerd tries upstream too, as it would without a mirror |

A Service IP would not work as well. Before Cilium runs, a node routes `10.66.0.0/16` out to the default gateway, which drops it silently, so every request during a boot would wait out the dial timeout Talos writes into `hosts.toml` (200 ms) before falling back. The loopback port fails at once and is the same address on every node. The homelab mirrors through a NodePort the same way. A DNS name would not resolve at all, because containerd uses the host resolver, not CoreDNS.

`skipFallback` stays `false`. RFC 0001 wants `true`, so that no node pulls from the internet, but that needs the bootstrap images baked into the Talos snapshot first (`ImageCacheConfig`, RFC 0001 section 1). Until then, a node with `skipFallback: true` could not boot while Zot is down, and Zot cannot run before the nodes have booted.

The order of merging does not matter. With this config applied before Zot exists, every pull is refused at the mirror and falls back, as it does today.

## Checks after an apply

- Talos wrote the mirror for containerd, read-only: `talosctl -n <node> read /etc/cri/conf.d/hosts/quay.io/hosts.toml` has a `[host.'http://127.0.0.1:30500/v2/quay.io']` section with `override_path = true`.
- Pulls go through Zot: after a pod starts with an image the node did not have, `kubectl -n zot logs zot-0 | grep -i "on demand"` shows that image's repository being synced. If no node pull ever appears there while new pods start, containerd is falling back every time; look in Hubble for dropped flows from `host` or `remote-node` to Zot on port 5000.
- The fallback works: while Zot is scaled to zero, a new image still starts. Do this on purpose once, in a quiet moment, by setting the StatefulSet to zero replicas in Git; containerd must fall back without delay.
