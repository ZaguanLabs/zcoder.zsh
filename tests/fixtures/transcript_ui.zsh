#!/usr/bin/env zsh
# Real curses/input fixture, controlled only through its PTY and private files.
emulate -R zsh
setopt extendedglob
zmodload zsh/curses zsh/terminfo zsh/datetime zsh/mapfile || exit 1
typeset -g fixture_root="$1" fixture_base="$2"
source "$fixture_root/lib/util.zsh"
source "$fixture_root/lib/json.zsh"
source "$fixture_root/lib/transcript.zsh"
source "$fixture_root/lib/input.zsh"
source "$fixture_root/lib/terminal.zsh"
source "$fixture_root/lib/ui.zsh"
typeset -g ZCODER_NAME=zcoder ZCODER_VERSION=test ZCODER_MODEL=fixture
typeset -g ZCODER_WORKSPACE="$fixture_root" OLLAMA_HOST=fixture
typeset -gi fixture_events=0
typeset -g fixture_ch="" fixture_key="" fixture_mouse=""
command stty rows 24 cols 80 < /dev/tty || exit 1
trap 'ui_end' EXIT
transcript_tool_event begin read_file '{"path":"example.zsh"}'
transcript_tool_event complete read_file '{}' 'PTY tool result' 1
ui_append_message assistant 'PTY assistant body' 'PTY private reasoning'
ui_append_message assistant 'PTY final entry'
UI_FOCUS=chat; UI_SELECTED_EVENT=1; UI_AUTO_SCROLL=0
ui_init || exit 1
typeset -a fixture_headers=("${(@M)UI_LINES:#*Assistant  *}")
mapfile[${fixture_base}.headers]=${#fixture_headers}
mapfile[${fixture_base}.ready]=1
while true; do
  fixture_ch=""; fixture_key=""; fixture_mouse=""
  zcurses timeout input_win 100
  terminal_read_event input_win fixture_ch fixture_key fixture_mouse || continue
  [[ "$fixture_ch" == q ]] && break
  if [[ "$fixture_ch" == $'\x12' ]]; then
    ui_toggle_reasoning
  elif [[ "$fixture_ch" == w ]]; then
    command stty cols 60 < /dev/tty
    UI_RESIZE_PENDING=1
    ui_poll_resize
  elif ! ui_chat_input "$fixture_ch" "$fixture_key"; then
    continue
  fi
  (( fixture_events++ ))
  mapfile[${fixture_base}.rendered]="${(F)UI_LINES}"
  mapfile[${fixture_base}.state]="${fixture_events}:${UI_SELECTED_EVENT}:${UI_BLOCK_OPEN[1]}:${UI_REASONING_OPEN[2]}:${SCREEN_W}:${UI_IDS[UI_SELECTED_EVENT]}"
done
ui_end
mapfile[${fixture_base}.done]=1
