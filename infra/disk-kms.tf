locals {
  # renovate: datasource=docker depName=ghcr.io/siderolabs/kms-server
  disk_kms_server_version = "v0.2.0@sha256:db6ee3a76129c5e1f88da71e0f0871f4390c4ca937366101bef534d34468ebcb"

  disk_kms_server_image = "ghcr.io/siderolabs/kms-server:${local.disk_kms_server_version}"
  disk_kms_port         = 4050
  disk_kms_on_headscale = "https://${var.headscale_hostname}:${local.disk_kms_port}"

  disk_encryption_kms_endpoint = coalesce(var.disk_encryption_kms_endpoint, local.disk_kms_on_headscale)

  disk_kms_metal_client_ipv4s = [for name in keys(local.metal_active) : data.external.metal_server[name].result.server_ip]

  disk_kms_client_cidrs = distinct(concat(
    [for server in hcloud_server.control_plane : "${server.ipv4_address}/32"],
    [for server in hcloud_server.worker : "${server.ipv4_address}/32"],
    [for address in local.disk_kms_metal_client_ipv4s : "${address}/32"],
    var.admin_cidrs,
  ))

  disk_kms_master_key = sensitive(lookup(data.external.disk_kms_master_key.result, "master_key", ""))
}

data "external" "disk_kms_master_key" {
  program = ["${path.module}/../scripts/disk-kms-key.sh"]
  query   = { path = "unfold-cluster/disk-kms", property = "master_key" }
}

resource "hcloud_firewall" "disk_kms" {
  name = "unfold-disk-kms"

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = tostring(local.disk_kms_port)
    source_ips = local.disk_kms_client_cidrs
  }

  labels = {
    cluster = "unfold-main"
    role    = "disk-kms"
  }

  lifecycle {
    precondition {
      condition     = length(setintersection(local.encrypted_nodes, keys(local.metal_active))) <= length(local.disk_kms_metal_client_ipv4s)
      error_message = "A metal node listed in disk_encryption_nodes must reach the KMS: add its public IPv4 to disk_kms_metal_client_ipv4s, or its STATE never unlocks."
    }
  }
}

resource "hcloud_firewall_attachment" "disk_kms" {
  firewall_id = hcloud_firewall.disk_kms.id
  server_ids  = [hcloud_server.headscale.id]
}

output "disk_encryption_kms_endpoint" {
  description = "The KMS that seals the nodes' LUKS2 keys. The diagnose run checks that it answers TLS with a certificate that verifies."
  value       = local.disk_encryption_kms_endpoint
}
