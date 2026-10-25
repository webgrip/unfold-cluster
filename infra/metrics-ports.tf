locals {
  etcd_metrics_port = 2383

  node_metrics_ports = [
    9100,
    9598,
    "9962-9963",
    9965,
  ]
}
