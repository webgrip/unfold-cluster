variable "location" {
  description = "Hetzner Cloud location for every cloud server. Falkenstein or Nuremberg, next to the AX41 (VIK-1767)."
  type        = string
  default     = "fsn1"

  validation {
    condition     = contains(["fsn1", "nbg1"], var.location)
    error_message = "The cluster lives in fsn1 or nbg1, beside its dedicated worker."
  }
}

variable "talos_snapshot_id" {
  description = "Id of the Hetzner snapshot built from talos/schematics/cloud.yaml at the Talos version in talos/talenv.yaml."
  type        = string
}

variable "control_plane_server_type" {
  description = "CPX22 until Hetzner's CX stock returns; then CX23, one node at a time."
  type        = string
  default     = "cpx22"
}

variable "unfold_worker_server_type" {
  description = "The worker dedicated to Unfold by label and taint (VIK-2157)."
  type        = string
  default     = "cpx32"
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

variable "hcloud_token" {
  description = "Hetzner Cloud API token handed to the cloud controller and CSI driver through a Talos inline manifest. Same value the provider reads from HCLOUD_TOKEN."
  type        = string
  sensitive   = true
}

variable "talos_cloud_schematic" {
  description = "Image Factory schematic id of talos/schematics/cloud.yaml."
  type        = string
  default     = "e6f2695f46beded22e55354c7bf5189c080e726d840f093384f54d07294b9939"
}

variable "talos_version" {
  description = "Talos version of the nodes; matches talos/talenv.yaml and the snapshot."
  type        = string
  default     = "v1.14.4"
}

variable "kubernetes_version" {
  description = "Kubernetes version of the control plane and kubelets; matches talos/talenv.yaml."
  type        = string
  default     = "1.37.1"
}

variable "gitops_url" {
  description = "Repository Flux reconciles from: the public GitHub mirror, so production keeps reconciling when the homelab is down."
  type        = string
  default     = "https://github.com/webgrip/unfold-cluster.git"
}
