variable "headscale_oidc_client_secret" {
  description = "Client secret of the Authentik application unfold-headscale. Generated in the homelab and kept in OpenBao secret/authentik/unfold-headscale-oidc (client_secret); the infra workflow reads it per run. It reaches the Headscale server only through the push tool, never through cloud-init or the plan. Empty skips the push, and Headscale then refuses every browser login at the token exchange."
  type        = string
  default     = ""
  sensitive   = true
}

locals {
  # renovate: datasource=github-releases depName=tailscale/tailscale extractVersion=^v(?<version>.+)$
  tailscale_version = "1.104.2"
  tailscale_sha256  = "512f613ed7d04fc7282f7dc5bd76aa105aae28168fbb9357eb749ebcbc29f0ae"

  headscale_own_node_wireguard_port = "41641"

  headscale_oidc = {
    issuer             = "https://authentik.webgrip.dev/application/o/unfold-headscale/"
    client_id          = "unfold-headscale"
    client_secret_path = "/etc/headscale/oidc_client_secret"
    allowed_groups     = ["unfold-admins"]
  }

  headscale_user_node_expiry = "720h"

  ops_console_domain = "ops.unfoldhq.dev"
  ops_console_hosts  = ["grafana", "headlamp", "hubble", "policy-reporter", "query"]
  ops_console_records = [
    for host in local.ops_console_hosts : { name = "${host}.${local.ops_console_domain}", type = "A", value = local.api_vip }
  ]

  headscale_config = templatefile("${path.module}/templates/headscale-config.yaml.tftpl", {
    hostname                = var.headscale_hostname
    ipv4                    = hcloud_primary_ip.headscale.ip_address
    acme_email              = var.acme_email
    user_node_expiry        = local.headscale_user_node_expiry
    oidc_issuer             = local.headscale_oidc.issuer
    oidc_client_id          = local.headscale_oidc.client_id
    oidc_client_secret_path = local.headscale_oidc.client_secret_path
    oidc_allowed_groups     = local.headscale_oidc.allowed_groups
    ops_console_records     = local.ops_console_records
  })

  headscale_oidc_client_secret_given = nonsensitive(var.headscale_oidc_client_secret != "")
}

resource "terraform_data" "headscale_host" {
  triggers_replace = [local.tailscale_version, local.tailscale_sha256, sha256(local.tailnet_key_tool), hcloud_server.headscale.id]

  provisioner "local-exec" {
    command = "${path.module}/../scripts/push-to-headscale.sh host"
    environment = merge(local.headscale_ssh, {
      TAILSCALE_VERSION = local.tailscale_version
      TAILSCALE_SHA256  = local.tailscale_sha256
    })
  }

  depends_on = [terraform_data.headscale_policy]
}

resource "terraform_data" "headscale_oidc_client_secret" {
  count = local.headscale_oidc_client_secret_given ? 1 : 0

  triggers_replace = [sha256(var.headscale_oidc_client_secret), hcloud_server.headscale.id]

  provisioner "local-exec" {
    command     = "${path.module}/../scripts/push-to-headscale.sh oidc-secret"
    environment = merge(local.headscale_ssh, { CONTENT_B64 = base64encode(var.headscale_oidc_client_secret) })
  }

  depends_on = [terraform_data.tailnet_key_tool]
}

resource "terraform_data" "headscale_config" {
  triggers_replace = [sha256(local.headscale_config), hcloud_server.headscale.id]

  provisioner "local-exec" {
    command     = "${path.module}/../scripts/push-to-headscale.sh config"
    environment = merge(local.headscale_ssh, { CONTENT_B64 = base64encode(local.headscale_config) })
  }

  depends_on = [terraform_data.headscale_host, terraform_data.headscale_oidc_client_secret]
}
