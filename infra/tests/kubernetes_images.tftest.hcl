mock_provider "hcloud" {
  mock_resource "hcloud_network" {
    defaults = {
      id = "101"
    }
  }

  mock_resource "hcloud_firewall" {
    defaults = {
      id = "102"
    }
  }

  mock_resource "hcloud_primary_ip" {
    defaults = {
      id = "103"
    }
  }

  mock_resource "hcloud_ssh_key" {
    defaults = {
      id = "104"
    }
  }

  mock_resource "hcloud_placement_group" {
    defaults = {
      id = "105"
    }
  }

  mock_resource "hcloud_server" {
    defaults = {
      id           = "106"
      ipv4_address = "198.51.100.10"
    }
  }

  mock_data "hcloud_images" {
    defaults = {
      images = []
    }
  }
}

mock_provider "talos" {}

mock_provider "helm" {}

mock_provider "tls" {}

mock_provider "external" {
  mock_data "external" {
    defaults = {
      result = {
        key             = "hskey-auth-mocked"
        state           = "ordered"
        product         = "AX41-NVMe"
        server_number   = "2345678"
        server_ip       = "198.51.100.40"
        monthly_net_eur = ""
        setup_net_eur   = ""
        id              = "31337"
        mac             = "a8:a1:59:0b:1c:2d"
      }
    }
  }
}

variables {
  state_passphrase     = "mock-passphrase-of-at-least-thirty-two-characters"
  admin_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMockOwnerKey owner"
  admin_cidrs          = ["203.0.113.7/32"]
}

run "talos_runs_every_kubernetes_image_by_digest" {
  command = plan

  assert {
    condition = alltrue([
      for component in ["kubelet", "apiServer", "controllerManager", "scheduler"] :
      can(regex("^[a-z0-9.-]+(/[a-z0-9._-]+)+:v[0-9]+\\.[0-9]+\\.[0-9]+@sha256:[0-9a-f]{64}$", local.kubernetes_images[component]))
    ])
    error_message = "talos/talenv.yaml must pin the kubelet, API server, controller manager and scheduler as repository:tag@sha256:digest"
  }

  assert {
    condition     = alltrue([for tag in values(local.kubernetes_image_tags) : tag == local.talenv.kubernetesVersion])
    error_message = "every kubernetesImages tag in talos/talenv.yaml must equal kubernetesVersion, so a Kubernetes upgrade moves all of them together"
  }

  assert {
    condition = alltrue([
      for component, image in local.talenv.kubernetesImages :
      length(regexall("depName=${replace(image.repository, ".", "\\.")}\\s*\\n\\s*reference: ${replace(image.reference, ".", "\\.")}\\n", file("${path.module}/../talos/talenv.yaml"))) == 1
    ])
    error_message = "each kubernetesImages reference in talos/talenv.yaml needs the `# renovate:` line naming its own repository directly above it, or Renovate freezes it or moves it to another image's digest"
  }

  assert {
    condition = alltrue([
      contains(local.control_plane_patches, yamlencode({ apiVersion = "v1alpha1", kind = "KubeAPIServerConfig", image = local.kubernetes_images.apiServer })),
      contains(local.control_plane_patches, yamlencode({ apiVersion = "v1alpha1", kind = "KubeControllerManagerConfig", image = local.kubernetes_images.controllerManager })),
      contains(local.control_plane_patches, yamlencode({ apiVersion = "v1alpha1", kind = "KubeSchedulerConfig", image = local.kubernetes_images.scheduler })),
      contains(local.control_plane_patches, yamlencode({ apiVersion = "v1alpha1", kind = "KubeCoreDNSConfig", image = local.coredns_image })),
    ])
    error_message = "the control planes must run the API server, controller manager, scheduler and CoreDNS from the pinned references, or Talos falls back to tags"
  }

  assert {
    condition = alltrue([
      contains(local.common_patches, local.kubelet_image_patch),
      contains(local.node_patches, local.kubelet_image_patch),
      yamldecode(local.kubelet_image_patch).image == local.kubernetes_images.kubelet,
    ])
    error_message = "every node, cloud, autoscaled and metal alike, must run the kubelet from the pinned reference"
  }

  assert {
    condition = alltrue([
      can(regex("^registry\\.k8s\\.io/coredns/coredns:v[0-9]+\\.[0-9]+\\.[0-9]+@sha256:[0-9a-f]{64}$", local.coredns_image)),
      local.coredns_deployment.metadata.name == "coredns",
      local.coredns_deployment.metadata.namespace == "kube-system",
      local.coredns_deployment.spec.selector.matchLabels == { "k8s-app" = "kube-dns" },
      local.coredns_deployment.metadata.annotations["kustomize.toolkit.fluxcd.io/prune"] == "disabled",
      contains(yamldecode(file("${path.module}/../kubernetes/clusters/main/kustomization.yaml")).resources, "../../platform/coredns"),
    ])
    error_message = "Flux must own Talos's kube-system/coredns Deployment with the same selector, a digest-pinned image and pruning disabled, and the Talos seed must read the same image from kubernetes/platform/coredns/deployment.yaml"
  }
}
