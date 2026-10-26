locals {
  control_plane_component_requests = {
    KubeAPIServerConfig         = { cpu = "250m", memory = "1Gi" }
    KubeControllerManagerConfig = { cpu = "50m", memory = "256Mi" }
    KubeSchedulerConfig         = { cpu = "10m", memory = "64Mi" }
  }

  control_plane_component_env = {
    KubeAPIServerConfig = { GOMEMLIMIT = "1400MiB" }
  }

  control_plane_component_requests_patches = [
    for kind, requests in local.control_plane_component_requests : yamlencode(merge(
      {
        apiVersion = "v1alpha1"
        kind       = kind
        resources  = { requests = requests }
      },
      contains(keys(local.control_plane_component_env), kind) ? { env = local.control_plane_component_env[kind] } : {},
    ))
  ]

  control_plane_kubelet_memory_patch = yamlencode({
    apiVersion = "v1alpha1"
    kind       = "KubeletConfig"
    config = {
      evictionHard = {
        "memory.available"  = "300Mi"
        "nodefs.available"  = "10%"
        "nodefs.inodesFree" = "5%"
        "imagefs.available" = "15%"
      }
      evictionSoft = {
        "memory.available" = "500Mi"
      }
      evictionSoftGracePeriod = {
        "memory.available" = "30s"
      }
    }
  })
}
