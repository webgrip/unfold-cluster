locals {
  cosign_webgrip_public_key = trimspace(file("${path.module}/keys/cosign-webgrip.pub"))

  unsigned_webgrip_images = []

  signed_webgrip_image_patterns = [
    "ghcr.io/webgrip/*",
    "ghcr.io/webgrip/*/*",
    "forgejo.webgrip.dev/webgrip/*",
    "forgejo.webgrip.dev/webgrip/*/*",
  ]

  unfold_hq_release_signer = {
    issuer       = "https://token.actions.githubusercontent.com"
    subjectRegex = "^https://github\\.com/unfold-hq/unfold/\\.github/workflows/on_release_published\\.yml@refs/tags/unfold-v0\\.[0-9]+\\.[0-9]+(-rc\\.[0-9]+)?$"
  }

  keyless_unfold_hq_image_patterns = [
    "ghcr.io/unfold-hq/*",
  ]

  image_verification_patch = yamlencode({
    apiVersion = "v1alpha1"
    kind       = "ImageVerificationConfig"
    rules = concat(
      [for image in local.unsigned_webgrip_images : { image = image, skip = true }],
      [for pattern in local.signed_webgrip_image_patterns : { image = pattern, publicKey = { certificate = local.cosign_webgrip_public_key } }],
      [for pattern in local.keyless_unfold_hq_image_patterns : { image = pattern, keyless = local.unfold_hq_release_signer }],
    )
  })
}
