variable "location" {
  description = "Hetzner Cloud location for every cloud server. Falkenstein or Nuremberg, next to the AX41 (VIK-1767)."
  type        = string
  default     = "fsn1"

  validation {
    condition     = contains(["fsn1", "nbg1"], var.location)
    error_message = "The cluster lives in fsn1 or nbg1, beside its dedicated worker."
  }
}

variable "talos_snapshot_required" {
  description = "True on apply runs, which build the Talos snapshot before they plan. A plan that would boot a node without that snapshot then fails, instead of showing a placeholder image as plan-only runs do."
  type        = bool
  default     = false
}

variable "control_plane_server_type" {
  description = "Cost-optimized CX23 (2 vCPU, 4 GB), chosen 2026-10-24 after Hetzner's price rises made CPX22 more than three times the price. Must stay x86: the Talos snapshot is amd64."
  type        = string
  default     = "cx23"

  validation {
    condition     = !startswith(lower(var.control_plane_server_type), "cax")
    error_message = "CAX servers are Arm; the Talos snapshot and the Headscale package are x86 (amd64)."
  }
}

variable "worker_pools" {
  description = "The fixed worker pools OpenTofu creates, by pool name. A pool without a location uses var.location. Each node is named name_prefix-N, takes the private address first_host+N-1 in the cloud subnet, and carries its pool's Kubernetes labels and taints (Talos KubeNodeConfig: taint value is value:Effect). unfold is the hub worker dedicated to Unfold (VIK-2157), a cost-optimized CX33; until the Unfold application or the metal node takes its place, it also runs up to two CI jobs under gVisor, the baseline that needs no cold node (docs/adr/0004-ci-baseline-on-the-hub-and-autoscaled-overflow.md). ci is the CI pool of RFC 0001 step 13; it has no fixed node (node_count 0) and the cluster-autoscaler grows it from zero with CPX42 servers in Nuremberg when CI overflows the hub worker (autoscaled_worker_pools); its CI jobs run under the gvisor RuntimeClass on the systrap platform. A pool labelled runtime.webgrip.io/gvisor=true gets the gVisor runtime config (sandbox-runtimes.tf), and the gvisor RuntimeClass selects that label. Nodes a cluster-autoscaler adds are not listed here. system is the platform pool of ADR 0013 (docs/adr/0013-control-planes-stay-small-and-a-system-pool-carries-the-platform.md), one CPX32 from stage S1: KEDA, the cluster-autoscaler, the CloudNativePG operator, Zot, Trivy and the observability stack prefer it and fall back to where they ran before, so raising its node_count from 0 to 1 is the whole switch."
  type = map(object({
    server_type = string
    location    = optional(string)
    node_count  = number
    name_prefix = string
    first_host  = number
    labels      = map(string)
    taints      = map(string)
  }))
  default = {
    unfold = {
      server_type = "cx33"
      node_count  = 1
      name_prefix = "unfold-app"
      first_host  = 21
      labels      = { "node.webgrip.io/pool" = "unfold", "runtime.webgrip.io/gvisor" = "true" }
      taints      = { "node.webgrip.io/pool" = "unfold:NoSchedule" }
    }
    ci = {
      server_type = "cx43"
      location    = "nbg1"
      node_count  = 0
      name_prefix = "unfold-ci"
      first_host  = 31
      labels      = { "node.webgrip.io/pool" = "ci", "runtime.webgrip.io/gvisor" = "true" }
      taints      = { "node.webgrip.io/pool" = "ci:NoSchedule" }
    }
    system = {
      server_type = "cpx32"
      location    = "fsn1"
      node_count  = 1
      name_prefix = "unfold-system"
      first_host  = 51
      labels      = { "node.webgrip.io/pool" = "system" }
      taints      = { "node.webgrip.io/pool" = "system:NoSchedule" }
    }
  }

  validation {
    condition     = alltrue([for pool in values(var.worker_pools) : !startswith(lower(pool.server_type), "cax")])
    error_message = "CAX servers are Arm; the Talos snapshot and the Headscale package are x86 (amd64)."
  }

  validation {
    condition     = alltrue([for pool in values(var.worker_pools) : pool.location == null || contains(["fsn1", "nbg1"], pool.location)])
    error_message = "A pool lives in fsn1 or nbg1: both sit in Hetzner's eu-central network zone, so the private network reaches it."
  }

  validation {
    condition     = alltrue([for name, pool in var.worker_pools : lookup(pool.labels, "node.webgrip.io/pool", "") == name])
    error_message = "Every node carries the label node.webgrip.io/pool with its own pool's name, which is how workloads and the cluster-autoscaler find a pool."
  }

  validation {
    condition = alltrue([
      for pool in values(var.worker_pools) :
      pool.node_count >= 0 && pool.node_count <= 10 && pool.first_host >= 20 && pool.first_host % 10 == 1 && pool.first_host + 9 <= 254
    ])
    error_message = "Each pool owns one block of ten addresses in the cloud subnet starting at x1 (21 to 30, 31 to 40, ...), above the control planes and the API address, and holds at most ten nodes."
  }

  validation {
    condition     = length(distinct([for pool in values(var.worker_pools) : pool.first_host])) == length(var.worker_pools)
    error_message = "Two pools share an address block; give each pool its own first_host."
  }

  validation {
    condition     = length(distinct([for pool in values(var.worker_pools) : pool.name_prefix])) == length(var.worker_pools)
    error_message = "Two pools share a name_prefix, so their nodes would share names."
  }
}

variable "admin_cidrs" {
  description = "Addresses allowed to reach the Talos and Kubernetes APIs from the internet, as a JSON list. Must include the public address the Forgejo runners leave from, because OpenTofu configures the nodes over the Talos API. Both APIs require client certificates."
  type        = list(string)
  default     = []
}

variable "metal_servers" {
  description = "The Robot dedicated servers the cluster runs on, by node name, in one of three modes. auction: the plan picks the cheapest server on Hetzner's server market that meets the declared criteria (CPU allowlist with core counts, memory, disk type, datacenters, a monthly ceiling net with the primary IPv4 address, a setup ceiling) and shows it; the apply orders exactly that offer once, re-checking it first, and fails without ordering when it was sold in between. order: a product Robot's order API sells, ordered once within max_monthly_eur and max_setup_eur. adopt: a server a person ordered, taken over by server_number after GET /server shows it on this account, a product starting with product_prefix, in location and not cancelled; while server_number is null the node is skipped. Every mode refuses more servers than are declared, keeps its order in OpenBao so nothing is bought twice, and never orders when a server with the node's name exists. The apply then puts the server on the vSwitch, sets its Robot firewall and installs Talos from the rescue system; raising install_generation is the reviewed way to wipe and reinstall a node. cpu_vendor (intel or amd) is declared for order and adopt and comes from the bought CPU for auction; it picks the KVM module. gvisor_platform is kvm, systrap the fallback. Cancelling stays a person's act in Robot (docs/runbooks/metal-node.md)."
  type = map(object({
    mode           = optional(string, "order")
    server_number  = optional(number)
    product        = optional(string)
    product_prefix = optional(string)
    cpu_vendor     = optional(string)
    location       = optional(string)
    auction = optional(object({
      cpu_cores       = map(number)
      min_cores       = number
      min_memory_gb   = number
      disk_type       = string
      datacenters     = list(string)
      max_monthly_eur = number
      max_setup_eur   = optional(number, 0)
    }))
    max_monthly_eur    = optional(number, 0)
    max_setup_eur      = optional(number, 0)
    private_host       = number
    install_generation = optional(number, 1)
    gvisor_platform    = optional(string, "kvm")
  }))
  nullable = false
  default  = {}

  validation {
    condition     = alltrue([for name in keys(var.metal_servers) : can(regex("^unfold-metal-[0-9]+$", name))])
    error_message = "A metal node is named unfold-metal-N: the order step counts the Robot servers named unfold-metal-* against the declared ones."
  }

  validation {
    condition     = alltrue([for server in values(var.metal_servers) : contains(["order", "adopt", "auction"], server.mode)])
    error_message = "mode is auction (the apply buys the cheapest matching server market offer), order (a product Robot's order API sells) or adopt (a person ordered it; the apply takes it over by server_number)."
  }

  validation {
    condition = alltrue([for server in values(var.metal_servers) : (
      server.mode == "adopt" ? try(length(server.product_prefix) > 0, false) :
      server.mode == "order" ? try(length(server.product) > 0, false) :
      server.auction != null
    )])
    error_message = "An adopted server declares product_prefix (EX44), an ordered one product (the exact Robot product id), an auctioned one its auction criteria."
  }

  validation {
    condition     = alltrue([for server in values(var.metal_servers) : server.mode == "auction" ? server.cpu_vendor == null : contains(["intel", "amd"], coalesce(server.cpu_vendor, "unset"))])
    error_message = "cpu_vendor is intel or amd for order and adopt; for auction it comes from the CPU of the offer bought, so it is not declared."
  }

  validation {
    condition     = alltrue([for server in values(var.metal_servers) : server.mode == "auction" || contains(["FSN1", "NBG1", "HEL1"], coalesce(server.location, "unset"))])
    error_message = "A metal server lives in FSN1, NBG1 or HEL1, Hetzner's eu-central zone, where the vSwitch reaches the Cloud Network."
  }

  validation {
    condition = alltrue([for server in values(var.metal_servers) : server.mode != "auction" || (
      length(server.auction.cpu_cores) > 0 &&
      alltrue([for cores in values(server.auction.cpu_cores) : cores >= server.auction.min_cores]) &&
      length(server.auction.datacenters) > 0 &&
      alltrue([for dc in server.auction.datacenters : contains(["FSN1", "NBG1", "HEL1"], dc)]) &&
      server.auction.min_memory_gb >= 8
    )])
    error_message = "Auction criteria name at least one CPU, each with at least min_cores cores, and only eu-central datacenters (FSN1, NBG1, HEL1)."
  }

  validation {
    condition = alltrue([for server in values(var.metal_servers) : (
      server.mode == "adopt" ? true :
      server.mode == "order" ? server.max_monthly_eur > 0 && server.max_monthly_eur <= 100 && server.max_setup_eur >= 0 && server.max_setup_eur <= 100 :
      server.auction.max_monthly_eur > 0 && server.auction.max_monthly_eur <= 100 && server.auction.max_setup_eur >= 0 && server.auction.max_setup_eur <= 100
    )])
    error_message = "Each bought server has a price ceiling between 0 and 100 EUR a month and a setup ceiling no higher than 100 EUR; a larger purchase is a decision for a person, not a variable."
  }

  validation {
    condition     = alltrue([for server in values(var.metal_servers) : server.mode == "adopt" || server.server_number == null])
    error_message = "server_number is only for mode adopt; a bought server is found by its name."
  }

  validation {
    condition     = alltrue([for server in values(var.metal_servers) : server.server_number == null ? true : server.server_number > 0 && floor(server.server_number) == server.server_number])
    error_message = "server_number is the Robot server number, a positive whole number."
  }

  validation {
    condition     = alltrue([for server in values(var.metal_servers) : server.private_host >= 11 && server.private_host <= 254 && floor(server.private_host) == server.private_host])
    error_message = "private_host is the node's host number in the vSwitch subnet 10.64.1.0/24, 11 to 254; the gateway and Hetzner's reserved addresses sit below."
  }

  validation {
    condition     = length(distinct([for server in values(var.metal_servers) : server.private_host])) == length(var.metal_servers)
    error_message = "Two metal servers share a private_host."
  }

  validation {
    condition     = alltrue([for server in values(var.metal_servers) : server.install_generation >= 1 && floor(server.install_generation) == server.install_generation])
    error_message = "install_generation is a whole number, 1 or higher; raising it wipes and reinstalls that node."
  }

  validation {
    condition     = alltrue([for server in values(var.metal_servers) : contains(["kvm", "systrap"], server.gvisor_platform)])
    error_message = "gvisor_platform is kvm, or systrap when the node's KVM misbehaves."
  }
}

variable "metal_vswitch_vlan" {
  description = "The VLAN id of the Robot vSwitch unfold-main that joins the metal servers to the Cloud Network. Robot accepts 4000 to 4091."
  type        = number
  default     = 4000

  validation {
    condition     = var.metal_vswitch_vlan >= 4000 && var.metal_vswitch_vlan <= 4091
    error_message = "Robot vSwitch VLANs are 4000 to 4091."
  }
}

variable "state_passphrase" {
  description = "Encrypts the OpenTofu state and plans, which hold the Talos machine secrets. Kept by the owner with the other bootstrap secrets."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.state_passphrase) >= 32
    error_message = "Use a passphrase of at least 32 characters."
  }
}

variable "hcloud_cluster_token" {
  description = "Hetzner Cloud API token for the cloud controller and the CSI driver, seeded into kube-system by a Talos inline manifest and rewritten into the running cluster by every apply that changes it. A different token from CI's, so either can be revoked alone."
  type        = string
  sensitive   = true
  default     = ""
}

variable "hcloud_autoscaler_token" {
  description = "Hetzner Cloud API token of the cluster-autoscaler, read from OpenBao secret/hetzner/unfold-autoscaler HCLOUD_TOKEN_AUTOSCALER. A fourth token, so the one that creates and deletes servers can be revoked alone. The apply writes it, with the worker config the autoscaler boots new nodes with, to the Secret cluster-autoscaler/cluster-autoscaler-hcloud. Empty writes nothing, and the autoscaler waits for its Secret (docs/runbooks/ci-autoscaler.md)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "autoscaled_worker_pools" {
  description = "The worker pools the cluster-autoscaler grows from zero. Each names a pool in worker_pools, whose labels, taints and gVisor config its nodes boot with; the node group's server type, location and size live in the cluster-autoscaler HelmRelease (kubernetes/platform/cluster-autoscaler)."
  type        = set(string)
  default     = ["ci"]

  validation {
    condition     = alltrue([for pool in var.autoscaled_worker_pools : contains(keys(var.worker_pools), pool)])
    error_message = "An autoscaled pool must be a pool in worker_pools, which holds its labels and taints."
  }
}

variable "hcloud_vip_token" {
  description = "Hetzner Cloud API token the control planes use to move the API address. A third token, so a leaked machine config does not expose the others."
  type        = string
  sensitive   = true
  default     = ""
}

variable "talos_cloud_schematic" {
  description = "Image Factory schematic id of talos/schematics/cloud.yaml."
  type        = string
  default     = "bd06ca487272b755c51239191fb53b48470a1daf0fe0b628e424b67dd66cf1f4"
}

variable "headscale_server_type" {
  description = "The small cloud server that runs Headscale, the self-hosted coordination server of the admin tailnet. x86, because cloud-init installs Headscale's amd64 package."
  type        = string
  default     = "cx23"

  validation {
    condition     = !startswith(lower(var.headscale_server_type), "cax")
    error_message = "CAX servers are Arm; the Talos snapshot and the Headscale package are x86 (amd64)."
  }
}

variable "headscale_hostname" {
  description = "Public DNS name of Headscale. Its A record, unproxied, points at the headscale_ipv4 output and is declared in homelab-cluster (kubernetes/apps/network/cloudflare-dns/app/unfold-headscale.dnsendpoint.yaml)."
  type        = string
  default     = "headscale.webgrip.dev"
}

variable "acme_email" {
  description = "Optional contact address Let's Encrypt uses for Headscale's certificate expiry notices. Empty sends none."
  type        = string
  default     = ""
}

variable "admin_ssh_public_key" {
  description = "The owner's SSH public key, the only interactive way into the Headscale server. OpenTofu's own key there may run nothing but the tailnet key command."
  type        = string
}

variable "headscale_admin_user" {
  description = "The Headscale user in group:admin, which owns the tags, and under which a device is registered by hand when the browser login is down. Every device a person registers, by hand or through Authentik, is autogroup:member and may reach the nodes and the cluster's private subnet (docs/runbooks/headscale-browser-login.md)."
  type        = string
  default     = "ryan"
}

variable "etcd_backup_s3_access_key" {
  description = "Access key of the Garage key that may write, but not read, the etcd backup bucket. Seeded into the etcd-backup namespace by a Talos inline manifest and rewritten into the running cluster by every apply that changes it."
  type        = string
  sensitive   = true
  default     = ""
}

variable "etcd_backup_s3_secret_key" {
  description = "Secret key belonging to etcd_backup_s3_access_key."
  type        = string
  sensitive   = true
  default     = ""
}

variable "etcd_backup_age_recipient" {
  description = "The age public key every etcd snapshot is encrypted to. Its private key stays with the owner and with the restore check, never in the cluster."
  type        = string
  default     = ""

  validation {
    condition     = var.etcd_backup_age_recipient == "" || startswith(var.etcd_backup_age_recipient, "age1")
    error_message = "etcd_backup_age_recipient must be an age public key, starting with age1."
  }
}

variable "tailnet_key_generation" {
  description = "A date, YYYY-MM-DD. Changing it gives every node a fresh tailnet pre-auth key on the next apply: the control planes the current tag:cp key, each worker a new single-use key minted for this generation, never the one stored for an earlier generation, which has expired after 24 hours. Bump it after expiring keys that leaked, or when a worker could not join because its key expired before the node first booted."
  type        = string
  default     = "2026-10-25"

  validation {
    condition     = can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", var.tailnet_key_generation))
    error_message = "tailnet_key_generation is a date, YYYY-MM-DD; its eight digits name the worker key slot on unfold-headscale."
  }
}

variable "host_firewall_enabled" {
  description = "Talos host firewall: block every inbound connection the node rules in host-firewall.tf do not name. False removes the firewall documents, and the next apply returns the nodes to Talos's accept-all default in place, without a reboot. The rollback for a rule set that turns out wrong."
  type        = bool
  default     = true
}

variable "disk_encryption_kms_endpoint" {
  description = "The KMS server that seals the LUKS2 keys of the Talos STATE and EPHEMERAL volumes, as https://host:port with a certificate from a public CA (STATE is unlocked before the machine config, and its custom CAs, are read). Empty means the KMS this repository runs on unfold-headscale (disk-kms.tf, ADR 0003); set it only to move the KMS elsewhere."
  type        = string
  default     = ""

  validation {
    condition     = var.disk_encryption_kms_endpoint == "" || can(regex("^https://[^/]+:[0-9]+$", var.disk_encryption_kms_endpoint))
    error_message = "Use https://host:port. A plaintext grpc:// endpoint would send the disk keys in the clear."
  }
}

variable "disk_encryption_nodes" {
  description = "Nodes whose STATE and EPHEMERAL volumes are encrypted. Talos encrypts a volume only when it formats it and refuses to mount a plain volume once encryption is configured, so adding a running cloud node here re-installs it: the apply drains it, takes a control plane out of etcd, wipes both volumes and applies the encrypted config (disk-encryption-rollout.tf). One running node per reviewed plan; scripts/guard-encryption-rollout.sh refuses more. A node created while listed is encrypted from its first boot. Every declared metal node is encrypted from its first install without being listed (local.encrypted_nodes). See docs/disk-encryption.md."
  type        = set(string)
  default     = []

  validation {
    condition     = alltrue([for name in var.disk_encryption_nodes : contains(keys(local.cluster_nodes), name)])
    error_message = "disk_encryption_nodes names a node this cluster does not have."
  }
}

variable "homelab_gateway_key_generation" {
  description = "The generation of the homelab gateway's single-use tailnet pre-auth key. Raising it makes the next apply mint a new tag:homelab-gateway key and hand it to OpenBao: after the gateway lost its Tailscale state, or when a key expired unused."
  type        = number
  default     = 1
}

variable "headscale_generation" {
  description = "The generation of unfold-headscale. Raising it replaces the server through a reviewed plan: the apply lifts its delete protection first (scripts/lift-headscale-protection.sh), the new server starts from the current cloud-init, and every node, the homelab gateway included, re-joins with a fresh key the same apply hands it. Generation 3 replaced the server of 2026-10-25, whose program and sudoers rule predate the apply's install and policy steps. Generation 4 adds the disk KMS (disk-kms.tf), which only a new server's cloud-init installs."
  type        = number
  default     = 4

  validation {
    condition     = var.headscale_generation >= 1 && floor(var.headscale_generation) == var.headscale_generation
    error_message = "headscale_generation is a whole number, 1 or higher."
  }
}

variable "headscale_address_property" {
  description = "The property of OpenBao secret/unfold/headscale-address that the apply sets to the Headscale server's public IPv4 address. The homelab publishes headscale.webgrip.dev from ipv4 and headscale-drill.webgrip.dev from drill_ipv4, so a server in a new Hetzner project, which has a new primary IP, is found without a commit."
  type        = string
  default     = "ipv4"

  validation {
    condition     = contains(["ipv4", "drill_ipv4"], var.headscale_address_property)
    error_message = "The homelab publishes only ipv4 (production) and drill_ipv4 (the rebuild drill)."
  }
}

variable "talos_secrets_import_file" {
  description = "Path of a talosctl secrets bundle to import as talos_machine_secrets.cluster. The infra workflow sets it only when the state holds no Talos secrets and OpenBao holds an escrowed bundle, so a rebuild from an empty state keeps the cluster's certificate authorities and service-account key. Empty imports nothing."
  type        = string
  default     = ""
}

variable "gvisor_oci_seccomp" {
  description = "Apply each pod's seccomp profile inside gVisor's sandbox as well (runsc oci-seccomp) on every node that runs gVisor. False is the rollback when a CI build needs a syscall the RuntimeDefault profile blocks; see docs/runbooks/metal-node.md."
  type        = bool
  default     = true
}

variable "metal_image_file" {
  description = "The file, relative to infra/, that pins the metal nodes' Talos installer and disk image (built with Kata 4.3.1 by webgrip/talos-kata-extension; docs/adr/0001-kata-4-on-the-metal-node.md). While its values are empty, the metal servers are ordered and wired but not installed. Tests point it at their fixtures."
  type        = string
  default     = "../talos/metal-image.yaml"
}

variable "metal_image_pull_username" {
  description = "The Forgejo user whose read:package token pulls the private metal images: webgrip-ci, read from OpenBao unfold-cluster/metal-image-pull, where homelab-cluster's unfold-metal-image-provisioner keeps it."
  type        = string
  default     = ""
}

variable "metal_image_pull_token" {
  description = "The read:package token that pulls the private metal images; the node's registry auth for upgrades. Minted by homelab-cluster's unfold-metal-image-provisioner, read from OpenBao unfold-cluster/metal-image-pull."
  type        = string
  sensitive   = true
  default     = ""
}
