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
        key = "hskey-auth-mocked"
      }
    }
  }
}

variables {
  state_passphrase     = "mock-passphrase-of-at-least-thirty-two-characters"
  admin_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMockOwnerKey owner"
  admin_cidrs          = ["203.0.113.7/32"]
}

run "kube_proxy_is_off_because_cilium_replaces_it_through_kubeprism" {
  command = plan

  assert {
    condition = alltrue([
      contains(local.control_plane_patches, local.kube_proxy_disabled_patch),
      yamldecode(local.kube_proxy_disabled_patch) == { apiVersion = "v1alpha1", kind = "KubeProxyConfig", enabled = false },
    ])
    error_message = "the control planes must carry a KubeProxyConfig with enabled: false; deleting the document falls back to the v1alpha1 default, which deploys kube-proxy"
  }

  assert {
    condition     = !anytrue([for patch in concat(local.common_patches, local.control_plane_patches) : try(yamldecode(patch).kind, "") == "KubeProxyConfig" && try(yamldecode(patch)["$patch"], "") == "delete"])
    error_message = "a $patch: delete on KubeProxyConfig turns kube-proxy back on"
  }

  assert {
    condition = alltrue([
      yamldecode(file("${path.module}/../kubernetes/platform/cilium/values.yaml")).kubeProxyReplacement == true,
      yamldecode(file("${path.module}/../kubernetes/platform/cilium/values.yaml")).k8sServiceHost == "localhost",
      yamldecode(file("${path.module}/../kubernetes/platform/cilium/values.yaml")).k8sServicePort == 7445,
    ])
    error_message = "without kube-proxy, Cilium must replace it and reach the API server through KubePrism on localhost:7445, which needs no Service"
  }

  assert {
    condition     = !anytrue([for patch in concat(local.common_patches, local.control_plane_patches) : try(yamldecode(patch).kind, "") == "KubePrismConfig"])
    error_message = "Cilium reaches the API server through KubePrism; leave Talos's KubePrismConfig at its default, enabled on 7445"
  }
}
