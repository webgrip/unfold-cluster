locals {
  headscale_ssh = {
    HEADSCALE_HOST            = hcloud_primary_ip.headscale.ip_address
    HEADSCALE_HOST_PUBLIC_KEY = trimspace(tls_private_key.headscale_host.public_key_openssh)
    HEADSCALE_TOFU_KEY        = tls_private_key.headscale_tofu.private_key_openssh
  }
}

resource "terraform_data" "tailnet_key_tool" {
  triggers_replace = [sha256(local.tailnet_key_tool), hcloud_server.headscale.id]

  provisioner "local-exec" {
    command     = "${path.module}/../scripts/push-to-headscale.sh install"
    environment = merge(local.headscale_ssh, { CONTENT_B64 = base64encode(local.tailnet_key_tool) })
  }
}

resource "terraform_data" "headscale_policy" {
  triggers_replace = [sha256(local.headscale_policy), hcloud_server.headscale.id]

  provisioner "local-exec" {
    command     = "${path.module}/../scripts/push-to-headscale.sh policy"
    environment = merge(local.headscale_ssh, { CONTENT_B64 = base64encode(local.headscale_policy) })
  }

  depends_on = [terraform_data.tailnet_key_tool]
}

data "external" "homelab_gateway_tailnet_key" {
  program = ["${path.module}/../scripts/read-tailnet-key.sh"]
  query   = merge(local.tailnet_key_query, { request = "gateway ${var.homelab_gateway_key_generation}" })

  depends_on = [terraform_data.headscale_policy]
}

resource "terraform_data" "homelab_gateway_tailnet_key" {
  input            = sensitive(data.external.homelab_gateway_tailnet_key.result.key)
  triggers_replace = [var.homelab_gateway_key_generation, hcloud_server.headscale.id]

  lifecycle {
    ignore_changes = [input]

    postcondition {
      condition     = startswith(self.output, "hskey-auth-")
      error_message = "unfold-headscale did not return the homelab gateway's pre-auth key."
    }
  }
}
