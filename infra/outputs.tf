output "control_planes" {
  description = "Name, private address and public IPv4 of each control plane."
  value = {
    for name, server in hcloud_server.control_plane : name => {
      private_ip  = local.control_planes[name]
      public_ipv4 = server.ipv4_address
    }
  }
}

output "workers" {
  description = "Name, pool, private address and public IPv4 of each worker."
  value = {
    for name, server in hcloud_server.worker : name => {
      pool        = local.workers[name].pool
      private_ip  = local.workers[name].private_ip
      public_ipv4 = server.ipv4_address
    }
  }
}

output "metal_nodes" {
  description = "Name, Robot server number, private address on the vSwitch and public IPv4 of each metal node."
  value = {
    for name in keys(local.metal_active) : name => {
      pool          = "metal"
      server_number = data.external.metal_server[name].result.server_number
      private_ip    = local.metal_nodes[name].private_ip
      public_ipv4   = data.external.metal_server[name].result.server_ip
    }
  }
}

output "network_id" {
  description = "Cloud Network the vSwitch and the hcloud cloud controller attach to."
  value       = hcloud_network.cluster.id
}

output "talosconfig" {
  description = "Client configuration for the Talos API. Read with: tofu output -raw talosconfig"
  value       = data.talos_client_configuration.cluster.talos_config
  sensitive   = true
}

output "kubeconfig" {
  description = "Admin kubeconfig for the cluster. Read with: tofu output -raw kubeconfig"
  value       = talos_cluster_kubeconfig.cluster.kubeconfig_raw
  sensitive   = true
}

output "headscale_ipv4" {
  description = "The address the headscale_hostname A record, declared in homelab-cluster, points at. A primary IP, so it survives a rebuild of the Headscale server."
  value       = hcloud_primary_ip.headscale.ip_address
}

output "headscale_ssh_known_hosts" {
  description = "The only SSH host key unfold-headscale presents, as a known_hosts line. Every apply also writes it to OpenBao secret/unfold/headscale-address, property ssh_known_hosts (drill_ssh_known_hosts for the rebuild drill), where it is read without the state."
  value       = local.headscale_known_hosts_line
}

output "homelab_gateway_tailnet_key" {
  description = "The homelab gateway's single-use tag:homelab-gateway pre-auth key. The infra workflow writes it to OpenBao secret/unfold/tailnet-homelab-gateway after each apply, where the homelab's External Secrets picks it up."
  value       = terraform_data.homelab_gateway_tailnet_key.output
  sensitive   = true
}

module "talos_secrets_bundle" {
  source          = "./modules/talos-secrets-bundle"
  machine_secrets = talos_machine_secrets.cluster.machine_secrets
}

output "talos_secrets_bundle" {
  description = "The cluster's Talos secrets as a talosctl secrets bundle. Every apply escrows it to OpenBao secret/unfold-cluster/talos-secrets, and an apply into an empty state imports it back (talos_secrets_import_file), so a rebuild keeps the cluster's identity."
  value       = module.talos_secrets_bundle.yaml
  sensitive   = true
}

output "headscale_tofu_ssh_private_key" {
  description = "OpenTofu's SSH key for the tofu user on unfold-headscale, which may run nothing but unfold-tailnet-key. The rebuild drill uses it to list the nodes Headscale knows."
  value       = tls_private_key.headscale_tofu.private_key_openssh
  sensitive   = true
}
