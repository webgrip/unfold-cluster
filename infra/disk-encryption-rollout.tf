locals {
  encrypt_node_program = "${path.module}/../scripts/encrypt-node.sh"

  cloud_node_public_ipv4 = merge(
    { for name, server in hcloud_server.control_plane : name => server.ipv4_address },
    { for name, server in hcloud_server.worker : name => server.ipv4_address },
  )

  disk_encryption_rollout_environment = {
    CONTROL_PLANE_IPS    = join(" ", [for server in hcloud_server.control_plane : server.ipv4_address])
    KUBE_TLS_SERVER_NAME = local.api_vip
    KMS_ENDPOINT         = local.disk_encryption_kms_endpoint
  }

  disk_encryption_node_environment = {
    for name, address in local.cloud_node_public_ipv4 : name => merge(local.disk_encryption_rollout_environment, {
      NODE_NAME = name
      NODE_IP   = address
      NODE_ROLE = contains(keys(local.control_planes), name) ? "controlplane" : "worker"
      DESIRED   = contains(var.disk_encryption_nodes, name) ? "encrypted" : "plain"
    })
  }
}

resource "terraform_data" "disk_encryption_reinstall" {
  for_each = local.cloud_node_public_ipv4

  triggers_replace = [contains(var.disk_encryption_nodes, each.key)]

  provisioner "local-exec" {
    command     = "${local.encrypt_node_program} reinstall"
    environment = local.disk_encryption_node_environment[each.key]
  }

  depends_on = [hcloud_firewall_attachment.disk_kms]
}

resource "terraform_data" "disk_encryption_rejoin" {
  for_each = local.cloud_node_public_ipv4

  triggers_replace = [terraform_data.disk_encryption_reinstall[each.key].id]

  provisioner "local-exec" {
    command     = "${local.encrypt_node_program} rejoin"
    environment = local.disk_encryption_node_environment[each.key]
  }

  depends_on = [talos_machine_configuration_apply.control_plane, talos_machine_configuration_apply.worker]
}
