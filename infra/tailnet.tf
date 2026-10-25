resource "tls_private_key" "headscale_tofu" {
  algorithm = "ED25519"
}

resource "tls_private_key" "headscale_host" {
  algorithm = "ED25519"
}

locals {
  tailnet_key_query = {
    host            = hcloud_primary_ip.headscale.ip_address
    host_public_key = trimspace(tls_private_key.headscale_host.public_key_openssh)
    private_key     = tls_private_key.headscale_tofu.private_key_openssh
  }
}

data "external" "control_plane_tailnet_key" {
  program = ["${path.module}/../scripts/read-tailnet-key.sh"]
  query   = merge(local.tailnet_key_query, { request = "control-plane" })

  depends_on = [hcloud_server.headscale]

  lifecycle {
    precondition {
      condition     = length(var.admin_cidrs) > 0
      error_message = "OpenTofu reads the tailnet keys over SSH, which the Headscale firewall opens only to admin_cidrs; set ADMIN_CIDRS to include the runners' address."
    }
  }
}

resource "terraform_data" "control_plane_tailnet_key" {
  for_each = local.control_planes

  input            = sensitive(data.external.control_plane_tailnet_key.result.key)
  triggers_replace = [var.tailnet_key_generation, hcloud_server.headscale.id]

  lifecycle {
    ignore_changes = [input]

    postcondition {
      condition     = startswith(self.output, "hskey-auth-")
      error_message = "unfold-headscale did not return the control planes' pre-auth key."
    }
  }
}

locals {
  worker_tailnet_tag = {
    for name, worker in local.workers : name => lookup(local.tailnet_tag_by_pool, worker.pool, "")
  }

  worker_tailnet_key_slot = {
    for name, server in hcloud_server.worker : name => "${server.id}${replace(var.tailnet_key_generation, "-", "")}${contains(var.disk_encryption_nodes, name) ? "1" : ""}"
  }
}

data "external" "worker_tailnet_key" {
  for_each = local.workers

  program = ["${path.module}/../scripts/read-tailnet-key.sh"]
  query   = merge(local.tailnet_key_query, { request = "worker ${local.worker_tailnet_key_slot[each.key]} ${local.worker_tailnet_tag[each.key]}" })

  depends_on = [hcloud_server.headscale, terraform_data.tailnet_key_tool]

  lifecycle {
    precondition {
      condition     = local.worker_tailnet_tag[each.key] != ""
      error_message = "Every worker pool needs a tailnet role tag in local.tailnet_tag_by_pool (infra/headscale.tf); the Headscale policy grants a tag only the homelab gateway ports its role needs."
    }
  }
}

resource "terraform_data" "worker_tailnet_key" {
  for_each = local.workers

  input            = sensitive(data.external.worker_tailnet_key[each.key].result.key)
  triggers_replace = [var.tailnet_key_generation, hcloud_server.headscale.id]

  lifecycle {
    ignore_changes       = [input]
    replace_triggered_by = [hcloud_server.worker[each.key].id, terraform_data.disk_encryption_reinstall[each.key]]

    postcondition {
      condition     = startswith(self.output, "hskey-auth-")
      error_message = "unfold-headscale did not return a worker pre-auth key."
    }
  }
}

locals {
  tailscale_login_args = "--login-server=https://${var.headscale_hostname} --accept-dns=false"

  tailscale_join = merge(
    {
      for name in keys(local.control_planes) : name => {
        authkey    = terraform_data.control_plane_tailnet_key[name].output
        extra_args = "${local.tailscale_login_args} --advertise-routes=${local.cloud_subnet_range}"
      }
    },
    {
      for name in keys(local.workers) : name => {
        authkey    = terraform_data.worker_tailnet_key[name].output
        extra_args = local.tailscale_login_args
      }
    },
  )

  tailscale_patch = {
    for name, node in local.tailscale_join : name => sensitive(yamlencode({
      apiVersion = "v1alpha1"
      kind       = "ExtensionServiceConfig"
      name       = "tailscale"
      environment = [
        "TS_AUTHKEY=${node.authkey}",
        "TS_AUTH_ONCE=true",
        "TS_EXTRA_ARGS=${node.extra_args}",
      ]
    }))
  }
}

locals {
  tailnet_node_tag = merge(
    { for name in keys(local.control_planes) : name => "tag:cp" },
    local.worker_tailnet_tag,
    { for name in keys(local.metal_installable) : name => local.tailnet_tag_by_pool["metal"] },
  )
}

resource "terraform_data" "tailnet_node_tag" {
  for_each = local.tailnet_node_tag

  triggers_replace = [each.value, hcloud_server.headscale.id]

  provisioner "local-exec" {
    command     = "${path.module}/../scripts/push-to-headscale.sh tag"
    environment = merge(local.headscale_ssh, { NODE_NAME = each.key, NODE_TAG = each.value })
  }

  depends_on = [terraform_data.headscale_policy]
}
