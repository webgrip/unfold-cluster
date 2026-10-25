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

override_data {
  target = data.external.disk_kms_master_key
  values = {
    result = {
      master_key = "q83vEjRWeJCrze8SNFZ4kKvN7xI0VniQq83vEjRWeJA="
    }
  }
}

run "only_the_metal_node_is_encrypted_by_default" {
  command = plan

  assert {
    condition     = alltrue([for name, patches in local.disk_encryption_patches : length(patches) == (name == "unfold-metal-1" ? 2 : 0)])
    error_message = "unfold-metal-1 is encrypted from its first install; every running cloud node stays plain until it is listed, because listing it wipes it"
  }

  assert {
    condition = alltrue([
      for patch in local.disk_encryption_patches["unfold-metal-1"] : alltrue([
        yamldecode(patch).encryption.allowDiscards == true,
        yamldecode(patch).encryption.keys == [{ slot = 0, kms = { endpoint = "https://headscale.webgrip.dev:4050" } }],
      ])
    ])
    error_message = "the AX41 seals with the same KMS key and passes discards to its local NVMe (ADR 0003)"
  }

  assert {
    condition     = alltrue([for name, environment in local.disk_encryption_node_environment : environment.DESIRED == "plain"])
    error_message = "with no node listed, every node's re-install step leaves plain volumes alone"
  }
}

run "a_listed_node_seals_state_and_ephemeral_with_the_kms_on_headscale_and_nothing_weaker" {
  command = plan

  variables {
    disk_encryption_nodes = ["unfold-cp-1"]
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
        yamldecode(patch).encryption.keys == [{ slot = 0, kms = { endpoint = "https://headscale.webgrip.dev:4050" } }],
        yamldecode(patch).encryption.allowDiscards == false,
      ])
    ])
    error_message = "LUKS2 aes-xts-plain64, 4096-byte sectors, both work queues off, one KMS key in slot 0 on unfold-headscale, no nodeID or static key, discards off on a cloud disk (RFC 0001, ADR 0003)"
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

run "a_listed_node_is_reinstalled_and_rejoined_with_what_the_script_needs" {
  command = plan

  variables {
    disk_encryption_nodes = ["unfold-cp-3"]
  }

  assert {
    condition = alltrue([
      terraform_data.disk_encryption_reinstall["unfold-cp-3"].triggers_replace == [true],
      terraform_data.disk_encryption_reinstall["unfold-app-1"].triggers_replace == [false],
    ])
    error_message = "the re-install step of a node is replaced exactly when the node joins or leaves disk_encryption_nodes"
  }

  assert {
    condition = alltrue([
      local.disk_encryption_node_environment["unfold-cp-3"].DESIRED == "encrypted",
      local.disk_encryption_node_environment["unfold-cp-3"].NODE_ROLE == "controlplane",
      local.disk_encryption_node_environment["unfold-app-1"].NODE_ROLE == "worker",
      local.disk_encryption_node_environment["unfold-cp-3"].KMS_ENDPOINT == "https://headscale.webgrip.dev:4050",
      local.disk_encryption_node_environment["unfold-cp-3"].KUBE_TLS_SERVER_NAME == local.api_vip,
      length(split(" ", local.disk_encryption_node_environment["unfold-cp-3"].CONTROL_PLANE_IPS)) == 3,
    ])
    error_message = "encrypt-node.sh needs the desired state, the role (a control plane leaves etcd), the KMS to check, the API certificate name and every control plane to count etcd members"
  }

  assert {
    condition     = keys(terraform_data.disk_encryption_reinstall) == keys(terraform_data.disk_encryption_rejoin)
    error_message = "every node that can be re-installed is also waited for until it rejoins"
  }
}

run "a_worker_listed_for_encryption_asks_for_a_new_tailnet_key" {
  command = plan

  variables {
    disk_encryption_nodes = ["unfold-app-1"]
  }

  assert {
    condition     = endswith(local.worker_tailnet_key_slot["unfold-app-1"], "1")
    error_message = "a wiped worker has lost its tailnet state, and its single-use key was spent at its first boot: re-installing it must mint a key in a new slot"
  }
}

run "an_unlisted_worker_keeps_its_tailnet_key_slot" {
  command = plan

  assert {
    condition     = local.worker_tailnet_key_slot["unfold-app-1"] == "106${replace(var.tailnet_key_generation, "-", "")}"
    error_message = "a worker that is not re-installed keeps the slot of its stored key, so this change mints nothing"
  }
}

run "the_metal_node_reaches_the_kms" {
  command = plan

  assert {
    condition     = length(local.disk_kms_metal_client_ipv4s) == length(var.metal_servers)
    error_message = "every metal node's public address is a source of the KMS firewall, or its STATE never opens"
  }
}

run "only_the_nodes_and_the_admin_addresses_reach_the_kms" {
  command = plan

  variables {
    metal_servers         = {}
    disk_encryption_nodes = []
  }

  assert {
    condition = alltrue([
      length(hcloud_firewall.disk_kms.rule) == 1,
      one(hcloud_firewall.disk_kms.rule).direction == "in",
      one(hcloud_firewall.disk_kms.rule).protocol == "tcp",
      one(hcloud_firewall.disk_kms.rule).port == "4050",
      toset(one(hcloud_firewall.disk_kms.rule).source_ips) == toset(["198.51.100.10/32", "203.0.113.7/32"]),
    ])
    error_message = "the KMS unseals for anyone holding a LUKS header, so only the cloud and metal nodes' public addresses and the runners' (for the pre-flight TLS check) may reach it"
  }

  assert {
    condition     = hcloud_firewall_attachment.disk_kms.server_ids == toset([tonumber(hcloud_server.headscale.id)])
    error_message = "the KMS firewall is attached to unfold-headscale"
  }

  assert {
    condition     = hcloud_server.headscale.ignore_remote_firewall_ids
    error_message = "unfold-headscale must ignore the attached KMS firewall in its firewall_ids, or every plan detaches it"
  }
}

run "headscale_runs_the_kms_with_the_master_key_from_openbao" {
  command = plan

  assert {
    condition = alltrue([
      strcontains(hcloud_server.headscale.user_data, "ghcr.io/siderolabs/kms-server:v0.2.0@sha256:"),
      strcontains(hcloud_server.headscale.user_data, "--kms-api-endpoint :4050"),
      strcontains(hcloud_server.headscale.user_data, "--tls-enable"),
      strcontains(hcloud_server.headscale.user_data, "content: \"q83vEjRWeJCrze8SNFZ4kKvN7xI0VniQq83vEjRWeJA=\""),
      strcontains(hcloud_server.headscale.user_data, "PathChanged=/var/lib/headscale/cache"),
    ])
    error_message = "cloud-init installs kms-server by digest with TLS from Headscale's certificate, the master key OpenBao holds, and a restart on certificate renewal"
  }

  assert {
    condition     = can(yamldecode(hcloud_server.headscale.user_data))
    error_message = "the cloud-init stays valid YAML"
  }
}

run "an_apply_without_a_master_key_is_refused" {
  command = plan

  variables {
    talos_snapshot_required = true
  }

  override_data {
    target = data.external.disk_kms_master_key
    values = {
      result = {
        master_key = ""
      }
    }
  }

  expect_failures = [hcloud_server.headscale]
}

run "a_plaintext_key_server_is_refused" {
  command = plan

  variables {
    disk_encryption_kms_endpoint = "grpc://10.64.0.5:4050"
  }

  expect_failures = [var.disk_encryption_kms_endpoint]
}

run "another_key_server_can_be_named" {
  command = plan

  variables {
    disk_encryption_kms_endpoint = "https://kms.example.org:4050"
    disk_encryption_nodes        = ["unfold-cp-1"]
  }

  assert {
    condition     = alltrue([for patch in local.disk_encryption_patches["unfold-cp-1"] : yamldecode(patch).encryption.keys[0].kms.endpoint == "https://kms.example.org:4050"])
    error_message = "disk_encryption_kms_endpoint moves the KMS off unfold-headscale"
  }
}

run "an_unknown_node_is_refused" {
  command = plan

  variables {
    disk_encryption_nodes = ["unfold-cp-9"]
  }

  expect_failures = [var.disk_encryption_nodes]
}
