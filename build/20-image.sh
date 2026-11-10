#!/bin/bash
# Stage 20: initramfs, then read-only squashfs root protected by dm-verity.
. "$(dirname "$0")/lib.sh"
need_root
need_cmd mksquashfs veritysetup truncate

[ -d "$ROOTFS/etc" ] || die "run build/10-rootfs.sh first"
KVER=$(kernel_version)

log "building initramfs for $KVER"
trap 'chroot_umount "$ROOTFS"' EXIT
chroot_mount "$ROOTFS"
in_chroot update-initramfs -c -k "$KVER" 2>/dev/null || in_chroot update-initramfs -u -k "$KVER"
in_chroot lsinitramfs "/boot/initrd.img-$KVER" | grep -q 'scripts/arcadeos' \
  || die "initramfs does not contain the arcadeos boot script"
chroot_umount "$ROOTFS"
trap - EXIT

mkdir -p "$WORK/boot"
cp "$ROOTFS/boot/vmlinuz-$KVER"    "$WORK/boot/vmlinuz"
cp "$ROOTFS/boot/initrd.img-$KVER" "$WORK/boot/initrd.img"

log "packing squashfs"
IMG="$WORK/root.img"
rm -f "$IMG"
mksquashfs "$ROOTFS" "$IMG" -comp zstd -Xcompression-level 15 -noappend -quiet \
  -wildcards -e 'boot/*' 'proc/*' 'sys/*' 'dev/*' 'run/*' 'tmp/*' 'var/tmp/*'

truncate -s %4096 "$IMG"                 # align data area to 4 KiB blocks
SIZE=$(stat -c %s "$IMG")

log "computing dm-verity hash tree"
VOUT=$(veritysetup format --data-blocks=$((SIZE / 4096)) --hash-offset="$SIZE" "$IMG" "$IMG")
ROOTHASH=$(awk '/Root hash:/ {print $3}' <<<"$VOUT")
[ -n "$ROOTHASH" ] || die "veritysetup did not print a root hash"
veritysetup verify --hash-offset="$SIZE" "$IMG" "$IMG" "$ROOTHASH"

cat > "$WORK/root.env" <<EOF
ARCADEOS_VERSION=$ARCADEOS_VERSION
KVER=$KVER
ROOTHASH=$ROOTHASH
HASHOFF=$SIZE
IMAGE_BYTES=$(stat -c %s "$IMG")
ROOT_PART_MIB=$ROOT_PART_MIB
EOF
log "root.img $(du -h "$IMG" | cut -f1), root hash $ROOTHASH"
