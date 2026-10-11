#!/usr/bin/env bash
# 03-bootstrap-controlplane.sh - Remote K8s bootstrap via SSH
set -euo pipefail

CP_IP="192.168.122.10"
WORKER_IPS=("192.168.122.11" "192.168.122.12")
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

echo "=================================================="
echo "[bootstrap] Initializing Control Plane on ${CP_IP}"
echo "=================================================="

ssh ${SSH_OPTS} root@"${CP_IP}" bash -s << 'REMOTESH'
  set -euo pipefail

  kubeadm init \
    --pod-network-cidr=10.244.0.0/16 \
    --kubernetes-version=v1.30.0 \
    --apiserver-advertise-address=192.168.122.10 \
    --cri-socket=unix:///run/containerd/containerd.sock

  mkdir -p /root/.kube
  cp -i /etc/kubernetes/admin.conf /root/.kube/config

  # ติดตั้ง Calico Operator และ Custom Resource (CIDR 10.244.0.0/16)
  kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/tigera-operator.yaml
  curl -fsSL https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/custom-resources.yaml -o /tmp/custom-resources.yaml
  sed -i 's|cidr: 192.168.0.0/16|cidr: 10.244.0.0/16|g' /tmp/custom-resources.yaml
  kubectl create -f /tmp/custom-resources.yaml
  rm -f /tmp/custom-resources.yaml
REMOTESH

echo "--> Fetching join token and admin kubeconfig..."
JOIN_CMD=$(ssh ${SSH_OPTS} root@"${CP_IP}" "kubeadm token create --print-join-command")
JOIN_CMD="${JOIN_CMD} --cri-socket=unix:///run/containerd/containerd.sock"

mkdir -p ~/.kube
scp ${SSH_OPTS} root@"${CP_IP}":/etc/kubernetes/admin.conf ~/.kube/config

for worker in "${WORKER_IPS[@]}"; do
  echo "=================================================="
  echo "[bootstrap] Joining worker node: ${worker}"
  echo "=================================================="
  ssh ${SSH_OPTS} root@"${worker}" "${JOIN_CMD}"
done

echo "[bootstrap] Cluster Bootstrap Complete!"
