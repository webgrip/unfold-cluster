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

run "git_declares_no_metal_server_and_the_plan_calls_robot_for_nothing" {
  command = plan

  assert {
    condition     = length(var.metal_servers) == 0
    error_message = "no metal server is declared until an EX44 or AX41 is in stock again"
  }

  assert {
    condition = alltrue([
      length(data.external.metal_quote) == 0,
      length(data.external.metal_auction_pick) == 0,
      length(data.external.metal_server) == 0,
      length(data.external.robot_vswitch) == 0,
      length(terraform_data.metal_order) == 0,
      length(terraform_data.metal_auction_order) == 0,
      length(terraform_data.metal_adoption) == 0,
      length(terraform_data.robot_vswitch) == 0,
      length(hcloud_network_subnet.vswitch) == 0,
      length(terraform_data.metal_robot_firewall) == 0,
      length(terraform_data.metal_install) == 0,
      length(talos_machine_configuration_apply.metal) == 0,
      !hcloud_network.cluster.expose_routes_to_vswitch,
      length(local.encrypted_nodes) == 0,
    ])
    error_message = "without a metal server the plan runs no Robot program, creates no metal resource and encrypts no node"
  }
}
