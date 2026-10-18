locals {
  cluster_name     = "unfold-main"
  cluster_endpoint = "https://${local.control_planes["unfold-cp-1"]}:6443"
  install_image    = "factory.talos.dev/installer/${var.talos_cloud_schematic}:${var.talos_version}"

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
  talos_version = var.talos_version
}

data "talos_machine_configuration" "control_plane" {
  cluster_name       = local.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.cluster.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version
  docs               = false
  examples           = false
  config_patches     = [local.common_patch, local.control_plane_patch]
}

data "talos_machine_configuration" "worker" {
  cluster_name       = local.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "worker"
  machine_secrets    = talos_machine_secrets.cluster.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version
  docs               = false
  examples           = false
  config_patches     = [local.common_patch]
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
