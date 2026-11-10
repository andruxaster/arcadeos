#!/bin/bash
# Stage 00: own Secure Boot keys (PK/KEK/db) + MOK key for kernel modules.
# Keys are created once and reused; delete $KEYS to start over
# (then every installed machine must be re-enrolled).
. "$(dirname "$0")/lib.sh"
need_cmd openssl cert-to-efi-sig-list sign-efi-sig-list uuidgen

mkdir -p "$KEYS" && chmod 700 "$KEYS"
cd "$KEYS" || exit 1

[ -f GUID.txt ] || uuidgen --random > GUID.txt
GUID=$(cat GUID.txt)

mkkey() { # name cn
  [ -f "$1.key" ] && return 0
  log "generating $1 key"
  openssl req -new -x509 -newkey rsa:2048 -sha256 -days 7300 -nodes \
    -subj "/CN=$2/" -keyout "$1.key" -out "$1.crt" 2>/dev/null
  openssl x509 -in "$1.crt" -outform DER -out "$1.der"
  chmod 600 "$1.key"
}
mkkey PK  "$SB_KEY_CN Platform Key"
mkkey KEK "$SB_KEY_CN Key Exchange Key"
mkkey db  "$SB_KEY_CN Signature Database"
mkkey MOK "$SB_KEY_CN Module Signing"   # signs nvidia.ko (DKMS)

log "building EFI signature lists"
for k in PK KEK db; do
  cert-to-efi-sig-list -g "$GUID" "$k.crt" "$k.esl"
done

cp db.esl db-all.esl
if [ "${SB_MS_UEFI_CA:-0}" = 1 ]; then
  mkdir -p ms
  MS_GUID="77fa9abd-0359-4d32-bd60-28f4e78f784b"
  i=0
  for url in "${SB_MS_CERT_URLS[@]}"; do
    i=$((i+1))
    f="ms/ms-uefi-ca-$i.der"
    if [ ! -s "$f" ]; then
      log "downloading Microsoft UEFI CA ($url)"
      wget -q -O "$f" "$url" || die "download failed; put the cert manually into $KEYS/$f"
    fi
    openssl x509 -inform DER -in "$f" -out "ms/ms-uefi-ca-$i.crt"
    cert-to-efi-sig-list -g "$MS_GUID" "ms/ms-uefi-ca-$i.crt" "ms/ms-uefi-ca-$i.esl"
    cat "ms/ms-uefi-ca-$i.esl" >> db-all.esl
  done
  warn "db includes Microsoft UEFI CA (SB_MS_UEFI_CA=1)"
fi

log "signing authenticated variables"
TS=$(date -u +"%Y-%m-%d %H:%M:%S")
sign-efi-sig-list -t "$TS" -g "$GUID" -k PK.key  -c PK.crt  PK  PK.esl     PK.auth
sign-efi-sig-list -t "$TS" -g "$GUID" -k PK.key  -c PK.crt  KEK KEK.esl    KEK.auth
sign-efi-sig-list -t "$TS" -g "$GUID" -k KEK.key -c KEK.crt db  db-all.esl db.auth

log "keys ready in $KEYS  (back this directory up, keep it offline)"
