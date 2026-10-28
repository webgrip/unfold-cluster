terraform {
  required_version = ">= 1.13.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.70"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.12"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.4"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.4"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.28"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }

  encryption {
    key_provider "pbkdf2" "state" {
      passphrase = var.state_passphrase
    }

    method "aes_gcm" "state" {
      keys = key_provider.pbkdf2.state
    }

    state {
      method   = method.aes_gcm.state
      enforced = true
    }

    plan {
      method   = method.aes_gcm.state
      enforced = true
    }
  }

  backend "s3" {
    key                         = "unfold-cluster/infra.tfstate"
    use_path_style              = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }
}

provider "hcloud" {
  poll_interval = "2s"
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token == "" ? null : var.cloudflare_api_token
}
