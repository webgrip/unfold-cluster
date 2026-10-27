locals {
  autoscaled_subnet_range = "10.64.2.0/24"

  autoscaler_namespace          = "cluster-autoscaler"
  autoscaler_secret_name        = "cluster-autoscaler-hcloud"
  autoscaler_revision_name      = "cluster-autoscaler-revision"
  autoscaler_server_role        = "autoscaled-worker"
  autoscaler_node_group_label   = "hcloud/node-group"
  hetzner_user_data_limit_bytes = 32768

  talos_snapshot_selector = "os=talos,talos-version=${local.talos_version},talos-schematic=${substr(var.talos_cloud_schematic, 0, 32)},cluster=unfold-main"

  autoscaled_pool_taints = {
    for pool in var.autoscaled_worker_pools : pool => [
      for key, value_and_effect in var.worker_pools[pool].taints : {
        key    = key
        value  = split(":", value_and_effect)[0]
        effect = split(":", value_and_effect)[1]
      }
    ]
  }

  hostname_from_hetzner_patch = yamlencode({
    apiVersion = "v1alpha1"
    kind       = "HostnameConfig"
    auto       = "off"
  })

  autoscaled_pool_user_data = {
    for pool in var.autoscaled_worker_pools : pool => base64gzip(data.talos_machine_configuration.autoscaled_worker[pool].machine_configuration)
  }

  autoscaler_cluster_config = {
    imagesForArch = {
      amd64 = local.talos_snapshot_selector
      arm64 = ""
    }
    nodeConfigs = {
      for pool in var.autoscaled_worker_pools : pool => {
        cloudInit     = local.autoscaled_pool_user_data[pool]
        labels        = var.worker_pools[pool].labels
        taints        = local.autoscaled_pool_taints[pool]
        subnetIPRange = local.autoscaled_subnet_range
        serverLabels = {
          cluster = "unfold-main"
          role    = local.autoscaler_server_role
          pool    = pool
        }
      }
    }
  }

  autoscaler_environment = {
    HCLOUD_TOKEN                   = var.hcloud_autoscaler_token
    HCLOUD_CLUSTER_CONFIG          = base64encode(jsonencode(local.autoscaler_cluster_config))
    HCLOUD_NETWORK                 = tostring(hcloud_network_subnet.autoscaled.network_id)
    HCLOUD_FIREWALL                = tostring(hcloud_firewall.nodes.id)
    HCLOUD_SSH_KEY                 = tostring(hcloud_ssh_key.admin.id)
    HCLOUD_PUBLIC_IPV4             = "true"
    HCLOUD_PUBLIC_IPV6             = "true"
    HCLOUD_SERVER_CREATION_TIMEOUT = "10"
  }

  autoscaler_cluster_secrets = {
    for key, secret in {
      cluster-autoscaler = {
        name      = local.autoscaler_secret_name
        namespace = local.autoscaler_namespace
        data      = tomap(local.autoscaler_environment)
      }
      cluster-autoscaler-revision = {
        name      = local.autoscaler_revision_name
        namespace = local.flux_namespace
        data = tomap({
          CLUSTER_AUTOSCALER_REVISION = substr(sha256(jsonencode(local.autoscaler_environment)), 0, 16)
        })
      }
    } : key => secret if var.hcloud_autoscaler_token != ""
  }
}

resource "hcloud_network_subnet" "autoscaled" {
  network_id   = hcloud_network.cluster.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = local.autoscaled_subnet_range
}

data "talos_machine_configuration" "autoscaled_worker" {
  for_each = var.autoscaled_worker_pools

  cluster_name       = local.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "worker"
  machine_secrets    = talos_machine_secrets.cluster.machine_secrets
  talos_version      = local.talos_version
  kubernetes_version = local.kubernetes_version
  docs               = false
  examples           = false
  config_patches = concat(
    local.common_patches,
    local.host_firewall_patches.worker,
    local.log_shipping_patches,
    local.worker_sandbox_patches[each.key],
    [local.worker_pool_patch[each.key], local.hostname_from_hetzner_patch],
  )

  lifecycle {
    postcondition {
      condition     = length(base64gzip(self.machine_configuration)) <= local.hetzner_user_data_limit_bytes
      error_message = "The worker config of an autoscaled pool, gzipped and base64-encoded, is Hetzner user data, which may not exceed 32 KiB."
    }
  }
}
