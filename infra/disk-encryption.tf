locals {
  cluster_nodes = merge(local.control_planes, local.unfold_worker)

  disk_encryption = {
    provider  = "luks2"
    cipher    = "aes-xts-plain64"
    blockSize = 4096
    options   = ["no_read_workqueue", "no_write_workqueue"]
    keys = [{
      slot = 0
      kms = {
        endpoint = var.disk_encryption_kms_endpoint
      }
    }]
  }

  disk_encryption_volume_patches = [for volume in ["STATE", "EPHEMERAL"] : yamlencode({
    apiVersion = "v1alpha1"
    kind       = "VolumeConfig"
    name       = volume
    encryption = local.disk_encryption
  })]

  disk_encryption_patches = {
    for name in keys(local.cluster_nodes) : name => contains(var.disk_encryption_nodes, name) ? local.disk_encryption_volume_patches : []
  }
}
