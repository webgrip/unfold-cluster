locals {
  zot_node_endpoint = "http://127.0.0.1:30500"

  mirrored_registries = ["docker.io", "ghcr.io", "quay.io", "registry.k8s.io"]

  registry_mirror_patches = [
    for registry in local.mirrored_registries : yamlencode({
      apiVersion = "v1alpha1"
      kind       = "RegistryMirrorConfig"
      name       = registry
      endpoints = [{
        url          = "${local.zot_node_endpoint}/v2/${registry}"
        overridePath = true
      }]
      skipFallback = false
    })
  ]
}
