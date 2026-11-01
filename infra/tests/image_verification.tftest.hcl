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

run "every_node_refuses_an_unsigned_webgrip_image_at_pull" {
  command = plan

  assert {
    condition = alltrue([
      contains(data.talos_machine_configuration.control_plane.config_patches, local.image_verification_patch),
      contains(data.talos_machine_configuration.worker.config_patches, local.image_verification_patch),
      contains(data.talos_machine_configuration.metal.config_patches, local.image_verification_patch),
      alltrue([for pool in var.autoscaled_worker_pools : contains(data.talos_machine_configuration.autoscaled_worker[pool].config_patches, local.image_verification_patch)]),
    ])
    error_message = "the control planes, the workers, the metal node and every autoscaled pool must carry the ImageVerificationConfig, or one of them pulls unsigned webgrip images"
  }

  assert {
    condition = alltrue(flatten([
      for registry in ["ghcr.io", "forgejo.webgrip.dev"] : [
        for pattern in ["${registry}/webgrip/*", "${registry}/webgrip/*/*"] :
        contains([for rule in yamldecode(local.image_verification_patch).rules : rule.image if try(rule.publicKey.certificate, "") == local.cosign_webgrip_public_key], pattern)
      ]
    ]))
    error_message = "webgrip images on ghcr.io and forgejo.webgrip.dev, one and two path levels deep, must verify against the cosign-webgrip public key"
  }

  assert {
    condition     = startswith(local.cosign_webgrip_public_key, "-----BEGIN PUBLIC KEY-----") && endswith(local.cosign_webgrip_public_key, "-----END PUBLIC KEY-----")
    error_message = "infra/keys/cosign-webgrip.pub must hold one PEM public key, the public half of the OpenBao Transit key cosign-webgrip"
  }
}

run "a_skipped_image_is_named_exactly_and_comes_before_the_patterns" {
  command = plan

  assert {
    condition = alltrue([
      for index, rule in yamldecode(local.image_verification_patch).rules :
      try(rule.skip, false) ? !strcontains(rule.image, "*") && alltrue([for earlier in slice(yamldecode(local.image_verification_patch).rules, 0, index) : try(earlier.skip, false)]) : true
    ])
    error_message = "Talos applies the first rule that matches, so a skip rule names one repository without a wildcard and sits before every verifying rule; a wildcard skip would let unsigned images through"
  }
}
