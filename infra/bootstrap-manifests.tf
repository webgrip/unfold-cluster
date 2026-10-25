locals {
  # renovate: datasource=docker depName=ghcr.io/controlplaneio-fluxcd/charts/flux-operator
  flux_operator_chart_version = "0.61.0"
  # renovate: datasource=docker depName=ghcr.io/controlplaneio-fluxcd/flux-operator
  flux_operator_image_tag = "v0.61.0@sha256:71041d9fff7f7b05f1a8123ebe73c73b7b156f4aacfe1e8e19b5aa953a98892c"
  # renovate: datasource=docker depName=ghcr.io/controlplaneio-fluxcd/charts/flux-instance
  flux_instance_chart_version = "0.61.0"
  # renovate: datasource=docker depName=ghcr.io/controlplaneio-fluxcd/flux-operator-manifests
  flux_manifests_tag = "v0.61.0@sha256:a94070768dc353efb3aaf7a28ae2d57566e8d20d8dc5287aacb6c10e169b7137"
  # renovate: datasource=github-releases depName=fluxcd/flux2 extractVersion=^v(?<version>.+)$
  flux_version = "2.9.6"

  flux_platform_dir = "${path.module}/../kubernetes/platform"

  cilium_release    = yamldecode(file("${local.flux_platform_dir}/cilium/helmrelease.yaml"))
  cilium_chart_ref  = yamldecode(file("${local.flux_platform_dir}/cilium/ocirepository.yaml")).spec
  cilium_chart_url  = regex("^(?P<repository>.+)/(?P<chart>[^/]+)$", local.cilium_chart_ref.url)
  cilium_values     = file("${local.flux_platform_dir}/cilium/values.yaml")
  cilium_values_map = yamldecode(local.cilium_values)

  hcloud_ccm_release   = yamldecode(file("${local.flux_platform_dir}/hcloud-cloud-controller-manager/helmrelease.yaml"))
  hcloud_ccm_chart     = local.hcloud_ccm_release.spec.chart.spec
  hcloud_ccm_values    = file("${local.flux_platform_dir}/hcloud-cloud-controller-manager/values.yaml")
  hetzner_chart_repo   = yamldecode(file("${local.flux_platform_dir}/hetzner-charts/helmrepository.yaml")).spec.url
  flux_owned_namespace = "kube-system"
}

data "helm_template" "cilium" {
  name         = local.cilium_release.spec.releaseName
  namespace    = local.flux_owned_namespace
  repository   = local.cilium_chart_url.repository
  chart        = local.cilium_chart_url.chart
  version      = local.cilium_chart_ref.ref.tag
  kube_version = local.kubernetes_version
  values       = [local.cilium_values]

  lifecycle {
    precondition {
      condition     = local.cilium_values_map.cluster.name == local.cluster_name && local.cilium_values_map.cluster.id == local.cilium_cluster_id
      error_message = "kubernetes/platform/cilium/values.yaml must name cluster ${local.cluster_name} with ID ${local.cilium_cluster_id}, the identity the address plan allocates for ClusterMesh"
    }
  }
}

data "helm_template" "hcloud_ccm" {
  name         = local.hcloud_ccm_release.spec.releaseName
  namespace    = local.flux_owned_namespace
  repository   = local.hetzner_chart_repo
  chart        = local.hcloud_ccm_chart.chart
  version      = local.hcloud_ccm_chart.version
  kube_version = local.kubernetes_version
  values       = [local.hcloud_ccm_values]
}

data "helm_template" "flux_operator" {
  name         = "flux-operator"
  namespace    = "flux-system"
  repository   = "oci://ghcr.io/controlplaneio-fluxcd/charts"
  chart        = "flux-operator"
  version      = local.flux_operator_chart_version
  kube_version = local.kubernetes_version

  values = [yamlencode({
    image = {
      tag = local.flux_operator_image_tag
    }
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
        version  = local.flux_version
        artifact = "oci://ghcr.io/controlplaneio-fluxcd/flux-operator-manifests:${local.flux_manifests_tag}"
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
      token   = var.hcloud_cluster_token
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

  etcd_backup_manifest = join("\n---\n", [
    yamlencode({
      apiVersion = "v1"
      kind       = "Namespace"
      metadata = {
        name = "etcd-backup"
      }
    }),
    yamlencode({
      apiVersion = "v1"
      kind       = "Secret"
      metadata = {
        name      = "etcd-backup"
        namespace = "etcd-backup"
      }
      stringData = {
        AWS_ACCESS_KEY_ID     = var.etcd_backup_s3_access_key
        AWS_SECRET_ACCESS_KEY = var.etcd_backup_s3_secret_key
        AGE_X25519_PUBLIC_KEY = var.etcd_backup_age_recipient
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
    { name = "etcd-backup", contents = local.etcd_backup_manifest },
  ]
}
