#!/bin/bash
# Stage 30: own shim, signed UKI (kernel + initramfs + cmdline with root hash),
# and the installer payload.
. "$(dirname "$0")/lib.sh"
need_root
need_cmd sbsign sbverify wget tar make gcc

[ -f "$WORK/root.env" ] || die "run build/20-image.sh first"
# shellcheck source=/dev/null
. "$WORK/root.env"

# --- shim with our vendor certificate ---------------------------------------
SHIMSRC="$WORK/shim-$SHIM_VERSION"
if [ ! -f "$SHIMSRC/shimx64.efi" ]; then
  log "building shim $SHIM_VERSION (vendor cert = our db key)"
  mkdir -p "$WORK/dl"
  [ -f "$WORK/dl/shim.tar.bz2" ] || wget -q -O "$WORK/dl/shim.tar.bz2" "$SHIM_URL"
  rm -rf "$SHIMSRC"; mkdir -p "$SHIMSRC"
  tar -xjf "$WORK/dl/shim.tar.bz2" -C "$SHIMSRC" --strip-components=1
  # default second stage is \grubx64.efi next to shim - that's our UKI
  make -C "$SHIMSRC" -j"$(nproc)" VENDOR_CERT_FILE="$KEYS/db.der" shimx64.efi mmx64.efi
fi

# --- UKI ---------------------------------------------------------------------
CMDLINE="boot=arcadeos arcadeos.roothash=$ROOTHASH arcadeos.hashoffset=$HASHOFF $KERNEL_CMDLINE_EXTRA"
log "building UKI"
trap 'chroot_umount "$ROOTFS"' EXIT
chroot_mount "$ROOTFS"
in_chroot ukify build \
  --linux="/boot/vmlinuz-$KVER" \
  --initrd="/boot/initrd.img-$KVER" \
  --uname="$KVER" \
  --os-release=@/etc/os-release \
  --cmdline="$CMDLINE" \
  --output=/root/arcadeos-uki.efi
chroot_umount "$ROOTFS"; trap - EXIT

PAY="$OUT/payload"
rm -rf "$PAY"; mkdir -p "$PAY"/{esp,sb,mok}

sign() { sbsign --key "$KEYS/db.key" --cert "$KEYS/db.crt" --output "$2" "$1" >/dev/null
         sbverify --cert "$KEYS/db.crt" "$2" >/dev/null || die "signature check failed: $2"; }
log "signing EFI binaries"
sign "$ROOTFS/root/arcadeos-uki.efi" "$PAY/esp/grubx64.efi"   # shim loads grubx64.efi
sign "$SHIMSRC/shimx64.efi"          "$PAY/esp/shimx64.efi"
sign "$SHIMSRC/mmx64.efi"            "$PAY/esp/mmx64.efi"
rm -f "$ROOTFS/root/arcadeos-uki.efi"

cp "$KEYS"/{PK,KEK,db}.auth "$PAY/sb/"
cp "$KEYS/MOK.der" "$PAY/mok/"
cp "$WORK/root.img" "$WORK/root.env" "$PAY/"
install -m 755 "$SRC_DIR/rootfs/usr/local/sbin/hwid-key" "$PAY/hwid-key"
install -m 755 "$SRC_DIR/installer/install.sh" "$PAY/install.sh"
( cd "$PAY" && sha256sum root.img esp/* sb/* mok/* hwid-key install.sh > SHA256SUMS )

log "payload ready: $PAY"
