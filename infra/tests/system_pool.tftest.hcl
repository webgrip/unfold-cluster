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

run "the_system_pool_waits_at_zero_for_hetzner_to_raise_the_primary_ip_limit" {
  command = plan

  assert {
    condition = alltrue([
      var.worker_pools.system.server_type == "cpx32",
      var.worker_pools.system.location == "fsn1",
      var.worker_pools.system.node_count == 0,
      var.worker_pools.system.name_prefix == "unfold-system",
      var.worker_pools.system.first_host == 51,
      var.worker_pools.system.labels == tomap({ "node.webgrip.io/pool" = "system" }),
      var.worker_pools.system.taints == tomap({ "node.webgrip.io/pool" = "system:NoSchedule" }),
    ])
    error_message = "the system pool of ADR 0013 is a CPX32 in fsn1, beside the hub and its volumes, labelled and tainted node.webgrip.io/pool=system, in the address block from 10.64.0.51; it holds no node until the Hetzner project may hold another primary IP"
  }

  assert {
    condition     = !contains(var.autoscaled_worker_pools, "system")
    error_message = "the system pool is fixed: the cluster-autoscaler runs on it and must never be the one deciding to delete its node"
  }

  assert {
    condition     = local.tailnet_tag_by_pool.system == "tag:system"
    error_message = "a system node joins the tailnet as tag:system"
  }
}

run "raising_the_count_to_one_adds_one_cpx32_in_its_role_and_changes_no_other_node" {
  command = plan

  variables {
    worker_pools = {
      unfold = {
        server_type = "cx33"
        node_count  = 1
        name_prefix = "unfold-app"
        first_host  = 21
        labels      = { "node.webgrip.io/pool" = "unfold", "runtime.webgrip.io/gvisor" = "true" }
        taints      = { "node.webgrip.io/pool" = "unfold:NoSchedule" }
      }
      ci = {
        server_type = "cx43"
        location    = "nbg1"
        node_count  = 0
        name_prefix = "unfold-ci"
        first_host  = 31
        labels      = { "node.webgrip.io/pool" = "ci", "runtime.webgrip.io/gvisor" = "true" }
        taints      = { "node.webgrip.io/pool" = "ci:NoSchedule" }
      }
      system = {
        server_type = "cpx32"
        location    = "fsn1"
        node_count  = 1
        name_prefix = "unfold-system"
        first_host  = 51
        labels      = { "node.webgrip.io/pool" = "system" }
        taints      = { "node.webgrip.io/pool" = "system:NoSchedule" }
      }
    }
  }

  assert {
    condition = alltrue([
      hcloud_server.worker["unfold-system-1"].server_type == "cpx32",
      hcloud_server.worker["unfold-system-1"].location == "fsn1",
      one(hcloud_server.worker["unfold-system-1"].network).ip == "10.64.0.51",
      hcloud_server.worker["unfold-system-1"].labels.pool == "system",
      hcloud_server.worker["unfold-system-1"].delete_protection,
    ])
    error_message = "the pool gives exactly one CPX32, unfold-system-1, in fsn1 at 10.64.0.51, delete-protected like every fixed node"
  }

  assert {
    condition     = sort(keys(hcloud_server.worker)) == sort(["unfold-app-1", "unfold-system-1"]) && hcloud_server.worker["unfold-app-1"].server_type == "cx33"
    error_message = "the system node joins the hub worker, which stays as it is"
  }

  assert {
    condition = yamldecode(local.worker_pool_patch["system"]) == {
      apiVersion = "v1alpha1"
      kind       = "KubeNodeConfig"
      labels     = { "node.webgrip.io/pool" = "system" }
      taints     = { "node.webgrip.io/pool" = "system:NoSchedule" }
    }
    error_message = "the system node registers with the label node.webgrip.io/pool=system and the taint node.webgrip.io/pool=system:NoSchedule, which the platform workloads prefer and tolerate"
  }

  assert {
    condition     = length(local.worker_sandbox_patches["system"]) == 0
    error_message = "the system node runs no sandbox runtime: no CI job or Run is scheduled there"
  }

  assert {
    condition     = local.worker_tailnet_tag["unfold-system-1"] == "tag:system" && endswith(data.external.worker_tailnet_key["unfold-system-1"].query.request, " tag:system")
    error_message = "the system node's pre-auth key is minted with tag:system"
  }
}
