#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob
typeset fixture_root="$1" fixture_base="$2" fixture_backend="${3:-auto}" fixture_columns="${4:-110}"
source "$fixture_root/lib/curses.zsh"
ZCODER_CURSES=$fixture_backend zcoder_curses_load "$fixture_root" || exit 1
zmodload zsh/terminfo zsh/datetime zsh/mapfile zsh/files
for fixture_lib in util json skills transcript agent input terminal ui; do source "$fixture_root/lib/$fixture_lib.zsh"; done
typeset ZCODER_NAME=zcoder.zsh ZCODER_VERSION=preview ZCODER_MODEL=qwen3-coder ZCODER_PROFILE=coding
typeset ZCODER_WORKSPACE="$fixture_root" CURRENT_SESSION_ID=preview ZCODER_COMMAND_POLICY=ask
typeset INPUT_BUF='Review the changes.' REMOTE_MODE=local ZCODER_SYNC_OUTPUT=false
typeset -i INPUT_POS=${#INPUT_BUF}
typeset -a SESSION_IDS=(preview) SESSION_TITLES=('Edit previews') SESSION_MODELS=(qwen3-coder)
typeset patch=$'--- a/lib/remote.zsh\n+++ b/lib/remote.zsh\n@@ -51,4 +51,5 @@\n handle_connection() {\n-  old_request()\n+  new_request()\n+  poll_ready_sockets()\n   dispatch_request()\n }\n'
command stty rows 32 cols "$fixture_columns" </dev/tty || exit 1
trap 'ui_end' EXIT
ui_append_message user 'Show applied changes directly in the chat.'
zjson_quote "$patch"
transcript_tool_event begin apply_patch "{\"patch\":$REPLY}"
transcript_tool_event complete apply_patch '{}' 'Patch applied successfully.' 1 '' "$patch"
transcript_tool_event begin replace_text '{"path":"lib/tools.zsh","old_text":"timeout=0","new_text":"timeout=120"}'
transcript_tool_event complete replace_text '{}' 'Replaced one exact text occurrence.' 1 '' $'--- a/lib/tools.zsh\n+++ b/lib/tools.zsh\n@@ -18,1 +18,1 @@\n-timeout=0\n+timeout=120\n'
ui_set_status Ready
ui_init || exit 2
UI_AUTO_SCROLL=0; UI_SCROLL=0
ui_draw_chat
typeset -a geometry cell
typeset -i row col
typeset line='' all_text='' old_color='' new_color=''
zcoder_curses position chat_win geometry
for (( row=1; row<geometry[5]-1; row++ )); do
  line=''
  for (( col=1; col<geometry[6]-1; col++ )); do
    zcoder_curses move chat_win "$row" "$col"
    zcoder_curses querychar chat_win cell || exit 3
    line+="$cell[1]"
  done
  if [[ "$line" == *old_request* ]]; then old_color="$cell[2]"; fi
  if [[ "$line" == *new_request* ]]; then new_color="$cell[2]"; fi
  all_text+="$line"$'\n'
done
[[ "$all_text" == *old_request* && "$all_text" == *new_request* && "$all_text" == *timeout=120* ]] || exit 4
if [[ $fixture_backend == auto && $UI_COLOR_MODE != mono ]]; then
  [[ -n "$old_color" && -n "$new_color" && "$old_color" != "$new_color" ]] || exit 5
fi
if [[ $fixture_backend == auto ]]; then
  source "$fixture_root/vendor/zdraw/lib/zdraw-fixture.zsh"
  typeset zdraw_ui_fixture
  zdraw-fixture chat_win || exit 6
  print -r -- "$zdraw_ui_fixture" > "$fixture_base.json"
fi
# Exercise a viewport starting inside a change, then its collapsed state.
UI_SCROLL=5
ui_draw_chat
UI_BLOCK_OPEN[2]=0; transcript_changed 2
ui_draw_chat
[[ "${(j: :)UI_LINES}" != *old_request* ]] || exit 7
ui_end
print -rn -- 1 > "$fixture_base.done"
