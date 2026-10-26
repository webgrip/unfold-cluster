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

run "the_forgejo_fallback_source_is_warm_verified_and_applies_nothing_by_itself" {
  command = plan

  assert {
    condition     = contains(yamldecode(file("${path.module}/../kubernetes/clusters/main/kustomization.yaml")).resources, "../../platform/flux-fallback-source")
    error_message = "Flux must apply kubernetes/platform/flux-fallback-source, or the fallback source is never fetched and nobody knows whether it works until GitHub is down"
  }

  assert {
    condition     = try(yamldecode(file("${path.module}/../kubernetes/platform/flux-fallback-source/gitrepository.yaml")).spec.verify, null) == yamldecode(file("${path.module}/../kubernetes/clusters/main/flux-system/gitrepository.yaml")).spec.verify
    error_message = "the fallback source must check the newest commit against the same trusted signers as flux-system; a fallback without the check would deploy whatever reaches Forgejo's main"
  }

  assert {
    condition = alltrue([
      try(yamldecode(file("${path.module}/../kubernetes/platform/flux-fallback-source/gitrepository.yaml")).spec.ref, null) == yamldecode(file("${path.module}/../kubernetes/clusters/main/flux-system/gitrepository.yaml")).spec.ref,
      yamldecode(file("${path.module}/../kubernetes/platform/flux-fallback-source/gitrepository.yaml")).spec.url == "https://forgejo.webgrip.dev/webgrip/unfold-cluster.git",
      yamldecode(file("${path.module}/../kubernetes/platform/flux-fallback-source/kustomization.yaml")).namespace == "flux-system",
    ])
    error_message = "the fallback source must read this repository's main branch on Forgejo, in flux-system where the trusted-signers Secret is"
  }

  assert {
    condition = alltrue([
      for f in fileset("${path.module}/../kubernetes", "**/*.yaml") :
      f == "platform/flux-fallback-source/gitrepository.yaml" || !strcontains(file("${path.module}/../kubernetes/${f}"), "unfold-cluster-forgejo")
    ])
    error_message = "nothing may reference the fallback source: a Kustomization on it would apply Forgejo's tree beside GitHub's, and switching to it is a break-glass step (docs/runbooks/break-glass.md), not a merge"
  }

  assert {
    condition     = strcontains(file("${path.module}/../kubernetes/platform/network-policy/flux-system-egress.yaml"), "        - matchName: forgejo.webgrip.dev\n")
    error_message = "source-controller-egress must name forgejo.webgrip.dev, or the fallback source cannot be fetched once flux-system's egress is enforced"
  }
}
