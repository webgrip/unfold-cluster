mock_provider "hcloud" {
  mock_resource "hcloud_network" {
    defaults = {
      id = "101"
    }
  }

  mock_resource "hcloud_firewall" {
    defaults = {
      id = "102"
    }
  }

  mock_resource "hcloud_primary_ip" {
    defaults = {
      id = "103"
    }
  }

  mock_resource "hcloud_ssh_key" {
    defaults = {
      id = "104"
    }
  }

  mock_resource "hcloud_placement_group" {
    defaults = {
      id = "105"
    }
  }

  mock_resource "hcloud_server" {
    defaults = {
      id           = "106"
      ipv4_address = "198.51.100.10"
    }
  }

  mock_data "hcloud_images" {
    defaults = {
      images = []
    }
  }
}

mock_provider "talos" {}

mock_provider "helm" {}

mock_provider "tls" {}

mock_provider "random" {}

mock_provider "cloudflare" {}

mock_provider "external" {
  mock_data "external" {
    defaults = {
      result = {
        key             = "hskey-auth-mocked"
        state           = "ordered"
        product         = "AX41-NVMe"
        server_number   = "2345678"
        server_ip       = "198.51.100.40"
        monthly_net_eur = ""
        setup_net_eur   = ""
        id              = "31337"
        mac             = "a8:a1:59:0b:1c:2d"
      }
    }
  }
}

variables {
  state_passphrase             = "mock-passphrase-of-at-least-thirty-two-characters"
  admin_ssh_public_key         = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMockOwnerKey owner"
  admin_cidrs                  = ["203.0.113.7/32", "2001:db8::/64"]
  unfold_staging_edge_enabled  = true
  cloudflare_api_token         = "mock-cloudflare-token"
  cloudflare_account_id        = "0123456789abcdef0123456789abcdef"
  cloudflare_zone_id_unfoldhq  = "fedcba9876543210fedcba9876543210"
  unfold_staging_access_emails = ["owner@example.org"]
}

run "the_edge_is_off_unless_asked_for_so_the_rebuild_drill_never_takes_the_hostname" {
  command = plan

  variables {
    unfold_staging_edge_enabled = false
    cloudflare_api_token        = ""
  }

  assert {
    condition = alltrue([
      length(cloudflare_zero_trust_tunnel_cloudflared.unfold_staging) == 0,
      length(cloudflare_dns_record.unfold_staging) == 0,
      length(cloudflare_zero_trust_access_application.unfold_staging) == 0,
      length(terraform_data.unfold_staging_tunnel_token) == 0,
      length(cloudflare_zero_trust_access_service_token.unfold_staging_editors) == 0,
      length(cloudflare_zero_trust_access_policy.unfold_staging_editors) == 0,
      length(terraform_data.unfold_staging_editor_token) == 0,
      output.unfold_staging_editor_token_expires_at == null,
    ])
    error_message = "without unfold_staging_edge_enabled the plan declares no tunnel, record, Access application, service token or token write"
  }
}

run "the_tunnel_sends_webhooks_to_ploegd_everything_else_to_unfold_and_nothing_else_anywhere" {
  command = plan

  assert {
    condition = jsonencode([for rule in cloudflare_zero_trust_tunnel_cloudflared_config.unfold_staging["unfold-staging"].config.ingress : [rule.hostname, rule.path, rule.service]]) == jsonencode([
      ["staging-app.unfoldhq.dev", "^/webhooks/", "http://ploeg.unfold-staging.svc.cluster.local:8080"],
      ["staging-app.unfoldhq.dev", null, "http://unfold.unfold-staging.svc.cluster.local:4080"],
      [null, null, "http_status:404"],
    ])
    error_message = "the ingress is exactly: /webhooks/ on the staging host to ploegd, the rest of the staging host to Unfold, and a 404 for any other request; the order matters, because cloudflared takes the first rule that matches"
  }

  assert {
    condition     = cloudflare_zero_trust_tunnel_cloudflared.unfold_staging["unfold-staging"].config_src == "cloudflare"
    error_message = "the tunnel is remotely managed, so its routes live in this state and not in the connector's arguments"
  }
}

run "a_hostname_deeper_than_universal_ssl_covers_is_refused" {
  command = plan

  variables {
    unfold_staging_hostname = "staging.app.unfoldhq.dev"
  }

  expect_failures = [var.unfold_staging_hostname]
}

run "the_record_is_proxied_so_traffic_meets_cloudflare_before_the_tunnel" {
  command = plan

  override_resource {
    target = cloudflare_zero_trust_tunnel_cloudflared.unfold_staging
    values = {
      id = "0b6a1e2c-3d4f-4a5b-8c6d-7e8f9a0b1c2d"
    }
  }

  assert {
    condition = alltrue([
      cloudflare_dns_record.unfold_staging["unfold-staging"].proxied == true,
      cloudflare_dns_record.unfold_staging["unfold-staging"].type == "CNAME",
      cloudflare_dns_record.unfold_staging["unfold-staging"].name == "staging-app.unfoldhq.dev",
      cloudflare_dns_record.unfold_staging["unfold-staging"].content == "0b6a1e2c-3d4f-4a5b-8c6d-7e8f9a0b1c2d.cfargotunnel.com",
    ])
    error_message = "the staging name is a proxied CNAME to the tunnel; an unproxied record would publish the tunnel's id and skip Access"
  }
}

run "access_guards_the_host_and_lets_only_webhooks_past" {
  command = plan

  assert {
    condition = alltrue([
      cloudflare_zero_trust_access_application.unfold_staging["unfold-staging"].domain == "staging-app.unfoldhq.dev",
      cloudflare_zero_trust_access_policy.unfold_staging_people["unfold-staging"].decision == "allow",
      [for rule in cloudflare_zero_trust_access_policy.unfold_staging_people["unfold-staging"].include : rule.email_domain.domain if rule.email_domain != null] == ["webgrip.nl"],
      [for rule in cloudflare_zero_trust_access_policy.unfold_staging_people["unfold-staging"].include : rule.email.email if rule.email != null] == ["owner@example.org"],
      alltrue([for rule in cloudflare_zero_trust_access_policy.unfold_staging_people["unfold-staging"].include : rule.everyone == null]),
      cloudflare_zero_trust_access_application.unfold_staging["unfold-staging"].session_duration == "8h",
    ])
    error_message = "the whole staging host is behind an Access allow policy for the webgrip.nl domain and the listed addresses only, with an 8-hour session"
  }

  assert {
    condition = alltrue([
      cloudflare_zero_trust_access_application.unfold_staging_webhooks["unfold-staging"].domain == "staging-app.unfoldhq.dev/webhooks/",
      cloudflare_zero_trust_access_policy.unfold_staging_webhooks["unfold-staging"].decision == "bypass",
    ])
    error_message = "the bypass covers /webhooks/ and nothing wider: forges and the tracker cannot answer Access, and ploegd checks their HMAC"
  }

  assert {
    condition     = [for name, decision in { people = cloudflare_zero_trust_access_policy.unfold_staging_people["unfold-staging"].decision, editors = cloudflare_zero_trust_access_policy.unfold_staging_editors["unfold-staging"].decision, webhooks = cloudflare_zero_trust_access_policy.unfold_staging_webhooks["unfold-staging"].decision } : name if decision == "bypass"] == ["webhooks"]
    error_message = "exactly one policy bypasses Access, the webhook path's"
  }
}

run "a_client_without_a_browser_passes_access_with_the_one_service_token_and_nothing_wider" {
  command = plan

  override_resource {
    target = cloudflare_zero_trust_access_service_token.unfold_staging_editors
    values = {
      id = "f174e90a-fafe-4643-bbbc-4a0ed4fc8415"
    }
  }

  override_resource {
    target = cloudflare_zero_trust_access_policy.unfold_staging_people
    values = {
      id = "11111111-1111-4111-8111-111111111111"
    }
  }

  override_resource {
    target = cloudflare_zero_trust_access_policy.unfold_staging_editors
    values = {
      id = "22222222-2222-4222-8222-222222222222"
    }
  }

  assert {
    condition = alltrue([
      cloudflare_zero_trust_access_policy.unfold_staging_editors["unfold-staging"].decision == "non_identity",
      length(cloudflare_zero_trust_access_policy.unfold_staging_editors["unfold-staging"].include) == 1,
      [for rule in cloudflare_zero_trust_access_policy.unfold_staging_editors["unfold-staging"].include : [for kind, value in rule : kind if value != null]] == [["service_token"]],
      [for rule in cloudflare_zero_trust_access_policy.unfold_staging_editors["unfold-staging"].include : try(rule.service_token.token_id, null)] == ["f174e90a-fafe-4643-bbbc-4a0ed4fc8415"],
    ])
    error_message = "the editors policy is Service Auth, never an allow or a bypass, and its only rule is the one service token this state declares: not every valid service token, not everyone, no address or email"
  }

  assert {
    condition     = [for policy in cloudflare_zero_trust_access_application.unfold_staging["unfold-staging"].policies : [policy.id, policy.precedence]] == [["11111111-1111-4111-8111-111111111111", 1], ["22222222-2222-4222-8222-222222222222", 2]]
    error_message = "the staging application carries the people policy first and the editors policy second, and no third"
  }

  assert {
    condition     = length(cloudflare_zero_trust_access_application.unfold_staging_webhooks["unfold-staging"].policies) == 1
    error_message = "the webhook application keeps its one bypass policy; the service token is not attached to it"
  }
}

run "the_service_token_lives_a_year_names_its_generation_and_keeps_its_secret_out_of_the_plan_log" {
  command = plan

  variables {
    unfold_staging_editor_token_generation = 3
  }

  assert {
    condition = alltrue([
      cloudflare_zero_trust_access_service_token.unfold_staging_editors["unfold-staging"].name == "unfold-staging editors 3",
      terraform_data.unfold_staging_editor_token_generation["unfold-staging"].input == 3,
    ])
    error_message = "a raised generation reaches the token's name and the value whose change replaces the token, so the old pair is deleted and no two tokens share a name"
  }

  assert {
    condition     = cloudflare_zero_trust_access_service_token.unfold_staging_editors["unfold-staging"].duration == "8760h"
    error_message = "the service token expires a year after the apply that made it; a token that never expires would outlive everyone who was given it"
  }

  assert {
    condition     = issensitive(cloudflare_zero_trust_access_service_token.unfold_staging_editors["unfold-staging"].client_secret)
    error_message = "the client secret is half of what passes Access; it must stay out of the public plan log"
  }
}

run "people_sign_in_with_a_one_time_pin_until_the_google_client_exists" {
  command = plan

  assert {
    condition = alltrue([
      length(cloudflare_zero_trust_access_identity_provider.google_workspace) == 0,
      length(cloudflare_zero_trust_access_identity_provider.one_time_pin) == 1,
    ])
    error_message = "without the Google client in OpenBao the edge keeps the one-time PIN, so the host never opens without a sign-in"
  }
}

run "people_sign_in_with_google_workspace_once_the_client_exists" {
  command = plan

  variables {
    unfold_staging_google_client_id     = "1234567890-mock.apps.googleusercontent.com"
    unfold_staging_google_client_secret = "mock-google-client-secret"
  }

  assert {
    condition = alltrue([
      cloudflare_zero_trust_access_identity_provider.google_workspace["unfold-staging"].type == "google-apps",
      cloudflare_zero_trust_access_identity_provider.google_workspace["unfold-staging"].config.apps_domain == "webgrip.nl",
      length(cloudflare_zero_trust_access_application.unfold_staging["unfold-staging"].allowed_idps) == 1,
      cloudflare_zero_trust_access_application.unfold_staging["unfold-staging"].auto_redirect_to_identity == true,
    ])
    error_message = "with the Google client, staging offers Google Workspace for the owners' domain alone and redirects to it, so a person signs in once"
  }
}

run "the_edge_refuses_to_open_without_anyone_allowed_in" {
  command = plan

  variables {
    unfold_staging_access_emails        = []
    unfold_staging_access_email_domains = []
  }

  expect_failures = [
    cloudflare_zero_trust_tunnel_cloudflared.unfold_staging,
  ]
}

run "the_connector_token_reaches_openbao_and_never_the_plan_log" {
  command = plan

  assert {
    condition     = issensitive(local.unfold_staging_tunnel_token["unfold-staging"])
    error_message = "the connector token is the tunnel's credential; it must stay out of the public plan log"
  }
}
