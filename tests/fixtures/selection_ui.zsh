#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob
zmodload zsh/terminfo zsh/datetime
root=$1 report_fd=$2 control_fd=$3 backend=${4:-auto}
for lib in util json transcript input terminal skills ui overlays; do source "$root/lib/$lib.zsh"; done
ZCODER_CURSES=$backend zcoder_curses_load "$root" || exit 1
ZCODER_NAME=zcoder ZCODER_VERSION=test ZCODER_MODEL=fixture
ZCODER_WORKSPACE=$root OLLAMA_HOST=fixture ZCODER_PROFILE=coding REMOTE_MODE=local
ZCODER_SYNC_OUTPUT=false ZCODER_COMMAND_POLICY=ask STATE_ENABLED=0
ZCODER_HOME=${TMPDIR:-/tmp}/zcoder-selection-no-preferences
INPUT_BUF='unfinished draft'; INPUT_POS=${#INPUT_BUF}
typeset sample=$'**Alpha beta gamma** delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau.\n\n```zsh\n  print -r -- "hello"\n    next line\n```\n\nWide 界 combining é emoji 👩‍💻.'
ui_append_message assistant "$sample"
trap 'ui_end' EXIT
ui_init || exit 2
UI_AUTO_SCROLL=0 UI_SCROLL=0; ui_draw_chat
function _selection_modal_input {
  [[ $modal_ch == q ]] && modal_done=1
  return 0
}
function report {
  local REPLY result='' value n
  ui_selection_get || true
  zjson_quote "$REPLY"; result="{\"text\":$REPLY"
  for value in enabled selected active valid; do
    case $value in enabled) n=$UI_SELECTION_ENABLED ;; *) n=${zdraw_text_selection[$value]:-0} ;; esac
    result+=",\"$value\":$n"
  done
  result+=",\"activity_result\":${activity_result:-0},\"width\":$SCREEN_W,\"height\":$SCREEN_H,\"side\":$SIDE_W,\"scroll\":$UI_SCROLL,\"rows\":["
  for (( n=1; n<=${#UI_COPY_TEXTS}; n++ )); do
    (( n>1 )) && result+=,
    zjson_quote "$UI_COPY_TEXTS[n]"
    result+="{\"text\":$REPLY,\"col\":${UI_COPY_COLUMNS[n]:--1},\"y\":$((TOP_H+n-UI_SCROLL))"
    zjson_quote "$UI_COPY_GAPS[n]"; result+=",\"gap\":$REPLY}"
  done
  result+=']'
  if [[ $control == snapshot && $ZCODER_CURSES_COMMAND == zdraw ]]; then
    local -A snapshot
    local win entry
    for win in chat_win side_win input_win; do
      zcoder_curses snapshot "$win" snapshot || continue
      result+=",\"$win\":{"
      local -i sep=0
      for entry in "${(@ok)snapshot}"; do
        (( sep )) && result+=,
        zjson_quote "$entry"; result+="$REPLY:"
        zjson_quote "$snapshot[$entry]"; result+=$REPLY
        sep=1
      done
      result+='}'
    done
  fi
  result+='}'
  print -r -u "$report_fd" -- "$result"
}
local_ch='' local_key='' local_mouse='' control=''
while true; do
  report
  IFS= read -r -u "$control_fd" control || break
  [[ $control == quit ]] && break
  if [[ $control == append ]]; then
    UI_CONTENTS[1]+=$'\nNew streaming output.'; transcript_changed 1; ui_draw_chat
  elif [[ $control == modal ]]; then
    ui_modal_run 'Selection test' ui_modal_frame _selection_modal_input 8 30
  elif [[ $control == code ]]; then
    ui_selection_cancel
    transcript_reset
    ui_append_message assistant $'```zsh\n'"${(l:5000::x:)${:-}}"$'\n界\tX\tY\n```'
    transcript_changed 1; UI_AUTO_SCROLL=0 UI_SCROLL=0; ui_draw_chat
  elif [[ $control == diff ]]; then
    ui_selection_cancel
    transcript_reset
    transcript_tool_event begin apply_patch '{}'
    transcript_tool_event complete apply_patch '{}' '' 1 '' $'--- a/demo.zsh\n+++ b/demo.zsh\n@@ -1,2 +1,2 @@\n-old text\n+new text\n context'
    UI_AUTO_SCROLL=0 UI_SCROLL=0; ui_draw_chat
  elif [[ $control == activity ]]; then
    ui_poll_activity 0; activity_result=$?
  elif [[ $control == scroll ]]; then
    ui_selection_cancel; UI_AUTO_SCROLL=0; (( UI_SCROLL++ )); ui_draw_chat
  elif [[ $control == reset ]]; then
    ui_selection_cancel; UI_AUTO_SCROLL=0 UI_SCROLL=0; ui_draw_chat
  elif [[ $control == (check|snapshot) ]]; then
    :
  else
    ui_poll_resize
    zcoder_curses timeout input_win 100
    terminal_read_event input_win local_ch local_key local_mouse
    [[ $local_key == RESIZE ]] && { UI_RESIZE_PENDING=1; ui_poll_resize; }
    [[ $local_ch == $'\x19' ]] && ui_copy_view
  fi
done
