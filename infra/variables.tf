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
  description = "The fixed worker pools OpenTofu creates, by pool name. Each node is named name_prefix-N, takes the private address first_host+N-1 in the cloud subnet, and carries its pool's Kubernetes labels and taints (Talos KubeNodeConfig: taint value is value:Effect). unfold is the hub worker dedicated to Unfold (VIK-2157), a cost-optimized CX33. ci is the CI worker of RFC 0001 step 13, a CX43 (8 vCPU, 16 GB), whose CI jobs run under the gvisor RuntimeClass. Nodes a cluster-autoscaler adds are not listed here."
  type = map(object({
    server_type = string
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
      labels      = { "node.webgrip.io/pool" = "unfold" }
      taints      = { "node.webgrip.io/pool" = "unfold:NoSchedule" }
    }
    ci = {
      server_type = "cx43"
      node_count  = 1
      name_prefix = "unfold-ci"
      first_host  = 31
      labels      = { "node.webgrip.io/pool" = "ci" }
      taints      = { "node.webgrip.io/pool" = "ci:NoSchedule" }
    }
  }

  validation {
    condition     = alltrue([for pool in values(var.worker_pools) : !startswith(lower(pool.server_type), "cax")])
    error_message = "CAX servers are Arm; the Talos snapshot and the Headscale package are x86 (amd64)."
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

variable "vswitch_id" {
  description = "Robot vSwitch id that joins the AX41 to the Cloud Network. Null until the AX41 is ordered."
  type        = number
  default     = null
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
  description = "Hetzner Cloud API token for the cloud controller and the CSI driver, delivered to kube-system through a Talos inline manifest. A different token from CI's, so either can be revoked alone."
  type        = string
  sensitive   = true
  default     = ""
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

variable "gitops_url" {
  description = "Repository Flux reconciles from: the public GitHub mirror, so production keeps reconciling when the homelab is down."
  type        = string
  default     = "https://github.com/webgrip/unfold-cluster.git"
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
  description = "The Headscale user whose devices are admins on the tailnet: the only members allowed to reach the nodes and the cluster's private subnet."
  type        = string
  default     = "ryan"
}

variable "etcd_backup_s3_access_key" {
  description = "Access key of the Garage key that may write, but not read, the etcd backup bucket. Delivered to the etcd-backup namespace through a Talos inline manifest."
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
