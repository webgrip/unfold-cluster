locals {
  talenv             = yamldecode(file("${path.module}/../talos/talenv.yaml"))
  talos_version      = local.talenv.talosVersion
  kubernetes_version = trimprefix(local.talenv.kubernetesVersion, "v")

  cluster_name     = "unfold-main"
  cluster_endpoint = "https://${local.api_vip}:6443"
  install_image    = "factory.talos.dev/installer/${var.talos_cloud_schematic}:${local.talos_version}"

  common_patches = [
    yamlencode({
      cluster = {
        externalCloudProvider = {
          enabled = true
        }
      }
    }),
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "UnattendedInstallConfig"
      installer = {
        image = local.install_image
      }
      provisioning = {
        diskSelector = {
          match = "disk.dev_path == \"/dev/sda\""
        }
      }
    }),
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeNodeConfig"
      nodeIP = {
        validSubnets = [local.network_range]
      }
    }),
    yamlencode({
      apiVersion     = "v1alpha1"
      kind           = "KubeNetworkConfig"
      podSubnets     = [local.pod_subnet]
      serviceSubnets = [local.service_subnet]
    }),
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeFlannelCNIConfig"
      "$patch"   = "delete"
    }),
  ]

  control_plane_patches = [
    yamlencode({
      cluster = {
        etcd = {
          advertisedSubnets = [local.network_range]
        }
        inlineManifests = local.inline_manifests
      }
    }),
    local.pod_security_patch,
    local.etcd_backup_access_patch,
    local.kube_proxy_disabled_patch,
  ]

  kube_proxy_disabled_patch = yamlencode({
    apiVersion = "v1alpha1"
    kind       = "KubeProxyConfig"
    enabled    = false
  })

  etcd_backup_access_patch = yamlencode({
    machine = {
      features = {
        kubernetesTalosAPIAccess = {
          enabled                     = true
          allowedRoles                = ["os:etcd:backup"]
          allowedKubernetesNamespaces = ["etcd-backup"]
        }
      }
    }
  })

  pod_security_patch = yamlencode({
    apiVersion = "v1alpha1"
    kind       = "KubeAdmissionControlConfig"
    name       = "PodSecurity"
    configuration = {
      apiVersion = "pod-security.admission.config.k8s.io/v1"
      kind       = "PodSecurityConfiguration"
      defaults = {
        enforce           = "restricted"
        "enforce-version" = "latest"
        audit             = "restricted"
        "audit-version"   = "latest"
        warn              = "restricted"
        "warn-version"    = "latest"
      }
    }
  })

  unfold_worker_patch = yamlencode({
    apiVersion = "v1alpha1"
    kind       = "KubeNodeConfig"
    labels = {
      "node.webgrip.io/pool" = "unfold"
    }
    taints = {
      "node.webgrip.io/pool" = "unfold:NoSchedule"
    }
  })
}

resource "talos_machine_secrets" "cluster" {
  talos_version = local.talos_version

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [talos_version]
  }
}

locals {
  api_vip_patch = yamlencode({
    apiVersion = "v1alpha1"
    kind       = "HCloudVIPConfig"
    name       = local.api_vip
    link       = local.private_link_alias
    apiToken   = var.hcloud_vip_token
  })
}

data "talos_machine_configuration" "control_plane" {
  cluster_name       = local.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.cluster.machine_secrets
  talos_version      = local.talos_version
  kubernetes_version = local.kubernetes_version
  docs               = false
  examples           = false
  config_patches     = concat(local.common_patches, local.control_plane_patches, [local.api_vip_patch], local.host_firewall_patches.control_plane)
}

data "talos_machine_configuration" "worker" {
  cluster_name       = local.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "worker"
  machine_secrets    = talos_machine_secrets.cluster.machine_secrets
  talos_version      = local.talos_version
  kubernetes_version = local.kubernetes_version
  docs               = false
  examples           = false
  config_patches     = concat(local.common_patches, local.host_firewall_patches.worker)
}

resource "talos_machine_configuration_apply" "control_plane" {
  for_each = {
    for name, server in hcloud_server.control_plane : name => {
      ipv4_address = server.ipv4_address
      private_mac  = one([for attachment in server.network : attachment.mac_address])
    }
  }

  client_configuration        = talos_machine_secrets.cluster.client_configuration
  machine_configuration_input = data.talos_machine_configuration.control_plane.machine_configuration
  node                        = each.value.ipv4_address
  endpoint                    = each.value.ipv4_address
  config_patches = [
    local.tailscale_patch[each.key],
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      auto       = "off"
      hostname   = each.key
    }),
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "LinkAliasConfig"
      name       = local.private_link_alias
      selector = {
        match = "mac(link.permanent_addr) == \"${lower(each.value.private_mac)}\""
      }
    }),
  ]
}

resource "talos_machine_configuration_apply" "unfold_worker" {
  for_each = { for name, server in hcloud_server.unfold_worker : name => server.ipv4_address }

  client_configuration        = talos_machine_secrets.cluster.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker.machine_configuration
  node                        = each.value
  endpoint                    = each.value
  config_patches = [
    local.unfold_worker_patch,
    local.tailscale_patch[each.key],
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      auto       = "off"
      hostname   = each.key
    }),
  ]
}

resource "talos_machine_bootstrap" "cluster" {
  client_configuration = talos_machine_secrets.cluster.client_configuration
  node                 = hcloud_server.control_plane["unfold-cp-1"].ipv4_address
  endpoint             = hcloud_server.control_plane["unfold-cp-1"].ipv4_address

  depends_on = [talos_machine_configuration_apply.control_plane]
}

data "talos_client_configuration" "cluster" {
  cluster_name         = local.cluster_name
  client_configuration = talos_machine_secrets.cluster.client_configuration
  endpoints            = [for server in hcloud_server.control_plane : server.ipv4_address]
  nodes                = concat([for server in hcloud_server.control_plane : server.ipv4_address], [for server in hcloud_server.unfold_worker : server.ipv4_address])
}

resource "talos_cluster_kubeconfig" "cluster" {
  client_configuration = talos_machine_secrets.cluster.client_configuration
  node                 = hcloud_server.control_plane["unfold-cp-1"].ipv4_address
  endpoint             = hcloud_server.control_plane["unfold-cp-1"].ipv4_address

  depends_on = [talos_machine_bootstrap.cluster]
}
