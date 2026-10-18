resource "hcloud_firewall" "nodes" {
  name = "unfold-nodes"

  rule {
    direction  = "in"
    protocol   = "icmp"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  dynamic "rule" {
    for_each = length(var.admin_cidrs) == 0 ? [] : ["50000", "6443"]

    content {
      direction  = "in"
      protocol   = "tcp"
      port       = rule.value
      source_ips = var.admin_cidrs
    }
  }

  labels = {
    cluster = "unfold-main"
  }
}
