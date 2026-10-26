locals {
  control_plane_component_requests = {
    KubeAPIServerConfig         = { cpu = "250m", memory = "1Gi" }
    KubeControllerManagerConfig = { cpu = "50m", memory = "256Mi" }
    KubeSchedulerConfig         = { cpu = "10m", memory = "64Mi" }
  }

  control_plane_component_requests_patches = [
    for kind, requests in local.control_plane_component_requests : yamlencode({
      apiVersion = "v1alpha1"
      kind       = kind
      resources  = { requests = requests }
    })
  ]
}
