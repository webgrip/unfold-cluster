# Metal node: ordering, installing and proving `unfold-metal-1`

`unfold-metal-1` is a Hetzner Robot AX41 in FSN1. It runs agent Runs of the `isolated` class under
Kata Containers 4.3.1 and CI under gVisor on the KVM platform
([ADR 0001](../adr/0001-kata-4-on-the-metal-node.md), [ADR 0002](../adr/0002-ci-under-gvisor-on-the-metal-node.md)).
Git declares it in `metal_servers` (`infra/variables.tf`); the `infra` workflow orders, wires and
installs it. The one hand step is the Robot webservice user, which Robot creates only in its UI.

## Once: the Robot webservice user

1. In Robot: *Settings* → *Web service and app settings* → create the webservice user. Robot allows
   one per account and shows its password once.
2. From a homelab-cluster checkout:

   ```sh
   just secret-set hetzner/unfold-robot ROBOT_USER
   just secret-set hetzner/unfold-robot ROBOT_PASSWORD
   ```

The OpenBao policy `ci-unfold-cluster` (homelab-cluster) lets the `infra` workflow read it, and
lets it write `secret/unfold-cluster/metal/*`, where the apply records each server's order,
server number and MAC address.

## What an apply does

A plan-only run reads Robot without changing anything: the product, its monthly price in FSN1 with
the primary IPv4 address, and its setup fee. A price above `max_monthly_eur` (65 EUR net) or a setup
fee above `max_setup_eur` (0) fails the plan. The plan shows `terraform_data.metal_order` with that
price; that plan's digest is what an apply approves.

The apply then runs, in order:

| Step | Resource | What happens |
| --- | --- | --- |
| Order | `terraform_data.metal_order` | `scripts/robot.sh order`: no order when Robot has a server named `unfold-metal-1`, when OpenBao records an order for it, or when an order for the product is in process (that one is adopted). Never past the number of declared servers. It re-checks the price, places a test order, then the real one with the primary IPv4 addon, records the transaction id in OpenBao at once, waits up to two hours for the server, and names it `unfold-metal-1` in Robot. |
| vSwitch | `terraform_data.robot_vswitch`, `hcloud_network_subnet.vswitch`, `terraform_data.metal_vswitch_membership` | Creates the vSwitch `unfold-main` on VLAN 4000 once, couples it to the Cloud Network as the subnet `10.64.1.0/24`, and adds the server. |
| Firewall | `terraform_data.metal_robot_firewall` | Sets the Robot firewall (below). It filters the public port and the vSwitch alike. |
| Install | `terraform_data.metal_install` | `scripts/robot.sh install` (below). Only when `talos/metal-image.yaml` is pinned. |
| Config | `talos_machine_configuration_apply.metal` | Hostname, pool labels and taint, kubelet provider id `hrobot://<number>` and reservations, gVisor on KVM, the public link by MAC with DHCP, VLAN 4000 at MTU 1400 with `10.64.1.31/24` and a route to `10.64.0.0/16` through `10.64.1.1`, the tailnet join, the host firewall. |

The metal node runs without the hcloud cloud provider: it is not a cloud server, and the cloud
controller has no Robot credentials, which would let it order and reset servers. The kubelet sets
the provider id `hrobot://<number>` itself, so the controller cannot take the node for a deleted
cloud server; it logs that it has no Robot client for that node, and that line is expected. The
node sets `instance.hetzner.cloud/provided-by=robot` itself, which keeps the hcloud CSI node plugin
off it.

An order Hetzner has not delivered within two hours fails the apply; the next apply waits for the
same order again and never orders twice.

### The Robot firewall

The Robot firewall is stateless and takes ten input rules. Inbound IPv6 is dropped except ICMPv6.

| Rule | Admits |
| --- | --- |
| `private-network` | everything from `10.64.0.0/16`, the Cloud Network over the vSwitch |
| `icmp` | ICMP |
| `dhcp` | UDP to 68, Hetzner's DHCP answers |
| `tcp-replies` | TCP with ACK to 32768-65535, replies to the node's own connections |
| `udp-replies` | UDP to 32768-65535, replies to DNS, NTP and the tailnet |
| `tailscale` | UDP 41641, direct tailnet paths |
| `admin-tcp-N` | TCP from each IPv4 range in `ADMIN_CIDRS`: the rescue system's SSH during an install, apid after it. At most four ranges. |

No port serves the internet. The Talos host firewall behind it admits only apid from the admin
ranges, the tailnet and the private network, and the cluster's ports from the private network
([host firewall](host-firewall.md)). The node is a worker, so 6443 is not served there.

### The install and its guard

1. If the server answers as Talos in maintenance mode and OpenBao records its MAC address, the
   install has run: nothing happens. If it answers as a configured Talos, the install refuses.
2. A fresh SSH key is registered in Robot, the rescue system armed with it, the server reset. The
   rescue host key must be one Robot announced.
3. In the rescue system the install refuses if any disk holds Talos partitions, then records the
   MAC address of the public link, downloads the disk image, checks its sha256, wipes both NVMe
   disks and writes the image to `nvme0n1`. The SSH key is removed from Robot.
4. The server reboots into Talos maintenance mode and the machine config follows.

**Reinstalling** wipes the node. Raise `install_generation` of that server in `infra/variables.tf`
in a reviewed pull request; nothing else lifts the guard.

## Fallbacks

| Symptom | Change |
| --- | --- |
| gVisor pods fail on KVM | `gvisor_platform = "systrap"` for that server |
| A CI build fails with `operation not permitted` under gVisor | `gvisor_oci_seccomp = false` |
| Kata misbehaves | remove `runtime.webgrip.io/kata` from `local.metal_labels`; new Kata pods stay away |
| An order Hetzner cancelled | read the order in Robot, then remove its `transaction_id` from `secret/unfold-cluster/metal/unfold-metal-1` before the next apply |

## Cancelling a server

Cancellation stays a person's act: Robot → *Servers* → the server → *Cancellation*. Robot's
cancellation API exists and is not automated on purpose. Remove the server from `metal_servers` in
the same week, or the next apply orders it again.

## Proof after the first install

Run the `infra` workflow in `diagnose` mode. It must show:

1. `kubectl get nodes`: `unfold-metal-1` Ready, with runtime handlers `kata` and `runsc`.
2. `talosctl get extensions`: `kata-containers` `4.3.1-webgrip.1`, `gvisor`, `tailscale`,
   `amd-ucode`; `/etc/unfold-sandbox/runsc.toml` with `platform = "kvm"`; `/dev/kvm` present;
   `vswitch0` with MTU 1400.
3. The `kata-probe` log: a guest kernel that differs from the node's `kernelVersion`, `seccomp=2`.
4. The `gvisor-probe` log: kernel `4.4.0` on the metal node.
5. The annotation guard refusing the dry-run pod with a Kata annotation (`sandbox-annotations`).
6. The Robot firewall active with the rules above.

Then run the `ci-smoke` workflow: it builds and pushes an image under gVisor and rebuilds it from
the cache alone.
