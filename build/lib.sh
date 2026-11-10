# shellcheck shell=bash
# Common helpers for ArcadeOS build stages.

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config.env
. "$SRC_DIR/config.env"

abspath() { case "$1" in /*) echo "$1" ;; *) echo "$SRC_DIR/$1" ;; esac; }
WORK="$(abspath "$WORK_DIR")"
OUT="$(abspath "$OUT_DIR")"
KEYS="$(abspath "$KEYS_DIR")"
ROOTFS="$WORK/rootfs"

log()  { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!  %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mxx  %s\033[0m\n' "$*" >&2; exit 1; }

need_root() { [ "$(id -u)" -eq 0 ] || die "run as root"; }
need_cmd()  { for c in "$@"; do command -v "$c" >/dev/null || die "missing command: $c"; done; }

# chroot mounts -----------------------------------------------------------
chroot_mount() {
  local r=$1
  mountpoint -q "$r/proc" || mount -t proc proc "$r/proc"
  mountpoint -q "$r/sys"  || mount -t sysfs sys "$r/sys"
  mountpoint -q "$r/dev"  || mount --bind /dev "$r/dev"
  mountpoint -q "$r/dev/pts" || mount -t devpts devpts "$r/dev/pts"
  mountpoint -q "$r/run"  || mount -t tmpfs tmpfs "$r/run"
}
chroot_umount() {
  local r=$1 m
  for m in run dev/pts dev sys proc; do
    mountpoint -q "$r/$m" && umount -l "$r/$m" || true
  done
}
in_chroot() { chroot "$ROOTFS" /usr/bin/env -i \
  HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin LANG=C.UTF-8 \
  DEBIAN_FRONTEND=noninteractive "$@"; }

kernel_version() { ls "$ROOTFS/lib/modules" | sort -V | tail -n1; }
