data "helm_template" "cilium" {
  name         = "cilium"
  namespace    = "kube-system"
  repository   = "oci://quay.io/cilium/charts"
  chart        = "cilium"
  version      = "1.20.3"
  kube_version = var.kubernetes_version

  values = [yamlencode({
    ipam = {
      mode = "kubernetes"
    }
    kubeProxyReplacement = true
    k8sServiceHost       = "localhost"
    k8sServicePort       = 7445
    routingMode          = "tunnel"
    tunnelProtocol       = "vxlan"
    MTU                  = 1350
    cgroup = {
      autoMount = {
        enabled = false
      }
      hostRoot = "/sys/fs/cgroup"
    }
    securityContext = {
      capabilities = {
        ciliumAgent      = ["CHOWN", "KILL", "NET_ADMIN", "NET_RAW", "IPC_LOCK", "SYS_ADMIN", "SYS_RESOURCE", "DAC_OVERRIDE", "FOWNER", "SETGID", "SETUID"]
        cleanCiliumState = ["NET_ADMIN", "SYS_ADMIN", "SYS_RESOURCE"]
      }
    }
    operator = {
      replicas = 1
    }
  })]
}

data "helm_template" "hcloud_ccm" {
  name         = "hcloud-cloud-controller-manager"
  namespace    = "kube-system"
  repository   = "https://charts.hetzner.cloud"
  chart        = "hcloud-cloud-controller-manager"
  version      = "1.39.0"
  kube_version = var.kubernetes_version

  values = [yamlencode({
    networking = {
      enabled = false
    }
  })]
}

data "helm_template" "flux_operator" {
  name         = "flux-operator"
  namespace    = "flux-system"
  repository   = "oci://ghcr.io/controlplaneio-fluxcd/charts"
  chart        = "flux-operator"
  version      = "0.61.0"
  kube_version = var.kubernetes_version
}

data "helm_template" "flux_instance" {
  name         = "flux"
  namespace    = "flux-system"
  repository   = "oci://ghcr.io/controlplaneio-fluxcd/charts"
  chart        = "flux-instance"
  version      = "0.61.0"
  kube_version = var.kubernetes_version

  values = [yamlencode({
    instance = {
      distribution = {
        version = "2.x"
      }
      sync = {
        kind = "GitRepository"
        url  = var.gitops_url
        ref  = "refs/heads/main"
        path = "kubernetes/clusters/main"
      }
    }
  })]
}

locals {
  hcloud_secret_manifest = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata = {
      name      = "hcloud"
      namespace = "kube-system"
    }
    stringData = {
      token   = var.hcloud_token
      network = tostring(hcloud_network.cluster.id)
    }
  })

  flux_namespace_manifest = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name = "flux-system"
    }
  })

  inline_manifests = [
    { name = "cilium", contents = data.helm_template.cilium.manifest },
    { name = "hcloud-secret", contents = local.hcloud_secret_manifest },
    { name = "hcloud-cloud-controller-manager", contents = data.helm_template.hcloud_ccm.manifest },
    { name = "flux-system-namespace", contents = local.flux_namespace_manifest },
    { name = "flux-operator", contents = data.helm_template.flux_operator.manifest },
    { name = "flux-instance", contents = data.helm_template.flux_instance.manifest },
  ]
}
