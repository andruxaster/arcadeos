#!/bin/bash
# ArcadeOS build: ./build.sh [stage...]
#   stages: keys rootfs image boot installer   (default: all)
set -euo pipefail
cd "$(dirname "$0")"

declare -A STAGE=(
  [keys]=build/00-keys.sh
  [rootfs]=build/10-rootfs.sh
  [image]=build/20-image.sh
  [boot]=build/30-boot.sh
  [installer]=build/40-installer.sh
)
ORDER=(keys rootfs image boot installer)

[ $# -eq 0 ] && set -- "${ORDER[@]}"
for s in "$@"; do
  [ -n "${STAGE[$s]:-}" ] || { echo "unknown stage: $s (use: ${ORDER[*]})" >&2; exit 1; }
done
for s in "$@"; do
  printf '\n\033[1;35m### stage: %s\033[0m\n' "$s"
  bash "${STAGE[$s]}"
done
