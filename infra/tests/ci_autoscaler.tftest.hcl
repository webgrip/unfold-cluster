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

  mock_resource "hcloud_network_subnet" {
    defaults = {
      id = "101-10.64.2.0/24"
    }
  }

  mock_data "hcloud_images" {
    defaults = {
      images = []
    }
  }
}

mock_provider "talos" {
  mock_data "talos_machine_configuration" {
    defaults = {
      machine_configuration = "version: v1alpha1\nmachine:\n  type: worker\n"
    }
  }
}

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
  state_passphrase        = "mock-passphrase-of-at-least-thirty-two-characters"
  admin_ssh_public_key    = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMockOwnerKey owner"
  admin_cidrs             = ["203.0.113.7/32"]
  hcloud_autoscaler_token = "mock-autoscaler-token-of-sixty-four-characters-000000000000000000"
}

run "the_autoscaler_gets_its_own_token_and_a_ci_pool_config_in_its_namespace" {
  command = plan

  assert {
    condition = alltrue([
      local.cluster_secrets["cluster-autoscaler"].namespace == "cluster-autoscaler",
      local.cluster_secrets["cluster-autoscaler"].name == "cluster-autoscaler-hcloud",
      local.cluster_secrets["cluster-autoscaler"].data["HCLOUD_TOKEN"] == var.hcloud_autoscaler_token,
      local.cluster_secrets["cluster-autoscaler"].data["HCLOUD_TOKEN"] != local.cluster_secrets["hcloud"].data["token"],
    ])
    error_message = "the autoscaler reads its own token from its own Secret, never the cloud controller's"
  }

  assert {
    condition     = keys(local.autoscaler_cluster_config.nodeConfigs) == ["ci"]
    error_message = "the autoscaler knows exactly one node group, ci"
  }

  assert {
    condition = alltrue([
      local.cluster_secrets["cluster-autoscaler"].data["HCLOUD_PUBLIC_IPV4"] == "true",
      local.cluster_secrets["cluster-autoscaler"].data["HCLOUD_FIREWALL"] == "102",
      local.cluster_secrets["cluster-autoscaler"].data["HCLOUD_SSH_KEY"] == "104",
      local.cluster_secrets["cluster-autoscaler"].data["HCLOUD_NETWORK"] == "101",
    ])
    error_message = "a new CI server sits behind the nodes firewall, on the cluster network, with the admin SSH key so Hetzner mails no root password, and a public IPv4 for its image pulls"
  }
}

run "the_ci_template_matches_what_the_node_registers_with" {
  command = plan

  assert {
    condition     = local.autoscaler_cluster_config.nodeConfigs.ci.labels == tomap({ "node.webgrip.io/pool" = "ci", "runtime.webgrip.io/gvisor" = "true" })
    error_message = "the autoscaler simulates a new CI node with the pool label and the gVisor capability label the gvisor RuntimeClass selects; without them a pending runner never fits the template and nothing scales up"
  }

  assert {
    condition = local.autoscaler_cluster_config.nodeConfigs.ci.taints == [
      { key = "node.webgrip.io/pool", value = "ci", effect = "NoSchedule" },
    ]
    error_message = "the simulated node carries the ci taint as key, value and effect, the shape the autoscaler reads"
  }

  assert {
    condition = alltrue([
      contains(data.talos_machine_configuration.autoscaled_worker["ci"].config_patches, local.worker_pool_patch["ci"]),
      alltrue([for patch in local.gvisor_runtime_patches.systrap : contains(data.talos_machine_configuration.autoscaled_worker["ci"].config_patches, patch)]),
      alltrue([for patch in local.registry_mirror_patches : contains(data.talos_machine_configuration.autoscaled_worker["ci"].config_patches, patch)]),
      alltrue([for patch in local.host_firewall_patches.worker : contains(data.talos_machine_configuration.autoscaled_worker["ci"].config_patches, patch)]),
      contains(data.talos_machine_configuration.autoscaled_worker["ci"].config_patches, local.hostname_from_hetzner_patch),
    ])
    error_message = "a CI node boots with its pool's labels and taint, gVisor on systrap with user namespaces allowed, the Zot mirrors, the worker host firewall, and its Hetzner server name as hostname"
  }

  assert {
    condition = alltrue([
      for patch in data.talos_machine_configuration.autoscaled_worker["ci"].config_patches :
      !strcontains(patch, "ExtensionServiceConfig") && !strcontains(patch, "hskey-") && !strcontains(patch, "VolumeConfig")
    ])
    error_message = "the user data holds no tailnet key and no disk-encryption config: a CI node needs only the private network, and a static key in user data would outlive every node it was meant for"
  }

  assert {
    condition     = data.talos_machine_configuration.autoscaled_worker["ci"].machine_type == "worker" && data.talos_machine_configuration.autoscaled_worker["ci"].cluster_endpoint == "https://10.64.0.10:6443"
    error_message = "a CI node joins as a worker through the private API address"
  }

  assert {
    condition     = local.autoscaler_cluster_config.imagesForArch.amd64 == data.hcloud_images.talos.with_selector
    error_message = "the autoscaler boots the same Talos snapshot the static nodes boot, found by the same labels"
  }
}

run "autoscaled_servers_live_in_their_own_subnet_and_never_look_like_static_ones" {
  command = plan

  assert {
    condition = alltrue([
      hcloud_network_subnet.autoscaled.ip_range == "10.64.2.0/24",
      local.autoscaler_cluster_config.nodeConfigs.ci.subnetIPRange == hcloud_network_subnet.autoscaled.ip_range,
      cidrsubnet(local.network_range, 8, 2) == local.autoscaled_subnet_range,
      local.autoscaled_subnet_range != local.cloud_subnet_range,
      local.autoscaled_subnet_range != local.vswitch_subnet_range,
    ])
    error_message = "autoscaled servers take addresses from 10.64.2.0/24, so they never hold an address the static plan in 10.64.0.0/24 reserves"
  }

  assert {
    condition = local.autoscaler_cluster_config.nodeConfigs.ci.serverLabels == {
      cluster = "unfold-main"
      role    = "autoscaled-worker"
      pool    = "ci"
    }
    error_message = "autoscaled servers carry cluster=unfold-main and role=autoscaled-worker, the labels the homelab cost exporter and its long-running alert read"
  }

  assert {
    condition = alltrue(concat(
      [for server in hcloud_server.control_plane : !contains(keys(server.labels), local.autoscaler_node_group_label) && server.delete_protection],
      [for server in hcloud_server.worker : !contains(keys(server.labels), local.autoscaler_node_group_label) && server.delete_protection],
      [!contains(keys(hcloud_server.headscale.labels), local.autoscaler_node_group_label) && hcloud_server.headscale.delete_protection],
    ))
    error_message = "the autoscaler owns only servers labelled hcloud/node-group; no server OpenTofu creates may carry that label, and each keeps delete protection, which the Hetzner API enforces against any token"
  }
}

run "the_flux_revision_follows_the_config" {
  command = plan

  assert {
    condition = alltrue([
      local.cluster_secrets["cluster-autoscaler-revision"].namespace == "flux-system",
      keys(local.cluster_secrets["cluster-autoscaler-revision"].data) == tolist(["CLUSTER_AUTOSCALER_REVISION"]),
      strcontains(file("${path.module}/../kubernetes/platform/cluster-autoscaler/ks.yaml"), "name: ${local.autoscaler_revision_name}"),
      strcontains(file("${path.module}/../kubernetes/platform/cluster-autoscaler/app/helmrelease.yaml"), "$${CLUSTER_AUTOSCALER_REVISION"),
      strcontains(file("${path.module}/../kubernetes/platform/cluster-autoscaler/app/helmrelease.yaml"), "envFromSecret: ${local.autoscaler_secret_name}"),
    ])
    error_message = "Flux substitutes a digest of the autoscaler's environment, from the Secret the apply writes to flux-system, into the pod template of the HelmRelease that reads the autoscaler Secret, so a new token, snapshot or worker config restarts it"
  }
}

run "without_a_token_the_apply_writes_no_autoscaler_secret" {
  command = plan

  variables {
    hcloud_autoscaler_token = ""
  }

  assert {
    condition     = !contains(keys(local.cluster_secrets), "cluster-autoscaler") && !contains(keys(local.cluster_secrets), "cluster-autoscaler-revision") && contains(keys(local.cluster_secrets), "hcloud")
    error_message = "until the owner seeds the token the apply writes the other Secrets and leaves the autoscaler's out, instead of failing on an empty value"
  }
}

run "the_hub_worker_is_the_ci_baseline_under_gvisor" {
  command = plan

  assert {
    condition     = var.worker_pools["unfold"].labels == tomap({ "node.webgrip.io/pool" = "unfold", "runtime.webgrip.io/gvisor" = "true" })
    error_message = "unfold-app-1 carries the gVisor capability label the gvisor RuntimeClass selects, so the runner ScaledJob, which alone tolerates the unfold taint, runs its baseline CI jobs there"
  }

  assert {
    condition     = local.worker_sandbox_patches["unfold"] == tolist(local.gvisor_runtime_patches.systrap) && local.worker_sandbox_patches["ci"] == tolist(local.gvisor_runtime_patches.systrap)
    error_message = "the hub worker and the CI pool both get gVisor's systrap config with user namespaces allowed; a node labelled for gVisor without it fails every sandboxed pod"
  }

  assert {
    condition     = !contains(keys(var.worker_pools["unfold"].labels), "runtime.webgrip.io/kvm") && !contains(keys(local.autoscaler_cluster_config.nodeConfigs.ci.labels), "runtime.webgrip.io/kvm")
    error_message = "neither the hub worker nor the autoscaled CI template claims KVM, so the gVisor probe, which selects runtime.webgrip.io/kvm, never lands on them or makes the autoscaler buy a server for it"
  }

  assert {
    condition = anytrue([
      for patch in local.gvisor_runtime_patches.systrap :
      contains([for profile in try(yamldecode(patch).machine.seccompProfiles, []) : profile.name], local.buildkit_seccomp_name)
    ])
    error_message = "every gVisor node installs the buildkit-rootless seccomp profile; runsc applies each pod's profile (oci-seccomp), and RuntimeDefault refuses the unshare and keyctl calls rootless BuildKit needs"
  }

  assert {
    condition     = strcontains(file("${path.module}/../kubernetes/platform/ci-runners/app/scaledjob.yaml"), "localhostProfile: profiles/${local.buildkit_seccomp_name}")
    error_message = "buildkitd names the same Localhost seccomp profile the gVisor nodes install"
  }

  assert {
    condition     = length(regexall("localhostProfile: profiles/${local.buildkit_seccomp_name}", file("${path.module}/../kubernetes/platform/ci-runners/app/scaledjob.yaml"))) == 1 && length(regexall("localhostProfile: profiles/${local.runner_seccomp_name}", file("${path.module}/../kubernetes/platform/ci-runners/app/scaledjob.yaml"))) == 1
    error_message = "only buildkitd runs under buildkit-rootless.json; the runner container runs under ci-runner.json, RuntimeDefault with clone3 answered ENOSYS through a trace rule, because runsc without gVisor's errnoRet fix (merged 2026-10-12) turns RuntimeDefault's ENOSYS into EPERM and glibc then cannot start a thread"
  }

  assert {
    condition = anytrue([
      for patch in local.gvisor_runtime_patches.systrap :
      contains([for profile in try(yamldecode(patch).machine.seccompProfiles, []) : profile.name], local.runner_seccomp_name)
    ])
    error_message = "every gVisor node installs the ci-runner seccomp profile, RuntimeDefault with clone3 answered ENOSYS through SCMP_ACT_TRACE, ready for the runner container"
  }


  assert {
    condition     = var.worker_pools["unfold"].node_count == 1 && var.worker_pools["ci"].node_count == 0 && contains(var.autoscaled_worker_pools, "ci")
    error_message = "the baseline is the one hub worker; the CI pool has no fixed node and grows only through the autoscaler"
  }
}

run "an_autoscaled_pool_must_be_a_declared_pool" {
  command = plan

  variables {
    autoscaled_worker_pools = ["gpu"]
  }

  expect_failures = [
    var.autoscaled_worker_pools,
  ]
}
