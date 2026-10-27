locals {
  gvisor_capability_label = "runtime.webgrip.io/gvisor"
  gvisor_config_etc_file  = "unfold-sandbox/runsc.toml"
  buildkit_seccomp_name   = "buildkit-rootless.json"
  runner_seccomp_name     = "ci-runner.json"

  gvisor_runtime_patches = {
    for platform in ["systrap", "kvm"] : platform => [
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "SysctlConfig"
        params = {
          "user.max_user_namespaces" = "11255"
        }
      }),
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "EtcFileConfig"
        name       = local.gvisor_config_etc_file
        mode       = 420
        contents = join("\n", [
          "[runsc_config]",
          "  platform = \"${platform}\"",
          "  oci-seccomp = \"${var.gvisor_oci_seccomp}\"",
          "",
        ])
      }),
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "CRICustomizationConfig"
        name       = "gvisor-runsc-options"
        content = join("\n", [
          "[plugins.\"io.containerd.cri.v1.runtime\".containerd.runtimes.runsc.options]",
          "  TypeUrl = \"io.containerd.runsc.v1.options\"",
          "  ConfigPath = \"/etc/${local.gvisor_config_etc_file}\"",
          "",
        ])
      }),
      yamlencode({
        machine = {
          seccompProfiles = [
            for name in [local.buildkit_seccomp_name, local.runner_seccomp_name] : {
              name  = name
              value = jsondecode(file("${path.module}/templates/seccomp/${name}"))
            }
          ]
        }
      }),
    ]
  }

  worker_sandbox_patches = {
    for name, pool in var.worker_pools : name => lookup(pool.labels, local.gvisor_capability_label, "") == "true" ? local.gvisor_runtime_patches.systrap : []
  }
}
