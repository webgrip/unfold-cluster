# Kubernetes upgrades

Talos runs the kubelet, the API server, the controller manager, the scheduler and CoreDNS. Every one of them runs from a `tag@sha256:digest` reference, so `immutable-image-references` can refuse tag-only images in `kube-system` as it does everywhere else ([admission policies](admission-policies.md)), and a registry that re-points a tag cannot change what a node runs.

## Where the references live

| Image | File | Reaches the cluster through |
| --- | --- | --- |
| kubelet | `talos/talenv.yaml`, `kubernetesImages.kubelet` | `KubeletConfig.image` on every node, cloud, autoscaled and metal |
| kube-apiserver | `talos/talenv.yaml`, `kubernetesImages.apiServer` | `KubeAPIServerConfig.image`, a static pod on each control plane |
| kube-controller-manager | `talos/talenv.yaml`, `kubernetesImages.controllerManager` | `KubeControllerManagerConfig.image`, a static pod |
| kube-scheduler | `talos/talenv.yaml`, `kubernetesImages.scheduler` | `KubeSchedulerConfig.image`, a static pod |
| CoreDNS | `kubernetes/platform/coredns/deployment.yaml` | Flux, which owns the `kube-system/coredns` Deployment; OpenTofu reads the same image into `KubeCoreDNSConfig.image`, so a new cluster boots with it |

`kubernetesVersion` in `talos/talenv.yaml` names the release, and every tag under `kubernetesImages` must equal it: the `infra` plan refuses anything else (preconditions on `data.talos_machine_configuration.worker`), and so does the OpenTofu test `infra/tests/kubernetes_images.tftest.hcl`, which also checks that each reference has the `# renovate:` line naming its own repository directly above it.

Talos creates CoreDNS once, at bootstrap, and never updates it afterwards: its bootstrap manifests are create-only (the README's seed section). Flux therefore owns the Deployment, with the selector and pod template Talos renders, and `kustomize.toolkit.fluxcd.io/prune: disabled` so a deleted file never removes cluster DNS. Talos still owns the CoreDNS ConfigMap, Service, ServiceAccount and RBAC. Replicas, spread and requests for CoreDNS are edits to that file.

## Upgrading Kubernetes

1. Renovate opens one pull request, group `kubernetes`, after approval on the dependency dashboard. It moves `kubernetesVersion` and the four `kubernetesImages` references with their digests. A manual bump does the same; take each digest from the registry as the multi-arch index digest (`crane digest registry.k8s.io/kube-apiserver:v1.37.2`).
2. Merge it. Nothing running changes yet.
3. Run the `infra` workflow: read the plan, then dispatch `apply` with its digest ([infra workflow](infra-workflow.md)). The plan shows `talos_machine_configuration_apply` updated in place for every node, and the autoscaled pools' worker config changing. Nothing is replaced.
4. Talos applies each machine config without a reboot. On each control plane it restarts the three static pods with the new references, and on every node it restarts the kubelet; running pods keep running. OpenTofu applies the nodes in parallel, so the three API servers restart within seconds of each other and the API is briefly unavailable; apply when no one is deploying.
5. Check that `kubectl -n kube-system get pods -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}' | sort -u` lists only digest-pinned images, and that `kubectl get nodes` shows the new kubelet version.

A minor upgrade moves the kubelet and the control plane in the same apply, as it did before the references were pinned. Read the release's upgrade notes for removed APIs first.

CoreDNS moves on its own: Renovate's Kubernetes manager updates the image in `kubernetes/platform/coredns/deployment.yaml`, Flux rolls the two replicas on merge, one at a time, and the next `infra` apply carries the same image into the Talos seed.

## Never use the Talos Kubernetes upgrade command

The `upgrade-k8s` subcommand of `talosctl` writes the static pod images back as `registry.k8s.io/kube-apiserver:v<version>`, without a digest. The API server's mirror pods would then be refused in `kube-system`, and the next `infra` apply would write the digests back anyway, because OpenTofu owns the machine configs. Kubernetes upgrades here go through OpenTofu only.
