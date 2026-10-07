#!/bin/bash
# Local stand-in for the Client's VM: QEMU + OVMF (UEFI, Secure Boot off) + swtpm. A "machine" is
# its own TPM state, firmware variables and data disk, like one cloud VM with its vTPM; the image
# it boots can be swapped between starts, as the VM's operator could do.
#
#   run.sh start NAME BOX.efi PORT [--smbios-cmdline "..."]   boot; waits for "ready"
#   run.sh stop NAME                                         power off (TPM state kept)
#   run.sh ssh NAME KEY COMMAND [< stdin]                    the box's forced command
#   run.sh destroy NAME
#
# Needs qemu-system-x86_64, swtpm, OVMF and KVM. Set ESCROW_BOX_CPUS to pin QEMU (taskset).
set -euo pipefail
export PATH=$PATH:/usr/sbin:/sbin
HERE=$(cd "$(dirname "$0")" && pwd)
MACHINES=${ESCROW_BOX_MACHINES:-$HERE/.work/machines}
CPUS=${ESCROW_BOX_CPUS:-}
cmd=${1:?start|stop|ssh|destroy}; name=${2:?machine name}
M=$MACHINES/$name
# Unix socket paths are limited to 108 bytes: the TPM socket lives in the runtime directory.
SOCK=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/escrow-box-$name.tpm

stop() {
  [ -f "$M/qemu.pid" ] && kill "$(cat "$M/qemu.pid")" 2>/dev/null || true
  for _ in $(seq 50); do kill -0 "$(cat "$M/qemu.pid" 2>/dev/null)" 2>/dev/null || break; sleep 0.2; done
  [ -f "$M/swtpm.pid" ] && kill "$(cat "$M/swtpm.pid")" 2>/dev/null || true
  rm -f "$M/qemu.pid" "$M/swtpm.pid" "$SOCK"
}

case "$cmd" in
start)
  uki=${3:?BOX.efi}; port=${4:?ssh port}; smbios=()
  [ "${5:-}" = --smbios-cmdline ] && smbios=(-smbios "type=11,value=io.systemd.stub.kernel-cmdline-extra=${6:?}")
  mkdir -p "$M"
  stop
  if [ ! -f "$M/tpm/.initialized" ]; then
    mkdir -p "$M/tpm"
    swtpm_setup --tpm2 --tpmstate "dir://$M/tpm" --createek --create-spk --lock-nvram >/dev/null
    : > "$M/tpm/.initialized"
  fi
  [ -f "$M/OVMF_VARS.fd" ] || cp /usr/share/OVMF/OVMF_VARS_4M.fd "$M/OVMF_VARS.fd"
  [ -f "$M/data.raw" ] || truncate -s 64M "$M/data.raw"
  # The boot disk: GPT with one EFI system partition holding the image as the default loader.
  esp=$M/esp.raw; rm -f "$esp"
  truncate -s $(( $(stat -c%s "$uki") / 1048576 + 80 ))M "$esp"
  # Fixed GPT and volume IDs: the boot disk is re-made at every start here, but a cloud boot disk
  # keeps its IDs, and the firmware measures the GPT (PCR 5).
  sgdisk -o -U 6f8e0f6c-0d6a-4c1e-9b1e-5a3c2d7e8f01 -n 1:2048:0 -t 1:EF00 -u 1:2b1c7a9e-4f3d-4e8a-a6b2-9c0d1e2f3a4b "$esp" >/dev/null
  sectors=$(sgdisk -i 1 "$esp" | sed -n 's/^Partition size: \([0-9]*\) sectors.*/\1/p')
  mkfs.vfat -F 32 -i 7a5c1e00 --invariant --offset=2048 "$esp" $(( sectors / 2 )) >/dev/null
  mmd -i "$esp@@1M" ::/EFI ::/EFI/BOOT
  mcopy -i "$esp@@1M" "$uki" ::/EFI/BOOT/BOOTX64.EFI
  swtpm socket --tpmstate "dir=$M/tpm" --ctrl "type=unixio,path=$SOCK" --tpm2 --flags startup-clear \
    --daemon --pid "file=$M/swtpm.pid" --log "file=$M/swtpm.log,level=1"
  : > "$M/console.log"
  ${CPUS:+taskset -c "$CPUS"} qemu-system-x86_64 -name "escrow-$name" -enable-kvm -machine q35,accel=kvm -cpu host -smp 4 -m 8192 \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,file="$M/OVMF_VARS.fd" \
    -drive file="$esp",format=raw,if=virtio \
    -drive file="$M/data.raw",format=raw,if=virtio \
    -chardev socket,id=chrtpm,path="$SOCK" -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis,tpmdev=tpm0 \
    -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:"$port"-:22 \
    "${smbios[@]}" -display none -serial file:"$M/console.log" -daemonize -pidfile "$M/qemu.pid"
  echo "$port" > "$M/port"
  for _ in $(seq 240); do
    grep -q 'escrow-box: ready' "$M/console.log" 2>/dev/null && { echo "$name: ready on port $port"; exit 0; }
    grep -q 'escrow-box init:' "$M/console.log" 2>/dev/null && break
    kill -0 "$(cat "$M/qemu.pid" 2>/dev/null)" 2>/dev/null || break
    sleep 1
  done
  echo "$name: did not come up" >&2; tail -5 "$M/console.log" >&2; exit 1
  ;;
stop) stop ;;
destroy) stop; rm -rf "$M" ;;
ssh)
  key=${3:?key}; shift 3
  exec ssh -q -i "$key" -p "$(cat "$M/port")" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes -o ConnectTimeout=10 root@127.0.0.1 "$@"
  ;;
*) echo "unknown command $cmd" >&2; exit 2 ;;
esac
