locals {
  # renovate: datasource=docker depName=quay.io/cilium/charts/cilium
  cilium_chart_version = "1.20.3"
  # renovate: datasource=helm depName=hcloud-cloud-controller-manager registryUrl=https://charts.hetzner.cloud
  hcloud_ccm_chart_version = "1.39.0"
  # renovate: datasource=docker depName=ghcr.io/controlplaneio-fluxcd/charts/flux-operator
  flux_operator_chart_version = "0.61.0"
  # renovate: datasource=docker depName=ghcr.io/controlplaneio-fluxcd/charts/flux-instance
  flux_instance_chart_version = "0.61.0"
}

data "helm_template" "cilium" {
  name         = "cilium"
  namespace    = "kube-system"
  repository   = "oci://quay.io/cilium/charts"
  chart        = "cilium"
  version      = local.cilium_chart_version
  kube_version = local.kubernetes_version

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
  version      = local.hcloud_ccm_chart_version
  kube_version = local.kubernetes_version

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
  version      = local.flux_operator_chart_version
  kube_version = local.kubernetes_version

  values = [yamlencode({
    tolerations  = local.control_plane_tolerations
    nodeSelector = local.control_plane_node_selector
  })]
}

data "helm_template" "flux_instance" {
  name         = "flux"
  namespace    = "flux-system"
  repository   = "oci://ghcr.io/controlplaneio-fluxcd/charts"
  chart        = "flux-instance"
  version      = local.flux_instance_chart_version
  kube_version = local.kubernetes_version

  values = [yamlencode({
    instance = {
      distribution = {
        version = "2.x"
      }
      kustomize = {
        patches = [{
          target = {
            kind = "Deployment"
          }
          patch = yamlencode([
            {
              op    = "add"
              path  = "/spec/template/spec/tolerations"
              value = local.control_plane_tolerations
            },
            {
              op    = "add"
              path  = "/spec/template/spec/nodeSelector"
              value = local.control_plane_node_selector
            },
          ])
        }]
      }
    }
  })]
}

locals {
  control_plane_tolerations = [{
    key      = "node-role.kubernetes.io/control-plane"
    operator = "Exists"
    effect   = "NoSchedule"
  }]
  control_plane_node_selector = {
    "node-role.kubernetes.io/control-plane" = ""
  }

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

  trusted_signers = {
    for file in fileset("${path.module}/trusted-signers", "*.sshpub") :
    file => trimspace(file("${path.module}/trusted-signers/${file}"))
  }

  flux_sync_manifest = join("\n---\n", [
    yamlencode({
      apiVersion = "v1"
      kind       = "Secret"
      metadata = {
        name      = "trusted-signers"
        namespace = "flux-system"
      }
      stringData = local.trusted_signers
    }),
    yamlencode({
      apiVersion = "source.toolkit.fluxcd.io/v1"
      kind       = "GitRepository"
      metadata = {
        name      = "flux-system"
        namespace = "flux-system"
      }
      spec = {
        interval = "1m"
        url      = var.gitops_url
        ref = {
          branch = "main"
        }
        verify = {
          mode = "HEAD"
          secretRef = {
            name = "trusted-signers"
          }
        }
      }
    }),
    yamlencode({
      apiVersion = "kustomize.toolkit.fluxcd.io/v1"
      kind       = "Kustomization"
      metadata = {
        name      = "flux-system"
        namespace = "flux-system"
      }
      spec = {
        interval = "10m"
        path     = "./kubernetes/clusters/main"
        prune    = true
        sourceRef = {
          kind = "GitRepository"
          name = "flux-system"
        }
      }
    }),
  ])

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
    { name = "flux-sync", contents = local.flux_sync_manifest },
  ]
}
