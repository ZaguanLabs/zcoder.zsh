#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob
zmodload zsh/terminfo zsh/datetime zsh/mapfile zsh/system zsh/stat zsh/files zsh/net/tcp zsh/zselect
typeset fixture_root=$1 fixture_base=$2 fixture_backend=$3 ZCODER_WORKSPACE=$4
typeset ZCODER_DIR=$fixture_root ZCODER_HOME=$fixture_base.home ZCODER_CURSES=$fixture_backend
typeset ZCODER_NAME=zcoder ZCODER_VERSION=test ZCODER_MODEL=fixture ZCODER_PROFILE=coding
typeset OLLAMA_HOST=fixture REMOTE_MODE=local ZCODER_COMMAND_POLICY=ask ZCODER_WARMUP=false
typeset -gi RUNNING=1 STATE_ENABLED=0 REMOTE_HANDSHAKE_PENDING=0
if [[ $fixture_backend == remote ]]; then ZCODER_CURSES=auto; fi
source "$fixture_root/lib/curses.zsh"
zcoder_curses_load "$fixture_root" || exit 1
for library in util json transcript input terminal ui overlays commands command_dispatch tui; do
  source "$fixture_root/lib/$library.zsh" || exit 1
done
if [[ $fixture_backend == remote ]]; then
  source "$fixture_root/lib/http.zsh"
  source "$fixture_root/lib/remote.zsh"
  REMOTE_MODE=client
  REMOTE_DOCUMENTS_SUPPORTED=true
  REMOTE_ENDPOINT=$(<"${fixture_base:h}/endpoint")
  REMOTE_TOKEN=fixture-document-token
  # This path deliberately does not exist locally. Only the server owns files.
  ZCODER_WORKSPACE=/remote-only-workspace
  remote_client_model_poll() { return 0; }
fi
typeset -g zdraw_ui_fixture=''
if [[ $ZCODER_CURSES_COMMAND == zdraw ]]; then
  source "$fixture_root/vendor/zdraw/lib/zdraw-fixture.zsh"
fi
state_init() { return 0; }
agent_warmup_start() { return 0; }
agent_warmup_poll() { return 0; }
zcoder_require() { return 0; }
relay_start() { return 0; }
agent_user_turn() { fixture_publish turn unexpected; }
zcoder_refresh_sessions() { return 0; }
fixture_publish() {
  print -rn -- "$2" > "$fixture_base.$1.tmp"
  zf_mv -f -- "$fixture_base.$1.tmp" "$fixture_base.$1"
}
functions[_fixture_terminal_read]=$functions[terminal_read_event]
terminal_read_event() {
  if [[ -f $fixture_base.stop ]]; then
    RUNNING=0
  elif [[ -f $fixture_base.activity ]]; then
    (( UI_ACTIVITY_DEPTH > 0 )) || UI_ACTIVITY_DEPTH=1
    if (( ! ${UI_MODAL_ACTIVE:-0} )) && [[ -f $fixture_base.approval && ! -f $fixture_base.decision ]]; then
      fixture_publish state approval:
      ui_confirm_command 'echo approval-required'
      fixture_publish decision "$REPLY"
    fi
  fi
  if (( ! ${UI_MODAL_ACTIVE:-0} )); then
    if [[ $ZCODER_CURSES_COMMAND == zdraw && $UI_DOCUMENT_TAB == 4 && ! -f $fixture_base.capture-$SCREEN_W ]]; then
      zdraw-fixture chat_win || exit 20
      fixture_publish "capture-$SCREEN_W" "$zdraw_ui_fixture"
    fi
    fixture_publish lines "${(F)UI_DOCUMENT_LINES}"
    fixture_publish renderer "$ZCODER_CURSES_COMMAND:$UI_MARKDOWN_BACKEND"
    if [[ $ZCODER_CURSES_COMMAND == zdraw ]]; then
      local -A tab_snapshot
      local header_text=''
      local -i header_column
      zdraw snapshot chat_win tab_snapshot || exit 21
      for (( header_column=0; header_column<tab_snapshot[columns]; header_column++ )); do
        header_text+=${tab_snapshot[0,$header_column,text]}
      done
      fixture_publish header "$header_text"
    fi
    fixture_publish geometry "$SCREEN_W:$SCREEN_H"
    fixture_publish tty "$TTY"
    fixture_publish loading "$UI_DOCUMENT_LOADING"
    fixture_publish count "${#UI_DOCUMENT_PATHS}"
    [[ -z $UI_NOTICE_TEXT ]] || fixture_publish notice "$UI_NOTICE_TEXT"
    fixture_publish draft "$INPUT_BUF"
    fixture_publish transcript "$UI_CONTENTS[1]"
    fixture_publish state "$UI_FOCUS:$UI_DOCUMENT_TAB:${UI_DOCUMENT_SCROLLS[$UI_DOCUMENT_TAB]:-0}:$INPUT_BUF"
  fi
  _fixture_terminal_read "$@"
  if (( UI_ACTIVITY_DEPTH > 0 && ! ${UI_MODAL_ACTIVE:-0} )); then
    ui_activity_input "$ch" "$key" || true
    ch=''; key=''
  fi
}
command stty rows 24 cols 100 < /dev/tty
trap 'ui_end; zcoder_runtime_cleanup' EXIT
ui_append_message user 'Original conversation'
main_tui
ui_end
fixture_publish state done
