locals {
  cosign_webgrip_public_key = trimspace(file("${path.module}/keys/cosign-webgrip.pub"))

  unsigned_webgrip_images = [
    "forgejo.webgrip.dev/webgrip/infra-runner",
  ]

  signed_webgrip_image_patterns = [
    "ghcr.io/webgrip/*",
    "ghcr.io/webgrip/*/*",
    "forgejo.webgrip.dev/webgrip/*",
    "forgejo.webgrip.dev/webgrip/*/*",
  ]

  image_verification_patch = yamlencode({
    apiVersion = "v1alpha1"
    kind       = "ImageVerificationConfig"
    rules = concat(
      [for image in local.unsigned_webgrip_images : { image = image, skip = true }],
      [for pattern in local.signed_webgrip_image_patterns : { image = pattern, publicKey = { certificate = local.cosign_webgrip_public_key } }],
    )
  })
}
