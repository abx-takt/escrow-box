#!/bin/bash
# Builds one escrow box: a single UKI (systemd-stub + kernel + the whole system as an initramfs,
# with an embedded command line). Booting it measures all of it into the TPM; the escrow key is
# later sealed to those measurements (box/escrow-box provision).
#
#   build.sh --order ID --source SOURCE.tar --delivered NAME:SHA256 --rule RULE.json \
#            --provider-key PROVIDER.pub --client-key CLIENT.pub --out DIR \
#            [--kernel vmlinuz] [--build-env DIR] [--cmdline-extra "..."]
#
#   DIR/box.efi    the image to boot (the customer runs it; it may read every byte of it)
#   DIR/box.json   public manifest: image and source hashes, delivered artifact, sealed PCRs
#   DIR/order.key  SECRET, the provider keeps it: the escrow key to provision with; it opens
#                  source.tar inside the box
#
# --source      a tar of the escrowed source; its single top directory holds a BUILD.txt that says
#               how to rebuild the delivered artifact (see tests/demo-source.sh for the format).
# --delivered   NAME:SHA256 of the artifact the customer was given; `verify` must reproduce it.
# --rule        JSON for the release rule in box/rule.py (see tests for an example).
# --kernel      an EFI-bootable Linux kernel (a distro vmlinuz); its drivers for your target's disk
#               and NIC must be built in, because the initramfs carries no modules. Default: the
#               running kernel's /boot/vmlinuz-$(uname -r).
# --build-env   a directory copied into the image at /opt (toolchains etc.) for `verify` to build
#               with, offline. Default: none (the base image's gcc only).
#
# Needs passwordless sudo (chroot and root-owned files of the image), and: debootstrap-free base via
# the official ubuntu-base tarball, plus mkfs/ukify/clevis/age on the host.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
STUB=${ESCROW_BOX_STUB:-/usr/lib/systemd/boot/efi/linuxx64.efi.stub}
WORK=${ESCROW_BOX_WORK:-$HERE/.work}
BASE=$WORK/base
PCR_BANK=sha256
PCR_IDS=${ESCROW_BOX_PCRS:-4,9,11,12,13}
EPOCH=1767225600
CMDLINE="console=ttyS0,115200n8 panic=-1 lockdown=confidentiality nohibernate sysctl.kernel.sysrq=0 module.sig_enforce=1 quiet loglevel=3"
UBUNTU_BASE_URL="https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release"

kernel=""; build_env=""; extra=""
while [ $# -gt 0 ]; do
  case "$1" in
    --order) order=$2;; --source) source=$2;; --delivered) delivered=$2;; --rule) rulef=$2;;
    --provider-key) provider_key=$2;; --client-key) client_key=$2;; --out) out=$2;;
    --kernel) kernel=$2;; --build-env) build_env=$2;; --cmdline-extra) extra=$2;;
    *) echo "unknown argument $1" >&2; exit 2;;
  esac
  shift 2
done
for v in order source delivered rulef provider_key client_key out; do [ -n "${!v:-}" ] || { echo "missing --${v//_/-}" >&2; exit 2; }; done
[ -z "$kernel" ] && kernel="/boot/vmlinuz-$(uname -r)"
[ -f "$kernel" ] || { echo "kernel not found: $kernel (pass --kernel)" >&2; exit 1; }
[ -f "$STUB" ] || { echo "systemd-stub not found: $STUB (install systemd-boot-efi / systemd-ukify)" >&2; exit 1; }
command -v ukify >/dev/null || { echo "ukify not found (install systemd-ukify)" >&2; exit 1; }
kver=$(basename "$kernel" | sed 's/^vmlinuz-//')

# --- the base system (cached): Ubuntu 24.04 base + everything the box needs -----------------
PKGS="gcc libc6-dev xz-utils zstd ca-certificates python3 tini clevis clevis-tpm2 tpm2-tools openssh-server age busybox-static iproute2 e2fsprogs util-linux dosfstools"
stamp=$(echo "$PKGS|$(sha256sum "${build_env:+$build_env/.escrow-env-stamp}" 2>/dev/null)" | sha256sum | cut -c1-16)
if [ "$(cat "$BASE.done" 2>/dev/null)" != "$stamp" ]; then
  mkdir -p "$WORK"
  curl -sfL -m 60 "$UBUNTU_BASE_URL/SHA256SUMS" -o "$WORK/SHA256SUMS"
  BASE_TAR=$(grep -o 'ubuntu-base-24.04[.0-9]*-base-amd64.tar.gz' "$WORK/SHA256SUMS" | sort -V | tail -1)
  [ -f "$WORK/$BASE_TAR" ] || curl -sfL -m 600 "$UBUNTU_BASE_URL/$BASE_TAR" -o "$WORK/$BASE_TAR"
  (cd "$WORK" && sha256sum -c --ignore-missing SHA256SUMS | grep -q "$BASE_TAR: OK")
  if findmnt -rn -o TARGET | grep -q "^$BASE/"; then echo "mounts left under $BASE: unmount them first" >&2; exit 1; fi
  sudo rm -rf "$BASE" "$BASE.done"; sudo mkdir -p "$BASE"
  sudo tar -xpzf "$WORK/$BASE_TAR" -C "$BASE" --numeric-owner
  sudo cp /etc/resolv.conf "$BASE/etc/resolv.conf"
  # Only these device nodes enter the chroot. Never bind the host's whole /dev: package scripts can
  # re-own real devices through it.
  devs="null zero random urandom full"
  for n in $devs; do sudo touch "$BASE/dev/$n"; sudo mount --bind "/dev/$n" "$BASE/dev/$n"; done
  sudo mount -t proc proc "$BASE/proc"
  unmount_base() { for n in $devs; do sudo umount "$BASE/dev/$n" 2>/dev/null; done; sudo umount "$BASE/proc" 2>/dev/null; true; }
  trap unmount_base EXIT
  sudo chroot "$BASE" apt-get update -q
  sudo chroot "$BASE" env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends $PKGS
  sudo chroot "$BASE" apt-get clean
  sudo chroot "$BASE" dpkg-query -W > "$WORK/base.packages.txt"
  unmount_base; trap - EXIT
  for n in $devs; do sudo rm -f "$BASE/dev/$n"; done
  sudo rm -rf "$BASE/usr/share/doc" "$BASE/usr/share/man" "$BASE/usr/share/info" "$BASE/var/lib/apt/lists/"* "$BASE/var/cache/apt/"*
  sudo rm -f "$BASE/etc/ssh/ssh_host_"* "$BASE/etc/resolv.conf"
  if [ -n "$build_env" ]; then sudo rm -rf "$BASE/opt/build-env"; sudo cp -a "$build_env" "$BASE/opt/build-env"; sudo chown -R 0:0 "$BASE/opt/build-env"; fi
  sudo chroot "$BASE" groupadd -g 902 builder
  sudo chroot "$BASE" useradd -u 902 -g 902 -M -d /nonexistent -s /usr/sbin/nologin builder
  sudo chroot "$BASE" usermod -s /bin/sh root
  echo "$stamp" | sudo tee "$BASE.done" >/dev/null
fi

# --- this order -----------------------------------------------------------------------------
mkdir -p "$out"; out=$(cd "$out" && pwd)
umask 077; age-keygen -o "$out/order.key" 2>/dev/null; recipient=$(age-keygen -y "$out/order.key"); umask 022
STAGE=$(mktemp -d "${ESCROW_BOX_STAGE:-/dev/shm}/escrow-box.XXXXXX")
trap 'sudo rm -rf "$STAGE"' EXIT
sudo cp -a "$BASE/." "$STAGE/"
sudo install -d -m 0755 "$STAGE/etc/escrow-box" "$STAGE/opt/escrow-box" "$STAGE/usr/local/lib/escrow-box"
sudo install -d -m 0700 "$STAGE/data"
age -r "$recipient" "$source" | sudo tee "$STAGE/opt/escrow-box/source.tar.age" >/dev/null
src_sha=$(sha256sum "$source" | cut -d' ' -f1)
image_id="$order-$(date -u +%Y%m%dT%H%M%SZ)"
python3 - "$rulef" "$order" "$src_sha" "${delivered%%:*}" "${delivered##*:}" "$PCR_BANK" "$PCR_IDS" > "$STAGE.config.json" <<'PY'
import json, sys
rulef, order, src, name, sha, bank, ids = sys.argv[1:]
r = json.load(open(rulef))
r.setdefault('time', {'max_skew_seconds': 600})
r.setdefault('max_tarball_bytes', 100 << 20)
r.setdefault('self_check_minutes', 60)
if 'heartbeat' in r:
    r['heartbeat'].setdefault('missing_grace_days', 14)
print(json.dumps({'box': 'escrow-box/1', 'order': order, 'pcr_bank': bank, 'pcr_ids': ids,
                  'source': {'sha256': src}, 'delivered': {'name': name, 'sha256': sha}, 'rule': r}, indent=1, sort_keys=True))
PY
sudo install -m 0644 "$STAGE.config.json" "$STAGE/etc/escrow-box/config.json"; rm -f "$STAGE.config.json"
{
  echo "restrict,command=\"/usr/local/bin/escrow-box provider\" $(cut -d' ' -f1,2 "$provider_key") provider"
  echo "restrict,command=\"/usr/local/bin/escrow-box client\" $(cut -d' ' -f1,2 "$client_key") client"
} | sudo tee "$STAGE/etc/escrow-box/authorized_keys" >/dev/null
echo "$image_id" | sudo tee "$STAGE/etc/escrow-box/image-id" >/dev/null
echo "escrow-box" | sudo tee "$STAGE/etc/hostname" >/dev/null
sudo install -m 0644 "$HERE/box/sshd_config" "$STAGE/etc/escrow-box/sshd_config"
sudo install -m 0755 "$HERE/box/init" "$STAGE/init"
sudo install -m 0755 "$HERE/box/escrow-box" "$STAGE/usr/local/bin/escrow-box"
sudo install -m 0644 "$HERE/box/rule.py" "$STAGE/usr/local/lib/escrow-box/rule.py"
sudo install -m 0755 "$HERE/box/udhcpc.script" "$STAGE/usr/local/lib/escrow-box/udhcpc.script"
sudo ln -sfn /run/resolv.conf "$STAGE/etc/resolv.conf"
sudo find "$STAGE" -xdev -exec touch -h -d "@$EPOCH" {} +
sudo chmod 755 "$STAGE"; sudo chown 0:0 "$STAGE"
(cd "$STAGE" && sudo find . -print0 | LC_ALL=C sort -z | sudo cpio --null -o -H newc --reproducible --quiet) \
  | zstd -q -T0 -9 > "$out/initrd.cpio.zst"
printf 'ID=escrow-box\nNAME="escrow box"\nPRETTY_NAME="escrow box %s"\n' "$image_id" > "$out/os-release"
ukify build --linux "$kernel" --initrd "$out/initrd.cpio.zst" --cmdline "$CMDLINE${extra:+ $extra}" \
  --os-release "@$out/os-release" --uname "$kver" --stub "$STUB" --output "$out/box.efi" >/dev/null
rm -f "$out/initrd.cpio.zst" "$out/os-release"
cat > "$out/box.json" <<JSON
{
 "image": "box.efi",
 "image_id": "$image_id",
 "image_sha256": "$(sha256sum "$out/box.efi" | cut -d' ' -f1)",
 "order": "$order",
 "source_sha256": "$src_sha",
 "delivered": {"name": "${delivered%%:*}", "sha256": "${delivered##*:}"},
 "sealed_to": "$PCR_BANK:$PCR_IDS",
 "cmdline": "$CMDLINE${extra:+ $extra}",
 "kernel": "$kver"
}
JSON
echo "$out/box.efi ($(du -h "$out/box.efi" | cut -f1))"
