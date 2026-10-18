resource "hcloud_placement_group" "control_planes" {
  name = "unfold-control-planes"
  type = "spread"

  labels = {
    cluster = "unfold-main"
  }
}

resource "hcloud_server" "control_plane" {
  for_each = local.control_planes

  name               = each.key
  server_type        = var.control_plane_server_type
  image              = var.talos_snapshot_id
  location           = var.location
  placement_group_id = hcloud_placement_group.control_planes.id
  firewall_ids       = [hcloud_firewall.nodes.id]

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  network {
    network_id = hcloud_network.cluster.id
    ip         = each.value
  }

  labels = {
    cluster = "unfold-main"
    role    = "controlplane"
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [image]
  }

  depends_on = [hcloud_network_subnet.cloud]
}

resource "hcloud_server" "unfold_worker" {
  for_each = local.unfold_worker

  name         = each.key
  server_type  = var.unfold_worker_server_type
  image        = var.talos_snapshot_id
  location     = var.location
  firewall_ids = [hcloud_firewall.nodes.id]

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  network {
    network_id = hcloud_network.cluster.id
    ip         = each.value
  }

  labels = {
    cluster = "unfold-main"
    role    = "worker"
    pool    = "unfold"
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [image]
  }

  depends_on = [hcloud_network_subnet.cloud]
}
