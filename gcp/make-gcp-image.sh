#!/bin/bash
# Turns one built box.efi into a Google Compute Engine image and uploads it.
#
#   escrow-box/gcp/make-gcp-image.sh --box DIR/box.efi --bucket gs://BUCKET --image NAME [--project P]
#
# DIR/box.efi is the output of escrow-box/build.sh. This makes a GPT disk whose one EFI system
# partition holds the UKI as the removable-media loader (EFI/BOOT/BOOTX64.EFI), the same layout the
# local runner boots, packs it as the GCE-required disk.raw tarball, uploads it and creates a GCE
# image marked UEFI_COMPATIBLE. The image carries no vTPM state and no order key; it is the same
# bytes for every machine made from it.
#
# Needs gcloud authenticated and a project with the Compute and Storage APIs on (see gcp/README.md).
set -euo pipefail
export PATH=$PATH:/usr/sbin:/sbin:$HOME/google-cloud-sdk/bin
project=""
while [ $# -gt 0 ]; do
  case "$1" in
    --box) box=$2;; --bucket) bucket=$2;; --image) image=$2;; --project) project=$2;;
    *) echo "unknown argument $1" >&2; exit 2;;
  esac
  shift 2
done
for v in box bucket image; do [ -n "${!v:-}" ] || { echo "missing --$v" >&2; exit 2; }; done
[ -f "$box" ] || { echo "no such box.efi: $box" >&2; exit 1; }
proj=(); [ -n "$project" ] && proj=(--project "$project")

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# A whole-GB raw disk (GCE rounds the image up to a GB anyway); the UKI plus slack fits in the ESP.
gb=$(( ($(stat -c%s "$box") / 1073741824) + 1 ))
raw=$work/disk.raw
truncate -s "${gb}G" "$raw"
sgdisk -o -U 6f8e0f6c-0d6a-4c1e-9b1e-5a3c2d7e8f01 -n 1:2048:0 -t 1:EF00 \
       -u 1:2b1c7a9e-4f3d-4e8a-a6b2-9c0d1e2f3a4b "$raw" >/dev/null
sectors=$(sgdisk -i 1 "$raw" | sed -n 's/^Partition size: \([0-9]*\) sectors.*/\1/p')
mkfs.vfat -F 32 -i 7a5c1e00 --invariant --offset=2048 "$raw" $(( sectors / 2 )) >/dev/null
mmd -i "$raw@@1M" ::/EFI ::/EFI/BOOT
mcopy -i "$raw@@1M" "$box" ::/EFI/BOOT/BOOTX64.EFI

# GCE wants the raw disk inside a gzipped tar whose member is exactly "disk.raw", sparse-packed.
tar --format=oldgnu -C "$work" -Sczf "$work/box-image.tar.gz" disk.raw
gsutil cp "$work/box-image.tar.gz" "$bucket/$image.tar.gz"
gcloud "${proj[@]}" compute images create "$image" \
  --source-uri "$bucket/$image.tar.gz" \
  --guest-os-features=UEFI_COMPATIBLE \
  --family=escrow-box
echo "image: $image (from $box, $(sha256sum "$box" | cut -c1-16)...)"
echo "create a machine from it with: escrow-box/gcp/create-vm.sh --image $image ..."
