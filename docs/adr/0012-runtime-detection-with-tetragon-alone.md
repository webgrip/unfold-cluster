---
status: accepted
date: 2026-10-25
---

# ADR 0012: Tetragon alone detects at runtime, on every node, in monitor mode first

## Context and problem statement

RFC 0001 section 9 and delivery step 12 call for runtime detection and, later, enforcement on the
nodes. The owner asked for "Tetragon … Falco". Both watch the kernel with eBPF. This record decides
which of them runs, how much each node pays for it, what it cannot see inside the gVisor and Kata
sandboxes, and how its policies move from detecting to enforcing.

## Facts the decision rests on

Checked on 2026-10-25.

**The nodes.** Three CX23 control planes (2 vCPU, 3.7 GiB allocatable, 1.4 to 1.6 GiB available
in the kubelet's summary) and the CX33 hub `unfold-app-1` (4 vCPU, 7.1 GiB allocatable, 6.4 GiB
available). The CX43 CI node and the AX41 metal node are planned. Talos 1.14.4, kernel
`6.18.57-talos`, SELinux permissive ([selinux.md](../selinux.md)).

**The kernel.** The Talos 1.14 kernel configuration (`siderolabs/pkgs` branch `release-1.14`,
`kernel/build/config-amd64`) has `CONFIG_DEBUG_INFO_BTF=y`, `CONFIG_KPROBES=y`,
`CONFIG_FTRACE_SYSCALLS=y`, `CONFIG_BPF_EVENTS=y`, `CONFIG_BPF_LSM=y` with `bpf` in `CONFIG_LSM`,
and `CONFIG_FUNCTION_ERROR_INJECTION=y`. `CONFIG_BPF_KPROBE_OVERRIDE` is not set. Lockdown is
`CONFIG_LOCK_DOWN_KERNEL_FORCE_NONE` and only rises under EFI Secure Boot, which no node uses
([ADR 0003](0003-disk-encryption-key-source.md)). No kernel module is needed by either tool.

So both tools load on these nodes. Tetragon's `Override` action on a kprobe needs
`BPF_KPROBE_OVERRIDE` and is not available; `Sigkill` is, and so is `Override` on BPF LSM hooks
(`lsmhooks`), once a node shows `bpf` in `/sys/kernel/security/lsm`.

**Falco and gVisor.** Falco's gVisor engine, which read gVisor's own trace points through
`runsc --pod-init-config`, was removed in Falco 0.44.0 ([falco#3797](https://github.com/falcosecurity/falco/pull/3797),
merged 2026-02-05); chart 9.0.0 dropped `driver.kind: gvisor`. The current releases are Falco
0.45.1 and chart 9.2.1. Only Falco 0.43.x and older can still read a gVisor sandbox, and they get
no fixes. The integration gVisor documents (gvisor.dev, "Configuring Falco with gVisor") therefore
no longer exists in a supported Falco.

**What a host sensor sees.** A gVisor pod's processes run inside the Sentry, a user-space kernel;
the host kernel sees only `runsc` and its gofer, not the guest's `execve`, `open` or `connect`. A
Kata pod's processes run under a guest kernel in a micro-VM; the host sees the VMM and its helpers.
This holds for Tetragon and Falco alike. The sandbox's network still leaves through the pod's veth,
where Cilium applies policy and Hubble records each flow with the pod's identity.

**Cost.** Tetragon filters in the kernel and copies only matching events to user space. The
homelab runs the same chart and image ([homelab ADR-0072](https://forgejo.webgrip.dev/webgrip/homelab-cluster/src/branch/main/docs/techdocs/docs/adr/adr-0072-tetragon-watches-agent-pods.md));
`kubectl top` on 2026-10-25 showed 178 and 195 MiB and 6 to 31 millicores per agent with two
policies on busy workers. Falco's modern eBPF probe copies every system call of the node to a ring
buffer (8 MiB per two CPUs at the chart's default) and evaluates its rules in user space; the
chart asks for 100m and 512 MiB, with limits of 1 CPU and 1 GiB.

**Enforcement.** Tetragon can kill a process (`Sigkill`) or fail a call (`Override` on LSM
hooks) in the kernel, inside the call, and every policy has a `policy-mode` (`monitor` or
`enforce`) that switches the enforcing actions off without changing the policy. Falco only
detects; responding needs Falco Talon, another component acting after the fact through the API.

## Options

1. Tetragon alone.
2. Falco alone.
3. Both, Falco for its rule catalogue and Tetragon for enforcement.
4. Falco 0.43.x beside Tetragon, only for gVisor's trace points.

## Decision

Option 1, **Tetragon 1.7.1 alone**, on every node, every policy in `monitor` mode first.

Running both would be justified only by coverage that one lacks. There is none: both sit at the
same vantage point and are blind in the same places, and every detection asked for (unexpected
exec, writes to sensitive host paths, network to unexpected destinations, privilege escalation,
Kubernetes credential access, crypto-miner patterns) is expressible as a Tetragon policy plus a
LogsQL rule. Falco's distinct asset, its maintained rule catalogue, does not outweigh a second
eBPF stack that copies every system call to user space on 2-vCPU control planes that also run
etcd. Option 4 would buy the one thing a host sensor cannot see, at the price of an unmaintained
security component; we document the gap instead.

What runs ([runtime-security](../runbooks/runtime-security.md) has the detail):

- **Agent.** Chart `tetragon` 1.7.1 from `https://helm.cilium.io`; the chart archive's SHA-256
  `79ec0f7d…c632` is pinned in `scripts/test-runtime-security.sh`, which fails until a person
  records the digest of a new version. Image `quay.io/cilium/tetragon:v1.7.1` by digest. In
  `kube-system`, beside Cilium, whose privilege class it shares. No operator (the chart installs
  the CRDs), no export sidecar, no metrics port yet. Every node, through
  `tolerations: [{operator: Exists}]`; no PriorityClass, so it never preempts a pod. 384 MiB
  request equal to limit (twice the homelab's measured use, and a pod with `memory.max` is one
  the Talos OOM controller skips), 50m CPU request, 1 CPU limit. Process credentials on, process
  cache 16384 entries. It talks to the API server through KubePrism on `localhost:7445`, like
  Cilium, so it does not depend on the Service network.
- **Policies.** Six cluster-wide `TracingPolicy` objects, each with `policy-mode: monitor` and
  only `Post` actions: sensitive host writes, Kubernetes and node credentials, privilege
  escalation, kernel modules, outbound connects outside the cluster and tailnet, and
  ptrace/mount/setns. Program starts need no policy; the base sensor records every exec.
- **Shipping.** Tetragon writes JSON lines to `/var/log/tetragon/tetragon.log` (10 MiB, two
  backups, at most 3000 events per minute per node). The existing Vector DaemonSet tails it,
  flattens each event (`source=tetragon`, `event`, `policy`, `binary`, `path`, `daddr`, …, the
  full event under `tetragon`) and sends it through the homelab gateway, which stamps
  `cluster=unfold`.
- **Alerts.** LogsQL rules in the homelab VMRule `unfold-runtime`, evaluated by a second
  evaluator, `vmalert-unfold-runtime`, because `vmalert-unfold` reads only VictoriaMetrics. DaemonSet
  health is PromQL in `unfold-cluster`. All detections start at `severity: warning`,
  `stage: observe`.
- **Canary.** A CronJob in `runtime-security-canary` does two things that must be recorded
  (reading its token with `cat`, dialling `192.0.2.10:3333`) and two that must not (reading
  `/etc/hostname`, dialling the cluster DNS Service) every 30 minutes. One alert fires when the
  first pair stops arriving, another when the second pair ever produces an event.

## Consequences

- Good: one eBPF agent, about 10% of a control plane's memory, reserved, never preempting.
- Good: the enforcement path exists in the same component and is one field per policy away.
- Good: events leave the node within seconds through a pipeline that already buffers 2 GiB on
  disk, and the canary proves the whole path every 30 minutes.
- Bad: **inside gVisor and Kata nothing is seen.** That is where agent Runs and CI execute. What
  remains: Cilium and Hubble on the pod's network, the API audit log for exec and attach, the
  sandboxes' own boundaries (gVisor's seccomp and `oci-seccomp`, Kata's VM), and the host tripwire
  `UnfoldSandboxedPodHostProcess` (any host process other than the sandbox runtime attributed to a
  sandboxed pod). Seeing inside gVisor needs a consumer for gVisor's trace-point "remote" sink,
  which Falco no longer provides; that is a separate proposal.
- Bad: without Tetragon's runtime hooks (NRI), a `podSelector` policy applies once Tetragon learns
  the container from the CRI and the API server, so the first instants of a container can pass
  unfiltered. Enabling NRI is a Talos change and a prerequisite of enforcement.
- Bad: rules are written by hand; there is no curated catalogue.
- Bad: the chart comes from an HTTP repository, which Flux cannot pin by digest; the test pin above
  closes that for review, not at pull time.
- Bad: Tetragon's own metrics (lost events, policy errors) are not scraped until a host firewall
  port for them lands in `infra/`.

## Confirmation

- `scripts/test-runtime-security.sh --mutation-test` (CI: `runtime-security-check`): chart digest,
  every policy through the CRD schema on a throwaway API server, `policy-mode` named on every
  policy, Vector's unit tests of the Tetragon transform, and each check broken on purpose.
- Homelab `scripts/test-vlogs-rules.sh --mutation-test` (homelab e2e): every rule fires on its
  case and stays quiet on its counter-case in a real VictoriaLogs and vmalert.
- Live, after the merge: `kubectl -n kube-system get ds tetragon` shows one ready pod per node,
  `kubectl get tracingpolicies` lists six, and the canary's events appear in VictoriaLogs
  (`cluster:=unfold source:=tetragon namespace:=runtime-security-canary`).
