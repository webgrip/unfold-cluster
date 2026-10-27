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

run "the_api_server_controller_manager_and_scheduler_request_what_they_use" {
  command = plan

  assert {
    condition = alltrue([
      for patch in local.control_plane_component_requests_patches :
      contains(data.talos_machine_configuration.control_plane.config_patches, patch)
    ])
    error_message = "every control-plane component's requests must reach the control planes' machine config"
  }

  assert {
    condition = {
      for patch in local.control_plane_component_requests_patches : yamldecode(patch).kind => yamldecode(patch).resources.requests
      } == {
      KubeAPIServerConfig         = { cpu = "250m", memory = "1Gi" }
      KubeControllerManagerConfig = { cpu = "50m", memory = "256Mi" }
      KubeSchedulerConfig         = { cpu = "10m", memory = "64Mi" }
    }
    error_message = "the API server requests 250m and 1Gi, the controller manager 50m and 256Mi, the scheduler 10m and 64Mi (docs/architecture/capacity-and-scale.md); the API server used 850 to 1170 MiB against Talos's default 512Mi"
  }

  assert {
    condition = alltrue([
      for patch in local.control_plane_component_requests_patches :
      keys(yamldecode(patch).resources) == ["requests"]
    ])
    error_message = "the control-plane components get requests only: a memory limit would let the kernel kill the API server or etcd's neighbours on a spike instead of the scheduler keeping room for them"
  }

  assert {
    condition     = one([for patch in local.control_plane_component_requests_patches : yamldecode(patch) if yamldecode(patch).kind == "KubeAPIServerConfig"]).env == { GOMEMLIMIT = "1400MiB" }
    error_message = "the API server runs with GOMEMLIMIT=1400MiB, so its garbage collector works before a 4 GB control plane runs out and the kernel kills it (ADR 0013, 2026-10-26)"
  }

  assert {
    condition     = contains(data.talos_machine_configuration.control_plane.config_patches, local.control_plane_kubelet_memory_patch)
    error_message = "the control planes' kubelet evicts ordinary pods before the kernel picks the API server"
  }

  assert {
    condition = yamldecode(local.control_plane_kubelet_memory_patch).config == {
      evictionHard = {
        "memory.available"  = "300Mi"
        "nodefs.available"  = "10%"
        "nodefs.inodesFree" = "5%"
        "imagefs.available" = "15%"
      }
      evictionSoft            = { "memory.available" = "500Mi" }
      evictionSoftGracePeriod = { "memory.available" = "30s" }
    }
    error_message = "eviction starts at 500 MiB available for 30s and is forced at 300 MiB; the disk and inode thresholds are stated too, because a kubelet given evictionHard without them drops their defaults"
  }
}
