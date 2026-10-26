locals {
  flux_platform_dir = "${path.module}/../kubernetes/platform"
  flux_sync_dir     = "${path.module}/../kubernetes/clusters/main/flux-system"

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
  name         = local.flux_operator_release.spec.releaseName
  namespace    = local.flux_namespace
  repository   = local.flux_operator_chart_repo
  chart        = local.flux_operator_chart.chart
  version      = local.flux_operator_chart.version
  kube_version = local.kubernetes_version
  values       = [local.flux_operator_values]
}

locals {
  flux_namespace = "flux-system"

  flux_operator_release    = yamldecode(file("${local.flux_platform_dir}/flux-operator/helmrelease.yaml"))
  flux_operator_chart      = local.flux_operator_release.spec.chart.spec
  flux_operator_chart_repo = yamldecode(file("${local.flux_platform_dir}/flux-operator/helmrepository.yaml")).spec.url
  flux_operator_values     = file("${local.flux_platform_dir}/flux-operator/values.yaml")

  flux_instance           = yamldecode(file("${local.flux_platform_dir}/flux-instance/fluxinstance.yaml"))
  flux_git_repository     = yamldecode(file("${local.flux_sync_dir}/gitrepository.yaml"))
  flux_sync_kustomization = yamldecode(file("${local.flux_sync_dir}/sync.yaml"))

  trusted_signers_generator = one([
    for generator in yamldecode(file("${local.flux_sync_dir}/kustomization.yaml")).secretGenerator :
    generator if generator.name == "trusted-signers"
  ])
  trusted_signers = {
    for signer_file in local.trusted_signers_generator.files :
    basename(signer_file) => file("${local.flux_sync_dir}/${signer_file}")
  }

  etcd_backup_namespace = yamldecode(file("${local.flux_platform_dir}/etcd-backup/namespace.yaml"))

  coredns_dir   = "${local.flux_platform_dir}/coredns"
  coredns_files = yamldecode(file("${local.coredns_dir}/kustomization.yaml")).resources
  coredns_manifest = join("\n", [
    for coredns_file in local.coredns_files : file("${local.coredns_dir}/${coredns_file}")
  ])

  flux_namespace_manifest = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name = local.flux_namespace
    }
  })

  flux_instance_manifest = yamlencode(merge(local.flux_instance, {
    metadata = merge(local.flux_instance.metadata, { namespace = local.flux_namespace })
  }))

  flux_sync_manifest = join("\n---\n", [
    yamlencode({
      apiVersion = "v1"
      kind       = "Secret"
      metadata = {
        name        = local.trusted_signers_generator.name
        namespace   = local.flux_namespace
        annotations = local.trusted_signers_generator.options.annotations
      }
      stringData = local.trusted_signers
    }),
    yamlencode(merge(local.flux_git_repository, {
      metadata = merge(local.flux_git_repository.metadata, { namespace = local.flux_namespace })
    })),
    yamlencode(merge(local.flux_sync_kustomization, {
      metadata = merge(local.flux_sync_kustomization.metadata, { namespace = local.flux_namespace })
    })),
  ])

  etcd_backup_manifest = join("\n---\n", [
    yamlencode(local.etcd_backup_namespace),
    local.cluster_secret_manifests["etcd-backup"],
  ])

  inline_manifests = [
    { name = "cilium", contents = data.helm_template.cilium.manifest },
    { name = "hcloud-secret", contents = local.cluster_secret_manifests["hcloud"] },
    { name = "hcloud-cloud-controller-manager", contents = data.helm_template.hcloud_ccm.manifest },
    { name = "coredns", contents = local.coredns_manifest },
    { name = "flux-system-namespace", contents = local.flux_namespace_manifest },
    { name = "flux-operator", contents = data.helm_template.flux_operator.manifest },
    { name = "flux-instance", contents = local.flux_instance_manifest },
    { name = "flux-sync", contents = local.flux_sync_manifest },
    { name = "etcd-backup", contents = local.etcd_backup_manifest },
  ]
}
