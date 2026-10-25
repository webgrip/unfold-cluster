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

run "every_node_pulls_the_four_public_registries_through_zot" {
  command = plan

  assert {
    condition = sort([for patch in local.registry_mirror_patches : yamldecode(patch).name]) == sort([
      "docker.io", "ghcr.io", "quay.io", "registry.k8s.io",
    ])
    error_message = "the nodes mirror exactly the four registries Zot syncs from"
  }

  assert {
    condition = alltrue([
      for patch in local.registry_mirror_patches :
      contains(data.talos_machine_configuration.control_plane.config_patches, patch) && contains(data.talos_machine_configuration.worker.config_patches, patch)
    ])
    error_message = "every mirror document must reach the control plane and the worker machine configs"
  }

  assert {
    condition = alltrue([
      for patch in local.registry_mirror_patches :
      yamldecode(patch).endpoints[0].url == "http://127.0.0.1:30500/v2/${yamldecode(patch).name}" && yamldecode(patch).endpoints[0].overridePath
    ])
    error_message = "each registry maps onto its own path prefix in Zot, the layout Zot's sync destinations use"
  }
}

run "a_node_never_depends_on_zot_to_pull" {
  command = plan

  assert {
    condition     = alltrue([for patch in local.registry_mirror_patches : yamldecode(patch).skipFallback == false])
    error_message = "skipFallback must stay false: Cilium, Zot itself and every image during a node's first boot come from upstream while Zot is unreachable"
  }

  assert {
    condition = alltrue([
      for patch in local.registry_mirror_patches : length(yamldecode(patch).endpoints) == 1 && startswith(yamldecode(patch).endpoints[0].url, "http://127.0.0.1:")
    ])
    error_message = "the mirror is the node's own loopback NodePort: before Cilium runs nothing listens there, so containerd falls back at once instead of waiting on a timeout to a Service address"
  }

  assert {
    condition     = !fileexists("${path.module}/../kubernetes/platform/zot/helmrelease.yaml") || strcontains(file("${path.module}/../kubernetes/platform/zot/helmrelease.yaml"), "nodePort: ${split(":", local.zot_node_endpoint)[2]}")
    error_message = "the mirror port must be the NodePort of the Zot Service in kubernetes/platform/zot"
  }
}
