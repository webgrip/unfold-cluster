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

run "flux_owns_coredns_and_the_talos_seed_installs_the_same_files" {
  command = plan

  assert {
    condition     = contains(local.control_plane_patches, local.talos_coredns_disabled_patch) && yamldecode(local.talos_coredns_disabled_patch) == { apiVersion = "v1alpha1", kind = "KubeCoreDNSConfig", enabled = false }
    error_message = "Talos's own CoreDNS must be off (KubeCoreDNSConfig enabled: false): Talos cannot spread its replicas, and a Kubernetes upgrade through talosctl would put its Deployment back over Flux's"
  }

  assert {
    condition     = contains([for manifest in local.inline_manifests : manifest.name if manifest.contents == local.coredns_manifest], "coredns")
    error_message = "the Talos seed must install CoreDNS from kubernetes/platform/coredns, because Flux needs cluster DNS to fetch its source"
  }

  assert {
    condition = [for document in split("\n---\n", trimprefix(local.coredns_manifest, "---\n")) : yamldecode(document)] == [
      for coredns_file in local.coredns_files : yamldecode(file("${path.module}/../kubernetes/platform/coredns/${coredns_file}"))
    ]
    error_message = "the seed's CoreDNS must be exactly the files Flux reconciles, one object per file in kustomization order"
  }

  assert {
    condition = alltrue([
      join(",", keys(yamldecode(file("${path.module}/../kubernetes/platform/coredns/kustomization.yaml")))) == "apiVersion,kind,resources",
      contains(yamldecode(file("${path.module}/../kubernetes/clusters/main/kustomization.yaml")).resources, "../../platform/coredns"),
    ])
    error_message = "Flux must reconcile kubernetes/platform/coredns from kubernetes/clusters/main with no namespace, patch or generator, so it owns the very objects the seed installs"
  }

  assert {
    condition = alltrue([
      for coredns_file in local.coredns_files :
      yamldecode(file("${path.module}/../kubernetes/platform/coredns/${coredns_file}")).metadata.annotations["kustomize.toolkit.fluxcd.io/prune"] == "disabled"
    ])
    error_message = "every CoreDNS object carries kustomize.toolkit.fluxcd.io/prune: disabled, so deleting or moving a file never takes cluster DNS down"
  }

  assert {
    condition     = yamldecode(file("${path.module}/../kubernetes/platform/coredns/service.yaml")).spec.clusterIP == cidrhost(local.service_subnet, 10)
    error_message = "the kube-dns Service keeps the tenth address of the service subnet, the address every kubelet hands its pods as their resolver"
  }
}

run "coredns_runs_on_two_control_planes_and_keeps_one_through_a_drain" {
  command = plan

  assert {
    condition = alltrue([
      yamldecode(file("${path.module}/../kubernetes/platform/coredns/deployment.yaml")).spec.replicas >= 2,
      yamldecode(file("${path.module}/../kubernetes/platform/coredns/deployment.yaml")).spec.template.spec.nodeSelector["node-role.kubernetes.io/control-plane"] == "",
    ])
    error_message = "CoreDNS runs at least two replicas, on the control planes with the rest of the recovery set (ADR 0013)"
  }

  assert {
    condition = anytrue([
      for constraint in yamldecode(file("${path.module}/../kubernetes/platform/coredns/deployment.yaml")).spec.template.spec.topologySpreadConstraints :
      constraint.topologyKey == "kubernetes.io/hostname" && constraint.maxSkew == 1 && constraint.whenUnsatisfiable == "DoNotSchedule" && constraint.labelSelector.matchLabels == { "k8s-app" = "kube-dns" }
    ])
    error_message = "CoreDNS spreads over the nodes with maxSkew 1 and DoNotSchedule: on 2026-10-26 both replicas ran on unfold-cp-2, so losing one node took cluster DNS down; a preferred anti-affinity alone allowed that"
  }

  assert {
    condition = alltrue([
      yamldecode(file("${path.module}/../kubernetes/platform/coredns/poddisruptionbudget.yaml")).spec.maxUnavailable == 1,
      yamldecode(file("${path.module}/../kubernetes/platform/coredns/poddisruptionbudget.yaml")).spec.selector.matchLabels == yamldecode(file("${path.module}/../kubernetes/platform/coredns/deployment.yaml")).spec.selector.matchLabels,
      contains(local.coredns_files, "poddisruptionbudget.yaml"),
    ])
    error_message = "a PodDisruptionBudget with maxUnavailable 1 over the CoreDNS pods keeps one replica answering through a node drain"
  }
}
