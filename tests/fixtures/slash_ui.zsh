#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob
typeset -g fixture_root=$1 fixture_base=$2
source "$fixture_root/lib/curses.zsh"
ZCODER_CURSES=${3:-stock} zcoder_curses_load "$fixture_root" || exit 1
zmodload zsh/terminfo zsh/datetime zsh/mapfile || exit 1
for fixture_lib in util json transcript input terminal ui commands; do
  source "$fixture_root/lib/$fixture_lib.zsh"
done
typeset -g ZCODER_NAME=zcoder ZCODER_VERSION=test ZCODER_MODEL=fixture
typeset -g ZCODER_WORKSPACE=$fixture_root OLLAMA_HOST=fixture ZCODER_PROFILE=coding REMOTE_MODE=local
typeset -g ZCODER_SYNC_OUTPUT=false
command stty rows 24 cols 100 </dev/tty || exit 1
trap 'ui_end' EXIT
ui_append_message assistant 'The transcript stays visible above the command suggestions.'
ui_init || exit 1
mapfile[$fixture_base.tty]=$TTY
typeset -g fixture_ch='' fixture_key='' fixture_mouse='' fixture_label=''
typeset -a fixture_cell=() fixture_cursor=()
while true; do
  ui_poll_resize
  if (( UI_SLASH_ROWS > 0 )); then
    # Check the selected marker in the actual curses window, then restore the
    # cursor so observing the fixture does not alter the next editor frame.
    zcoder_curses position input_win fixture_cursor
    zcoder_curses move input_win $(( INPUT_VISIBLE_ROWS + 2 + (UI_SLASH_SELECTED > UI_SLASH_ROWS - 1 ? UI_SLASH_ROWS - 2 : UI_SLASH_SELECTED - 1) )) 2
    zcoder_curses querychar input_win fixture_cell
    zcoder_curses move input_win "$fixture_cursor[1]" "$fixture_cursor[2]"
    mapfile[$fixture_base.marker]=${fixture_cell[1]}
    fixture_label=${UI_SLASH_TEXTS[UI_SLASH_SELECTED]}
  else
    fixture_label=''
  fi
  mapfile[$fixture_base.state]="$INPUT_BUF:$UI_SLASH_ROWS:$fixture_label:$SCREEN_W:$SCREEN_H"
  zcoder_curses timeout input_win 100
  terminal_read_event input_win fixture_ch fixture_key fixture_mouse
  [[ "$fixture_ch" == $'\x04' ]] && break
  if [[ "$fixture_key" == RESIZE ]]; then UI_RESIZE_PENDING=1; continue; fi
  ui_slash_input "$fixture_ch" "$fixture_key" && continue
  [[ -z "$fixture_ch$fixture_key" ]] && continue
  if input_decode_terminal_event "$fixture_ch" "$fixture_key"; then
    if [[ "$INPUT_EVENT_ACTION" == paste || "$INPUT_EVENT_ACTION" == newline ]]; then
      [[ "$INPUT_EVENT_ACTION" == newline ]] && INPUT_EVENT_TEXT=$'\n'
      input_insert "$INPUT_EVENT_TEXT"; ui_input_changed
    fi
  else
    ui_editor_input "$fixture_ch" "$fixture_key" || true
  fi
done
ui_end
mapfile[$fixture_base.done]=1
