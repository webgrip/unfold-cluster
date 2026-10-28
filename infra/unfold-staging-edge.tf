variable "unfold_staging_edge_enabled" {
  description = "Declare Unfold staging's public edge: the Cloudflare Tunnel, its DNS record and the Access applications (docs/adr/0017-staging-runs-here-with-agents-under-gvisor-on-the-hub.md). The infra workflow sets it true only while the repository variable UNFOLD_STAGING_EDGE is enabled, and the rebuild drill never does, so a throwaway cluster never takes the staging hostname."
  type        = bool
  default     = false
}

variable "cloudflare_api_token" {
  description = "The Cloudflare API token that manages the tunnel, the record and Access: Account Cloudflare Tunnel edit, Account Access apps and policies edit, Account Access identity providers edit, and Zone DNS edit on unfoldhq.dev. Read per run from OpenBao secret/cloudflare/unfold-tunnel (api-token)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "cloudflare_account_id" {
  description = "The Cloudflare account that holds the unfoldhq.dev zone, the tunnel and the Access applications."
  type        = string
  default     = ""
}

variable "cloudflare_zone_id_unfoldhq" {
  description = "The Cloudflare zone id of unfoldhq.dev."
  type        = string
  default     = ""
}

variable "unfold_staging_hostname" {
  description = "The one public hostname of Unfold staging. A name two levels below unfoldhq.dev needs Cloudflare Advanced Certificate Manager at the edge; a first-level name is covered by Universal SSL (docs/runbooks/unfold-staging-edge.md)."
  type        = string
  default     = "staging.app.unfoldhq.dev"

  validation {
    condition     = can(regex("^([a-z0-9-]+\\.)+unfoldhq\\.dev$", var.unfold_staging_hostname))
    error_message = "The staging hostname must be a name under unfoldhq.dev, the zone the token covers."
  }
}

variable "unfold_staging_access_emails" {
  description = "The email addresses Cloudflare Access lets into Unfold staging with a one-time PIN, as a JSON list."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for email in var.unfold_staging_access_emails : can(regex("^[^@\\s]+@[^@\\s]+\\.[a-z]+$", email))])
    error_message = "Every entry must be one email address."
  }
}

locals {
  unfold_staging_edge = var.unfold_staging_edge_enabled ? toset(["unfold-staging"]) : toset([])

  unfold_staging_origins = {
    webhooks = "http://ploeg.unfold-staging.svc.cluster.local:8080"
    unfold   = "http://unfold.unfold-staging.svc.cluster.local:4080"
  }

  unfold_staging_webhook_path = "/webhooks/"

  unfold_staging_ingress = [
    {
      hostname = var.unfold_staging_hostname
      path     = "^${local.unfold_staging_webhook_path}"
      service  = local.unfold_staging_origins.webhooks
    },
    {
      hostname = var.unfold_staging_hostname
      path     = null
      service  = local.unfold_staging_origins.unfold
    },
    {
      hostname = null
      path     = null
      service  = "http_status:404"
    },
  ]

  unfold_staging_access_session = "8h"
}

variable "unfold_staging_tunnel_generation" {
  description = "Raise to replace the staging tunnel's secret, and with it the tunnel, its record and the connector token the apply writes to OpenBao."
  type        = number
  default     = 1
}

resource "random_bytes" "unfold_staging_tunnel_secret" {
  for_each = local.unfold_staging_edge

  length = 32
  keepers = {
    generation = var.unfold_staging_tunnel_generation
  }
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "unfold_staging" {
  for_each = local.unfold_staging_edge

  account_id    = var.cloudflare_account_id
  name          = each.key
  config_src    = "cloudflare"
  tunnel_secret = random_bytes.unfold_staging_tunnel_secret[each.key].base64

  lifecycle {
    precondition {
      condition     = var.cloudflare_api_token != "" && var.cloudflare_account_id != "" && var.cloudflare_zone_id_unfoldhq != ""
      error_message = "The staging edge needs the Cloudflare token from OpenBao secret/cloudflare/unfold-tunnel and the variables CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_ZONE_ID_UNFOLDHQ (docs/runbooks/unfold-staging-edge.md)."
    }

    precondition {
      condition     = length(var.unfold_staging_access_emails) > 0
      error_message = "UNFOLD_STAGING_ACCESS_EMAILS is empty, so Access would let nobody in; set it before enabling the staging edge."
    }
  }
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "unfold_staging" {
  for_each = local.unfold_staging_edge

  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.unfold_staging[each.key].id

  config = {
    ingress = local.unfold_staging_ingress
  }
}

resource "cloudflare_dns_record" "unfold_staging" {
  for_each = local.unfold_staging_edge

  zone_id = var.cloudflare_zone_id_unfoldhq
  name    = var.unfold_staging_hostname
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.unfold_staging[each.key].id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "Unfold staging, through the tunnel unfold-staging; managed by unfold-cluster infra"
}

resource "cloudflare_zero_trust_access_identity_provider" "one_time_pin" {
  for_each = local.unfold_staging_edge

  account_id = var.cloudflare_account_id
  name       = "One-time PIN"
  type       = "onetimepin"
  config     = {}
}

resource "cloudflare_zero_trust_access_policy" "unfold_staging_people" {
  for_each = local.unfold_staging_edge

  account_id       = var.cloudflare_account_id
  name             = "unfold-staging people"
  decision         = "allow"
  session_duration = local.unfold_staging_access_session
  include          = [for email in var.unfold_staging_access_emails : { email = { email = email } }]
}

resource "cloudflare_zero_trust_access_policy" "unfold_staging_webhooks" {
  for_each = local.unfold_staging_edge

  account_id = var.cloudflare_account_id
  name       = "unfold-staging webhooks"
  decision   = "bypass"
  include    = [{ everyone = {} }]
}

resource "cloudflare_zero_trust_access_application" "unfold_staging" {
  for_each = local.unfold_staging_edge

  account_id                 = var.cloudflare_account_id
  name                       = "Unfold staging"
  type                       = "self_hosted"
  domain                     = var.unfold_staging_hostname
  destinations               = [{ type = "public", uri = var.unfold_staging_hostname }]
  session_duration           = local.unfold_staging_access_session
  allowed_idps               = [cloudflare_zero_trust_access_identity_provider.one_time_pin[each.key].id]
  auto_redirect_to_identity  = true
  app_launcher_visible       = false
  http_only_cookie_attribute = true
  same_site_cookie_attribute = "lax"
  policies = [
    { id = cloudflare_zero_trust_access_policy.unfold_staging_people[each.key].id, precedence = 1 },
  ]
}

resource "cloudflare_zero_trust_access_application" "unfold_staging_webhooks" {
  for_each = local.unfold_staging_edge

  account_id           = var.cloudflare_account_id
  name                 = "Unfold staging webhooks"
  type                 = "self_hosted"
  domain               = "${var.unfold_staging_hostname}${local.unfold_staging_webhook_path}"
  destinations         = [{ type = "public", uri = "${var.unfold_staging_hostname}${local.unfold_staging_webhook_path}" }]
  session_duration     = local.unfold_staging_access_session
  app_launcher_visible = false
  policies = [
    { id = cloudflare_zero_trust_access_policy.unfold_staging_webhooks[each.key].id, precedence = 1 },
  ]
}

locals {
  unfold_staging_tunnel_token = {
    for name, tunnel in cloudflare_zero_trust_tunnel_cloudflared.unfold_staging : name => base64encode(jsonencode({
      a = var.cloudflare_account_id
      t = tunnel.id
      s = random_bytes.unfold_staging_tunnel_secret[name].base64
    }))
  }
}

resource "terraform_data" "unfold_staging_tunnel_token" {
  for_each = local.unfold_staging_edge

  triggers_replace = [sha256(local.unfold_staging_tunnel_token[each.key])]

  provisioner "local-exec" {
    command = "printf '%s\\n' \"$TUNNEL_TOKEN\" | ${path.module}/../scripts/openbao-kv.sh put tunnel-token unfold-main/staging/cloudflare-tunnel token"
    environment = {
      TUNNEL_TOKEN = local.unfold_staging_tunnel_token[each.key]
    }
  }
}
