run "the_node_patches_put_the_vlan_at_mtu_1400_and_name_the_robot_server" {
  command = plan

  module {
    source = "./modules/metal-node-patches"
  }

  variables {
    name            = "unfold-metal-1"
    server_number   = "2345678"
    public_mac      = "A8:A1:59:0B:1C:2D"
    private_address = "10.64.1.31/24"
    vswitch_vlan    = 4000
    vswitch_mtu     = 1400
    vswitch_router  = "10.64.1.1"
    network_range   = "10.64.0.0/16"
    public_link     = "public0"
    vswitch_link    = "vswitch0"
    kubelet_config  = { systemReserved = { cpu = "1" } }
  }

  assert {
    condition = one([for patch in output.patches : yamldecode(patch) if yamldecode(patch).kind == "VLANConfig"]) == {
      apiVersion = "v1alpha1"
      kind       = "VLANConfig"
      name       = "vswitch0"
      vlanID     = 4000
      parent     = "public0"
      up         = true
      mtu        = 1400
      addresses  = [{ address = "10.64.1.31/24" }]
      routes     = [{ destination = "10.64.0.0/16", gateway = "10.64.1.1" }]
    }
    error_message = "the node's VLAN 4000 runs at MTU 1400 with its vSwitch address and routes the cluster network through the vSwitch gateway"
  }

  assert {
    condition     = one([for patch in output.patches : yamldecode(patch) if yamldecode(patch).kind == "LinkAliasConfig"]).selector.match == "mac(link.permanent_addr) == \"a8:a1:59:0b:1c:2d\""
    error_message = "the public link is found by the MAC address the install recorded, in Talos's lower-case form"
  }

  assert {
    condition     = one([for patch in output.patches : yamldecode(patch) if yamldecode(patch).kind == "DHCPv4Config"]).name == "public0"
    error_message = "the public link takes its IPv4 address from Hetzner's DHCP"
  }

  assert {
    condition     = one([for patch in output.patches : yamldecode(patch) if yamldecode(patch).kind == "KubeletConfig"]).config.providerID == "hrobot://2345678"
    error_message = "the kubelet names its Robot server, so the hcloud cloud controller never takes the node for a deleted cloud server"
  }

  assert {
    condition     = one([for patch in output.patches : yamldecode(patch) if yamldecode(patch).kind == "KubeletConfig"]).config.systemReserved.cpu == "1"
    error_message = "the provider id is added to the kubelet reservations, not instead of them"
  }
}
