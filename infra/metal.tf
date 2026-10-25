locals {
  robot_program        = "${path.module}/../scripts/robot.sh"
  metal_record_prefix  = "unfold-cluster/metal"
  metal_name_prefix    = "unfold-metal-"
  metal_vswitch_name   = "unfold-main"
  metal_vswitch_link   = "vswitch0"
  metal_public_link    = "public0"
  metal_vswitch_mtu    = 1400
  metal_system_disk    = "nvme0n1"
  metal_vswitch_router = cidrhost(local.vswitch_subnet_range, 1)

  metal_image        = yamldecode(file("${path.module}/${var.metal_image_file}"))
  metal_image_pinned = alltrue([for key in ["installerImage", "diskImageUrl", "diskImageSha256"] : try(local.metal_image[key], "") != ""])
  metal_installable  = local.metal_image_pinned ? var.metal_servers : {}

  metal_nodes = {
    for name, server in var.metal_servers : name => {
      private_ip = cidrhost(local.vswitch_subnet_range, server.private_host)
    }
  }

  metal_labels = {
    "node.webgrip.io/pool"               = "metal"
    "runtime.webgrip.io/kata"            = "true"
    (local.gvisor_capability_label)      = "true"
    "runtime.webgrip.io/kvm"             = "true"
    "instance.hetzner.cloud/provided-by" = "robot"
  }

  metal_taints = {
    "node.webgrip.io/pool" = "metal:NoSchedule"
  }

  metal_admin_ipv4_cidrs = [for cidr in var.admin_cidrs : cidr if !strcontains(cidr, ":")]

  metal_robot_firewall = {
    input = concat([
      { name = "private-network", ip_version = "ipv4", src_ip = local.network_range, action = "accept" },
      { name = "icmp", ip_version = "ipv4", protocol = "icmp", action = "accept" },
      { name = "dhcp", ip_version = "ipv4", protocol = "udp", dst_port = "68", action = "accept" },
      { name = "tcp-replies", ip_version = "ipv4", protocol = "tcp", dst_port = "32768-65535", tcp_flags = "ack", action = "accept" },
      { name = "udp-replies", ip_version = "ipv4", protocol = "udp", dst_port = "32768-65535", action = "accept" },
      { name = "tailscale", ip_version = "ipv4", protocol = "udp", dst_port = "41641", action = "accept" },
      ], [
      for index, cidr in local.metal_admin_ipv4_cidrs : {
        name       = "admin-tcp-${index + 1}"
        ip_version = "ipv4"
        protocol   = "tcp"
        src_ip     = cidr
        action     = "accept"
      }
    ])
    output = [
      { name = "all", action = "accept" },
    ]
  }

  metal_install_patch = yamlencode({
    apiVersion = "v1alpha1"
    kind       = "UnattendedInstallConfig"
    installer = {
      image = try(local.metal_image.installerImage, "")
    }
    provisioning = {
      diskSelector = {
        match = "disk.dev_path == \"/dev/${local.metal_system_disk}\""
      }
    }
  })

  metal_pool_patch = yamlencode({
    apiVersion = "v1alpha1"
    kind       = "KubeNodeConfig"
    labels     = local.metal_labels
    taints     = local.metal_taints
  })

  metal_kubelet_reservations = {
    systemReserved = {
      cpu                 = "1"
      memory              = "2Gi"
      "ephemeral-storage" = "10Gi"
    }
    kubeReserved = {
      cpu    = "500m"
      memory = "1Gi"
    }
    evictionHard = {
      "memory.available"  = "1Gi"
      "nodefs.available"  = "10%"
      "imagefs.available" = "15%"
    }
  }
}

data "external" "metal_quote" {
  for_each = var.metal_servers

  program = [local.robot_program, "quote"]
  query = {
    name            = each.key
    product         = each.value.product
    location        = each.value.location
    max_monthly_eur = tostring(each.value.max_monthly_eur)
    max_setup_eur   = tostring(each.value.max_setup_eur)
  }
}

resource "terraform_data" "metal_order" {
  for_each = var.metal_servers

  triggers_replace = [each.key]

  input = {
    product         = each.value.product
    location        = each.value.location
    primary_ipv4    = true
    quoted_state    = data.external.metal_quote[each.key].result.state
    monthly_net_eur = data.external.metal_quote[each.key].result.monthly_net_eur
    setup_net_eur   = data.external.metal_quote[each.key].result.setup_net_eur
  }

  lifecycle {
    ignore_changes = [input]

    precondition {
      condition     = data.external.metal_quote[each.key].result.product == each.value.product
      error_message = "Robot quoted another product than the one declared for ${each.key}; refusing."
    }
  }

  provisioner "local-exec" {
    command = "${local.robot_program} order"
    environment = {
      NAME               = each.key
      PRODUCT            = each.value.product
      LOCATION           = each.value.location
      MAX_MONTHLY_EUR    = tostring(each.value.max_monthly_eur)
      MAX_SETUP_EUR      = tostring(each.value.max_setup_eur)
      SERVER_LIMIT       = tostring(length(var.metal_servers))
      METAL_NAME_PREFIX  = local.metal_name_prefix
      RECORD_PATH        = "${local.metal_record_prefix}/${each.key}"
      ORDER_WAIT_SECONDS = "7200"
      ORDER_POLL_SECONDS = "60"
    }
  }
}

data "external" "metal_server" {
  for_each = var.metal_servers

  program = [local.robot_program, "server"]
  query = {
    name = each.key
  }

  depends_on = [terraform_data.metal_order]
}

resource "terraform_data" "robot_vswitch" {
  count = length(var.metal_servers) > 0 ? 1 : 0

  triggers_replace = [local.metal_vswitch_name, var.metal_vswitch_vlan]

  provisioner "local-exec" {
    command = "${local.robot_program} vswitch-ensure"
    environment = {
      VSWITCH_NAME = local.metal_vswitch_name
      VSWITCH_VLAN = tostring(var.metal_vswitch_vlan)
    }
  }
}

data "external" "robot_vswitch" {
  count = length(var.metal_servers) > 0 ? 1 : 0

  program = [local.robot_program, "vswitch-id"]
  query = {
    name = local.metal_vswitch_name
    vlan = tostring(var.metal_vswitch_vlan)
  }

  depends_on = [terraform_data.robot_vswitch]
}

resource "terraform_data" "metal_vswitch_membership" {
  for_each = var.metal_servers

  triggers_replace = [data.external.metal_server[each.key].result.server_number, data.external.robot_vswitch[0].result.id]

  provisioner "local-exec" {
    command = "${local.robot_program} vswitch-attach"
    environment = {
      VSWITCH_ID    = data.external.robot_vswitch[0].result.id
      SERVER_NUMBER = data.external.metal_server[each.key].result.server_number
    }
  }

  depends_on = [hcloud_network_subnet.vswitch]
}

resource "terraform_data" "metal_robot_firewall" {
  for_each = var.metal_servers

  triggers_replace = [data.external.metal_server[each.key].result.server_number, sha256(jsonencode(local.metal_robot_firewall))]

  lifecycle {
    precondition {
      condition     = length(local.metal_robot_firewall.input) <= 10
      error_message = "The Robot firewall takes 10 input rules and six are fixed; narrow ADMIN_CIDRS to at most four IPv4 ranges."
    }

    precondition {
      condition     = length(local.metal_admin_ipv4_cidrs) > 0
      error_message = "The metal nodes take their Talos configuration over apid from the runners; ADMIN_CIDRS must hold their IPv4 range."
    }
  }

  provisioner "local-exec" {
    command = "${local.robot_program} firewall"
    environment = {
      SERVER_NUMBER  = data.external.metal_server[each.key].result.server_number
      FIREWALL_RULES = jsonencode(local.metal_robot_firewall)
    }
  }
}

resource "terraform_data" "metal_install" {
  for_each = local.metal_installable

  triggers_replace = [data.external.metal_server[each.key].result.server_number, each.value.install_generation]

  lifecycle {
    precondition {
      condition     = can(regex(":${replace(local.talos_version, ".", "\\.")}-[^@/]+@sha256:[0-9a-f]{64}$", local.metal_image.installerImage))
      error_message = "talos/metal-image.yaml must pin its installer by digest, with a tag that starts with Talos ${local.talos_version} from talos/talenv.yaml."
    }

    precondition {
      condition     = can(regex("^[0-9a-f]{64}$", local.metal_image.diskImageSha256)) && startswith(local.metal_image.diskImageUrl, "https://")
      error_message = "talos/metal-image.yaml pins the disk image by sha256 and fetches it over https."
    }
  }

  provisioner "local-exec" {
    command = "${local.robot_program} install"
    environment = {
      NAME               = each.key
      SERVER_NUMBER      = data.external.metal_server[each.key].result.server_number
      SERVER_IP          = data.external.metal_server[each.key].result.server_ip
      INSTALL_GENERATION = tostring(each.value.install_generation)
      DISK_IMAGE_URL     = local.metal_image.diskImageUrl
      DISK_IMAGE_SHA256  = local.metal_image.diskImageSha256
      EXPECTED_DISK      = local.metal_system_disk
      RECORD_PATH        = "${local.metal_record_prefix}/${each.key}"
    }
  }

  depends_on = [terraform_data.metal_robot_firewall, terraform_data.metal_vswitch_membership]
}

data "external" "metal_link" {
  for_each = local.metal_installable

  program = [local.robot_program, "mac"]
  query = {
    name        = each.key
    record_path = "${local.metal_record_prefix}/${each.key}"
  }

  depends_on = [terraform_data.metal_install]
}

locals {
  metal_tailnet_key_slot = {
    for name in keys(local.metal_installable) : name => "${data.external.metal_server[name].result.server_number}${replace(var.tailnet_key_generation, "-", "")}"
  }
}

data "external" "metal_tailnet_key" {
  for_each = local.metal_installable

  program = ["${path.module}/../scripts/read-tailnet-key.sh"]
  query   = merge(local.tailnet_key_query, { request = "worker ${local.metal_tailnet_key_slot[each.key]}" })

  depends_on = [hcloud_server.headscale, terraform_data.metal_install]
}

resource "terraform_data" "metal_tailnet_key" {
  for_each = local.metal_installable

  input            = sensitive(data.external.metal_tailnet_key[each.key].result.key)
  triggers_replace = [var.tailnet_key_generation, hcloud_server.headscale.id]

  lifecycle {
    ignore_changes       = [input]
    replace_triggered_by = [terraform_data.metal_install[each.key].id]

    postcondition {
      condition     = startswith(self.output, "hskey-auth-")
      error_message = "unfold-headscale did not return a metal node's pre-auth key."
    }
  }
}

data "talos_machine_configuration" "metal" {
  cluster_name       = local.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "worker"
  machine_secrets    = talos_machine_secrets.cluster.machine_secrets
  talos_version      = local.talos_version
  kubernetes_version = local.kubernetes_version
  docs               = false
  examples           = false
  config_patches     = concat(local.node_patches, [local.metal_install_patch, local.metal_pool_patch], local.host_firewall_patches.worker, local.log_shipping_patches)
}

module "metal_node_patches" {
  source   = "./modules/metal-node-patches"
  for_each = local.metal_installable

  name            = each.key
  server_number   = data.external.metal_server[each.key].result.server_number
  public_mac      = data.external.metal_link[each.key].result.mac
  private_address = "${local.metal_nodes[each.key].private_ip}/${split("/", local.vswitch_subnet_range)[1]}"
  vswitch_vlan    = var.metal_vswitch_vlan
  vswitch_mtu     = local.metal_vswitch_mtu
  vswitch_router  = local.metal_vswitch_router
  network_range   = local.network_range
  public_link     = local.metal_public_link
  vswitch_link    = local.metal_vswitch_link
  kubelet_config  = local.metal_kubelet_reservations
}

locals {
  metal_node_patches = {
    for name, server in local.metal_installable : name => concat(
      local.disk_encryption_patches[name],
      local.gvisor_runtime_patches[server.gvisor_platform],
      [local.metal_tailscale_patch[name]],
      module.metal_node_patches[name].patches,
    )
  }

  metal_tailscale_patch = {
    for name in keys(local.metal_installable) : name => sensitive(yamlencode({
      apiVersion = "v1alpha1"
      kind       = "ExtensionServiceConfig"
      name       = "tailscale"
      environment = [
        "TS_AUTHKEY=${terraform_data.metal_tailnet_key[name].output}",
        "TS_AUTH_ONCE=true",
        "TS_EXTRA_ARGS=${local.tailscale_login_args}",
      ]
    }))
  }
}

resource "talos_machine_configuration_apply" "metal" {
  for_each = local.metal_installable

  client_configuration        = talos_machine_secrets.cluster.client_configuration
  machine_configuration_input = data.talos_machine_configuration.metal.machine_configuration
  node                        = data.external.metal_server[each.key].result.server_ip
  endpoint                    = data.external.metal_server[each.key].result.server_ip
  config_patches              = local.metal_node_patches[each.key]

  lifecycle {
    replace_triggered_by = [terraform_data.metal_install[each.key].id]
  }
}
