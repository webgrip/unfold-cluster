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
  admin_cidrs          = ["203.0.113.7/32", "2001:db8::/64"]
}

run "the_tailnet_policy_lets_the_nodes_reach_the_homelab_gateway_and_nothing_more" {
  command = plan

  assert {
    condition = [for rule in jsondecode(local.headscale_policy).acls : rule if !contains(rule.src, "autogroup:member")] == [
      { action = "accept", src = ["tag:cp"], dst = ["tag:homelab-gateway:8200"] },
      { action = "accept", src = ["tag:cp", "tag:ci", "tag:hub", "tag:metal", "tag:runs", "tag:system"], dst = ["tag:homelab-gateway:8427"] },
      { action = "accept", src = ["tag:cp"], dst = ["tag:homelab-gateway:9150"] },
      { action = "accept", src = ["tag:headscale"], dst = ["tag:homelab-gateway:443"] },
      { action = "accept", src = ["tag:hub"], dst = ["tag:homelab-gateway:443"] },
      { action = "accept", src = ["tag:homelab-gateway"], dst = ["10.64.0.10/32:443"] },
    ]
    error_message = "besides the admins, only the nodes and Headscale may open connections: OpenBao (8200) only from the control planes, which run External Secrets; the metrics and log ingest (8427) from every node, because Vector ships each node's logs from its host network; the CI job count (9150) only from the control planes, which run KEDA; Headscale and the hub only to the identity provider behind the gateway's 443 (ADR 0006: the hub runs authentik-relay); and the homelab gateway only to the ops Gateway's 443 on the API address, where query.ops.unfoldhq.dev serves the homelab Grafana's read-only, token-checked queries (ADR 0013)"
  }

  assert {
    condition     = jsondecode(local.headscale_policy).tagOwners["tag:homelab-gateway"] == ["group:admin"]
    error_message = "the gateway tag must have an owner, or Headscale refuses the policy"
  }
}

run "the_server_and_the_apply_install_the_same_program_and_policy" {
  command = plan

  assert {
    condition     = terraform_data.tailnet_key_tool.triggers_replace[0] == sha256(file("${path.module}/templates/unfold-tailnet-key.sh"))
    error_message = "a change to unfold-tailnet-key.sh must reinstall it on the running server"
  }

  assert {
    condition     = terraform_data.headscale_policy.triggers_replace[0] == sha256(local.headscale_policy)
    error_message = "a change to the Headscale policy must reach the running server"
  }

  assert {
    condition = alltrue([
      strcontains(hcloud_server.headscale.user_data, trimspace(local.tailnet_key_sudoers)),
      strcontains(hcloud_server.headscale.user_data, "policy set"),
      strcontains(hcloud_server.headscale.user_data, "\"tag:homelab-gateway\""),
    ])
    error_message = "a new server must start with the same program, sudoers rule and policy that the apply pushes"
  }

  assert {
    condition     = trimspace(local.tailnet_key_sudoers) == "tofu ALL=(root) NOPASSWD: /usr/local/sbin/unfold-tailnet-key *"
    error_message = "the tofu user may run unfold-tailnet-key as root and nothing else"
  }
}

run "the_gateway_key_never_shows_in_a_plan" {
  command = plan

  override_resource {
    target = terraform_data.homelab_gateway_tailnet_key
    values = {
      output = "hskey-auth-mocked-gateway"
    }
  }

  assert {
    condition     = issensitive(output.homelab_gateway_tailnet_key)
    error_message = "the gateway's pre-auth key must stay out of the public plan log"
  }
}
