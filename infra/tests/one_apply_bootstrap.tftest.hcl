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

run "a_plan_only_run_before_the_snapshot_exists_still_plans_every_node" {
  command = plan

  assert {
    condition     = length(hcloud_server.control_plane) == 3 && length(hcloud_server.unfold_worker) == 1
    error_message = "a plan-only run must show every cluster node, with no human-set gate"
  }

  assert {
    condition     = hcloud_server.control_plane["unfold-cp-1"].image == "talos-snapshot-is-built-by-the-apply-run"
    error_message = "without a snapshot, a plan-only run shows the placeholder image"
  }
}

run "an_apply_run_refuses_to_boot_nodes_without_the_snapshot" {
  command = plan

  variables {
    talos_snapshot_required = true
  }

  expect_failures = [
    hcloud_server.control_plane,
    hcloud_server.unfold_worker,
  ]
}

run "an_apply_run_boots_nodes_from_the_labelled_snapshot_with_the_key_read_from_headscale" {
  command = plan

  variables {
    talos_snapshot_required = true
  }

  override_resource {
    target = tls_private_key.headscale_tofu
    values = {
      public_key_openssh = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMockTofuKey\n"
    }
  }

  override_resource {
    target = tls_private_key.headscale_host
    values = {
      public_key_openssh  = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMockHostKey\n"
      private_key_openssh = "-----BEGIN OPENSSH PRIVATE KEY-----\nbW9jaw==\n-----END OPENSSH PRIVATE KEY-----\n"
    }
  }

  override_data {
    target = data.hcloud_images.talos
    values = {
      images = [{
        id                    = 4242
        name                  = ""
        type                  = "snapshot"
        description           = "Talos"
        architecture          = "x86"
        os_flavor             = "unknown"
        os_version            = ""
        rapid_deploy          = false
        deprecated            = ""
        deprecation_announced = ""
        unavailable_after     = ""
        is_deprecated         = false
        labels                = {}
        created               = ""
      }]
    }
  }

  assert {
    condition     = hcloud_server.control_plane["unfold-cp-1"].image == "4242"
    error_message = "nodes boot from the snapshot the label selector found"
  }

  assert {
    condition = alltrue([
      data.external.control_plane_tailnet_key.query.request == "control-plane",
      data.external.control_plane_tailnet_key.query.host_public_key == "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMockHostKey",
      data.external.worker_tailnet_key["unfold-app-1"].query.host_public_key == "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMockHostKey",
    ])
    error_message = "OpenTofu asks unfold-headscale for the keys and trusts only the host key it generated for it"
  }

  assert {
    condition     = data.external.worker_tailnet_key["unfold-app-1"].query.request == "worker ${hcloud_server.unfold_worker["unfold-app-1"].id}"
    error_message = "a worker key is asked for by the worker's own server id, so each server gets one"
  }

  assert {
    condition = alltrue([
      for name in keys(local.control_planes) :
      strcontains(local.tailscale_join[name].extra_args, "--advertise-tags=tag:cp --advertise-routes=10.64.0.0/24")
    ])
    error_message = "control planes join as tag:cp and advertise the cloud subnet"
  }

  assert {
    condition     = strcontains(local.tailscale_join["unfold-app-1"].extra_args, "--advertise-tags=tag:node") && !strcontains(local.tailscale_join["unfold-app-1"].extra_args, "--advertise-routes")
    error_message = "the worker joins as tag:node and advertises no route"
  }

  assert {
    condition     = strcontains(hcloud_server.headscale.user_data, "restrict,command=\"set -f; exec sudo -n /usr/local/sbin/unfold-tailnet-key $SSH_ORIGINAL_COMMAND\" ${trimspace(tls_private_key.headscale_tofu.public_key_openssh)}")
    error_message = "OpenTofu's key on unfold-headscale is restricted to the tailnet key command"
  }

  assert {
    condition = alltrue([
      strcontains(hcloud_server.headscale.user_data, "ssh_deletekeys: true"),
      strcontains(hcloud_server.headscale.user_data, "ssh_genkeytypes: [ed25519]"),
      strcontains(hcloud_server.headscale.user_data, "ed25519_public: ${trimspace(tls_private_key.headscale_host.public_key_openssh)}"),
      strcontains(hcloud_server.headscale.user_data, "    -----BEGIN OPENSSH PRIVATE KEY-----"),
    ])
    error_message = "unfold-headscale presents only the ed25519 host key OpenTofu generated"
  }

  assert {
    condition     = hcloud_server.headscale.delete_protection && hcloud_server.headscale.rebuild_protection
    error_message = "unfold-headscale is created protected"
  }
}

run "the_tailnet_key_is_not_read_without_an_admin_address" {
  command = plan

  variables {
    admin_cidrs = []
  }

  expect_failures = [
    data.external.control_plane_tailnet_key,
  ]
}
