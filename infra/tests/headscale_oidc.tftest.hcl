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

run "only_headscale_reaches_the_identity_provider_behind_the_gateways_443" {
  command = plan

  assert {
    condition = [
      for rule in jsondecode(local.headscale_policy).acls : rule.src
      if anytrue([
        for destination in rule.dst : (
          anytrue([
            contains(["*", "tag:homelab-gateway", "autogroup:tagged"], trimsuffix(destination, ":${reverse(split(":", destination))[0]}")),
            try(cidrcontains(trimsuffix(destination, ":${reverse(split(":", destination))[0]}"), "100.64.0.0"), false),
            try(cidrcontains("100.64.0.0/10", cidrhost(trimsuffix(destination, ":${reverse(split(":", destination))[0]}"), 0)), false),
            try(cidrcontains(trimsuffix(destination, ":${reverse(split(":", destination))[0]}"), "fd7a:115c:a1e0::"), false),
            try(cidrcontains("fd7a:115c:a1e0::/48", cidrhost(trimsuffix(destination, ":${reverse(split(":", destination))[0]}"), 0)), false),
          ])
          && anytrue([
            for ports in split(",", reverse(split(":", destination))[0]) :
            ports == "*" || ports == "443" || try(tonumber(split("-", ports)[0]) <= 443 && tonumber(split("-", ports)[1]) >= 443, false)
          ])
        )
      ])
    ] == [["tag:headscale"]]
    error_message = "exactly one rule may reach the homelab gateway's port 443, which leads to the homelab's internal gateway, and only tag:headscale may be its source; no wildcard, port range, tailnet prefix or admin rule may cover it"
  }

  assert {
    condition     = jsondecode(local.headscale_policy).tagOwners["tag:headscale"] == ["group:admin"]
    error_message = "the Headscale server's own tag must have an owner, or Headscale refuses the policy"
  }
}

run "the_admins_reach_every_node_and_route_but_not_the_identity_provider_port" {
  command = plan

  assert {
    condition = alltrue(concat(
      [
        for tag in keys(jsondecode(local.headscale_policy).tagOwners) :
        contains(one([for rule in jsondecode(local.headscale_policy).acls : rule if rule.src == ["autogroup:member"]]).dst, "${tag}:*")
        if tag != "tag:homelab-gateway"
      ],
      [
        for route in keys(jsondecode(local.headscale_policy).autoApprovers.routes) :
        contains(one([for rule in jsondecode(local.headscale_policy).acls : rule if rule.src == ["autogroup:member"]]).dst, "${route}:*")
      ],
      [contains(one([for rule in jsondecode(local.headscale_policy).acls : rule if rule.src == ["autogroup:member"]]).dst, "autogroup:member:*")],
    ))
    error_message = "every device a person registers, by browser or by hand, must reach every tagged node, every approved route and the other people's devices; a new tag or route needs its line in the admin rule"
  }
}

run "headscale_signs_people_in_through_authentik_and_admits_only_unfold_admins" {
  command = plan

  assert {
    condition = yamldecode(local.headscale_config).oidc == {
      only_start_if_oidc_is_available = false
      issuer                          = "https://authentik.webgrip.dev/application/o/unfold-headscale/"
      client_id                       = "unfold-headscale"
      client_secret_path              = "/etc/headscale/oidc_client_secret"
      scope                           = ["openid", "profile", "email", "groups"]
      allowed_groups                  = ["unfold-admins"]
      use_expiry_from_token           = false
      pkce                            = { enabled = true, method = "S256" }
    }
    error_message = "Headscale must start without its identity provider, read the client secret from a file, ask for the groups claim, admit unfold-admins only, and use PKCE with S256"
  }

  assert {
    condition     = yamldecode(local.headscale_config).node.expiry == "720h"
    error_message = "a device registered by a person expires after 30 days; tagged servers never expire (Headscale 0.29 removed oidc.expiry in favour of node.expiry)"
  }
}

run "the_client_secret_reaches_headscale_only_through_the_push" {
  command = plan

  variables {
    headscale_oidc_client_secret = "canary-oidc-client-secret-that-must-stay-out-of-every-plan"
  }

  assert {
    condition     = length(terraform_data.headscale_oidc_client_secret) == 1 && issensitive(terraform_data.headscale_oidc_client_secret[0].triggers_replace[0])
    error_message = "the push of the client secret is triggered by a value the plan shows only as (sensitive value)"
  }

  assert {
    condition = alltrue([
      !strcontains(local.headscale_config, var.headscale_oidc_client_secret),
      !strcontains(hcloud_server.headscale.user_data, var.headscale_oidc_client_secret),
      !strcontains(local.headscale_policy, var.headscale_oidc_client_secret),
    ])
    error_message = "the client secret must not be in the configuration, the policy or cloud-init, which Hetzner keeps as user data"
  }
}

run "without_a_client_secret_nothing_is_pushed" {
  command = plan

  assert {
    condition     = length(terraform_data.headscale_oidc_client_secret) == 0
    error_message = "an empty client secret must not be pushed over the one the server holds"
  }
}

run "the_server_and_the_apply_install_the_same_configuration_and_host" {
  command = plan

  assert {
    condition     = terraform_data.headscale_config.triggers_replace[0] == sha256(local.headscale_config)
    error_message = "a change to the Headscale configuration must reach the running server"
  }

  assert {
    condition = alltrue([
      strcontains(hcloud_server.headscale.user_data, indent(6, local.headscale_config)),
      strcontains(hcloud_server.headscale.user_data, "- path: ${local.headscale_oidc.client_secret_path}"),
      strcontains(hcloud_server.headscale.user_data, "[chgrp, headscale, ${local.headscale_oidc.client_secret_path}]"),
      strcontains(hcloud_server.headscale.user_data, "[/usr/local/sbin/unfold-tailnet-key, host, apply, \"${local.tailscale_version}\", \"${local.tailscale_sha256}\"]"),
    ])
    error_message = "a new server must start with the configuration the apply pushes, an empty client secret file Headscale can read, and the same host apply"
  }

  assert {
    condition     = strcontains(local.tailnet_key_tool, ": \"$${OIDC_SECRET_PATH:=${local.headscale_oidc.client_secret_path}}\"")
    error_message = "unfold-tailnet-key must write the client secret where the configuration reads it"
  }

  assert {
    condition = terraform_data.headscale_host.triggers_replace == [
      local.tailscale_version,
      local.tailscale_sha256,
      sha256(local.tailnet_key_tool),
      hcloud_server.headscale.id,
    ]
    error_message = "a new Tailscale version or program must reach the running server"
  }
}

run "nothing_new_on_headscale_answers_the_internet_but_its_own_tailnet_transport" {
  command = plan

  assert {
    condition = sort([for rule in hcloud_firewall.headscale.rule : "${rule.protocol}/${rule.port}" if contains(rule.source_ips, "0.0.0.0/0")]) == sort([
      "tcp/443",
      "tcp/80",
      "udp/3478",
      "udp/41641",
    ])
    error_message = "from the internet Headscale answers only HTTPS, the ACME challenge, STUN and the WireGuard port of its own tailnet node"
  }
}
