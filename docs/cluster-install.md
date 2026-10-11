# Cluster Install Guide: CKS Lab on KVM (Falco, Prometheus)

On-prem sandbox on the **Hobgoblin** KVM host for CKS practice and runtime-security drills.
This document explains the architecture and order of operations. Commands live in
[`scripts/`](../scripts) and manifests in [`manifests/`](../manifests).

## Topology

| Node | Role | IP | RAM | vCPU |
|------|------|----|-----|------|
| `cks-cp` | control plane | 192.168.122.10 | 4 GiB | 2 |
| `cks-worker01` | worker | 192.168.122.11 | 12 GiB | 4 |
| `cks-worker02` | worker | 192.168.122.12 | 12 GiB | 4 |

- Network: libvirt `default` bridge (192.168.122.0/24) with static DHCP reservations (MAC to IP).
- Pod CIDR: `10.244.0.0/16` (avoids clashing with common home/host `192.168.x.x` ranges).
- CNI: Calico v3.28.0 · Runtime: containerd (`SystemdCgroup = true`) · Kubernetes v1.30.

## Install order

| Step | Where | Command |
|------|-------|---------|
| 0. Reset (optional) | KVM host | `scripts/00-cleanup-vms.sh` |
| 1. Provision VMs | KVM host | `scripts/01-provision-vms.sh` |
| 2. OS prep | every node | `scripts/02-os-prep.sh` |
| 3. Control plane + Calico | `cks-cp` | `scripts/03-bootstrap-controlplane.sh` |
| 4. Join workers | each worker | run the `kubeadm join ...` line printed by step 3 |

## Phases

1. **Phase 1: cluster bootstrap**: KVM VMs, kubeadm v1.30, Calico; all 3 nodes `Ready`.
2. **Phase 2: CKS security drills**: PSA, NetworkPolicy, AppArmor/seccomp and Falco on a plain workload.
3. **Phase 3: AI platform (deferred)**: KServe, after the CKS exam. Its manifests are parked in `manifests/kserve/`.

## Workloads and policy (phase 2)

| Area | File |
|------|------|
| `sec-workload` namespace (PSA restricted) | `manifests/workload/namespace.yaml` |
| Hardened Deployment (`hardened-app`) | `manifests/workload/hardened-app.yaml` |
| Zero-trust NetworkPolicy (default-deny + DNS over TCP and UDP) | `manifests/workload/isolation-policy.yaml` |
| Prometheus anomaly alerts (Go app metrics) | `manifests/monitoring/anomaly-rules.yaml` |
| Falco rule for shells in `sec-workload` | `manifests/falco/falco_rules.local.yaml` |
| Platform app, observability, security stack | `k8s/` (deployed via `Makefile`) |
| KServe manifests and alerts (phase 3, deferred) | `manifests/kserve/` |

Drills and expected results: [incident-runbook.md](incident-runbook.md).

## Design notes

- **Static IPs** come from `virsh net-update ... ip-dhcp-host`, so `kubeadm init --apiserver-advertise-address=192.168.122.10` always matches the node NIC.
- **DNS egress** allows both UDP and TCP 53 (TCP fallback for responses over 512 bytes).
- **Idempotent scripts**: re-running skips existing VMs and an initialised control plane; `00-cleanup-vms.sh` gives a clean slate in minutes.
- **Lab-only credentials**: the VM root password is `ubuntu`; override with `ROOT_PASSWORD`.

## CKS exam prep extras

1. **Kubelet hardening**: in `/var/lib/kubelet/config.yaml` set `authentication.anonymous.enabled: false`, enable webhook authentication and set `readOnlyPort: 0`.
2. **kube-bench**: once all 3 nodes have joined, run `kube-bench run --targets master,node` for a CIS baseline.
3. **AppArmor**: load a profile on workers (`apparmor_parser -q /path/to/profile`) and reference it via the `appArmorProfile` field in the Pod spec, in addition to `seccompProfile`.