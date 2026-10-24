locals {
  cluster_enabled = nonsensitive(try(length(var.tailscale_authkey), 0) > 0)

  network_range        = "10.64.0.0/16"
  cloud_subnet_range   = "10.64.0.0/24"
  vswitch_subnet_range = "10.64.1.0/24"
  api_vip              = "10.64.0.10"
  private_link_alias   = "private0"

  cilium_cluster_id = 2
  pod_subnet        = "10.65.0.0/16"
  service_subnet    = "10.66.0.0/16"

  control_planes = {
    "unfold-cp-1" = "10.64.0.11"
    "unfold-cp-2" = "10.64.0.12"
    "unfold-cp-3" = "10.64.0.13"
  }

  unfold_worker = {
    "unfold-app-1" = "10.64.0.21"
  }
}

resource "hcloud_network" "cluster" {
  name                     = "unfold-cluster"
  ip_range                 = local.network_range
  expose_routes_to_vswitch = var.vswitch_id != null
  delete_protection        = true

  labels = {
    cluster = "unfold-main"
  }
}

resource "hcloud_network_subnet" "cloud" {
  network_id   = hcloud_network.cluster.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = local.cloud_subnet_range
}

resource "hcloud_network_subnet" "vswitch" {
  count = var.vswitch_id == null ? 0 : 1

  network_id   = hcloud_network.cluster.id
  type         = "vswitch"
  network_zone = "eu-central"
  ip_range     = local.vswitch_subnet_range
  vswitch_id   = var.vswitch_id
}
