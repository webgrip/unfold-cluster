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

override_data {
  target = data.external.metal_quote
  values = {
    result = {
      state           = "to-order"
      product         = "AX41-NVMe"
      location        = "FSN1"
      server_number   = ""
      monthly_net_eur = "50.7000"
      setup_net_eur   = "0.0000"
    }
  }
}

override_data {
  target = data.external.metal_server
  values = {
    result = {
      server_number   = "2345678"
      server_ip       = "198.51.100.40"
      server_ipv6_net = "2a01:4f8::"
      status          = "ready"
    }
  }
}

override_data {
  target = data.external.robot_vswitch
  values = {
    result = {
      id = "31337"
    }
  }
}

override_data {
  target = data.external.metal_link
  values = {
    result = {
      mac = "a8:a1:59:0b:1c:2d"
    }
  }
}

variables {
  state_passphrase     = "mock-passphrase-of-at-least-thirty-two-characters"
  admin_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMockOwnerKey owner"
  admin_cidrs          = ["203.0.113.7/32"]
  metal_image_file     = "tests/fixtures/metal-image-pinned.yaml"
}

run "the_ax41_is_ordered_once_with_its_price_in_the_reviewed_plan" {
  command = plan

  assert {
    condition = terraform_data.metal_order["unfold-metal-1"].input == {
      product         = "AX41-NVMe"
      location        = "FSN1"
      primary_ipv4    = true
      quoted_state    = "to-order"
      monthly_net_eur = "50.7000"
      setup_net_eur   = "0.0000"
    }
    error_message = "the plan that orders the AX41 shows its product, location, IPv4 address and price, so the reviewed digest covers the purchase"
  }

  assert {
    condition     = length(var.metal_servers) == 1 && var.metal_servers["unfold-metal-1"].max_monthly_eur == 65 && var.metal_servers["unfold-metal-1"].max_setup_eur == 0
    error_message = "git declares exactly one AX41 with a ceiling of 65 EUR a month and no setup fee"
  }
}

run "the_metal_node_joins_the_cloud_network_through_the_vswitch" {
  command = plan

  assert {
    condition     = hcloud_network.cluster.expose_routes_to_vswitch && hcloud_network_subnet.vswitch[0].ip_range == "10.64.1.0/24" && hcloud_network_subnet.vswitch[0].network_zone == "eu-central"
    error_message = "the vSwitch subnet 10.64.1.0/24 joins the Robot vSwitch to the Cloud Network, which exposes its routes to it"
  }

  assert {
    condition     = local.metal_nodes["unfold-metal-1"].private_ip == "10.64.1.31"
    error_message = "unfold-metal-1 takes 10.64.1.31 on the vSwitch"
  }

  assert {
    condition     = local.metal_vswitch_mtu == yamldecode(file("${path.module}/../kubernetes/platform/cilium/values.yaml")).MTU && var.metal_vswitch_vlan == 4000
    error_message = "the vSwitch VLAN runs at the MTU Cilium is configured for, 1400"
  }
}

run "the_metal_node_is_a_tainted_kata_and_gvisor_pool_named_by_its_robot_number" {
  command = plan

  assert {
    condition = yamldecode(local.metal_pool_patch) == {
      apiVersion = "v1alpha1"
      kind       = "KubeNodeConfig"
      labels = {
        "node.webgrip.io/pool"               = "metal"
        "runtime.webgrip.io/kata"            = "true"
        "runtime.webgrip.io/gvisor"          = "true"
        "runtime.webgrip.io/kvm"             = "true"
        "instance.hetzner.cloud/provided-by" = "robot"
      }
      taints = { "node.webgrip.io/pool" = "metal:NoSchedule" }
    }
    error_message = "the metal node carries the pool, kata, gvisor and kvm labels and the provided-by label that keeps the hcloud CSI node plugin off it"
  }

  assert {
    condition     = !contains(data.talos_machine_configuration.metal.config_patches, local.hcloud_cloud_provider_patch)
    error_message = "the metal node does not wait for the hcloud cloud controller to initialise it"
  }

  assert {
    condition     = yamldecode(local.metal_install_patch).installer.image == "forgejo.webgrip.dev/webgrip/talos-installer-unfold-metal:v1.14.4-kata4.3.1-webgrip.1@sha256:1111111111111111111111111111111111111111111111111111111111111111"
    error_message = "the metal node upgrades with the pinned Kata 4.3.1 installer"
  }

  assert {
    condition     = local.metal_kubelet_reservations.systemReserved.memory == "2Gi" && local.metal_kubelet_reservations.kubeReserved.cpu == "500m"
    error_message = "the kubelet reserves room for the system and for the sandboxes' VMMs outside pod requests"
  }
}

run "gvisor_runs_on_kvm_on_metal_and_systrap_in_the_cloud_with_seccomp_inside" {
  command = plan

  assert {
    condition     = strcontains(yamldecode(local.gvisor_runtime_patches[var.metal_servers["unfold-metal-1"].gvisor_platform][1]).contents, "platform = \"kvm\"") && strcontains(yamldecode(local.gvisor_runtime_patches.kvm[1]).contents, "oci-seccomp = \"true\"")
    error_message = "gVisor on the metal node uses the KVM platform and applies each pod's seccomp profile inside the sandbox"
  }

  assert {
    condition     = strcontains(yamldecode(local.worker_sandbox_patches["ci"][1]).contents, "platform = \"systrap\"") && length(local.worker_sandbox_patches["unfold"]) == 0
    error_message = "the cloud CI pool runs gVisor on systrap, and the hub pool gets no sandbox runtime"
  }

  assert {
    condition     = yamldecode(local.worker_sandbox_patches["ci"][0]).params["user.max_user_namespaces"] != "0"
    error_message = "gVisor needs user namespaces, which Talos turns off by default"
  }

  assert {
    condition     = strcontains(yamldecode(local.worker_sandbox_patches["ci"][2]).content, "ConfigPath = \"/etc/unfold-sandbox/runsc.toml\"")
    error_message = "containerd hands runsc the node's own config file"
  }
}

run "kvm_can_fall_back_to_systrap" {
  command = plan

  variables {
    metal_servers = {
      "unfold-metal-1" = {
        product         = "AX41-NVMe"
        location        = "FSN1"
        max_monthly_eur = 65
        private_host    = 31
        gvisor_platform = "systrap"
      }
    }
  }

  assert {
    condition     = strcontains(yamldecode(local.gvisor_runtime_patches[var.metal_servers["unfold-metal-1"].gvisor_platform][1]).contents, "platform = \"systrap\"")
    error_message = "gvisor_platform switches the metal node to systrap"
  }
}

run "the_robot_firewall_admits_apid_from_the_admins_and_the_rest_only_privately" {
  command = plan

  assert {
    condition = local.metal_robot_firewall.input[length(local.metal_robot_firewall.input) - 1] == {
      name = "admin-tcp-1", ip_version = "ipv4", protocol = "tcp", src_ip = "203.0.113.7/32", action = "accept"
    }
    error_message = "only ADMIN_CIDRS reach the node over TCP: the rescue system's SSH during an install, apid on 50000 after it, and the Talos host firewall narrows that to apid"
  }

  assert {
    condition     = length([for rule in local.metal_robot_firewall.input : rule if lookup(rule, "src_ip", "") == "" && lookup(rule, "protocol", "") == "tcp" && lookup(rule, "tcp_flags", "") != "ack"]) == 0
    error_message = "no TCP port is open to the internet; only replies to the node's own connections come back"
  }

  assert {
    condition     = local.metal_robot_firewall.input[0].src_ip == "10.64.0.0/16"
    error_message = "the private network, which the Robot firewall also filters on the vSwitch, is admitted"
  }
}

run "five_admin_ranges_overflow_the_robot_firewall" {
  command = plan

  variables {
    admin_cidrs = ["203.0.113.1/32", "203.0.113.2/32", "203.0.113.3/32", "203.0.113.4/32", "203.0.113.5/32"]
  }

  expect_failures = [
    terraform_data.metal_robot_firewall,
  ]
}

run "an_unpinned_image_orders_and_wires_the_server_but_installs_nothing" {
  command = plan

  variables {
    metal_image_file = "../talos/metal-image.yaml"
  }

  assert {
    condition     = length(terraform_data.metal_order) == 1 && length(terraform_data.metal_robot_firewall) == 1 && length(terraform_data.metal_install) == 0 && length(talos_machine_configuration_apply.metal) == 0
    error_message = "until talos/metal-image.yaml is pinned, the server is ordered, firewalled and on the vSwitch, and nothing is installed"
  }
}

run "an_installer_for_another_talos_version_is_refused" {
  command = plan

  variables {
    metal_image_file = "tests/fixtures/metal-image-other-talos.yaml"
  }

  expect_failures = [
    terraform_data.metal_install,
  ]
}

run "the_install_reruns_only_for_a_new_server_or_a_raised_generation" {
  command = plan

  assert {
    condition     = length(terraform_data.metal_install["unfold-metal-1"].triggers_replace) == 2 && terraform_data.metal_install["unfold-metal-1"].triggers_replace[1] == 1
    error_message = "a new image pin or Talos version never reinstalls a node; only another server or a raised install_generation does"
  }
}

run "a_metal_node_not_named_unfold_metal_n_is_refused" {
  command = plan

  variables {
    metal_servers = {
      "gpu-1" = { product = "AX41-NVMe", location = "FSN1", max_monthly_eur = 65, private_host = 31 }
    }
  }

  expect_failures = [var.metal_servers]
}

run "a_price_ceiling_above_one_hundred_is_refused" {
  command = plan

  variables {
    metal_servers = {
      "unfold-metal-1" = { product = "AX41-NVMe", location = "FSN1", max_monthly_eur = 150, private_host = 31 }
    }
  }

  expect_failures = [var.metal_servers]
}

run "a_location_outside_the_network_zone_is_refused" {
  command = plan

  variables {
    metal_servers = {
      "unfold-metal-1" = { product = "AX41-NVMe", location = "HEL1", max_monthly_eur = 65, private_host = 31 }
    }
  }

  expect_failures = [var.metal_servers]
}

run "an_unknown_gvisor_platform_is_refused" {
  command = plan

  variables {
    metal_servers = {
      "unfold-metal-1" = { product = "AX41-NVMe", location = "FSN1", max_monthly_eur = 65, private_host = 31, gvisor_platform = "ptrace" }
    }
  }

  expect_failures = [var.metal_servers]
}

run "the_metal_image_carries_gvisor_and_tailscale_and_leaves_kata_to_our_build" {
  command = plan

  assert {
    condition = alltrue([
      contains(yamldecode(file("${path.module}/../talos/schematics/metal.yaml")).customization.systemExtensions.officialExtensions, "siderolabs/gvisor"),
      contains(yamldecode(file("${path.module}/../talos/schematics/metal.yaml")).customization.systemExtensions.officialExtensions, "siderolabs/tailscale"),
      !contains(yamldecode(file("${path.module}/../talos/schematics/metal.yaml")).customization.systemExtensions.officialExtensions, "siderolabs/kata-containers"),
    ])
    error_message = "the metal image lists gvisor and tailscale as official extensions; Kata 4.3.1 is our own extension, never Sidero's 3.32"
  }
}
