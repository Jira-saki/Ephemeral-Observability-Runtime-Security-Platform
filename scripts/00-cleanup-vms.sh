#!/usr/bin/env bash
# 00-cleanup-vms.sh - Destroy lab VMs, their disks and DHCP reservations.
# Run on the KVM host. Safe to re-run (idempotent).
set -euo pipefail

IMG_DIR="${IMG_DIR:-/var/lib/libvirt/images}"
NETWORK="${NETWORK:-default}"

# name mac ip
NODES=(
  "cks-cp 52:54:00:12:34:10 192.168.122.10"
  "cks-worker01 52:54:00:12:34:11 192.168.122.11"
  "cks-worker02 52:54:00:12:34:12 192.168.122.12"
)

for entry in "${NODES[@]}"; do
  read -r NODE MAC IP <<< "${entry}"

  if sudo virsh dominfo "${NODE}" >/dev/null 2>&1; then
    echo "[cleanup] removing domain ${NODE}"
    sudo virsh destroy "${NODE}" >/dev/null 2>&1 || true
    sudo virsh undefine "${NODE}" --nvram >/dev/null 2>&1 || sudo virsh undefine "${NODE}"
  fi

  if [[ -f "${IMG_DIR}/${NODE}.qcow2" ]]; then
    echo "[cleanup] removing disk ${NODE}.qcow2"
    sudo rm -f "${IMG_DIR}/${NODE}.qcow2"
  fi

  sudo virsh net-update "${NETWORK}" delete ip-dhcp-host \
    "<host mac='${MAC}' name='${NODE}' ip='${IP}'/>" --live --config >/dev/null 2>&1 || true
done

echo "[cleanup] done"
