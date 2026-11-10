#!/bin/bash
# Test the installer and the whole boot chain in QEMU (no NVIDIA, so games won't run,
# but Secure Boot enrollment, MokManager, LUKS/HWID, verity and the launcher do).
#   tools/qemu-test.sh out/arcadeos-installer-*.iso     # first run: install
#   tools/qemu-test.sh                                  # later: boot the disk
# Change SERIAL to simulate "another motherboard" -> recovery-key prompt.
set -euo pipefail
cd "$(dirname "$0")/.."
VM=work/qemu; mkdir -p "$VM"
CODE=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd
VARS_TEMPLATE=/usr/share/OVMF/OVMF_VARS_4M.fd   # no keys enrolled = Setup Mode
UUID=${UUID:-6f1c2a7e-3b4d-4e5f-8a9b-0c1d2e3f4a5b}
SERIAL=${SERIAL:-ARCADE-BOARD-0001}

[ -f "$CODE" ] || { echo "install the 'ovmf' package" >&2; exit 1; }
[ -f "$VM/vars.fd" ] || cp "$VARS_TEMPLATE" "$VM/vars.fd"
[ -f "$VM/disk.qcow2" ] || qemu-img create -f qcow2 "$VM/disk.qcow2" 40G

ISO=()
[ $# -ge 1 ] && ISO=(-drive "file=$1,media=cdrom,readonly=on" -boot d)

exec qemu-system-x86_64 \
  -machine q35,smm=on,accel=kvm -cpu host -m 4096 -smp 4 \
  -global driver=cfi.pflash01,property=secure,value=on \
  -drive if=pflash,format=raw,unit=0,readonly=on,file="$CODE" \
  -drive if=pflash,format=raw,unit=1,file="$VM/vars.fd" \
  -uuid "$UUID" \
  -smbios type=1,manufacturer=ArcadeTest,product=VM,serial="SYS-$SERIAL" \
  -smbios type=2,manufacturer=ArcadeTest,product=Board,serial="$SERIAL" \
  -drive file="$VM/disk.qcow2",if=none,id=d0 -device nvme,drive=d0,serial=ARCNVME0 \
  -device virtio-vga -device qemu-xhci -device usb-tablet -device usb-kbd \
  -audiodev pa,id=snd0 -device ich9-intel-hda -device hda-output,audiodev=snd0 \
  -nic user,model=virtio-net-pci \
  "${ISO[@]}"
