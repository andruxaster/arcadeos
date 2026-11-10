#!/bin/bash
# Stage 40: bootable installer ISO (black screen + INSTALL button).
. "$(dirname "$0")/lib.sh"
need_root
need_cmd lb

PAY="$OUT/payload"
[ -f "$PAY/SHA256SUMS" ] || die "run build/30-boot.sh first"

LIVE="$WORK/live"
if [ -d "$LIVE" ]; then (cd "$LIVE" && lb clean --purge >/dev/null 2>&1) || true; fi
rm -rf "$LIVE"
cp -a "$SRC_DIR/installer/live" "$LIVE"

INC="$LIVE/config/includes.chroot/opt/arcadeos-installer"
mkdir -p "$INC"
install -m 755 "$SRC_DIR/installer/installer.py" "$INC/installer.py"
install -m 755 "$SRC_DIR/installer/install.sh"   "$INC/install.sh"
install -m 755 "$SRC_DIR/rootfs/usr/local/sbin/hwid-key" "$INC/hwid-key"
sed -i "s/@ARCADEOS_VERSION@/$ARCADEOS_VERSION/" "$INC/installer.py"

log "copying payload into ISO tree"
mkdir -p "$LIVE/config/includes.binary/arcadeos"
cp -a "$PAY/." "$LIVE/config/includes.binary/arcadeos/"

sed -i "s|@MIRROR@|$DEBIAN_MIRROR|; s|@SUITE@|$DEBIAN_SUITE|" "$LIVE/auto/config"
chmod +x "$LIVE/auto/config" "$LIVE"/config/hooks/normal/*.hook.chroot

log "running live-build (takes a while)"
( cd "$LIVE" && lb config && lb build )

ISO=$(ls "$LIVE"/*.iso 2>/dev/null | head -n1)
[ -n "$ISO" ] || die "live-build produced no ISO"
mkdir -p "$OUT"
mv "$ISO" "$OUT/arcadeos-installer-$ARCADEOS_VERSION.iso"
log "ISO: $OUT/arcadeos-installer-$ARCADEOS_VERSION.iso"
