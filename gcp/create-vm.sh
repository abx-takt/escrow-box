#!/bin/bash
# Creates a Shielded VM on GCE from a box image: a vTPM the operator cannot read, Secure Boot off
# (the UKI is unsigned; PCR 4 covers the image), integrity monitoring on (its baseline is a free
# read of the boot PCRs). A blank persistent disk is attached for the box's /data.
#
#   escrow-box/gcp/create-vm.sh --image NAME --vm NAME [--zone Z] [--project P] [--data-gb 10]
#
# Driver constraint (checked against the image's kernel): the initramfs carries no modules, so the
# machine must present the disk over virtio-scsi and the network over virtio-net. NVMe and gVNIC
# are kernel modules and would leave the box with no disk or no network. This script pins both:
#   - the data disk interface to SCSI;
#   - the NIC type to VIRTIO_NET;
#   - a machine family that offers them (default n2-standard-2).
# Do not switch to a machine type or image that forces NVMe or gVNIC without first building those
# drivers into the kernel or the initramfs.
set -euo pipefail
export PATH=$PATH:$HOME/google-cloud-sdk/bin
zone=europe-west4-a; project=""; machine=n2-standard-2; data_gb=10
while [ $# -gt 0 ]; do
  case "$1" in
    --image) image=$2;; --vm) vm=$2;; --zone) zone=$2;; --project) project=$2;;
    --machine) machine=$2;; --data-gb) data_gb=$2;;
    *) echo "unknown argument $1" >&2; exit 2;;
  esac
  shift 2
done
for v in image vm; do [ -n "${!v:-}" ] || { echo "missing --$v" >&2; exit 2; }; done
proj=(); [ -n "$project" ] && proj=(--project "$project")

# Boot disk from the image, over SCSI; a separate blank SCSI disk for /data (the box formats and
# labels it on first boot). The NIC is virtio-net. Shielded: vTPM on, Secure Boot off.
gcloud "${proj[@]}" compute instances create "$vm" \
  --zone "$zone" \
  --machine-type "$machine" \
  --image "$image" \
  --boot-disk-device-name "$vm-boot" \
  --create-disk "name=$vm-data,size=${data_gb}GB,type=pd-balanced,device-name=$vm-data,interface=SCSI,auto-delete=yes" \
  --network-interface "nic-type=VIRTIO_NET" \
  --no-shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring
cat <<EOF

VM $vm created in $zone.
Reach the box over SSH to its forced commands (the box runs its own sshd on port 22; use the VM's
external IP or an IAP tunnel). Then, as in the local runner:
  escrow-box provider provision  (provider key, escrow key on stdin)  -> H
  escrow-box client   check|verify|status|unlock|sealed|pcrs  (client key)

Read the current boot's measurements:
  gcloud ${project:+--project $project }compute instances get-shielded-identity $vm --zone $zone
  (and the box's own 'pcrs' command) to compare PCRs 4,9,11,12,13 across stop/start and recreate.
EOF
