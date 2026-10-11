#!/usr/bin/env bash
# 02-os-prep.sh - Remote OS & Containerd preparation on all K8s VMs
set -euo pipefail

NODES=("192.168.122.10" "192.168.122.11" "192.168.122.12")
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

for ip in "${NODES[@]}"; do
  echo "=================================================="
  echo "[os-prep] Configuring remote node: ${ip}"
  echo "=================================================="

  ssh ${SSH_OPTS} root@"${ip}" bash -s << 'REMOTESH'
    set -euo pipefail

    # 0. ขยาย Root Partition ให้เต็มความจุดิสก์ 40GB (POSIX compatible parsing)
    ROOT_PART=$(findmnt -n -o SOURCE /)
    ROOT_DISK="/dev/$(lsblk -no pkname "${ROOT_PART}")"
    PART_NUM=$(echo "${ROOT_PART}" | grep -o '[0-9]*$')

    growpart "${ROOT_DISK}" "${PART_NUM}" || true
    resize2fs "${ROOT_PART}"

    # A. ปิด Swap
    swapoff -a
    sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

    # B. Kernel Modules
    cat <<K8S_CONF > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
K8S_CONF
    modprobe overlay
    modprobe br_netfilter

    # C. Sysctl Parameters
    cat <<SYSCTL_CONF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
SYSCTL_CONF
    sysctl --system

    # D. Containerd พร้อม SystemdCgroup
    apt-get clean
    rm -rf /var/lib/apt/lists/*
    apt-get update && apt-get install -y containerd apt-transport-https ca-certificates curl gpg
    mkdir -p /etc/containerd
    containerd config default > /etc/containerd/config.toml
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
    systemctl restart containerd && systemctl enable containerd

    # CKS Drill: กำหนด crictl endpoint ชัดเจน
    cat <<CRICTL > /etc/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
CRICTL

    # E. ติดตั้ง Kubernetes v1.30
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' > /etc/apt/sources.list.d/kubernetes.list
    apt-get update
    apt-get install -y kubelet kubeadm kubectl
    apt-mark hold kubelet kubeadm kubectl
REMOTESH
done

echo "[os-prep] Remote preparation complete on all nodes."
