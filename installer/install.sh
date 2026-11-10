#!/bin/bash
# ArcadeOS installer backend. Used by installer.py, also works by hand.
#
#   install.sh --list-disks
#   install.sh --check-hwid
#   install.sh --install --disk /dev/nvme0n1 [--no-secureboot] [--force-weak-hwid]
#   install.sh --update  --disk /dev/nvme0n1 [--recovery-key KEY]
#
# Machine-readable lines for the GUI start with "@@":
#   @@PROGRESS <0-100> <text>   @@RECOVERY <key>   @@MOKPASS <digits>
#   @@NOTE <text>               @@DISK <dev> <bytes> <existing 0|1> <model>
#   @@DONE                      @@ERROR <text>
set -uo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "$0")" && pwd)"
if   [ -f "$HERE/root.img" ];                  then PAY="$HERE"
elif [ -f /run/live/medium/arcadeos/root.img ]; then PAY=/run/live/medium/arcadeos
else PAY=""; fi
HWID="$HERE/hwid-key"; [ -x "$HWID" ] || HWID="$PAY/hwid-key"

ESP_MIB=512
MNT=/run/arcadeos-install
ARC_UID=1000

progress() { echo "@@PROGRESS $1 $2"; }
note()     { echo "@@NOTE $*"; }
fail()     { echo "@@ERROR $*"; cleanup; exit 1; }
run()      { echo "+ $*"; "$@" || fail "command failed: $*"; }

cleanup() {
  mountpoint -q "$MNT/esp"  && umount "$MNT/esp"
  mountpoint -q "$MNT/data" && umount "$MNT/data"
  [ -e /dev/mapper/arcinst-root ] && cryptsetup close arcinst-root
  [ -e /dev/mapper/arcinst-data ] && cryptsetup close arcinst-data
  return 0
}

part() { case "$1" in *[0-9]) echo "${1}p$2" ;; *) echo "$1$2" ;; esac; }

live_disk() {
  local src; src=$(findmnt -no SOURCE /run/live/medium 2>/dev/null) || return 0
  lsblk -no PKNAME "$src" 2>/dev/null | head -n1
}

has_arcadeos() { lsblk -nro PARTLABEL "$1" 2>/dev/null | grep -qx ARC_ROOT; }

list_disks() {
  local live name size model
  live=$(live_disk)
  while read -r name size; do
    [ "$(basename "$name")" = "$live" ] && continue
    model=$(lsblk -dno MODEL "$name" | sed 's/  */ /g')
    echo "@@DISK $name $size $(has_arcadeos "$name" && echo 1 || echo 0) ${model:-disk}"
  done < <(lsblk -dbnpo NAME,SIZE,TYPE | awk '$3=="disk" && $2>0 {print $1, $2}')
}

gen_recovery() { # 32 chars, no ambiguous letters, shown as XXXX-XXXX-...
  tr -dc 'A-HJ-NP-Z2-9' < /dev/urandom | head -c 32
}
fmt_recovery() { sed 's/.\{4\}/&-/g; s/-$//' <<<"$1"; }

efivar_byte() { # last byte of an EFI global variable, empty if missing
  local f="/sys/firmware/efi/efivars/$1-8be4df61-93ca-11d2-aa0d-00e098032b8c"
  [ -r "$f" ] && od -An -t u1 "$f" | awk '{print $NF}' | tail -n1
}

check_common() {
  [ "$(id -u)" -eq 0 ] || fail "must run as root"
  [ -d /sys/firmware/efi ] || fail "not booted in UEFI mode (disable CSM/Legacy)"
  [ -n "$PAY" ] || fail "payload (root.img) not found"
  # shellcheck source=/dev/null
  . "$PAY/root.env"
  progress 2 "Verifying installer files"
  ( cd "$PAY" && sha256sum --quiet -c SHA256SUMS ) || fail "installer media is corrupted (checksum)"
  [ -b "$DISK" ] || fail "no such disk: $DISK"
  [ "$(basename "$DISK")" != "$(live_disk)" ] || fail "refusing to overwrite the installer USB"
}

write_esp() {
  local esp; esp=$(part "$DISK" 1)
  mkdir -p "$MNT/esp"
  run mount "$esp" "$MNT/esp"
  for d in EFI/arcadeos EFI/BOOT; do
    mkdir -p "$MNT/esp/$d"
    cp "$PAY/esp/grubx64.efi" "$PAY/esp/mmx64.efi" "$MNT/esp/$d/" || fail "ESP copy failed"
  done
  cp "$PAY/esp/shimx64.efi" "$MNT/esp/EFI/arcadeos/shimx64.efi"
  cp "$PAY/esp/shimx64.efi" "$MNT/esp/EFI/BOOT/BOOTX64.EFI"
  sync; umount "$MNT/esp"
  # replace old boot entries
  efibootmgr | awk '/ArcadeOS/ {sub(/^Boot/,""); sub(/\*.*/,""); print}' | while read -r n; do
    efibootmgr -q -b "$n" -B
  done
  efibootmgr -q -c -d "$DISK" -p 1 -L "ArcadeOS" -l '\EFI\arcadeos\shimx64.efi' \
    || note "Could not create a UEFI boot entry; the firmware will use the fallback path."
}

make_luks() { # device mapper-name hwid-key recovery-key
  echo "+ luksFormat $1"
  printf '%s' "$3" | cryptsetup luksFormat --batch-mode --type luks2 --cipher aes-xts-plain64 \
      --key-size 512 --pbkdf argon2id --iter-time 1000 --key-file=- "$1" || fail "luksFormat $1 failed"
  printf '%s' "$3" | cryptsetup open --key-file=- "$1" "$2" || fail "cannot open $1"
  cryptsetup luksAddKey --key-file=<(printf '%s' "$3") "$1" <(printf '%s' "$4") \
      || fail "cannot add recovery key to $1"
}

write_root() { # mapper name opened
  local cap
  cap=$(blockdev --getsize64 /dev/mapper/arcinst-root)
  [ "$IMAGE_BYTES" -le "$cap" ] || fail "root image ($IMAGE_BYTES) larger than partition ($cap)"
  progress 30 "Writing system image"
  dd if="$PAY/root.img" of=/dev/mapper/arcinst-root bs=4M conv=fsync status=progress 2>&1 \
    | tr '\r' '\n' | grep --line-buffered -o '^[0-9]* bytes' \
    | while read -r b _; do progress $((30 + 40 * b / IMAGE_BYTES)) "Writing system image"; done
  [ "${PIPESTATUS[0]}" -eq 0 ] || fail "writing the system image failed"
  progress 72 "Verifying system image"
  veritysetup verify --hash-offset="$HASHOFF" /dev/mapper/arcinst-root /dev/mapper/arcinst-root \
    "$ROOTHASH" || fail "image verification failed after writing"
}

enroll_secureboot() {
  local setup
  setup=$(efivar_byte SetupMode)
  if [ "$setup" != 1 ]; then
    note "Firmware is NOT in Setup Mode: Secure Boot keys were not installed. Boot will work with Secure Boot disabled. To lock the system: BIOS > Secure Boot > clear keys, then run UPDATE."
    return 0
  fi
  progress 85 "Installing Secure Boot keys"
  for v in db KEK PK; do        # PK last: it ends Setup Mode
    chattr -i /sys/firmware/efi/efivars/"$v"-* 2>/dev/null
    efi-updatevar -f "$PAY/sb/$v.auth" "$v" || fail "efi-updatevar $v failed (firmware refused the key)"
  done
  [ "$(efivar_byte SetupMode)" = 0 ] || note "Firmware still reports Setup Mode; check BIOS Secure Boot settings."

  progress 90 "Scheduling module key enrollment (MOK)"
  local pw hash
  pw=$(tr -dc 0-9 < /dev/urandom | head -c 8)
  hash=$(mktemp)
  mokutil --generate-hash="$pw" > "$hash" && mokutil --import "$PAY/mok/MOK.der" --hash-file "$hash" \
    || note "mokutil --import failed; NVIDIA driver will not load with Secure Boot on."
  rm -f "$hash"
  echo "@@MOKPASS $pw"
}

do_install() {
  check_common
  if ! "$HWID" --check >/dev/null; then
    "$HWID" --check | awk '{print $1, $2}'
    [ "${FORCE_WEAK:-0}" = 1 ] || fail "hardware IDs of this board look generic; HWID binding would be weak (use --force-weak-hwid to continue)"
    note "Weak hardware IDs - continuing because --force-weak-hwid was given."
  fi
  local key_root key_data rec
  key_root=$("$HWID" root); key_data=$("$HWID" data)
  rec=$(gen_recovery)

  progress 5 "Partitioning $DISK"
  for p in $(lsblk -nrpo NAME "$DISK" | tail -n +2); do umount "$p" 2>/dev/null; done
  run wipefs -qa "$DISK"
  run sgdisk --zap-all "$DISK"
  local root_mib
  root_mib=$(( $(stat -c %s "$PAY/root.img") / 1048576 * 3 / 2 + 1024 ))   # room for updates
  [ "$root_mib" -lt "${ROOT_PART_MIB:-0}" ] && root_mib=$ROOT_PART_MIB
  run sgdisk -n1:0:+${ESP_MIB}M  -t1:ef00 -c1:ARC_ESP \
             -n2:0:+${root_mib}M -t2:8309 -c2:ARC_ROOT \
             -n3:0:0             -t3:8309 -c3:ARC_DATA "$DISK"
  partprobe "$DISK" 2>/dev/null; udevadm settle
  run mkfs.vfat -F 32 -n ARC_ESP "$(part "$DISK" 1)"

  progress 12 "Encrypting system partition"
  make_luks "$(part "$DISK" 2)" arcinst-root "$key_root" "$rec"
  progress 20 "Encrypting data partition"
  make_luks "$(part "$DISK" 3)" arcinst-data "$key_data" "$rec"

  write_root

  progress 75 "Creating data volume"
  run mkfs.ext4 -q -L ARC_DATA -m 1 /dev/mapper/arcinst-data
  mkdir -p "$MNT/data"; run mount /dev/mapper/arcinst-data "$MNT/data"
  mkdir -p "$MNT/data"/{games,config,saves}
  printf 'AUTOBOOT_GAME=\nAUTOBOOT_DELAY=3\n' > "$MNT/data/config/arcadeos.conf"
  chown -R "$ARC_UID:$ARC_UID" "$MNT/data"/{games,config,saves}
  sync; umount "$MNT/data"

  progress 80 "Installing boot loader"
  write_esp
  [ "${NO_SB:-0}" = 1 ] && note "Secure Boot setup skipped (--no-secureboot)." || enroll_secureboot

  cleanup
  echo "@@RECOVERY $(fmt_recovery "$rec")"
  progress 100 "Installation complete"
  echo "@@DONE"
}

do_update() {
  check_common
  has_arcadeos "$DISK" || fail "no ArcadeOS installation on $DISK"
  progress 10 "Unlocking system partition"
  local p2; p2=$(part "$DISK" 2)
  if ! "$HWID" root | cryptsetup open --key-file=- "$p2" arcinst-root 2>/dev/null; then
    [ -n "${RECOVERY:-}" ] || fail "hardware key rejected - this is a different/changed machine. Enter the recovery key."
    local rec; rec=$(printf '%s' "$RECOVERY" | tr -d ' -' | tr 'a-z' 'A-Z')
    printf '%s' "$rec" | cryptsetup open --key-file=- "$p2" arcinst-root || fail "recovery key rejected"
    # re-bind both volumes to the current hardware (adds a new HWID keyslot)
    cryptsetup luksAddKey --key-file=<(printf '%s' "$rec") "$p2" <("$HWID" root) \
      && note "System volume re-bound to this hardware."
    cryptsetup luksAddKey --key-file=<(printf '%s' "$rec") "$(part "$DISK" 3)" <("$HWID" data) \
      && note "Data volume re-bound to this hardware."
  fi
  write_root
  progress 80 "Updating boot loader"
  write_esp
  [ "${NO_SB:-0}" = 1 ] || { [ "$(efivar_byte SetupMode)" = 1 ] && enroll_secureboot; }
  cleanup
  progress 100 "Update complete (games and settings kept)"
  echo "@@DONE"
}

MODE=""; DISK=""; NO_SB=0; FORCE_WEAK=0; RECOVERY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --list-disks|--check-hwid|--install|--update) MODE=$1 ;;
    --disk) DISK=$2; shift ;;
    --no-secureboot) NO_SB=1 ;;
    --force-weak-hwid) FORCE_WEAK=1 ;;
    --recovery-key) RECOVERY=$2; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
trap cleanup EXIT

case "$MODE" in
  --list-disks) list_disks ;;
  --check-hwid) "$HWID" --check | awk '{print $1, $2}' ;;   # never print the values
  --install)    [ -n "$DISK" ] || fail "--disk required"; do_install ;;
  --update)     [ -n "$DISK" ] || fail "--disk required"; do_update ;;
  *) sed -n '2,8p' "$0"; exit 2 ;;
esac
