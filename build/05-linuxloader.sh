#!/bin/bash
# Stage 05: build linuxloader from the git submodule (vendor/linuxloader).
#
# Mirrors upstream CI (.github/workflows/linux-build.yml): Ubuntu 22.04 chroot,
# 32-bit SDL3 / SDL3_ttf / SDL3_image / FAudio from source, then
# scripts/linux/make-linux.sh. Result: work/linuxloader-dist/
#   linuxloader, ll-deps/ (+ SDL3 libs), LICENSE-NOTICE
#
# Linux Loader (c) Linux Loader Development Team, CC BY-NC-SA 4.0.
# Non-commercial use only - see THIRD_PARTY.md.
. "$(dirname "$0")/lib.sh"
need_root
need_cmd debootstrap git

LLSRC="$SRC_DIR/vendor/linuxloader"
[ -f "$LLSRC/CMakeLists.txt" ] || die "submodule missing: run  git submodule update --init"

BCH="$WORK/llbuild"          # build chroot
DIST="$WORK/linuxloader-dist"
REV=$(git -C "$LLSRC" describe --tags --always --dirty 2>/dev/null || echo unknown)

trap 'chroot_umount "$BCH"' EXIT

# --- build chroot (reused between runs) -------------------------------------
if [ ! -f "$BCH/.arcadeos-ready" ]; then
  log "debootstrap $LL_BUILD_SUITE (build environment for linuxloader)"
  chroot_umount "$BCH" 2>/dev/null || true
  rm -rf "$BCH"; mkdir -p "$BCH"
  script=/usr/share/debootstrap/scripts/$LL_BUILD_SUITE
  [ -e "$script" ] || script=/usr/share/debootstrap/scripts/gutsy   # all Ubuntu suites use it
  debootstrap --variant=minbase --arch=amd64 --components=main,universe \
    "$LL_BUILD_SUITE" "$BCH" "$LL_BUILD_MIRROR" "$script"
  cat > "$BCH/etc/apt/sources.list" <<EOF
deb $LL_BUILD_MIRROR $LL_BUILD_SUITE main universe
deb $LL_BUILD_MIRROR $LL_BUILD_SUITE-updates main universe
EOF
  printf '#!/bin/sh\nexit 101\n' > "$BCH/usr/sbin/policy-rc.d"; chmod +x "$BCH/usr/sbin/policy-rc.d"
  touch "$BCH/.arcadeos-bootstrapped"
fi

chroot_mount "$BCH"
cp -L /etc/resolv.conf "$BCH/etc/resolv.conf" 2>/dev/null || true
# upstream scripts call sudo, which wants to resolve the host name
printf '127.0.0.1 localhost %s\n' "$(hostname)" > "$BCH/etc/hosts"
bch() { chroot "$BCH" /usr/bin/env -i HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin \
          LANG=C.UTF-8 DEBIAN_FRONTEND=noninteractive \
          http_proxy="${http_proxy:-}" https_proxy="${https_proxy:-}" \
          HTTP_PROXY="${HTTP_PROXY:-}" HTTPS_PROXY="${HTTPS_PROXY:-}" "$@"; }

if [ ! -f "$BCH/.arcadeos-ready" ]; then
  log "installing build dependencies (upstream install-packages.sh)"
  bch dpkg --add-architecture i386
  bch apt-get update
  bch apt-get install -y --no-install-recommends sudo ca-certificates git cmake
  # upstream script uses sudo + apt; run it as-is so we track their dependency list
  install -m 755 "$LLSRC/scripts/appimage/install-packages.sh" "$BCH/root/install-packages.sh"
  bch bash -c 'cd /root && ./install-packages.sh'

  log "building 32-bit SDL3, SDL3_ttf, SDL3_image, FAudio (upstream build-deps.sh)"
  install -m 755 "$LLSRC/scripts/appimage/build-deps.sh" "$BCH/root/build-deps.sh"
  # upstream script has no "set -e": force it, otherwise failures go unnoticed
  bch bash -c 'cd /root && rm -rf build-deps build linuxloader.AppDir && bash -e ./build-deps.sh' \
    || die "building SDL3/FAudio failed (see output above)"
  bch bash -c 'ls /usr/lib/libSDL3.so* /usr/lib/*/libSDL3.so* /usr/local/lib/libSDL3.so* 2>/dev/null | grep -q .' \
    || die "SDL3 was not installed in the build chroot"
  touch "$BCH/.arcadeos-ready"
fi

# --- build linuxloader --------------------------------------------------------
log "building linuxloader $REV"
rm -rf "$BCH/root/linuxloader"
mkdir -p "$BCH/root/linuxloader"
# copy without .git (a submodule's .git is a pointer file)
tar -C "$LLSRC" --exclude=.git --exclude=build-linux --exclude=build-win32 -cf - . \
  | tar -C "$BCH/root/linuxloader" -xf -

# version.h from the changelog, exactly like upstream CI does
# (sed, not gawk-only awk: Debian's default awk is mawk)
VER=$(sed -n 's/^## \[\([^]]*\)\].*/\1/p' "$LLSRC/docs/changelog" | head -n1)
if [ -n "$VER" ]; then
  IFS=. read -r MA MI UP <<<"$VER"
  VH="$BCH/root/linuxloader/src/loader/version.h"
  sed -i "s/\(#define MAJOR_VERSION \).*/\1$MA/;s/\(#define MINOR_VERSION \).*/\1$MI/;s/\(#define UPDATE_VERSION \).*/\1${UP:-0}/" "$VH"
fi

bch bash -c 'cd /root/linuxloader && bash -e scripts/linux/make-linux.sh' \
  || die "linuxloader build failed (see output above)"
TGZ="$BCH/root/linuxloader/linuxloader-linux.tar.gz"
[ -f "$TGZ" ] || die "linuxloader build did not produce linuxloader-linux.tar.gz"

rm -rf "$DIST"; mkdir -p "$DIST"
tar -xzf "$TGZ" -C "$DIST"
[ -x "$DIST/linuxloader" ] || die "no linuxloader binary in build output"

# upstream's tarball expects SDL3 on the system; ship it in ll-deps instead
log "adding SDL3 runtime libraries to ll-deps"
n=0
while read -r f; do
  cp -a "$f" "$DIST/ll-deps/" && n=$((n + 1))
done < <(find "$BCH/usr/lib" "$BCH/usr/local/lib" \( -name 'libSDL3*.so*' \) 2>/dev/null)
[ "$n" -gt 0 ] || die "SDL3 libraries not found in build chroot"

# 32-bit check: is everything resolvable inside the build chroot?
log "checking library dependencies"
rm -rf "$BCH/tmp/lldist"; cp -a "$DIST" "$BCH/tmp/lldist"
missing=$(bch bash -c 'cd /tmp/lldist && for f in linuxloader ll-deps/*.so*; do
            LD_LIBRARY_PATH=/tmp/lldist/ll-deps ldd "$f" 2>/dev/null; done' \
          | awk '/not found/ {print $1}' | sort -u | tr '\n' ' ')
rm -rf "$BCH/tmp/lldist"
[ -z "$missing" ] || warn "unresolved even in build env: $missing"

cat > "$DIST/LICENSE-NOTICE" <<EOF
Linux Loader (linuxloader) $REV
Copyright (c) Linux Loader Development Team
https://github.com/lindbergh-loader/linuxloader

Licensed under Creative Commons Attribution-NonCommercial-ShareAlike 4.0
International (CC BY-NC-SA 4.0): https://creativecommons.org/licenses/by-nc-sa/4.0/

Built unmodified from the upstream source by ArcadeOS.
NOT for pay-to-play, subscription or any other commercial use without prior
consent of the Linux Loader Development Team.
Bundled third-party libraries in ll-deps/ remain under their own licenses.
EOF
echo "$REV" > "$DIST/VERSION"
log "linuxloader $REV ready in $DIST ($(du -sh "$DIST" | cut -f1))"
