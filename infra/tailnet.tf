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
  worker_tailnet_key_slot = {
    for name, server in hcloud_server.worker : name => "${server.id}${replace(var.tailnet_key_generation, "-", "")}"
  }
}

data "external" "worker_tailnet_key" {
  for_each = local.workers

  program = ["${path.module}/../scripts/read-tailnet-key.sh"]
  query   = merge(local.tailnet_key_query, { request = "worker ${local.worker_tailnet_key_slot[each.key]}" })

  depends_on = [hcloud_server.headscale]
}

resource "terraform_data" "worker_tailnet_key" {
  for_each = local.workers

  input            = sensitive(data.external.worker_tailnet_key[each.key].result.key)
  triggers_replace = [var.tailnet_key_generation, hcloud_server.headscale.id]

  lifecycle {
    ignore_changes       = [input]
    replace_triggered_by = [hcloud_server.worker[each.key].id]

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
