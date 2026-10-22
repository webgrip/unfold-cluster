locals {
  talenv             = yamldecode(file("${path.module}/../talos/talenv.yaml"))
  talos_version      = local.talenv.talosVersion
  kubernetes_version = trimprefix(local.talenv.kubernetesVersion, "v")

  cluster_name     = "unfold-main"
  cluster_endpoint = "https://${local.api_vip}:6443"
  install_image    = "factory.talos.dev/installer/${var.talos_cloud_schematic}:${local.talos_version}"

  common_patch = yamlencode({
    machine = {
      install = {
        image = local.install_image
      }
      kubelet = {
        nodeIP = {
          validSubnets = [local.network_range]
        }
      }
      features = {
        kubePrism = {
          enabled = true
          port    = 7445
        }
      }
    }
    cluster = {
      network = {
        cni = {
          name = "none"
        }
        podSubnets     = ["10.244.0.0/16"]
        serviceSubnets = ["10.96.0.0/12"]
      }
      proxy = {
        disabled = true
      }
      externalCloudProvider = {
        enabled = true
      }
    }
  })

  control_plane_patch = yamlencode({
    cluster = {
      etcd = {
        advertisedSubnets = [local.network_range]
      }
      inlineManifests = local.inline_manifests
    }
  })

  unfold_worker_patch = yamlencode({
    machine = {
      nodeLabels = {
        "node.webgrip.io/pool" = "unfold"
      }
      nodeTaints = {
        "node.webgrip.io/pool" = "unfold:NoSchedule"
      }
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
    link       = local.private_link
    apiToken   = var.hcloud_token
  })

  control_plane_tailscale_patch = yamlencode({
    apiVersion = "v1alpha1"
    kind       = "ExtensionServiceConfig"
    name       = "tailscale"
    environment = [
      "TS_AUTHKEY=${coalesce(var.tailscale_authkey, "unset")}",
      "TS_EXTRA_ARGS=--login-server=https://${var.headscale_hostname} --accept-dns=false --advertise-routes=${local.network_range}",
    ]
  })

  tailscale_patch = yamlencode({
    apiVersion = "v1alpha1"
    kind       = "ExtensionServiceConfig"
    name       = "tailscale"
    environment = [
      "TS_AUTHKEY=${coalesce(var.tailscale_authkey, "unset")}",
      "TS_EXTRA_ARGS=--login-server=https://${var.headscale_hostname} --accept-dns=false",
    ]
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
  config_patches     = [local.common_patch, local.control_plane_patch, local.control_plane_tailscale_patch, local.api_vip_patch]
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
  config_patches     = [local.common_patch, local.tailscale_patch]
}

resource "talos_machine_configuration_apply" "control_plane" {
  for_each = hcloud_server.control_plane

  client_configuration        = talos_machine_secrets.cluster.client_configuration
  machine_configuration_input = data.talos_machine_configuration.control_plane.machine_configuration
  node                        = each.value.ipv4_address
  endpoint                    = each.value.ipv4_address
  config_patches = [yamlencode({
    machine = {
      network = {
        hostname = each.key
      }
    }
  })]
}

resource "talos_machine_configuration_apply" "unfold_worker" {
  for_each = hcloud_server.unfold_worker

  client_configuration        = talos_machine_secrets.cluster.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker.machine_configuration
  node                        = each.value.ipv4_address
  endpoint                    = each.value.ipv4_address
  config_patches = [
    local.unfold_worker_patch,
    yamlencode({
      machine = {
        network = {
          hostname = each.key
        }
      }
    }),
  ]
}

resource "talos_machine_bootstrap" "cluster" {
  count = local.cluster_enabled ? 1 : 0

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
  count = local.cluster_enabled ? 1 : 0

  client_configuration = talos_machine_secrets.cluster.client_configuration
  node                 = hcloud_server.control_plane["unfold-cp-1"].ipv4_address
  endpoint             = hcloud_server.control_plane["unfold-cp-1"].ipv4_address

  depends_on = [talos_machine_bootstrap.cluster]
}
