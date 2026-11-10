#!/bin/bash
# Stage 10: Debian root filesystem with NVIDIA driver, X, launcher.
. "$(dirname "$0")/lib.sh"
need_root
need_cmd debootstrap

LL="$(abspath "$LINUXLOADER_DIR")"
[ -x "$LL/linuxloader" ] || die "linuxloader not found in $LL (unpack a release there, see README)"
[ -f "$KEYS/MOK.key" ] || die "run build/00-keys.sh first"

trap 'chroot_umount "$ROOTFS"' EXIT
chroot_umount "$ROOTFS" 2>/dev/null || true
rm -rf "$ROOTFS"; mkdir -p "$ROOTFS"

log "debootstrap $DEBIAN_SUITE"
debootstrap --variant=minbase --arch=amd64 \
  --components=main,contrib,non-free,non-free-firmware \
  "$DEBIAN_SUITE" "$ROOTFS" "$DEBIAN_MIRROR"

cat > "$ROOTFS/etc/apt/sources.list" <<EOF
deb $DEBIAN_MIRROR $DEBIAN_SUITE main contrib non-free non-free-firmware
deb $DEBIAN_MIRROR $DEBIAN_SUITE-updates main contrib non-free non-free-firmware
deb $DEBIAN_SECURITY $DEBIAN_SUITE-security main contrib non-free non-free-firmware
EOF
printf '#!/bin/sh\nexit 101\n' > "$ROOTFS/usr/sbin/policy-rc.d"
chmod +x "$ROOTFS/usr/sbin/policy-rc.d"
echo arcadeos > "$ROOTFS/etc/hostname"

chroot_mount "$ROOTFS"
in_chroot dpkg --add-architecture i386
in_chroot apt-get update

pkgs() { grep -vE '^\s*(#|$)' "$SRC_DIR/packages/$1"; }

# DKMS signs every module it builds with /var/lib/dkms/mok.{key,pub}.
# The private key is removed again before the image is packed.
install -d -m 700 "$ROOTFS/var/lib/dkms"
install -m 600 "$KEYS/MOK.key" "$ROOTFS/var/lib/dkms/mok.key"
install -m 644 "$KEYS/MOK.der" "$ROOTFS/var/lib/dkms/mok.pub"

log "installing base packages"
# shellcheck disable=SC2046
in_chroot apt-get install -y --no-install-recommends $(pkgs base.list)

log "installing NVIDIA ($NVIDIA_KMOD)"
# shellcheck disable=SC2046
in_chroot apt-get install -y --no-install-recommends dkms "$NVIDIA_KMOD" $(pkgs nvidia.list)

KVER=$(kernel_version)
in_chroot dkms autoinstall -k "$KVER" || true
SIGNER=$(in_chroot modinfo -k "$KVER" -F signer nvidia 2>/dev/null || true)
[ -n "$SIGNER" ] || die "nvidia.ko for $KVER missing or unsigned"
log "nvidia.ko signed by: $SIGNER"

log "installing i386 libraries"
while read -r p; do
  in_chroot apt-get install -y --no-install-recommends "$p" || warn "package $p not available, skipped"
done < <(pkgs i386.list)

shred -u "$ROOTFS/var/lib/dkms/mok.key"

log "copying overlay"
cp -a "$SRC_DIR/rootfs/." "$ROOTFS/"
chmod 755 "$ROOTFS"/usr/local/sbin/* "$ROOTFS"/opt/arcadeos/bin/* \
          "$ROOTFS"/etc/initramfs-tools/hooks/arcadeos
chmod 440 "$ROOTFS/etc/sudoers.d/arcadeos"

log "installing linuxloader"
rm -rf "$ROOTFS/opt/arcadeos/linuxloader"
cp -a "$LL" "$ROOTFS/opt/arcadeos/linuxloader"
chmod +x "$ROOTFS/opt/arcadeos/linuxloader/linuxloader"

log "users and services"
in_chroot useradd -u "$ARCADE_UID" -m -s /bin/bash \
  -G audio,video,input,dialout,render arcade
install -o "$ARCADE_UID" -g "$ARCADE_UID" -m 644 \
  "$ROOTFS/opt/arcadeos/skel/bash_profile" "$ROOTFS/home/arcade/.bash_profile"
in_chroot passwd -l arcade
if [ -n "$DEBUG_ROOT_PASSWORD" ]; then
  warn "DEBUG build: root password set, tty2 login enabled"
  echo "root:$DEBUG_ROOT_PASSWORD" | in_chroot chpasswd
  sed -i 's/^NAutoVTs=.*/NAutoVTs=2/' "$ROOTFS/etc/systemd/logind.conf.d/arcadeos.conf"
else
  in_chroot passwd -l root
fi

in_chroot systemctl enable systemd-networkd.service
in_chroot systemctl mask ctrl-alt-del.target systemd-networkd-wait-online.service \
  apt-daily.timer apt-daily-upgrade.timer e2scrub_reap.service
in_chroot systemctl set-default multi-user.target
in_chroot plymouth-set-default-theme arcadeos

sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' "$ROOTFS/etc/locale.gen"
in_chroot locale-gen

cat > "$ROOTFS/etc/arcadeos-release" <<EOF
ARCADEOS_VERSION=$ARCADEOS_VERSION
BUILD_DATE=$(date -u +%Y-%m-%dT%H:%MZ)
KERNEL=$KVER
EOF

log "cleanup"
in_chroot apt-get clean
rm -rf "$ROOTFS"/var/lib/apt/lists/* "$ROOTFS"/var/cache/apt/*.bin \
       "$ROOTFS/usr/sbin/policy-rc.d" "$ROOTFS"/tmp/* "$ROOTFS"/root/.bash_history
: > "$ROOTFS/etc/machine-id"
log "rootfs ready: $ROOTFS (kernel $KVER)"
