locals {
  tailnet_prefixes = ["100.64.0.0/10", "fd7a:115c:a1e0::/48"]

  host_firewall_operator_sources = distinct(concat(var.admin_cidrs, local.tailnet_prefixes, [local.network_range]))

  control_plane_host_addresses = [for address in values(local.control_planes) : "${address}/32"]

  host_firewall_node_rules = [
    { name = "kubelet", protocol = "tcp", ports = [10250], sources = [local.network_range, local.pod_subnet] },
    { name = "cilium-vxlan", protocol = "udp", ports = [8472], sources = [local.network_range] },
    { name = "cilium-wireguard", protocol = "udp", ports = [51871], sources = [local.network_range] },
    { name = "cilium-health", protocol = "tcp", ports = [4240], sources = [local.network_range] },
    { name = "hubble-peer", protocol = "tcp", ports = [4244], sources = [local.network_range, local.pod_subnet] },
    { name = "node-metrics", protocol = "tcp", ports = local.node_metrics_ports, sources = [local.pod_subnet] },
  ]

  host_firewall_rules = {
    worker = concat(local.host_firewall_node_rules, [
      { name = "apid", protocol = "tcp", ports = [50000], sources = local.host_firewall_operator_sources },
    ])
    control_plane = concat(local.host_firewall_node_rules, [
      { name = "apid", protocol = "tcp", ports = [50000], sources = concat(local.host_firewall_operator_sources, [local.pod_subnet]) },
      { name = "kube-apiserver", protocol = "tcp", ports = [6443], sources = concat(local.host_firewall_operator_sources, [local.pod_subnet]) },
      { name = "trustd", protocol = "tcp", ports = [50001], sources = [local.network_range] },
      { name = "etcd", protocol = "tcp", ports = ["2379-2380"], sources = local.control_plane_host_addresses },
      { name = "etcd-metrics", protocol = "tcp", ports = [local.etcd_metrics_port], sources = [local.pod_subnet] },
      { name = "ops-gateway", protocol = "tcp", ports = [443], sources = concat(local.tailnet_prefixes, [local.network_range]) },
    ])
  }

  host_firewall_block_by_default = yamlencode({
    apiVersion = "v1alpha1"
    kind       = "NetworkDefaultActionConfig"
    ingress    = "block"
  })

  host_firewall_patches = {
    for role, rules in local.host_firewall_rules : role => var.host_firewall_enabled ? concat(
      [local.host_firewall_block_by_default],
      [for rule in rules : yamlencode({
        apiVersion = "v1alpha1"
        kind       = "NetworkRuleConfig"
        name       = "${rule.name}-ingress"
        portSelector = {
          ports    = rule.ports
          protocol = rule.protocol
        }
        ingress = [for source in rule.sources : { subnet = source }]
      })],
    ) : []
  }
}
