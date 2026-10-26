# Runtime security

Tetragon watches every node's kernel and records process starts, credential reads, writes to node paths, privilege raises, kernel module loads, outbound connects and ptrace, mount and setns calls. The events go to the homelab VictoriaLogs, where LogsQL rules alert on the ones that should never happen. Nothing is blocked yet: every policy runs in `monitor` mode. Why Tetragon and not Falco, and what it cannot see, is [ADR 0012](../adr/0012-runtime-detection-with-tetragon-alone.md). This is RFC 0001 section 9 and delivery step 12.

## What runs where

| Piece | Where | What it does |
| --- | --- | --- |
| Tetragon agent | `kube-system`, DaemonSet `tetragon`, every node | eBPF in the host kernel. 384 MiB reserved (request equals limit), 50m CPU request, 1 CPU limit, no PriorityClass. Writes JSON lines to `/var/log/tetragon/tetragon.log` on the node, at most 3000 events per minute; past that it writes one `rate_limit_info` event and drops the rest. Arguments matching the redaction filters (`--password=…`, `*_TOKEN=…`, `Authorization:` headers, `sk-…` keys) are replaced by `*****` before they are written |
| TracingPolicies | cluster-scoped, `kubernetes/platform/runtime-security/policies/` | Six policies, below. Flux Kustomization `tetragon-policies`, after the `tetragon` HelmRelease is Ready |
| alloy-logs | `observability`, DaemonSet `alloy-logs` | `loki.source.file "tetragon"` tails the file, `loki.process "tetragon"` (`alloy/logs/pipelines.alloy`) drops `node_labels`, keeps the event as the record's fields and adds the flat fields the rules read (`event`, `namespace`, `workload`, `binary`, `policy`, `path`, `daddr`, `dport`, ...), and writes it to the cluster's `vlsingle-logs` |
| Canary | `runtime-security-canary`, CronJob every 30 minutes on the hub node | Proves the path end to end, below |
| vmalert-logs | `observability`, Deployment | Evaluates the LogsQL rules in `kubernetes/platform/observability/app/alerting/rules/runtime.yaml` against `vlsingle-logs` every minute and sends to the cluster's own Alertmanager ([observability](../observability.md#alerts)) |

## The policies

| Policy | Hook | Records | Scope |
| --- | --- | --- | --- |
| `runtime-sensitive-host-writes` | `security_file_permission` with `MAY_WRITE`, `security_path_truncate` | writes below `/etc/kubernetes`, `/var/lib/kubelet`, `/var/lib/etcd`, `/var/lib/containerd`, `/run/containerd`, `/system`, `/proc/sys`, `/sys/kernel`, `/host`, and to `/etc/passwd`, `/etc/shadow`, `/etc/sudoers`, `/etc/ld.so.preload`, `/root/.ssh` | pods |
| `runtime-kubernetes-credentials` | `security_file_open` | ServiceAccount and projected tokens, the kubelet's certificates and pod volumes, `/etc/kubernetes`, Talos `/system/secrets`, `/etc/shadow`, any `…/environ`, kube and Docker configs, `.git-credentials`, `.netrc`, SSH private keys | pods |
| `runtime-privilege-escalation` | `create_user_ns` without `CAP_SYS_ADMIN`, `security_capset`, `setuid`, `setreuid`, `setresuid`, `setgid` to 0 | each at most once a minute per process | pods |
| `runtime-kernel-modules` | `security_kernel_module_request`, `security_kernel_read_file` for modules | module name or file | host and pods |
| `runtime-outbound-connects` | `tcp_connect` | destinations outside `127.0.0.0/8`, `10.64.0.0/14` (nodes, pods, Services), `100.64.0.0/10` (tailnet), `169.254.0.0/16`, `::1` | pods |
| `runtime-namespace-escape` | `ptrace`, `mount`, `setns` system calls | the call and its arguments | pods |

Program starts come from Tetragon's base sensor and need no policy. "Pods" means `podSelector: {}`: Talos's own services (kubelet, etcd, containerd, machined) are left out in the kernel, because they write these paths all day.

## Event fields

Query in Grafana with the **VictoriaLogs** datasource. Every event has `cluster=unfold`, `source=tetragon`, `node`, and for a pod `namespace`, `pod`, `container`, `workload`. Then:

| Field | Meaning |
| --- | --- |
| `event` | `process_exec`, `process_kprobe` (a policy matched), `process_lsm`, `rate_limit_info` |
| `policy`, `function` | the TracingPolicy and the kernel function it hooked |
| `binary`, `arguments`, `uid`, `parent_binary` | the process and its parent |
| `in_init_tree` | `false` when the process was not started by the container's own entrypoint: `kubectl exec`, `nsenter`, `runc exec`, an exec probe |
| `privileges_changed` | set on an exec of a setuid or file-capability binary |
| `path`, `daddr`, `dport`, `string_args` | the hooked call's file, destination or string arguments |
| `isolation_class` | the pod's `ploeg.webgrip.dev/isolation-class` label |
| `tetragon.*` | the whole event as Tetragon wrote it, including exec IDs to follow a process tree |

Useful queries:

- `{cluster="unfold", source="tetragon"} | stats by (event, policy) count()`: what is arriving.
- `{cluster="unfold", source="tetragon"} namespace:=zot event:=process_exec | stats by (binary) count()`: what a workload runs.
- `{cluster="unfold", source="tetragon"} policy:="runtime-outbound-connects" | stats by (namespace, workload, binary, daddr, dport) count()`: who dials out, next to Hubble's verdicts (`{cluster="unfold", source="hubble-egress"}`).

## The alerts

All detection alerts start at `severity: warning` with `stage: observe` and `detection: high`. Each section says what to check. The alert's labels name the workload and binary; the full event is one query away.

### Exec outside init tree

`UnfoldPodExecOutsideInitTree`: a process entered a running container from outside its entrypoint's tree. Find the API call: VictoriaLogs audit, `cluster:=unfold objectRef.subresource:=exec`. A person's debugging session is fine to acknowledge. An exec probe added to a workload is a reason to exclude that workload and binary in the rule. Anything else: cordon the node and follow "A real detection" below.

### Attack tool

`UnfoldPodRanAttackTool`: `nmap`, `nc`, `socat`, `tcpdump`, `nsenter`, `unshare`, `chroot`, module tools, `setcap`, `crictl`, `ctr`, `runc` or `docker` started in a pod. Cilium's own init containers are excluded. Read the exec's parent and arguments.

### Host path write

`UnfoldPodWroteHostPath`: a pod wrote below a node, kubelet, runtime or Talos path, `/proc/sys` or `/sys/kernel`, or to an account file. Only a pod with a hostPath mount or a container escape can reach the node paths; the admission policy grants hostPath to nobody who writes there. Treat it as an escape until a platform component explains it.

### Credential read

`UnfoldCredentialReadByTool`: a shell, a file tool or an interpreter read a credential file, or any pod read the kubelet's or Talos's credentials. Programs reading their own token are recorded, not alerted. Rotate what was read if nobody owns the read.

### Privilege escalation

`UnfoldPrivilegeEscalation`: setuid or setgid to root, new capabilities, an unprivileged user namespace, or an exec of a setuid or file-capability binary. Compare with the pod's securityContext and the [admission grants](admission-policies.md#granted-exceptions).

### Kernel module

`UnfoldKernelModuleLoad`: the kernel loaded, or was asked to load, a module after boot. Cilium can ask for one the first time it uses a feature; compare with the node's boot time and the Cilium agent's log. A module requested from an application pod is a node compromise.

### Crypto miner

`UnfoldCryptoMinerPattern`: a known miner binary, stratum arguments, or a connect to a common pool port (3333, 4444, 5555, 7777, 14433, 14444, 45560, 45700). Stop the workload, keep its image digest.

### Tool connect

`UnfoldToolConnectedOutside`: a shell, `curl`, `wget`, `nc` or an interpreter dialled an address outside the cluster and the tailnet. Hubble says whether Cilium let it through.

### Sandbox host process

`UnfoldSandboxedPodHostProcess`: a host process other than `runsc`, the Kata shim, Cloud Hypervisor, QEMU or virtiofsd was attributed to a pod in `ci` or with an isolation class. Inside the sandbox Tetragon sees nothing, so on the host such a pod should have only its runtime's processes. Check the pod's `runtimeClassName`; if it is sandboxed, cordon the node.

### Host shell

`UnfoldHostShell`: a shell ran on a node outside any pod. Talos has no shell. Cordon and drain the node and keep it for evidence.

### Namespace escape

`UnfoldPodNamespaceEscapeCall`: a pod called `ptrace`, `mount` or `setns`. Cilium and the hcloud CSI node plugin do this by design and are excluded.

### Canary silent

`UnfoldRuntimeDetectionCanarySilent`: the canary's two must-fire actions have not both arrived in two hours, after having arrived in the last seven days. Every detection may be blind. In order:

1. `kubectl -n runtime-security-canary get jobs` and the last Job's log: did it run, did it print its four lines?
2. `kubectl -n kube-system get ds tetragon -o wide`: a ready pod on the node the Job ran on? `kubectl -n kube-system logs ds/tetragon | grep -i -E "error|fail"`.
3. `kubectl get tracingpolicies`: all six present? A policy that failed to load is in the agent's log.
4. `{cluster="unfold", source="tetragon"} | stats by (node) count()` in VictoriaLogs: does any node send? If no node sends, alloy-logs or vlsingle-logs is the problem ([observability](../observability.md)); `UnfoldLogShipperDropping` and `UnfoldLogsNotArriving` or `UnfoldMetricsAbsent` fire too.

### Canary overreach

`UnfoldRuntimeDetectionCanaryOverreach`: the canary's must-not-fire actions (reading `/etc/hostname`, dialling the DNS Service `10.66.0.10:53`) produced a policy event. A policy's filter matches more than it should; diff `kubernetes/platform/runtime-security/policies/` against the last good commit.

### Events dropped

`UnfoldTetragonEventsDropped`: a node hit the export rate limit. Find the noisiest binary with `{cluster="unfold", source="tetragon", node="<node>"} | stats by (binary, policy) count()` and narrow its policy, or exclude a looping exec.

### A real detection

1. Do not delete the pod: its processes and files are the evidence. Isolate it with a CiliumNetworkPolicy that denies all its egress (RFC 0001's quarantine label, once it exists), and cordon its node.
2. Save the evidence: the VictoriaLogs query of the pod over the last day, the audit log entries for it, the Hubble flows.
3. If the node itself is suspect (host path write, host shell, module load, sandbox host process), drain it and rebuild it through the `infra` workflow instead of repairing it.

## What it cannot see

| Gap | Why | What covers it now |
| --- | --- | --- |
| Inside gVisor pods (CI, `hardened` Runs) | The Sentry is a user-space kernel; the guest's system calls never reach the host kernel. gVisor's trace points could export them, but Falco removed its gVisor engine in 0.44.0 and nothing else supported consumes them | Hubble records the pod's flows with its identity and Cilium enforces egress; the API audit log records exec and attach; `oci-seccomp` applies the pod's seccomp profile inside the sandbox; `UnfoldSandboxedPodHostProcess` catches a process escaping to the host |
| Inside Kata pods (`isolated` Runs) | Their processes run under a guest kernel in a micro-VM | The same, with the VM as the boundary |
| The first instants of a container | Without Tetragon's runtime hooks, a `podSelector` policy applies once Tetragon learns the container from the CRI and the API server | The canary sleeps 20 seconds before acting, so it tests the steady state; enabling NRI hooks is step 1 of the enforcement plan |
| Tetragon's own health metrics | The agent's metrics port is off until a host firewall rule for it lands in `infra/` | The DaemonSet health alerts and the canary |
| A node the agent is Pending on | No PriorityClass, by design | `UnfoldTetragonNotOnEveryNode` after 15 minutes |

A gVisor trace consumer of our own (runsc `--pod-init-config` with a `remote` sink into a small receiver that writes the same JSON lines) is the way to close the first gap. It is new software to write and keep, so it is a proposal, not part of this change.

## From monitor to enforce

The admission policies went Audit, Warn, then Deny, one policy per pull request, each after the evidence showed no workload that should keep running would be refused ([admission policies](admission-policies.md#rollout-audit-warn-then-deny)). Runtime policies follow the same path. Tetragon's default mode is `enforce`, so `scripts/test-runtime-security.sh` refuses any policy that does not name its mode.

**Before the first enforcing policy:**

1. Read `/sys/kernel/security/lsm` on every node through the `infra` workflow's `diagnose` run and confirm it lists `bpf`; `Override` uses BPF LSM hooks because the Talos kernel has no `BPF_KPROBE_OVERRIDE`.
2. Turn on containerd's NRI in the Talos config (`infra/`) and Tetragon's runtime hooks (`rthooks.enabled`, interface `nri-hook`), so a policy applies before a container's first instruction.
3. Scrape Tetragon's metrics, so `tetragon_policy_stats_total` shows what each policy would have done.

**Per policy, in its own pull request:**

1. Seven days in observe with every alert of that policy explained, and the exclusions found added to the policy's selectors (in the kernel), not only to the alert rule.
2. Add the enforcing action to exactly the selector that alerted (`Sigkill`, or `Override` with `-1` on an `lsmhooks` hook) and set `policy-mode: enforce`.
3. Extend the canary with the enforced action and the expectation that its process is killed or its call fails, and prove it on the cluster before the merge reaches the policy: the canary Job's log must show the kill, and the event must carry `action: KPROBE_ACTION_SIGKILL` or the override.
4. Raise the matching alert to `severity: critical` and drop `stage: observe`.

**Order**, from least to most likely to hurt a legitimate workload:

| Step | Policy | Enforcement |
| --- | --- | --- |
| 1 | `runtime-kernel-modules`, pods only | `Sigkill`: no pod has a reason to load a module |
| 2 | `runtime-namespace-escape`, outside Cilium and the CSI node plugin | `Sigkill` on `ptrace`, `mount`, `setns` |
| 3 | `runtime-sensitive-host-writes` | `Sigkill`, then `Override` on the `file_permission` LSM hook so the write never happens |
| 4 | `runtime-kubernetes-credentials`, for shells, file tools and interpreters (`matchBinaries`) | `Override` on the `file_open` LSM hook |
| 5 | Execs into Run pods outside their init tree (`TracingPolicyNamespaced` in the Run namespaces, RFC 0001 agent oversight) | `Sigkill` |

`runtime-outbound-connects` and `runtime-privilege-escalation` stay detect-only: Cilium is the egress enforcement point, and the admission policies already refuse privilege escalation; Tetragon's records are the evidence that they held.

## Testing

| Test | Runs | Proves |
| --- | --- | --- |
| `scripts/test-runtime-security.sh --mutation-test` | `runtime-security-check` on every PR and push touching these files | the chart digest; every policy through the CRD schema on a throwaway API server at the cluster's version; `policy-mode` on every policy; and that each check fails when what it checks is broken |
| `scripts/test-observability-logs.sh --mutation-test` | `observability-check` | the Tetragon records the real Alloy pipeline writes to a real VictoriaLogs, field by field, and every runtime rule firing on its fixture with its labels; each rule and pipeline mutation must break a check |
| homelab `scripts/test-vlogs-rules.sh --mutation-test` | homelab `e2e` | each alert fires on its case and stays quiet on its counter-case, in a pinned VictoriaLogs with a real vmalert; each rule neutralised or edited must change the result |
| The canary CronJob | the cluster, every 30 minutes, declared in git | the whole path from kernel to alert, both ways |

Rendered manifests were also sent as server-side dry runs to the live API server before merging: the Tetragon chart, the Flux objects, and the canary's Namespace, ServiceAccount, ConfigMap, CronJob and Pod pass the Deny admission policies without a warning.

## Rollback

Revert the pull request. Flux prunes the `tetragon`, `tetragon-policies` and `runtime-security-canary` Kustomizations; Helm removes the DaemonSet and its CRDs, and the BPF programs detach when the agent exits. alloy-logs keeps tailing a file that no longer grows.
