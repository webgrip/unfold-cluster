mock_provider "hcloud" {
  mock_resource "hcloud_network" {
    defaults = {
      id = "101"
    }
  }

  mock_resource "hcloud_firewall" {
    defaults = {
      id = "102"
    }
  }

  mock_resource "hcloud_primary_ip" {
    defaults = {
      id = "103"
    }
  }

  mock_resource "hcloud_ssh_key" {
    defaults = {
      id = "104"
    }
  }

  mock_resource "hcloud_placement_group" {
    defaults = {
      id = "105"
    }
  }

  mock_resource "hcloud_server" {
    defaults = {
      id = "106"
    }
  }

  mock_data "hcloud_images" {
    defaults = {
      images = []
    }
  }
}

mock_provider "talos" {}

mock_provider "helm" {}

mock_provider "tls" {}

mock_provider "external" {
  mock_data "external" {
    defaults = {
      result = {
        key = "hskey-auth-mocked"
      }
    }
  }
}

variables {
  state_passphrase     = "mock-passphrase-of-at-least-thirty-two-characters"
  admin_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMockOwnerKey owner"
  admin_cidrs          = ["203.0.113.7/32"]
}

run "a_plan_only_run_before_the_snapshot_exists_still_plans_every_node" {
  command = plan

  assert {
    condition     = length(hcloud_server.control_plane) == 3 && length(hcloud_server.worker) == 2
    error_message = "a plan-only run must show every cluster node, with no human-set gate"
  }

  assert {
    condition     = hcloud_server.control_plane["unfold-cp-1"].image == "talos-snapshot-is-built-by-the-apply-run"
    error_message = "without a snapshot, a plan-only run shows the placeholder image"
  }
}

run "an_apply_run_refuses_to_boot_nodes_without_the_snapshot" {
  command = plan

  variables {
    talos_snapshot_required = true
  }

  expect_failures = [
    hcloud_server.control_plane,
    hcloud_server.worker,
  ]
}

run "an_apply_run_boots_nodes_from_the_labelled_snapshot_with_the_key_read_from_headscale" {
  command = plan

  variables {
    talos_snapshot_required = true
  }

  override_resource {
    target = tls_private_key.headscale_tofu
    values = {
      public_key_openssh = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMockTofuKey\n"
    }
  }

  override_resource {
    target = tls_private_key.headscale_host
    values = {
      public_key_openssh  = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMockHostKey\n"
      private_key_openssh = "-----BEGIN OPENSSH PRIVATE KEY-----\nbW9jaw==\n-----END OPENSSH PRIVATE KEY-----\n"
    }
  }

  override_data {
    target = data.hcloud_images.talos
    values = {
      images = [{
        id                    = 4242
        name                  = ""
        type                  = "snapshot"
        description           = "Talos"
        architecture          = "x86"
        os_flavor             = "unknown"
        os_version            = ""
        rapid_deploy          = false
        deprecated            = ""
        deprecation_announced = ""
        unavailable_after     = ""
        is_deprecated         = false
        labels                = {}
        created               = ""
      }]
    }
  }

  assert {
    condition     = hcloud_server.control_plane["unfold-cp-1"].image == "4242"
    error_message = "nodes boot from the snapshot the label selector found"
  }

  assert {
    condition = alltrue([
      data.external.control_plane_tailnet_key.query.request == "control-plane",
      data.external.control_plane_tailnet_key.query.host_public_key == "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMockHostKey",
      data.external.worker_tailnet_key["unfold-app-1"].query.host_public_key == "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMockHostKey",
    ])
    error_message = "OpenTofu asks unfold-headscale for the keys and trusts only the host key it generated for it"
  }

  assert {
    condition     = data.external.worker_tailnet_key["unfold-app-1"].query.request == "worker ${hcloud_server.worker["unfold-app-1"].id}20261025"
    error_message = "a worker key is asked for by the worker's own server id and the key generation, so each server gets one per generation"
  }

  assert {
    condition = alltrue([
      for name in keys(local.control_planes) :
      strcontains(local.tailscale_join[name].extra_args, "--advertise-routes=10.64.0.0/24")
    ])
    error_message = "control planes advertise the cloud subnet"
  }

  assert {
    condition     = !strcontains(local.tailscale_join["unfold-app-1"].extra_args, "--advertise-routes")
    error_message = "the worker advertises no route"
  }

  assert {
    condition = alltrue([
      for name, node in local.tailscale_join : !strcontains(node.extra_args, "--advertise-tags")
    ])
    error_message = "Headscale refuses a pre-auth key registration that also requests tags, so every node takes its tags from its key alone"
  }

  assert {
    condition     = strcontains(hcloud_server.headscale.user_data, "restrict,command=\"set -f; exec sudo -n /usr/local/sbin/unfold-tailnet-key $SSH_ORIGINAL_COMMAND\" ${trimspace(tls_private_key.headscale_tofu.public_key_openssh)}")
    error_message = "OpenTofu's key on unfold-headscale is restricted to the tailnet key command"
  }

  assert {
    condition = alltrue([
      strcontains(hcloud_server.headscale.user_data, "ssh_deletekeys: true"),
      strcontains(hcloud_server.headscale.user_data, "ssh_genkeytypes: [ed25519]"),
      strcontains(hcloud_server.headscale.user_data, "ed25519_public: ${trimspace(tls_private_key.headscale_host.public_key_openssh)}"),
      strcontains(hcloud_server.headscale.user_data, "    -----BEGIN OPENSSH PRIVATE KEY-----"),
    ])
    error_message = "unfold-headscale presents only the ed25519 host key OpenTofu generated"
  }

  assert {
    condition     = hcloud_server.headscale.delete_protection && hcloud_server.headscale.rebuild_protection
    error_message = "unfold-headscale is created protected"
  }
}

run "the_tailnet_key_is_not_read_without_an_admin_address" {
  command = plan

  variables {
    admin_cidrs = []
  }

  expect_failures = [
    data.external.control_plane_tailnet_key,
  ]
}

run "the_pod_security_defaults_leave_the_talos_exemptions_alone" {
  command = plan

  assert {
    condition     = !strcontains(local.pod_security_patch, "exemptions")
    error_message = "Talos already exempts kube-system; a patch that names it again lists it twice, and the API server refuses the PodSecurity config"
  }
}

run "the_tailnet_keys_never_show_in_a_plan" {
  command = plan

  override_resource {
    target = terraform_data.control_plane_tailnet_key
    values = {
      output = "hskey-auth-mocked-control-plane"
    }
  }

  override_resource {
    target = terraform_data.worker_tailnet_key
    values = {
      output = "hskey-auth-mocked-worker"
    }
  }

  assert {
    condition     = alltrue([for patch in values(local.tailscale_patch) : issensitive(patch)])
    error_message = "the Tailscale patch carries a pre-auth key; unmarked, it prints in the public plan log"
  }
}

run "the_talos_seed_installs_cilium_exactly_as_flux_reconciles_it" {
  command = plan

  assert {
    condition     = contains(yamldecode(file("${path.module}/../kubernetes/clusters/main/kustomization.yaml")).resources, "../../platform/cilium")
    error_message = "Flux must reconcile kubernetes/platform/cilium, or nothing changes Cilium after the first boot"
  }

  assert {
    condition     = try(yamldecode(file("${path.module}/../kubernetes/platform/cilium/helmrelease.yaml")).spec.values, null) == null
    error_message = "the cilium HelmRelease carries inline values the Talos seed never sees; put them in kubernetes/platform/cilium/values.yaml"
  }

  assert {
    condition = alltrue([
      yamldecode(file("${path.module}/../kubernetes/platform/cilium/helmrelease.yaml")).spec.valuesFrom == [{ kind = "ConfigMap", name = "cilium-values", valuesKey = "values.yaml" }],
      one([for generator in yamldecode(file("${path.module}/../kubernetes/platform/cilium/kustomization.yaml")).configMapGenerator : generator if generator.name == "cilium-values"]).files == ["values.yaml"],
    ])
    error_message = "Flux must read the cilium values only from the ConfigMap generated from kubernetes/platform/cilium/values.yaml"
  }

  assert {
    condition = alltrue([
      length(data.helm_template.cilium.values) == 1,
      yamldecode(data.helm_template.cilium.values[0]) == yamldecode(file("${path.module}/../kubernetes/platform/cilium/values.yaml")),
      try(length(data.helm_template.cilium.set), 0) == 0,
    ])
    error_message = "the Talos seed must render Cilium with kubernetes/platform/cilium/values.yaml and nothing else, the values Flux uses"
  }

  assert {
    condition = alltrue([
      data.helm_template.cilium.name == yamldecode(file("${path.module}/../kubernetes/platform/cilium/helmrelease.yaml")).spec.releaseName,
      data.helm_template.cilium.namespace == yamldecode(file("${path.module}/../kubernetes/platform/cilium/kustomization.yaml")).namespace,
      try(yamldecode(file("${path.module}/../kubernetes/platform/cilium/helmrelease.yaml")).spec.targetNamespace, null) == null,
    ])
    error_message = "the Talos seed and Flux must install Cilium as the same Helm release in the same namespace, or Flux installs a second Cilium beside the seed's"
  }

  assert {
    condition = alltrue([
      yamldecode(file("${path.module}/../kubernetes/platform/cilium/helmrelease.yaml")).spec.chartRef == { kind = "OCIRepository", name = yamldecode(file("${path.module}/../kubernetes/platform/cilium/ocirepository.yaml")).metadata.name },
      "${data.helm_template.cilium.repository}/${data.helm_template.cilium.chart}" == yamldecode(file("${path.module}/../kubernetes/platform/cilium/ocirepository.yaml")).spec.url,
      data.helm_template.cilium.version == yamldecode(file("${path.module}/../kubernetes/platform/cilium/ocirepository.yaml")).spec.ref.tag,
    ])
    error_message = "the Talos seed must render the Cilium chart and version the cilium OCIRepository points Flux at"
  }
}

run "the_talos_seed_installs_the_cloud_controller_exactly_as_flux_reconciles_it" {
  command = plan

  assert {
    condition     = contains(yamldecode(file("${path.module}/../kubernetes/clusters/main/kustomization.yaml")).resources, "../../platform/hcloud-cloud-controller-manager")
    error_message = "Flux must reconcile kubernetes/platform/hcloud-cloud-controller-manager, or nothing changes the cloud controller after the first boot"
  }

  assert {
    condition     = try(yamldecode(file("${path.module}/../kubernetes/platform/hcloud-cloud-controller-manager/helmrelease.yaml")).spec.values, null) == null
    error_message = "the cloud controller HelmRelease carries inline values the Talos seed never sees; put them in kubernetes/platform/hcloud-cloud-controller-manager/values.yaml"
  }

  assert {
    condition = alltrue([
      yamldecode(file("${path.module}/../kubernetes/platform/hcloud-cloud-controller-manager/helmrelease.yaml")).spec.valuesFrom == [{ kind = "ConfigMap", name = "hcloud-cloud-controller-manager-values", valuesKey = "values.yaml" }],
      one([for generator in yamldecode(file("${path.module}/../kubernetes/platform/hcloud-cloud-controller-manager/kustomization.yaml")).configMapGenerator : generator if generator.name == "hcloud-cloud-controller-manager-values"]).files == ["values.yaml"],
    ])
    error_message = "Flux must read the cloud controller values only from the ConfigMap generated from kubernetes/platform/hcloud-cloud-controller-manager/values.yaml"
  }

  assert {
    condition = alltrue([
      length(data.helm_template.hcloud_ccm.values) == 1,
      yamldecode(data.helm_template.hcloud_ccm.values[0]) == yamldecode(file("${path.module}/../kubernetes/platform/hcloud-cloud-controller-manager/values.yaml")),
      try(length(data.helm_template.hcloud_ccm.set), 0) == 0,
    ])
    error_message = "the Talos seed must render the cloud controller with kubernetes/platform/hcloud-cloud-controller-manager/values.yaml and nothing else, the values Flux uses"
  }

  assert {
    condition = alltrue([
      data.helm_template.hcloud_ccm.name == yamldecode(file("${path.module}/../kubernetes/platform/hcloud-cloud-controller-manager/helmrelease.yaml")).spec.releaseName,
      data.helm_template.hcloud_ccm.namespace == yamldecode(file("${path.module}/../kubernetes/platform/hcloud-cloud-controller-manager/kustomization.yaml")).namespace,
      try(yamldecode(file("${path.module}/../kubernetes/platform/hcloud-cloud-controller-manager/helmrelease.yaml")).spec.targetNamespace, null) == null,
    ])
    error_message = "the Talos seed and Flux must install the cloud controller as the same Helm release in the same namespace, or Flux installs a second one beside the seed's"
  }

  assert {
    condition = alltrue([
      yamldecode(file("${path.module}/../kubernetes/platform/hcloud-cloud-controller-manager/helmrelease.yaml")).spec.chart.spec.sourceRef == { kind = "HelmRepository", name = yamldecode(file("${path.module}/../kubernetes/platform/hetzner-charts/helmrepository.yaml")).metadata.name },
      data.helm_template.hcloud_ccm.repository == yamldecode(file("${path.module}/../kubernetes/platform/hetzner-charts/helmrepository.yaml")).spec.url,
      data.helm_template.hcloud_ccm.chart == yamldecode(file("${path.module}/../kubernetes/platform/hcloud-cloud-controller-manager/helmrelease.yaml")).spec.chart.spec.chart,
      data.helm_template.hcloud_ccm.version == yamldecode(file("${path.module}/../kubernetes/platform/hcloud-cloud-controller-manager/helmrelease.yaml")).spec.chart.spec.version,
    ])
    error_message = "the Talos seed must render the cloud controller chart and version its HelmRelease points Flux at"
  }
}
