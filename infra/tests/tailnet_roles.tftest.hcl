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

run "each_worker_joins_with_its_pools_role_tag" {
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
        node_count  = 1
        name_prefix = "unfold-ci"
        first_host  = 31
        labels      = { "node.webgrip.io/pool" = "ci" }
        taints      = { "node.webgrip.io/pool" = "ci:NoSchedule" }
      }
    }
  }

  assert {
    condition     = local.worker_tailnet_tag == { "unfold-app-1" = "tag:hub", "unfold-ci-1" = "tag:ci" }
    error_message = "the hub worker joins as tag:hub and a CI node as tag:ci; the tag comes from the worker's pool"
  }

  assert {
    condition = alltrue([
      for name, key in data.external.worker_tailnet_key : endswith(key.query.request, " ${local.worker_tailnet_tag[name]}")
    ])
    error_message = "each worker's pre-auth key is minted with its pool's role tag, so a new or re-keyed node joins in its role"
  }

  assert {
    condition = local.tailnet_node_tag == {
      "unfold-cp-1"  = "tag:cp"
      "unfold-cp-2"  = "tag:cp"
      "unfold-cp-3"  = "tag:cp"
      "unfold-app-1" = "tag:hub"
      "unfold-ci-1"  = "tag:ci"
    }
    error_message = "the apply gives every node already on the tailnet its role tag, the control planes included, so a node that joined as tag:node takes its role without a new key or a new Headscale"
  }

  assert {
    condition = alltrue([
      for name, tag in local.tailnet_node_tag :
      terraform_data.tailnet_node_tag[name].triggers_replace[0] == tag && terraform_data.tailnet_node_tag[name].triggers_replace[1] == hcloud_server.headscale.id
    ])
    error_message = "a node's tag is set again when its role changes and when Headscale is replaced"
  }
}

run "a_pool_without_a_role_tag_is_refused" {
  command = plan

  variables {
    autoscaled_worker_pools = []
    worker_pools = {
      gpu = {
        server_type = "cx43"
        node_count  = 1
        name_prefix = "unfold-gpu"
        first_host  = 41
        labels      = { "node.webgrip.io/pool" = "gpu" }
        taints      = {}
      }
    }
  }

  expect_failures = [data.external.worker_tailnet_key]
}

run "only_the_control_planes_reach_openbao_and_the_ci_job_count" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for port in ["8200", "9150"] : [
        for tag in ["tag:hub", "tag:ci", "tag:runs", "tag:metal", "tag:node"] : !anytrue([
          for rule in jsondecode(local.headscale_policy).acls :
          (contains(rule.src, tag) || contains(rule.src, "*") || contains(rule.src, "autogroup:tagged")) && anytrue([
            for destination in rule.dst :
            contains(["*", "tag:homelab-gateway", "autogroup:tagged"], trimsuffix(destination, ":${reverse(split(":", destination))[0]}")) && anytrue([
              for ports in split(",", reverse(split(":", destination))[0]) :
              ports == "*" || ports == port || try(tonumber(split("-", ports)[0]) <= tonumber(port) && tonumber(split("-", ports)[1]) >= tonumber(port), false)
            ])
          ])
        ])
      ]
    ]))
    error_message = "no worker role (tag:hub, tag:ci, tag:runs, tag:metal) nor the retired tag:node may reach the gateway's OpenBao (8200) or CI job count (9150): those run on the control planes only (External Secrets and KEDA), and untrusted CI jobs run on the hub and CI nodes"
  }

  assert {
    condition = alltrue([
      for port in ["8200", "9150", "8427"] : anytrue([
        for rule in jsondecode(local.headscale_policy).acls :
        contains(rule.src, "tag:cp") && contains(rule.dst, "tag:homelab-gateway:${port}")
      ])
    ])
    error_message = "the control planes run External Secrets (8200), KEDA (9150) and Vector (8427), so they must keep each of those ports"
  }

  assert {
    condition = alltrue([
      for tag in values(local.tailnet_tag_by_pool) : anytrue([
        for rule in jsondecode(local.headscale_policy).acls :
        contains(rule.src, tag) && contains(rule.dst, "tag:homelab-gateway:8427")
      ])
    ])
    error_message = "Vector runs on every node's host network and ships its logs to the gateway's 8427, so every role keeps that port"
  }

  assert {
    condition     = !contains(keys(jsondecode(local.headscale_policy).tagOwners), "tag:node")
    error_message = "tag:node is retired: no key is minted with it and the policy no longer defines it, so a node still carrying it reaches nothing"
  }

  assert {
    condition = alltrue([
      for tag in concat(["tag:cp"], values(local.tailnet_tag_by_pool)) :
      jsondecode(local.headscale_policy).tagOwners[tag] == ["group:admin"]
    ])
    error_message = "every role tag must have an owner, or Headscale refuses the policy and the node keys"
  }
}
