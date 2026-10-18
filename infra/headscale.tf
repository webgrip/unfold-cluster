locals {
  headscale_version = "0.29.5"
  headscale_sha256  = "9e8ec12a65229435863a2cdf5082853c282808e845efd3a1f0b0c02b8f84d723"
}

resource "hcloud_ssh_key" "admin" {
  name       = "unfold-admin"
  public_key = var.admin_ssh_public_key
}

resource "hcloud_primary_ip" "headscale" {
  name        = "unfold-headscale-ipv4"
  type        = "ipv4"
  location    = var.location
  auto_delete = false

  labels = {
    cluster = "unfold-main"
    role    = "headscale"
  }
}

resource "hcloud_firewall" "headscale" {
  name = "unfold-headscale"

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "3478"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  dynamic "rule" {
    for_each = length(var.admin_cidrs) == 0 ? [] : ["22"]

    content {
      direction  = "in"
      protocol   = "tcp"
      port       = rule.value
      source_ips = var.admin_cidrs
    }
  }

  labels = {
    cluster = "unfold-main"
    role    = "headscale"
  }
}

resource "hcloud_server" "headscale" {
  name         = "unfold-headscale"
  server_type  = var.headscale_server_type
  image        = "ubuntu-24.04"
  location     = var.location
  ssh_keys     = [hcloud_ssh_key.admin.id]
  firewall_ids = [hcloud_firewall.headscale.id]

  public_net {
    ipv4_enabled = true
    ipv4         = hcloud_primary_ip.headscale.id
    ipv6_enabled = true
  }

  user_data = templatefile("${path.module}/templates/headscale-cloud-init.yaml.tftpl", {
    hostname          = var.headscale_hostname
    ipv4              = hcloud_primary_ip.headscale.ip_address
    acme_email        = var.acme_email
    ssh_public_key    = var.admin_ssh_public_key
    headscale_version = local.headscale_version
    headscale_sha256  = local.headscale_sha256
  })

  labels = {
    cluster = "unfold-main"
    role    = "headscale"
  }

  lifecycle {
    ignore_changes = [user_data, image]
  }
}
