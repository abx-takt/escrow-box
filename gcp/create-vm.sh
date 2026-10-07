#!/bin/bash
# Creates a Shielded VM on GCE from a box image: a vTPM the operator cannot read, Secure Boot off
# (the UKI is unsigned; PCR 4 covers the image), integrity monitoring on (its baseline is a free
# read of the boot PCRs). A blank persistent disk is attached for the box's /data.
#
#   escrow-box/gcp/create-vm.sh --image NAME --vm NAME [--zone Z] [--project P] [--data-gb 10] [--confidential]
#
# Default (Shielded VM): the NIC is virtio-net and the data disk is SCSI, which the stock kernel has
# built in; no extra modules needed.
#
# --confidential makes it an SEV Confidential VM (encrypted memory; the "trust the CPU vendor" tier).
# GCP then forces gVNIC for the NIC and attaches persistent disks as NVMe, so the image must carry
# and early-load the gve and nvme drivers (build.sh --modules) and be created with SEV_CAPABLE,GVNIC
# guest-os-features (make-gcp-image.sh --features SEV_CAPABLE,GVNIC); this switches the machine to
# n2d and the maintenance policy to TERMINATE. The box boots regardless because its root is the
# in-RAM initramfs, but it needs nvme to find the /data disk and gve to get a network.
set -euo pipefail
export PATH=$PATH:$HOME/google-cloud-sdk/bin
zone=europe-west4-a; project=""; machine=n2-standard-2; data_gb=10; conf=""
while [ $# -gt 0 ]; do
  case "$1" in
    --image) image=$2; shift 2;;
    --vm) vm=$2; shift 2;;
    --zone) zone=$2; shift 2;;
    --project) project=$2; shift 2;;
    --machine) machine=$2; shift 2;;
    --data-gb) data_gb=$2; shift 2;;
    --confidential) conf=1; shift 1;;
    *) echo "unknown argument $1" >&2; exit 2;;
  esac
done
for v in image vm; do [ -n "${!v:-}" ] || { echo "missing --$v" >&2; exit 2; }; done
proj=(); [ -n "$project" ] && proj=(--project "$project")
NIC=VIRTIO_NET; CONF_FLAGS=""
if [ -n "$conf" ]; then NIC=GVNIC; CONF_FLAGS="--confidential-compute-type=SEV --maintenance-policy=TERMINATE"; case "$machine" in n2-standard-*) machine="n2d-standard-${machine##*-}";; esac; fi

# Boot disk from the image, over SCSI; a separate blank SCSI disk for /data (the box formats and
# labels it on first boot). The NIC is virtio-net. Shielded: vTPM on, Secure Boot off.
gcloud "${proj[@]}" compute instances create "$vm" \
  --zone "$zone" \
  --machine-type "$machine" \
  --image "$image" \
  --boot-disk-device-name "$vm-boot" \
  --create-disk "name=$vm-data,size=${data_gb}GB,type=pd-balanced,device-name=$vm-data,interface=SCSI,auto-delete=yes" \
  --network-interface "nic-type=${NIC}" \
  ${CONF_FLAGS} \
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
