#!/usr/bin/env bash
set -euo pipefail

IMG_DIR="${IMG_DIR:-/var/lib/libvirt/images}"
BASE_IMG="${IMG_DIR}/jammy-server-cloudimg-amd64.img"
NETWORK="${NETWORK:-default}"
PUB_KEY="$(cat ~/.ssh/id_ed25519.pub)"

if [[ ! -f "${BASE_IMG}" ]]; then
  echo "Base image not found: ${BASE_IMG}"
  exit 1
fi

NODES=(
  "cks-cp 52:54:00:12:34:10 192.168.122.10 4096 2 40G"
  "cks-worker01 52:54:00:12:34:11 192.168.122.11 12288 4 40G"
  "cks-worker02 52:54:00:12:34:12 192.168.122.12 12288 4 40G"
)

for entry in "${NODES[@]}"; do
  read -r NODE MAC IP RAM VCPU DISK_SIZE <<< "${entry}"

  echo "[provision] Configuring ${NODE} (${IP})"

  sudo virsh net-update "${NETWORK}" add ip-dhcp-host \
    "<host mac='${MAC}' name='${NODE}' ip='${IP}'/>" --live --config >/dev/null 2>&1 || true

  sudo qemu-img create -f qcow2 -F qcow2 -b "${BASE_IMG}" "${IMG_DIR}/${NODE}.qcow2" "${DISK_SIZE}"

  sudo virt-customize -a "${IMG_DIR}/${NODE}.qcow2" \
    --root-password password:ubuntu \
    --hostname "${NODE}" \
    --run-command 'mkdir -p /etc/cloud/cloud.cfg.d && echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg' \
    --run-command 'mkdir -p /etc/netplan' \
    --run-command 'printf "network:\n  version: 2\n  renderer: networkd\n  ethernets:\n    enp1s0:\n      dhcp4: true\n" > /etc/netplan/01-netcfg.yaml' \
    --run-command 'chmod 600 /etc/netplan/01-netcfg.yaml' \
    --run-command 'ssh-keygen -A' \
    --run-command 'rm -f /etc/ssh/sshd_config.d/*' \
    --run-command 'printf "PermitRootLogin yes\nPasswordAuthentication yes\n" > /etc/ssh/sshd_config.d/00-lab-auth.conf' \
    --run-command 'systemctl enable ssh' \
    --run-command "mkdir -p /root/.ssh && chmod 700 /root/.ssh && echo '${PUB_KEY}' >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys"

  sudo virt-install \
    --name "${NODE}" \
    --memory "${RAM}" \
    --vcpus "${VCPU}" \
    --disk path="${IMG_DIR}/${NODE}.qcow2",format=qcow2 \
    --os-variant ubuntu22.04 \
    --network network="${NETWORK}",model=virtio,mac="${MAC}" \
    --graphics none \
    --console pty,target_type=serial \
    --import --noautoconsole
done

echo "[provision] Completed successfully."
