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

run "the_ci_pool_is_one_cx43_tainted_for_ci_only" {
  command = plan

  assert {
    condition = alltrue([
      hcloud_server.worker["unfold-ci-1"].server_type == "cx43",
      hcloud_server.worker["unfold-ci-1"].labels.pool == "ci",
      one(hcloud_server.worker["unfold-ci-1"].network).ip == "10.64.0.31",
      hcloud_server.worker["unfold-ci-1"].firewall_ids == toset([tonumber(hcloud_firewall.nodes.id)]),
      hcloud_server.worker["unfold-ci-1"].delete_protection,
    ])
    error_message = "the CI pool is one CX43, unfold-ci-1, on the private network at 10.64.0.31 behind the nodes firewall"
  }

  assert {
    condition = yamldecode(local.worker_pool_patch["ci"]) == {
      apiVersion = "v1alpha1"
      kind       = "KubeNodeConfig"
      labels     = { "node.webgrip.io/pool" = "ci" }
      taints     = { "node.webgrip.io/pool" = "ci:NoSchedule" }
    }
    error_message = "the CI node registers with the label node.webgrip.io/pool=ci and the taint node.webgrip.io/pool=ci:NoSchedule"
  }

  assert {
    condition     = !strcontains(local.tailscale_join["unfold-ci-1"].extra_args, "--advertise-routes")
    error_message = "the CI node joins the tailnet as a plain worker and advertises no route"
  }

  assert {
    condition     = length(hcloud_server.worker) == 2 && length(terraform_data.worker_tailnet_key) == 2 && length(talos_machine_configuration_apply.worker) == 2
    error_message = "each worker of every pool gets a server, a tailnet key and a machine config"
  }
}

run "the_hub_worker_keeps_its_server_and_machine_config" {
  command = plan

  assert {
    condition = alltrue([
      hcloud_server.worker["unfold-app-1"].server_type == "cx33",
      one(hcloud_server.worker["unfold-app-1"].network).ip == "10.64.0.21",
      hcloud_server.worker["unfold-app-1"].labels == tomap({ cluster = "unfold-main", role = "worker", pool = "unfold" }),
    ])
    error_message = "unfold-app-1 keeps its type, address and Hetzner labels, so the pool shape replaces nothing"
  }

  assert {
    condition     = local.worker_pool_patch["unfold"] == "\"apiVersion\": \"v1alpha1\"\n\"kind\": \"KubeNodeConfig\"\n\"labels\":\n  \"node.webgrip.io/pool\": \"unfold\"\n\"taints\":\n  \"node.webgrip.io/pool\": \"unfold:NoSchedule\"\n"
    error_message = "the hub worker's pool patch must stay byte for byte what it was, or its machine config changes on the next apply"
  }
}

run "a_pool_whose_label_names_another_pool_is_refused" {
  command = plan

  variables {
    worker_pools = {
      ci = {
        server_type = "cx43"
        node_count  = 1
        name_prefix = "unfold-ci"
        first_host  = 31
        labels      = { "node.webgrip.io/pool" = "unfold" }
        taints      = {}
      }
    }
  }

  expect_failures = [
    var.worker_pools,
  ]
}

run "two_pools_in_one_address_block_are_refused" {
  command = plan

  variables {
    worker_pools = {
      unfold = {
        server_type = "cx33"
        node_count  = 1
        name_prefix = "unfold-app"
        first_host  = 21
        labels      = { "node.webgrip.io/pool" = "unfold" }
        taints      = {}
      }
      ci = {
        server_type = "cx43"
        node_count  = 1
        name_prefix = "unfold-ci"
        first_host  = 21
        labels      = { "node.webgrip.io/pool" = "ci" }
        taints      = {}
      }
    }
  }

  expect_failures = [
    var.worker_pools,
  ]
}

run "the_snapshot_every_worker_boots_carries_gvisor" {
  command = plan

  assert {
    condition     = contains(yamldecode(file("${path.module}/../talos/schematics/cloud.yaml")).customization.systemExtensions.officialExtensions, "siderolabs/gvisor")
    error_message = "the gvisor RuntimeClass schedules CI pods onto nodes booted from the cloud schematic; without siderolabs/gvisor in it their runsc handler does not exist"
  }
}
