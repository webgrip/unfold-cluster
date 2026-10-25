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

output "talos_machine_secrets" {
  description = "The cluster's Talos secrets bundle, for the owner's offline escrow. Read with: tofu output -raw talos_machine_secrets"
  value       = yamlencode(talos_machine_secrets.cluster.machine_secrets)
  sensitive   = true
}

output "headscale_ipv4" {
  description = "The address the headscale_hostname A record, declared in homelab-cluster, points at. A primary IP, so it survives a rebuild of the Headscale server."
  value       = hcloud_primary_ip.headscale.ip_address
}

output "headscale_ssh_known_hosts" {
  description = "The only SSH host key unfold-headscale presents, as a known_hosts line. Read with: tofu output -raw headscale_ssh_known_hosts >> ~/.ssh/known_hosts"
  value       = "${var.headscale_hostname},${hcloud_primary_ip.headscale.ip_address} ${trimspace(tls_private_key.headscale_host.public_key_openssh)}"
}

output "homelab_gateway_tailnet_key" {
  description = "The homelab gateway's single-use tag:homelab-gateway pre-auth key. The infra workflow writes it to OpenBao secret/unfold/tailnet-homelab-gateway after each apply, where the homelab's External Secrets picks it up."
  value       = terraform_data.homelab_gateway_tailnet_key.output
  sensitive   = true
}
