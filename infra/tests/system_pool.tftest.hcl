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

run "the_system_pool_costs_nothing_until_the_owner_raises_its_count" {
  command = plan

  assert {
    condition     = var.worker_pools["system"].node_count == 0 && !anytrue([for name in keys(hcloud_server.worker) : startswith(name, "unfold-sys")])
    error_message = "the system pool is declared at node_count 0 and plans no server, so nothing is billed until the owner raises the count (ADR 0013)"
  }
}

run "raising_the_count_plans_one_cpx32_in_nuremberg_tainted_for_the_system_pool" {
  command = plan

  variables {
    worker_pools = {
      unfold = {
        server_type = "cx33"
        node_count  = 1
        name_prefix = "unfold-app"
        first_host  = 21
        labels      = { "node.webgrip.io/pool" = "unfold" }
        taints      = { "node.webgrip.io/pool" = "unfold:NoSchedule" }
      }
      ci = {
        server_type = "cx43"
        location    = "nbg1"
        node_count  = 0
        name_prefix = "unfold-ci"
        first_host  = 31
        labels      = { "node.webgrip.io/pool" = "ci" }
        taints      = { "node.webgrip.io/pool" = "ci:NoSchedule" }
      }
      system = {
        server_type = "cpx32"
        location    = "nbg1"
        node_count  = 1
        name_prefix = "unfold-sys"
        first_host  = 41
        labels      = { "node.webgrip.io/pool" = "system" }
        taints      = { "node.webgrip.io/pool" = "system:NoSchedule" }
      }
    }
  }

  assert {
    condition = alltrue([
      hcloud_server.worker["unfold-sys-1"].server_type == "cpx32",
      hcloud_server.worker["unfold-sys-1"].location == "nbg1",
      local.worker_tailnet_tag["unfold-sys-1"] == "tag:system",
    ])
    error_message = "the system node is a CPX32 in nbg1 that joins the tailnet as tag:system"
  }
}
