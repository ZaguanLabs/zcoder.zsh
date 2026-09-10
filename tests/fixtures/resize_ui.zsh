#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob
typeset -g fixture_root=$1 fixture_base=$2
typeset -g ZCODER_HOME="$fixture_base.home"
source "$fixture_root/lib/curses.zsh"
if [[ ${3:-} == auto ]]; then
  ZCODER_CURSES=auto zcoder_curses_load "$fixture_root" || exit 1
elif [[ -n ${3:-} ]]; then
  module_path=("$3" $module_path)
  zmodload zdraw || exit 1
  ZCODER_CURSES_MODULE=zdraw ZCODER_CURSES_COMMAND=zdraw
else
  ZCODER_CURSES=stock zcoder_curses_load "$fixture_root" || exit 1
fi
zmodload zsh/terminfo zsh/datetime zsh/mapfile zsh/system zsh/files || exit 1
typeset -gi fixture_geometry_calls=0
zcoder_curses() {
  [[ $1 == geometry ]] && (( fixture_geometry_calls++ ))
  builtin "$ZCODER_CURSES_COMMAND" "$@"
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
command chmod +x "$fixture_base.bin/stty"
path=("$fixture_base.bin" $path)
"$RESIZE_REAL_STTY" rows 24 cols 80 </dev/tty || exit 1
[[ ${4:-} == restore ]] && "$RESIZE_REAL_STTY" rows 24 cols 120 </dev/tty
trap 'ui_end' EXIT
input_insert 'preserved draft'
ui_append_message assistant "${(pl:220::word :)}"
ui_init || exit 1
if [[ ${4:-} == restore ]]; then
  mapfile[$fixture_base.restored]="$UI_SIDEBAR_HIDDEN:$SIDE_W"
  ui_toggle_sidebar
  # Automatic hiding before exit must not replace the explicit choice.
  "$RESIZE_REAL_STTY" rows 24 cols 60 </dev/tty || exit 1
  UI_RESIZE_PENDING=1
  ui_poll_resize
  ui_end
  mapfile[$fixture_base.done]=1
  exit 0
fi
mapfile[$fixture_base.initial_preference]="$([[ -e $ZCODER_HOME/ui-preferences ]] && print 1 || print 0)"
mapfile[$fixture_base.initial]="$UI_NATIVE_GEOMETRY"
# Read the real shortcut from the PTY, then exercise the busy-input path.
typeset -g fixture_ch='' fixture_key='' fixture_mouse=''
zcoder_curses timeout input_win 2000
terminal_read_event input_win fixture_ch fixture_key fixture_mouse
ui_activity_begin
ui_activity_input "$fixture_ch" "$fixture_key"
mapfile[$fixture_base.hidden]="$UI_SIDEBAR_HIDDEN:$SIDE_W:$INPUT_BUF:$INPUT_POS"
typeset -a fixture_sizes=() fixture_native=() fixture_widths=() fixture_position=()
typeset -i fixture_h fixture_w
for fixture_h fixture_w in 40 120 20 60 40 120; do
  "$RESIZE_REAL_STTY" rows "$fixture_h" cols "$fixture_w" </dev/tty || exit 1
  UI_RESIZE_PENDING=1
  ui_poll_resize
  fixture_sizes+=("$SCREEN_H" "$SCREEN_W")
  zcoder_curses position chat_win fixture_position
  fixture_widths+=("$SIDE_W" "${fixture_position[6]}")
done
mapfile[$fixture_base.widths]="${(j.:.)fixture_widths}"
typeset -i fixture_full_lines=${#UI_LINES}
ui_activity_input $'\x02' ''
zcoder_curses position chat_win fixture_position
mapfile[$fixture_base.shown]="$SIDE_W:${fixture_position[6]}:$(( ${#UI_LINES} > fixture_full_lines ))"
ui_activity_end
UI_FOCUS=sidebar
ui_toggle_sidebar
mapfile[$fixture_base.focus]="$UI_FOCUS:$INPUT_BUF:$INPUT_POS"
ui_editor_input $'\b' ''
mapfile[$fixture_base.backspace]="$UI_SIDEBAR_HIDDEN:$INPUT_BUF"
# Polling unchanged dimensions still queries the selected backend.
UI_RESIZE_PENDING=1
ui_poll_resize
fixture_native+=("$UI_NATIVE_GEOMETRY")
ui_end
ui_init || exit 1
mapfile[$fixture_base.reentry]="$UI_SIDEBAR_HIDDEN:$SIDE_W"
UI_RESIZE_PENDING=1
ui_poll_resize
fixture_native+=("$UI_NATIVE_GEOMETRY")
ui_end
mapfile[$fixture_base.sizes]="${(j.:.)fixture_sizes}"
mapfile[$fixture_base.native]="${(j.:.)fixture_native}"
mapfile[$fixture_base.probes]="$fixture_geometry_calls"
mapfile[$fixture_base.done]=1
