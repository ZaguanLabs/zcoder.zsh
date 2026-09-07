#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob
typeset -g fixture_root=$1 fixture_base=$2
if [[ ${3:-} == auto ]]; then
  source "$fixture_root/lib/curses.zsh"
  ZCODER_CURSES=auto zcoder_curses_load "$fixture_root" || exit 1
elif [[ -n ${3:-} ]]; then
  module_path=("$3" $module_path)
fi
zmodload zsh/curses zsh/terminfo zsh/datetime zsh/mapfile || exit 1
typeset -gi fixture_geometry_calls=0
zcurses() {
  [[ $1 == geometry ]] && (( fixture_geometry_calls++ ))
  builtin zcurses "$@"
}
for fixture_lib in util json transcript input terminal ui; do
  source "$fixture_root/lib/$fixture_lib.zsh"
done
typeset -g ZCODER_NAME=zcoder ZCODER_VERSION=test ZCODER_MODEL=fixture
typeset -g ZCODER_WORKSPACE=$fixture_root OLLAMA_HOST=fixture ZCODER_PROFILE=coding REMOTE_MODE=local
typeset -g ZCODER_SYNC_OUTPUT=false
typeset -gx RESIZE_REAL_STTY=${commands[stty]} RESIZE_STTY_LOG=$fixture_base.stty
mkdir -p "$fixture_base.bin"
print -r -- '#!/bin/sh
printf "%s\n" "$*" >> "$RESIZE_STTY_LOG"
exec "$RESIZE_REAL_STTY" "$@"' > "$fixture_base.bin/stty"
chmod +x "$fixture_base.bin/stty"
path=("$fixture_base.bin" $path)
"$RESIZE_REAL_STTY" rows 24 cols 80 </dev/tty || exit 1
trap 'ui_end' EXIT
ui_init || exit 1
mapfile[$fixture_base.initial]="$UI_NATIVE_GEOMETRY"
typeset -a fixture_sizes=() fixture_native=()
typeset -i fixture_h fixture_w
for fixture_h fixture_w in 40 120 20 60 40 120; do
  "$RESIZE_REAL_STTY" rows "$fixture_h" cols "$fixture_w" </dev/tty || exit 1
  UI_RESIZE_PENDING=1
  ui_poll_resize
  fixture_sizes+=("$SCREEN_H" "$SCREEN_W")
done
# Polling unchanged dimensions still queries the selected backend.
UI_RESIZE_PENDING=1
ui_poll_resize
fixture_native+=("$UI_NATIVE_GEOMETRY")
ui_end
ui_init || exit 1
UI_RESIZE_PENDING=1
ui_poll_resize
fixture_native+=("$UI_NATIVE_GEOMETRY")
ui_end
mapfile[$fixture_base.sizes]="${(j.:.)fixture_sizes}"
mapfile[$fixture_base.native]="${(j.:.)fixture_native}"
mapfile[$fixture_base.probes]="$fixture_geometry_calls"
mapfile[$fixture_base.done]=1
