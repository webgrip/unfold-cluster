data "hcloud_images" "talos" {
  with_selector     = "os=talos,talos-version=${local.talos_version},talos-schematic=${substr(var.talos_cloud_schematic, 0, 32)},cluster=unfold-main"
  with_architecture = ["x86"]
  with_status       = ["available"]
  most_recent       = true
}

locals {
  talos_snapshot_id = try(tostring(data.hcloud_images.talos.images[0].id), "")
  talos_image       = local.talos_snapshot_id != "" ? local.talos_snapshot_id : "talos-snapshot-is-built-by-the-apply-run"
}

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
  image              = local.talos_image
  location           = var.location
  placement_group_id = hcloud_placement_group.control_planes.id
  firewall_ids       = [hcloud_firewall.nodes.id]
  delete_protection  = true
  rebuild_protection = true

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

    precondition {
      condition     = !var.talos_snapshot_required || local.talos_snapshot_id != ""
      error_message = "No available Hetzner snapshot carries the labels of Talos ${local.talos_version} with schematic ${var.talos_cloud_schematic}; scripts/build-talos-snapshot.sh builds it."
    }
  }

  depends_on = [hcloud_network_subnet.cloud, terraform_data.control_plane_tailnet_key]
}

resource "hcloud_server" "unfold_worker" {
  for_each = local.unfold_worker

  name               = each.key
  server_type        = var.unfold_worker_server_type
  image              = local.talos_image
  location           = var.location
  firewall_ids       = [hcloud_firewall.nodes.id]
  delete_protection  = true
  rebuild_protection = true

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

    precondition {
      condition     = !var.talos_snapshot_required || local.talos_snapshot_id != ""
      error_message = "No available Hetzner snapshot carries the labels of Talos ${local.talos_version} with schematic ${var.talos_cloud_schematic}; scripts/build-talos-snapshot.sh builds it."
    }
  }

  depends_on = [hcloud_network_subnet.cloud, terraform_data.control_plane_tailnet_key]
}
