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
      id = "106"
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

run "every_tailnet_key_is_minted_again_by_a_new_headscale" {
  command = plan

  assert {
    condition = alltrue([
      for key in values(terraform_data.control_plane_tailnet_key) :
      key.triggers_replace[0] == var.tailnet_key_generation && key.triggers_replace[1] == hcloud_server.headscale.id
    ])
    error_message = "a new unfold-headscale has an empty database: the control planes' key must be read again from the new server in the same apply"
  }

  assert {
    condition = alltrue([
      for key in values(terraform_data.worker_tailnet_key) :
      key.triggers_replace[0] == var.tailnet_key_generation && key.triggers_replace[1] == hcloud_server.headscale.id
    ])
    error_message = "a new unfold-headscale must mint a single-use key for every worker in the same apply"
  }

  assert {
    condition     = terraform_data.homelab_gateway_tailnet_key.triggers_replace[1] == hcloud_server.headscale.id
    error_message = "a new unfold-headscale must mint the homelab gateway a key, which the apply hands to OpenBao"
  }
}

run "a_node_logs_in_with_its_key_only_when_headscale_refuses_its_identity" {
  command = plan

  override_resource {
    target = terraform_data.control_plane_tailnet_key
    values = { output = "hskey-auth-control-plane" }
  }

  override_resource {
    target = terraform_data.worker_tailnet_key
    values = { output = "hskey-auth-worker" }
  }

  assert {
    condition = alltrue([
      for name, patch in local.tailscale_patch :
      strcontains(patch, "TS_AUTH_ONCE=true") && strcontains(patch, "TS_AUTHKEY=hskey-auth-${contains(keys(local.control_planes), name) ? "control-plane" : "worker"}")
    ])
    error_message = "every node carries the key OpenTofu read and TS_AUTH_ONCE: a running node keeps its identity, and one a rebuilt Headscale refuses falls back to NeedsLogin and logs in with the key the apply just wrote"
  }
}

run "the_live_server_is_replaced_once_to_match_a_fresh_rebuild" {
  command = plan

  assert {
    condition     = terraform_data.headscale_generation.input == 3
    error_message = "generation 3 replaces the server of 2026-10-25, whose program and sudoers rule refuse the apply's install, policy and gateway steps"
  }
}

run "the_headscale_generation_is_a_whole_number" {
  command = plan

  variables {
    headscale_generation = 2.5
  }

  expect_failures = [var.headscale_generation]
}

run "the_apply_publishes_the_headscale_address_for_the_homelab_dns" {
  command = plan

  override_resource {
    target = hcloud_primary_ip.headscale
    values = {
      id         = "103"
      ip_address = "198.51.100.23"
    }
  }

  assert {
    condition     = terraform_data.headscale_address.triggers_replace[0] == "198.51.100.23" && terraform_data.headscale_address.triggers_replace[1] == "ipv4"
    error_message = "a new primary IP, as in a new Hetzner project, must be written to OpenBao in the apply that makes it"
  }

  assert {
    condition = alltrue([
      strcontains(hcloud_server.headscale.user_data, "resolvectl query --cache=no --legend=no -4 headscale.webgrip.dev"),
      strcontains(hcloud_server.headscale.user_data, "grep -qwF '198.51.100.23'"),
    ])
    error_message = "a new server must wait until its name resolves to its own address before Headscale asks Let's Encrypt for a certificate"
  }
}

run "only_the_two_published_addresses_may_be_written" {
  command = plan

  variables {
    headscale_address_property = "anything_else"
  }

  expect_failures = [var.headscale_address_property]
}

run "the_escrowed_bundle_is_the_clusters_own_secrets" {
  command = plan

  assert {
    condition     = issensitive(output.talos_secrets_bundle) && issensitive(output.headscale_tofu_ssh_private_key)
    error_message = "the Talos secrets and the tofu SSH key must never show in a public plan log"
  }
}
