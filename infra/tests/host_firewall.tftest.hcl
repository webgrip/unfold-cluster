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
        key = "hskey-auth-mocked"
      }
    }
  }
}

variables {
  state_passphrase     = "mock-passphrase-of-at-least-thirty-two-characters"
  admin_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMockOwnerKey owner"
  admin_cidrs          = ["203.0.113.7/32", "2001:db8::/64"]
}

run "every_node_blocks_inbound_connections_the_rules_do_not_name" {
  command = plan

  assert {
    condition = alltrue([
      contains(data.talos_machine_configuration.control_plane.config_patches, local.host_firewall_block_by_default),
      contains(data.talos_machine_configuration.worker.config_patches, local.host_firewall_block_by_default),
      yamldecode(local.host_firewall_block_by_default).ingress == "block",
    ])
    error_message = "both machine configs must carry NetworkDefaultActionConfig ingress: block"
  }

  assert {
    condition = alltrue([
      for patch in concat(local.host_firewall_patches.control_plane, local.host_firewall_patches.worker) :
      contains(data.talos_machine_configuration.control_plane.config_patches, patch) || contains(data.talos_machine_configuration.worker.config_patches, patch)
    ])
    error_message = "every firewall document must reach a machine config"
  }
}

run "the_operators_keep_two_independent_ways_to_the_talos_and_kubernetes_apis" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for role, rules in local.host_firewall_rules : [
        for rule in rules : [
          for source in concat(var.admin_cidrs, ["100.64.0.0/10", "fd7a:115c:a1e0::/48"]) : contains(rule.sources, source)
        ] if rule.name == "apid"
      ]
    ]))
    error_message = "apid must accept every ADMIN_CIDRS entry, from which OpenTofu and the diagnose run reach it, and the tailnet, the owner's way in when ADMIN_CIDRS is wrong"
  }

  assert {
    condition = alltrue([
      for source in concat(var.admin_cidrs, ["100.64.0.0/10", "fd7a:115c:a1e0::/48"]) :
      contains(one([for rule in local.host_firewall_rules.control_plane : rule if rule.name == "kube-apiserver"]).sources, source)
    ])
    error_message = "the API server must accept ADMIN_CIDRS, which the diagnose run uses on 6443, and the tailnet"
  }

  assert {
    condition = alltrue([
      for source in ["100.64.0.0/10", "fd7a:115c:a1e0::/48"] :
      strcontains(file("${path.module}/templates/headscale-cloud-init.yaml.tftpl"), source)
    ])
    error_message = "the tailnet prefixes the firewall allows must be the ones Headscale hands out"
  }

  assert {
    condition = alltrue([
      for rule in local.host_firewall_rules.control_plane : contains(rule.sources, local.pod_subnet) if contains(["apid", "kube-apiserver"], rule.name)
    ])
    error_message = "pods reach the API server through the kubernetes Service and the etcd backup reaches apid through the talos Service; both arrive from the pod network"
  }
}

run "the_firewall_opens_exactly_the_ports_the_nodes_listen_on_for_others" {
  command = plan

  assert {
    condition = sort([for rule in local.host_firewall_rules.control_plane : "${rule.protocol}/${join(",", [for port in rule.ports : tostring(port)])}"]) == sort([
      "tcp/10250", "udp/8472", "udp/51871", "tcp/4240", "tcp/4244", "tcp/50000", "tcp/6443", "tcp/50001", "tcp/2379-2380",
      "tcp/9100,9598,9962-9963,9965", "tcp/2383",
    ])
    error_message = "a control plane opens kubelet, Cilium VXLAN, WireGuard, health and Hubble, apid, the API server, trustd, etcd and the metrics ports, nothing more"
  }

  assert {
    condition = sort([for rule in local.host_firewall_rules.worker : "${rule.protocol}/${join(",", [for port in rule.ports : tostring(port)])}"]) == sort([
      "tcp/10250", "udp/8472", "udp/51871", "tcp/4240", "tcp/4244", "tcp/50000", "tcp/9100,9598,9962-9963,9965",
    ])
    error_message = "a worker runs no API server, trustd or etcd, so it opens none of their ports"
  }

  assert {
    condition = alltrue([
      for rule in concat(local.host_firewall_rules.control_plane, local.host_firewall_rules.worker) :
      rule.sources == [local.pod_subnet] if contains(["node-metrics", "etcd-metrics"], rule.name)
    ])
    error_message = "the metrics ports answer the scraper, which runs as a pod, and nothing else"
  }

  assert {
    condition     = sort(one([for rule in local.host_firewall_rules.control_plane : rule if rule.name == "etcd"]).sources) == sort([for address in values(local.control_planes) : "${address}/32"])
    error_message = "etcd accepts the control planes and nothing else"
  }

  assert {
    condition = alltrue([
      for rule in concat(local.host_firewall_rules.control_plane, local.host_firewall_rules.worker) :
      !contains(rule.sources, "0.0.0.0/0") && !contains(rule.sources, "::/0") if rule.name != "apid" && rule.name != "kube-apiserver"
    ])
    error_message = "only the two operator APIs may take a source from ADMIN_CIDRS; every other port stays inside the cluster"
  }
}

run "turning_the_firewall_off_returns_the_nodes_to_talos_defaults" {
  command = plan

  variables {
    host_firewall_enabled = false
  }

  assert {
    condition     = length(local.host_firewall_patches.control_plane) == 0 && length(local.host_firewall_patches.worker) == 0
    error_message = "host_firewall_enabled = false must remove every firewall document, the rollback"
  }
}
