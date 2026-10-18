output "control_planes" {
  description = "Name, private address and public IPv4 of each control plane."
  value = {
    for name, server in hcloud_server.control_plane : name => {
      private_ip  = local.control_planes[name]
      public_ipv4 = server.ipv4_address
    }
  }
}

output "unfold_worker" {
  description = "Name, private address and public IPv4 of the Unfold worker."
  value = {
    for name, server in hcloud_server.unfold_worker : name => {
      private_ip  = local.unfold_worker[name]
      public_ipv4 = server.ipv4_address
    }
  }
}

output "network_id" {
  description = "Cloud Network the vSwitch and the hcloud cloud controller attach to."
  value       = hcloud_network.cluster.id
}
