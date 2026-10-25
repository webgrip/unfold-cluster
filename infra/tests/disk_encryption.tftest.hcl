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

run "no_node_is_encrypted_until_the_key_server_exists" {
  command = plan

  assert {
    condition     = alltrue([for name, patches in local.disk_encryption_patches : length(patches) == 0])
    error_message = "by default no machine config carries an encrypted VolumeConfig"
  }
}

run "a_listed_node_seals_state_and_ephemeral_with_the_kms_and_nothing_weaker" {
  command = plan

  variables {
    disk_encryption_kms_endpoint = "https://kms.example.org:4050"
    disk_encryption_nodes        = ["unfold-cp-1"]
  }

  assert {
    condition     = sort([for patch in local.disk_encryption_patches["unfold-cp-1"] : yamldecode(patch).name]) == tolist(["EPHEMERAL", "STATE"])
    error_message = "a listed node encrypts STATE and EPHEMERAL"
  }

  assert {
    condition = alltrue([
      for patch in local.disk_encryption_patches["unfold-cp-1"] : alltrue([
        yamldecode(patch).encryption.provider == "luks2",
        yamldecode(patch).encryption.cipher == "aes-xts-plain64",
        yamldecode(patch).encryption.blockSize == 4096,
        yamldecode(patch).encryption.options == ["no_read_workqueue", "no_write_workqueue"],
        yamldecode(patch).encryption.keys == [{ slot = 0, kms = { endpoint = "https://kms.example.org:4050" } }],
        !can(yamldecode(patch).encryption.allowDiscards),
      ])
    ])
    error_message = "LUKS2 aes-xts-plain64, 4096-byte sectors, both work queues off, one KMS key in slot 0, no nodeID or static key, discards off (RFC 0001)"
  }

  assert {
    condition = alltrue([
      for name in ["unfold-cp-2", "unfold-cp-3", "unfold-app-1"] : length(local.disk_encryption_patches[name]) == 0
    ])
    error_message = "only listed nodes get the encrypted VolumeConfig; the others would refuse their plain volumes at the next boot"
  }

  assert {
    condition = alltrue([
      for patch in local.disk_encryption_patches["unfold-cp-1"] : contains(talos_machine_configuration_apply.control_plane["unfold-cp-1"].config_patches, patch)
    ])
    error_message = "the encrypted VolumeConfig must reach the listed node's machine config"
  }
}

run "encryption_without_a_key_server_is_refused" {
  command = plan

  variables {
    disk_encryption_nodes = ["unfold-cp-1"]
  }

  expect_failures = [var.disk_encryption_nodes]
}

run "a_plaintext_key_server_is_refused" {
  command = plan

  variables {
    disk_encryption_kms_endpoint = "grpc://10.64.0.5:4050"
  }

  expect_failures = [var.disk_encryption_kms_endpoint]
}

run "an_unknown_node_is_refused" {
  command = plan

  variables {
    disk_encryption_kms_endpoint = "https://kms.example.org:4050"
    disk_encryption_nodes        = ["unfold-cp-9"]
  }

  expect_failures = [var.disk_encryption_nodes]
}
