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

variable "unfold_worker_server_type" {
  description = "The worker dedicated to Unfold by label and taint (VIK-2157). Cost-optimized CX33 (4 vCPU, 8 GB), x86 like the Talos snapshot."
  type        = string
  default     = "cx33"

  validation {
    condition     = !startswith(lower(var.unfold_worker_server_type), "cax")
    error_message = "CAX servers are Arm; the Talos snapshot and the Headscale package are x86 (amd64)."
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
  description = "Hetzner Cloud API token for the cloud controller and the CSI driver, seeded into kube-system by a Talos inline manifest and rewritten into the running cluster by every apply that changes it. A different token from CI's, so either can be revoked alone."
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
  description = "Changing this makes the next apply read fresh tailnet pre-auth keys from unfold-headscale instead of reusing the ones in the state. Bump it after expiring keys that leaked."
  type        = string
  default     = "2026-10-25"
}

variable "host_firewall_enabled" {
  description = "Talos host firewall: block every inbound connection the node rules in host-firewall.tf do not name. False removes the firewall documents, and the next apply returns the nodes to Talos's accept-all default in place, without a reboot. The rollback for a rule set that turns out wrong."
  type        = bool
  default     = true
}
