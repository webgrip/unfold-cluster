locals {
  cluster_secrets = merge(local.seeded_cluster_secrets, local.autoscaler_cluster_secrets)

  seeded_cluster_secrets = {
    hcloud = {
      name      = "hcloud"
      namespace = "kube-system"
      data = {
        token   = var.hcloud_cluster_token
        network = tostring(hcloud_network.cluster.id)
      }
    }
    etcd-backup = {
      name      = "etcd-backup"
      namespace = "etcd-backup"
      data = {
        AWS_ACCESS_KEY_ID     = var.etcd_backup_s3_access_key
        AWS_SECRET_ACCESS_KEY = var.etcd_backup_s3_secret_key
        AGE_X25519_PUBLIC_KEY = var.etcd_backup_age_recipient
      }
    }
  }

  cluster_secret_manifests = {
    for key, secret in local.cluster_secrets : key => yamlencode({
      apiVersion = "v1"
      kind       = "Secret"
      metadata = {
        name      = secret.name
        namespace = secret.namespace
      }
      stringData = secret.data
    })
  }

  cluster_secrets_apply_body = jsonencode([
    for secret in values(local.cluster_secrets) : {
      apiVersion = "v1"
      kind       = "Secret"
      metadata = {
        name      = secret.name
        namespace = secret.namespace
      }
      data = { for key, value in secret.data : key => base64encode(value) }
    }
  ])
}

resource "terraform_data" "cluster_secrets" {
  triggers_replace = sha256(local.cluster_secrets_apply_body)

  provisioner "local-exec" {
    command = "${path.module}/../scripts/write-cluster-secrets.sh"
    environment = {
      CLUSTER_SECRETS         = local.cluster_secrets_apply_body
      KUBE_API_ENDPOINTS      = join(" ", [for server in hcloud_server.control_plane : server.ipv4_address])
      KUBE_API_SERVER_NAME    = local.api_vip
      KUBE_CA_CERTIFICATE     = talos_cluster_kubeconfig.cluster.kubernetes_client_configuration.ca_certificate
      KUBE_CLIENT_CERTIFICATE = talos_cluster_kubeconfig.cluster.kubernetes_client_configuration.client_certificate
      KUBE_CLIENT_KEY         = talos_cluster_kubeconfig.cluster.kubernetes_client_configuration.client_key
    }
  }
}
