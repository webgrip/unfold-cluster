variable "name" {
  description = "The node name, which is also the server's name in Robot."
  type        = string
}

variable "server_number" {
  description = "The Robot server number."
  type        = string
}

variable "public_mac" {
  description = "MAC address of the server's public link, as the install recorded it in the rescue system."
  type        = string
}

variable "private_address" {
  description = "The node's address on the vSwitch, in CIDR form."
  type        = string
}

variable "vswitch_vlan" {
  description = "VLAN id of the Robot vSwitch."
  type        = number
}

variable "vswitch_mtu" {
  description = "MTU of the VLAN link: the vSwitch carries at most 1400 bytes."
  type        = number
}

variable "vswitch_router" {
  description = "The Cloud Network's gateway on the vSwitch subnet."
  type        = string
}

variable "network_range" {
  description = "The Cloud Network, routed through the vSwitch gateway."
  type        = string
}

variable "public_link" {
  description = "Alias of the public link."
  type        = string
}

variable "vswitch_link" {
  description = "Name of the VLAN link."
  type        = string
}

variable "kubelet_config" {
  description = "Kubelet configuration merged into KubeletConfig: the reservations for the system and the sandboxes' VMMs."
  type        = any
}

output "patches" {
  description = "The node's own Talos config documents: hostname, kubelet provider id and reservations, public link by MAC with DHCP, and the vSwitch VLAN."
  value = [
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      auto       = "off"
      hostname   = var.name
    }),
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeletConfig"
      config = merge(var.kubelet_config, {
        providerID = "hrobot://${var.server_number}"
      })
    }),
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "LinkAliasConfig"
      name       = var.public_link
      selector = {
        match = "mac(link.permanent_addr) == \"${lower(var.public_mac)}\""
      }
    }),
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "DHCPv4Config"
      name       = var.public_link
    }),
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "VLANConfig"
      name       = var.vswitch_link
      vlanID     = var.vswitch_vlan
      parent     = var.public_link
      up         = true
      mtu        = var.vswitch_mtu
      addresses  = [{ address = var.private_address }]
      routes     = [{ destination = var.network_range, gateway = var.vswitch_router }]
    }),
  ]
}
