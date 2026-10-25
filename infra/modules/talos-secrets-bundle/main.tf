variable "machine_secrets" {
  description = "The machine_secrets attribute of a talos_machine_secrets resource."
  type        = any
  sensitive   = true
}

locals {
  secrets = var.machine_secrets.secrets
  certs   = var.machine_secrets.certs

  bundle = {
    cluster = {
      id     = var.machine_secrets.cluster.id
      secret = var.machine_secrets.cluster.secret
    }
    secrets = merge(
      {
        bootstraptoken            = local.secrets.bootstrap_token
        secretboxencryptionsecret = local.secrets.secretbox_encryption_secret
      },
      try(local.secrets.aescbc_encryption_secret, null) == null ? {} : { aescbcencryptionsecret = local.secrets.aescbc_encryption_secret },
    )
    trustdinfo = {
      token = var.machine_secrets.trustdinfo.token
    }
    certs = {
      etcd              = { crt = local.certs.etcd.cert, key = local.certs.etcd.key }
      k8s               = { crt = local.certs.k8s.cert, key = local.certs.k8s.key }
      k8saggregator     = { crt = local.certs.k8s_aggregator.cert, key = local.certs.k8s_aggregator.key }
      k8sserviceaccount = { key = local.certs.k8s_serviceaccount.key }
      os                = { crt = local.certs.os.cert, key = local.certs.os.key }
    }
  }
}

output "yaml" {
  description = "The secrets as the talosctl secrets bundle, the file format talos_machine_secrets imports."
  value       = yamlencode(local.bundle)
  sensitive   = true
}
