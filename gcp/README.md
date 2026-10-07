# Running the escrow box on a GCE Shielded VM

A Shielded VM gives the box a vTPM that the VM's operator (here the customer) cannot read, and whose
state Google keeps off the guest. That is the "trust the cloud" variant of the model, and the one a
local QEMU harness cannot provide. This directory turns a built `box.efi` into a GCE image and a
Shielded VM.

Tested once end-to-end: the box boots, provisions, `check`/`verify` pass, the sealed key survives a
stop/start, and the sealed PCRs (4, 9, 11, 12, 13) are byte-identical across the restart. See the
caveats at the end — this does not test survival across a cloud firmware update.

## Prerequisites (interactive — your own account and spend)

With the Google Cloud SDK installed and `gcloud auth login` done, in a project with billing and the
Compute + Storage APIs enabled:

```
gcloud config set project YOUR_PROJECT
gcloud services enable compute.googleapis.com storage.googleapis.com
gsutil mb -l europe-west4 gs://YOUR_BUCKET
```

The box runs **its own** sshd on port 22 and accepts only the two keys baked into the image; it does
**not** use GCE OS Login or metadata SSH keys. Open tcp:22 to it from your address (or tunnel via
IAP and allow `35.235.240.0/20`):

```
gcloud compute firewall-rules create escrow-box-ssh \
    --direction=INGRESS --action=ALLOW --rules=tcp:22 --source-ranges=YOUR.IP/32
```

## Build, upload, run

```
# 1. build the image for the deal (see the top-level README / tests)
./build.sh --order demo --source SRC.tar --delivered NAME:SHA256 --rule RULE.json \
           --provider-key PROVIDER.pub --client-key CLIENT.pub --out OUT

# 2. upload it and make a GCE image
gcp/make-gcp-image.sh --box OUT/box.efi --bucket gs://YOUR_BUCKET --image escrow-demo

# 3. create the Shielded VM (vTPM on, Secure Boot off, integrity monitoring on)
gcp/create-vm.sh --image escrow-demo --vm escrow-demo --zone europe-west4-a
```

Then provision and operate over SSH to the VM's address (not through GCE's SSH):

```
ssh -i PROVIDER.key root@VM_IP provision < OUT/order.key   # provider, once
ssh -i CLIENT.key   root@VM_IP check                       # client; then verify / status / unlock / sealed / pcrs
```

## Why the machine is pinned to virtio-scsi and virtio-net

The box's initramfs carries no kernel modules (everything it needs is built into the kernel, and
module loading is disabled after boot). With a stock Ubuntu `vmlinuz`:

| Driver | GCE use | Typically in the kernel |
|---|---|---|
| `virtio_blk`, `virtio_scsi` | persistent disk over SCSI | built in |
| `virtio_net` | VirtioNet NIC | built in |
| `nvme` | persistent/local disk over NVMe | **module** |
| `gve` | gVNIC NIC | **module** |

So `create-vm.sh` pins the data disk to `interface=SCSI` and the NIC to `nic-type=VIRTIO_NET`, and
uses a machine family (default `n2-standard-2`) that offers both. A machine type or image that forces
NVMe or gVNIC would leave the box with no disk or no network until those drivers are built into the
kernel or the initramfs.

GCE also hands the instance a **/32 address**, so the subnet gateway is not on-link. The box's DHCP
hook adds a host route to the gateway first, then the default route via it. Without that the default
route silently fails and the box is unreachable.

## What this test answers

- **PCR stability.** Compare the box's `pcrs` across a stop/start of the same VM. The sealed PCRs
  must be identical; note which (if any) the cloud's firmware moves — those must not be in the sealed
  set. Using `gcloud compute instances get-shielded-identity` and the integrity-monitoring baseline
  gives a second view.
- **Operator cannot read the key.** Once provisioned, the escrow key lives only in the vTPM and in
  RAM while a command runs; the Shielded VM keeps both off the operator.

## Caveats

- Confirmed across **stop/start**, not across a cloud **firmware / dbx update**, which could move
  PCR 4 — bind only the PCRs that describe your image, and re-provision after a platform change (see
  the top-level README's limitations).
- **Secure Boot is off** because the UKI is unsigned; that is fine for the key binding (PCR 4 covers
  the image). Sign the UKI with your own key enrolled in the image if your platform requires it.
- The uploaded image and running VM cost money; delete them when done
  (`gcloud compute instances delete …`, `gcloud compute images delete …`).
