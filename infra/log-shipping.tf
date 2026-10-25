locals {
  log_collector_services = "tcp://127.0.0.1:6050/"
  log_collector_kernel   = "tcp://127.0.0.1:6051/"

  log_shipping_patches = [
    yamlencode({
      machine = {
        logging = {
          destinations = [
            {
              endpoint = local.log_collector_services
              format   = "json_lines"
            },
          ]
        }
      }
    }),
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KmsgLogConfig"
      name       = "log-collector"
      url        = local.log_collector_kernel
    }),
  ]
}
