locals {
  headscale_known_hosts_line     = "${var.headscale_hostname},${hcloud_primary_ip.headscale.ip_address} ${trimspace(tls_private_key.headscale_host.public_key_openssh)}"
  headscale_known_hosts_property = "${trimsuffix(var.headscale_address_property, "ipv4")}ssh_known_hosts"
}

resource "terraform_data" "headscale_known_hosts" {
  triggers_replace = [local.headscale_known_hosts_line, local.headscale_known_hosts_property]

  provisioner "local-exec" {
    command = "printf '%s\\n' \"$KNOWN_HOSTS\" | ${path.module}/../scripts/openbao-kv.sh put known-hosts unfold/headscale-address \"$PROPERTY\""
    environment = {
      KNOWN_HOSTS = local.headscale_known_hosts_line
      PROPERTY    = local.headscale_known_hosts_property
    }
  }
}
