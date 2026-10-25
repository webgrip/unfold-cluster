locals {
  cluster_nodes = merge(local.control_planes, { for name, worker in local.workers : name => worker.private_ip })

  disk_encryption_keys = [{
    slot = 0
    kms = {
      endpoint = local.disk_encryption_kms_endpoint
    }
  }]

  disk_encryption_cloud_disk = {
    provider      = "luks2"
    cipher        = "aes-xts-plain64"
    blockSize     = 4096
    options       = ["no_read_workqueue", "no_write_workqueue"]
    allowDiscards = false
    keys          = local.disk_encryption_keys
  }

  disk_encryption_local_nvme = merge(local.disk_encryption_cloud_disk, {
    allowDiscards = true
  })

  disk_encryption_by_node = {
    for name in keys(local.cluster_nodes) : name => startswith(name, "unfold-metal-") ? local.disk_encryption_local_nvme : local.disk_encryption_cloud_disk
  }

  disk_encryption_patches = {
    for name in keys(local.cluster_nodes) : name => !contains(var.disk_encryption_nodes, name) ? [] : [
      for volume in ["STATE", "EPHEMERAL"] : yamlencode({
        apiVersion = "v1alpha1"
        kind       = "VolumeConfig"
        name       = volume
        encryption = local.disk_encryption_by_node[name]
      })
    ]
  }
}
