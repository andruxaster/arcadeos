# shellcheck shell=bash
# Shared definitions for ArcadeOS launcher scripts.

ARC_HOME=/opt/arcadeos
ARC_LOADER="$ARC_HOME/linuxloader"
ARC_DATA=/data
ARC_GAMES="$ARC_DATA/games"
ARC_CONF="$ARC_DATA/config/arcadeos.conf"

# Defaults; overridden by $ARC_CONF
AUTOBOOT_GAME=""
AUTOBOOT_DELAY=3

load_arc_conf() {
  # shellcheck source=/dev/null
  [ -r "$ARC_CONF" ] && . "$ARC_CONF"
  return 0
}

save_arc_conf() {
  mkdir -p "$(dirname "$ARC_CONF")"
  {
    echo "# ArcadeOS settings (written by the launcher)"
    printf 'AUTOBOOT_GAME=%q\n'  "$AUTOBOOT_GAME"
    printf 'AUTOBOOT_DELAY=%q\n' "$AUTOBOOT_DELAY"
  } > "$ARC_CONF.tmp" && mv "$ARC_CONF.tmp" "$ARC_CONF"
}

valid_id() { [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]]; }

# load_game <id>  -> sets NAME PLATFORM GAMEPATH ELF ARGS GAME_DIR ELF_DIR
load_game() {
  local id=$1
  valid_id "$id" || return 1
  GAME_DIR="$ARC_GAMES/$id"
  [ -r "$GAME_DIR/game.conf" ] || return 1
  NAME="$id"; PLATFORM="lindbergh"; GAMEPATH="."; ELF=""; ARGS=""
  # shellcheck source=/dev/null
  . "$GAME_DIR/game.conf"
  ELF_DIR="$GAME_DIR/$GAMEPATH"
}

# list_games -> fills GAME_IDS[] and GAME_NAMES[]
list_games() {
  GAME_IDS=(); GAME_NAMES=()
  local d id
  for d in "$ARC_GAMES"/*/; do
    [ -r "$d/game.conf" ] || continue
    id=$(basename "$d")
    valid_id "$id" || continue
    GAME_IDS+=("$id")
    GAME_NAMES+=("$(NAME=$id; . "$d/game.conf" 2>/dev/null; echo "$NAME")")
  done
}
