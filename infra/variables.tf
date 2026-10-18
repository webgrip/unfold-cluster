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
  description = "Addresses allowed to reach the Talos and Kubernetes APIs from the internet. Empty after bootstrap: admin traffic then arrives over WireGuard or Tailscale."
  type        = list(string)
  default     = []
}

variable "vswitch_id" {
  description = "Robot vSwitch id that joins the AX41 to the Cloud Network. Null until the AX41 is ordered."
  type        = number
  default     = null
}
